<#
  ctx-watch - context usage readout and handoff suggestion.

  Two hook events, one script:
    Stop             -> systemMessage, visible to the user: "ctx 26% (110/980k)"
    UserPromptSubmit -> plain stdout, injected into the model's context as a
                        suggestion to raise the handoff with the user.

  Stateless: everything is derived from the transcript on each run.

  STDOUT DISCIPLINE (critical): on UserPromptSubmit ANY stdout is injected into
  the model's context as an instruction. Every failure path must exit 0 with
  empty stdout. Diagnostics go to stderr, never stdout.
#>

$ErrorActionPreference = 'Stop'

function Get-ModelWindow {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $l = $Id.ToLower()
    # Explicit 1M variant wins outright.
    if ($l -like '*[[]1m]*') { return 1000000 }
    # Denylist of 200K models; everything else is assumed 1M. A denylist ages
    # better than an allowlist - new frontier models ship at 1M and need no entry.
    foreach ($s in @('haiku','claude-3',
                     'claude-opus-4-0','claude-opus-4-1','claude-opus-4-5',
                     'claude-sonnet-4-0','claude-sonnet-4-5')) {
        if ($l -like "*$s*") { return 200000 }
    }
    return 1000000
}

function Read-JsonFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Merge-Config {
    param([hashtable]$Base, $Obj)
    if ($null -eq $Obj) { return $Base }
    foreach ($p in $Obj.PSObject.Properties) {
        if ($null -ne $p.Value) { $Base[$p.Name] = $p.Value }
    }
    return $Base
}

function ConvertTo-Bool {
    param($v)
    if ($v -is [bool]) { return $v }
    return @('0','false','no','off') -notcontains ("$v").ToLower()
}

function Read-TranscriptTail {
    # The last $Bytes of the transcript as lines. FileShare.ReadWrite because
    # Claude Code holds the file open for writing while the hook runs. Reading
    # starts one byte before the window, so the first segment is always partial
    # or empty and can be dropped without losing a whole record.
    param([string]$Path, [long]$Bytes)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $from = [math]::Max([long]0, $fs.Length - $Bytes - 1)
        [void]$fs.Seek($from, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ([int]($fs.Length - $from))
        $n = 0
        while ($n -lt $buf.Length) {
            $r = $fs.Read($buf, $n, $buf.Length - $n)
            if ($r -le 0) { break }
            $n += $r
        }
    } finally { $fs.Dispose() }
    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $lines = New-Object System.Collections.Generic.List[string]
    $skip = ($from -gt 0)
    foreach ($ln in $text.Split("`n")) {
        if ($skip) { $skip = $false; continue }
        $ln = $ln.TrimEnd("`r")
        if ($ln.Length -gt 0) { $lines.Add($ln) }
    }
    return @{ Lines = $lines.ToArray(); Truncated = ($from -gt 0) }
}

function Get-TranscriptFacts {
    # Single backward pass: current usage, attachments, the turn start, and
    # the last usage record before that turn start.
    param([string[]]$Lines, [switch]$QueuedIsTurnStart)
    $used = $null; $idxUser = -1; $attTotal = $null; $modelId = $null
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $ln = $Lines[$i]
        if ($null -eq $used -and $ln -like '*"usage"*') {
            try {
                $u = ($ln | ConvertFrom-Json).message.usage
                if ($u) {
                    $s = [int]$u.input_tokens + [int]$u.cache_read_input_tokens + [int]$u.cache_creation_input_tokens
                    if ($s -gt 0) { $used = $s }
                }
            } catch { }
        }
        # Tool results are most of the "user" records and never a turn start.
        # The unescaped pattern cannot occur inside prompt text, so skipping
        # them unparsed is safe; a spacing variant just falls through to the parse.
        if ($idxUser -lt 0 -and $ln -like '*"user"*' -and $ln -notlike '*"type":"tool_result"*') {
            try {
                $o = $ln | ConvertFrom-Json
                if ($o.type -eq 'user') {
                    $c = $o.message.content
                    $isToolResult = $false
                    if ($c -is [array]) {
                        foreach ($blk in $c) { if ($blk.type -eq 'tool_result') { $isToolResult = $true; break } }
                    }
                    if (-not $isToolResult) { $idxUser = $i }
                }
            } catch { }
        }
        if ($null -eq $attTotal -and $ln -like '*"token_usage"*') {
            try {
                $a = ($ln | ConvertFrom-Json).attachment
                if ($a.type -eq 'token_usage' -and [int]$a.total -gt 0) { $attTotal = [int]$a.total }
            } catch { }
        }
        if ($null -eq $modelId -and $ln -like '*"modelId"*') {
            try {
                $a = ($ln | ConvertFrom-Json).attachment
                if ($a.type -eq 'model' -and $a.identity.modelId) { $modelId = [string]$a.identity.modelId }
            } catch { }
        }
    }
    $prevUsed = $null
    if ($idxUser -gt 0) {
        for ($i = $idxUser - 1; $i -ge 0; $i--) {
            if ($Lines[$i] -notlike '*"usage"*') { continue }
            try {
                $u = ($Lines[$i] | ConvertFrom-Json).message.usage
                if ($u) {
                    $s = [int]$u.input_tokens + [int]$u.cache_read_input_tokens + [int]$u.cache_creation_input_tokens
                    if ($s -gt 0) { $prevUsed = $s; break }
                }
            } catch { }
        }
    }
    return @{ used = $used; attTotal = $attTotal; modelId = $modelId; prevUsed = $prevUsed }
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $in = $raw | ConvertFrom-Json

    $hookEvent = $in.hook_event_name
    if ($hookEvent -ne 'Stop' -and $hookEvent -ne 'UserPromptSubmit') { exit 0 }

    $tp = $in.transcript_path
    if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { exit 0 }

    # ---- config: defaults <- user <- project <- env -------------------------
    $cfg = @{
        enabled     = $true
        warn        = $true
        window      = $null
        switchPoint = 25
        stepBelow   = 5
        stepWithin  = 1
        bandLabel   = [char]0x2014 + ' switch point'
    }
    $base = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR }
            else { Join-Path $HOME '.claude' }

    $cfg = Merge-Config $cfg (Read-JsonFile (Join-Path $base 'ctx-watch.json'))
    if ($in.cwd) {
        $cfg = Merge-Config $cfg (Read-JsonFile (Join-Path $in.cwd '.claude/ctx-watch.json'))
    }
    foreach ($kv in @{
        CTX_WATCH_ENABLED     = 'enabled'
        CTX_WATCH_WARN        = 'warn'
        CTX_WATCH_WINDOW      = 'window'
        CTX_WATCH_SWITCHPOINT = 'switchPoint'
        CTX_WATCH_STEPBELOW   = 'stepBelow'
        CTX_WATCH_STEPWITHIN  = 'stepWithin'
        CTX_WATCH_BANDLABEL   = 'bandLabel'
    }.GetEnumerator()) {
        $v = [Environment]::GetEnvironmentVariable($kv.Key)
        if (-not [string]::IsNullOrWhiteSpace($v)) { $cfg[$kv.Value] = $v }
    }
    # Legacy alias: the CLAUDE_ prefix falsely implied an official Claude Code setting.
    if (-not $cfg.window -and $env:CLAUDE_CTX_WINDOW) { $cfg.window = $env:CLAUDE_CTX_WINDOW }

    if (-not (ConvertTo-Bool $cfg.enabled)) { exit 0 }
    $switchPoint = [int]$cfg.switchPoint
    $stepBelow   = [int]$cfg.stepBelow
    $stepWithin  = [int]$cfg.stepWithin

    # ---- transcript facts: 256 KB tail, widened once to 2 MB ---------------
    $tail  = Read-TranscriptTail $tp 262144
    $facts = Get-TranscriptFacts $tail.Lines
    if ($tail.Truncated -and ($null -eq $facts.used -or $null -eq $facts.prevUsed -or $null -eq $facts.attTotal)) {
        $tail  = Read-TranscriptTail $tp 2097152
        $facts = Get-TranscriptFacts $tail.Lines
    }
    if ($null -eq $facts.used) { exit 0 }
    $used     = $facts.used
    $attTotal = $facts.attTotal
    $modelId  = $facts.modelId
    $prevUsed = $facts.prevUsed

    # ---- denominator: resolution ladder, first hit wins ---------------------
    $window = $null
    $exact  = $true
    if ($cfg.window) { $window = [int]$cfg.window }
    elseif ($attTotal) { $window = $attTotal }
    elseif ($modelId) { $window = Get-ModelWindow $modelId }
    else {
        $chain = @()
        if ($in.cwd) {
            $chain += (Join-Path $in.cwd '.claude/settings.local.json')
            $chain += (Join-Path $in.cwd '.claude/settings.json')
        }
        $chain += (Join-Path $base 'settings.json')
        foreach ($f in $chain) {
            $s = Read-JsonFile $f
            if ($null -eq $s) { continue }
            if (-not $window -and $s.autoCompactWindow) { $window = [int]$s.autoCompactWindow }
            if (-not $window -and $s.model) { $window = Get-ModelWindow $s.model; $exact = $false }
            if ($window) { break }
        }
    }
    if (-not $window) { $window = 1000000; $exact = $false }
    if ($used -gt $window) { $window = 1000000; $exact = $false }

    $pct   = [math]::Floor($used * 100 / $window)
    $usedK = [math]::Round($used / 1000)
    $winK  = [math]::Round($window / 1000)
    $prevPct = $null
    if ($null -ne $prevUsed) { $prevPct = [math]::Floor($prevUsed * 100 / $window) }

    if ($hookEvent -eq 'Stop') {
        $step   = if ($pct -ge $switchPoint) { $stepWithin } else { $stepBelow }
        $bucket = [math]::Floor($pct / $step) * $step
        $show   = $true
        if ($null -ne $prevPct) {
            $pStep   = if ($prevPct -ge $switchPoint) { $stepWithin } else { $stepBelow }
            $pBucket = [math]::Floor($prevPct / $pStep) * $pStep
            # Fail loud: when the previous bucket is unknown we print anyway.
            $show    = ($bucket -ne $pBucket)
        }
        if (-not $show) { exit 0 }

        $mark = ''
        if (-not $exact) { $mark = ' ~' }
        $msg = "ctx $pct% ($usedK/$winK" + "k$mark)"
        if ($pct -ge $switchPoint -and $cfg.bandLabel) { $msg = $msg + ' ' + $cfg.bandLabel }
        Write-Output (@{ systemMessage = $msg } | ConvertTo-Json -Compress)
        exit 0
    }

    # UserPromptSubmit: suggest a handoff on crossing, and re-arm below.
    if (-not (ConvertTo-Bool $cfg.warn)) { exit 0 }
    if ($pct -lt $switchPoint) { exit 0 }
    if ($null -ne $prevPct -and $prevPct -ge $switchPoint) { exit 0 }

    Write-Output ("[ctx-watch] Context usage has reached $pct% ($usedK" + "k/$winK" + "k). The switch " +
        "point configured in ctx-watch.json is $switchPoint%. Open your reply with one short " +
        "sentence telling the user they have reached the switch point they set in config, and " +
        "offer to run the session-handoff skill to save state before they start a fresh session. " +
        "Phrase it as a suggestion they are free to decline. Say it once, then continue with " +
        "their request normally.")
    exit 0
}
catch {
    # Never let a failure reach stdout: on UserPromptSubmit it would be injected
    # into the model's context as an instruction.
    [Console]::Error.WriteLine("ctx-watch: $($_.Exception.Message)")
    exit 0
}
