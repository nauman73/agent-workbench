# Test harness for ctx-watch.ps1. Fabricates transcripts and synthetic hook
# payloads, asserts stdout. Nothing here touches the live setup.

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
# The script under test is the SIBLING of this file. That is deliberate: this
# harness is synced from ~/.claude/hooks/ alongside ctx-watch.ps1, so running
# the live copy tests the live script and running the repo copy tests the repo
# script, with no path juggling either way.
$script = Join-Path $here 'ctx-watch.ps1'
# Which PowerShell runs the script under test. On Windows that is the same
# powershell.exe the launcher uses in production, so the tests match reality
# there; everywhere else only pwsh exists. $IsWindows is absent in Windows
# PowerShell 5.1, hence the $env:OS fallback.
$psExe  = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'powershell.exe' } else { 'pwsh' }
# Scratch data goes to TEMP, never into the repo working tree.
$tmp    = Join-Path ([System.IO.Path]::GetTempPath()) 'ctx-watch-tests'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Isolate from the real ~/.claude so tests never read live config.
$fakeCfgDir = Join-Path $tmp 'cfgdir'
New-Item -ItemType Directory -Force -Path $fakeCfgDir | Out-Null
$env:CLAUDE_CONFIG_DIR = $fakeCfgDir

$pass = 0; $fail = 0
function Assert-Eq {
    param($Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else {
        $script:fail++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        expected: [$Expected]"
        Write-Host "        actual:   [$Actual]"
    }
}

# ---- transcript fabrication -------------------------------------------------
function New-Usage {
    param([int]$Used)
    # Split across the three fields the numerator sums, to prove the sum works.
    $inp = 2
    $read = [math]::Floor(($Used - $inp) * 0.9)
    $crea = $Used - $inp - $read
    $u = @{ input_tokens = $inp; cache_read_input_tokens = $read; cache_creation_input_tokens = $crea }
    (@{ type = 'assistant'; message = @{ model = 'claude-opus-5'; usage = $u } } | ConvertTo-Json -Compress -Depth 10)
}
function New-RealUser   { (@{ type = 'user'; message = @{ role = 'user'; content = 'hello' } } | ConvertTo-Json -Compress -Depth 10) }
function New-ToolResult { (@{ type = 'user'; message = @{ role = 'user'; content = @(@{ type = 'tool_result'; content = 'ok' }) } } | ConvertTo-Json -Compress -Depth 10) }
function New-AttTokenUsage { param([int]$Total) (@{ type = 'attachment'; attachment = @{ type = 'token_usage'; used = 1; total = $Total; remaining = 1 } } | ConvertTo-Json -Compress -Depth 10) }
function New-AttModel      { param([string]$Id)  (@{ type = 'attachment'; attachment = @{ type = 'model'; identity = @{ modelId = $Id } } } | ConvertTo-Json -Compress -Depth 10) }
# Assistant text record of about $Size bytes. No "usage" and no "user" in it,
# so the hook's -like filters skip it, as they skip real prose records.
function New-Filler {
    param([int]$Count, [int]$Size = 1000)
    $line = (@{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = ('x' * $Size) }) } } | ConvertTo-Json -Compress -Depth 10)
    return @(1..$Count | ForEach-Object { $line })
}
function Write-Lines {
    # Writes UTF-8 WITHOUT a BOM, so a test controls whether a BOM is present.
    param([string]$Name, [string[]]$Lines, [switch]$Bom)
    $p = Join-Path $tmp "$Name.jsonl"
    $enc = New-Object System.Text.UTF8Encoding($Bom.IsPresent)
    [System.IO.File]::WriteAllText($p, (($Lines -join "`n") + "`n"), $enc)
    return $p
}

function New-Transcript {
    # Builds: [extra lines] prevUsage, realUser, currUsage
    param([string]$Name, [int]$PrevUsed, [int]$CurrUsed, [string[]]$Prefix = @(), [switch]$NoUserTurn)
    $p = Join-Path $tmp "$Name.jsonl"
    $l = @()
    $l += $Prefix
    if ($PrevUsed -gt 0) { $l += New-Usage $PrevUsed }
    if (-not $NoUserTurn) { $l += New-RealUser }
    $l += New-ToolResult          # noise: must not be mistaken for a user turn
    $l += New-Usage $CurrUsed
    Set-Content -LiteralPath $p -Value $l -Encoding UTF8
    return $p
}

function Invoke-Hook {
    param([string]$Event, [string]$Transcript, [string]$Cwd = $tmp, [hashtable]$Extra = @{})
    $payload = @{
        hook_event_name = $Event
        transcript_path = $Transcript
        session_id      = 'test-session'
        cwd             = $Cwd
    }
    foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] }
    $json = $payload | ConvertTo-Json -Compress -Depth 6
    $out = $json | & $psExe -NoProfile -ExecutionPolicy Bypass -File $script 2>$null
    if ($null -eq $out) { return '' }
    return ($out -join "`n").Trim()
}
function Get-Decision {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return '' }
    try { $o = $Json | ConvertFrom-Json; if ($o.decision) { return [string]$o.decision } else { return '' } }
    catch { return "<not json: $Json>" }
}
# Shape as recorded by Claude Code 2.1.289 when a queued message is delivered mid-turn.
function New-Queued { (@{ type = 'attachment'; attachment = @{ type = 'queued_command'; prompt = 'more'; commandMode = 'prompt' } } | ConvertTo-Json -Compress -Depth 10) }
function Get-SysMsg {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return '' }
    try { return ($Json | ConvertFrom-Json).systemMessage } catch { return "<not json: $Json>" }
}
# Strip the band label so ladder tests assert only on the number. A regex like
# ' .*switch point' is greedy and eats the whole line - use a literal replace.
$bandSuffix = ' ' + [char]0x2014 + ' switch point'
function Remove-Band { param([string]$s) return $s.Replace($bandSuffix, '') }

Write-Host "`n=== 1. Numerator and percentage ===" -ForegroundColor Cyan
# 260000 / 980000 = 26.53% -> 26
$t = New-Transcript -Name 'basic' -PrevUsed 200000 -CurrUsed 260000 -Prefix @(New-AttTokenUsage 980000)
Assert-Eq 'sums the three usage fields; exact denominator from attachment' `
    'ctx 26% (260/980k) - switch point' `
    ((Get-SysMsg (Invoke-Hook 'Stop' $t)) -replace [char]0x2014, '-')

Write-Host "`n=== 2. Ladder ===" -ForegroundColor Cyan
# Rung 2: attachment total wins over model attachment
$t = New-Transcript -Name 'rung2' -PrevUsed 100000 -CurrUsed 260000 -Prefix @((New-AttModel 'claude-opus-5[1m]'), (New-AttTokenUsage 980000))
Assert-Eq 'rung 2 - token_usage attachment beats model attachment' `
    'ctx 26% (260/980k)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $t)))

# Rung 3: model attachment with [1m]
$t = New-Transcript -Name 'rung3' -PrevUsed 100000 -CurrUsed 260000 -Prefix @(New-AttModel 'claude-opus-5[1m]')
Assert-Eq 'rung 3 - [1m] suffix resolves to 1M, exact (no tilde)' `
    'ctx 26% (260/1000k)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $t)))

# Rung 3: 200K denylist model
$t = New-Transcript -Name 'rung3b' -PrevUsed 10000 -CurrUsed 60000 -Prefix @(New-AttModel 'claude-sonnet-4-5')
Assert-Eq 'rung 3 - denylisted model resolves to 200K' `
    'ctx 30% (60/200k)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $t)))

# Rung 4: autoCompactWindow from the settings chain
Set-Content -LiteralPath (Join-Path $fakeCfgDir 'settings.json') -Value '{"autoCompactWindow": 500000}' -Encoding UTF8
$t = New-Transcript -Name 'rung4' -PrevUsed 10000 -CurrUsed 200000
Assert-Eq 'rung 4 - autoCompactWindow, exact (no tilde)' `
    'ctx 40% (200/500k)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $t)))

# Rung 5: settings model pin -> estimate
Set-Content -LiteralPath (Join-Path $fakeCfgDir 'settings.json') -Value '{"model": "claude-opus-4-5"}' -Encoding UTF8
$t = New-Transcript -Name 'rung5' -PrevUsed 10000 -CurrUsed 60000
Assert-Eq 'rung 5 - model pin is an estimate, marked with tilde' `
    'ctx 30% (60/200k ~)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $t)))

# Rung 6: used > window promotes to 1M and marks estimate
$t = New-Transcript -Name 'rung6' -PrevUsed 10000 -CurrUsed 300000
Assert-Eq 'rung 6 - used above window promotes to 1M, marked estimate' `
    'ctx 30% (300/1000k ~)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $t)))
Remove-Item (Join-Path $fakeCfgDir 'settings.json') -Force

# Rung 1: env override beats everything
$t = New-Transcript -Name 'rung1' -PrevUsed 100000 -CurrUsed 260000 -Prefix @(New-AttTokenUsage 980000)
$env:CTX_WATCH_WINDOW = '1300000'
Assert-Eq 'rung 1 - CTX_WATCH_WINDOW overrides the attachment' `
    'ctx 20% (260/1300k)' (Get-SysMsg (Invoke-Hook 'Stop' $t))
Remove-Item Env:\CTX_WATCH_WINDOW
$env:CLAUDE_CTX_WINDOW = '1300000'
Assert-Eq 'rung 1 - legacy CLAUDE_CTX_WINDOW alias still honoured' `
    'ctx 20% (260/1300k)' (Get-SysMsg (Invoke-Hook 'Stop' $t))
Remove-Item Env:\CLAUDE_CTX_WINDOW

Write-Host "`n=== 3. Stepping ===" -ForegroundColor Cyan
# Below the band: 5% steps. 10% -> 14% is the same bucket, so silent.
$t = New-Transcript -Name 'step-same' -PrevUsed 100000 -CurrUsed 140000 -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 'below band - same 5% bucket stays silent' '' (Invoke-Hook 'Stop' $t)
# 10% -> 15% crosses a 5% boundary, so prints.
$t = New-Transcript -Name 'step-cross' -PrevUsed 100000 -CurrUsed 150000 -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 'below band - crossing a 5% boundary prints' 'ctx 15% (150/1000k)' (Get-SysMsg (Invoke-Hook 'Stop' $t))
# Inside the band: 1% steps, so 26% -> 27% prints.
$t = New-Transcript -Name 'step-within' -PrevUsed 260000 -CurrUsed 270000 -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 'in band - 1% step prints' `
    'ctx 27% (270/1000k) - switch point' `
    ((Get-SysMsg (Invoke-Hook 'Stop' $t)) -replace [char]0x2014, '-')

Write-Host "`n=== 4. Fail loud ===" -ForegroundColor Cyan
$t = New-Transcript -Name 'noprev' -PrevUsed 0 -CurrUsed 140000 -NoUserTurn -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 'no previous turn - prints rather than staying silent' 'ctx 14% (140/1000k)' (Get-SysMsg (Invoke-Hook 'Stop' $t))

Write-Host "`n=== 5. Real-user vs tool-result discrimination ===" -ForegroundColor Cyan
# Many tool_result turns between the two usage records. If tool_results were
# mistaken for user turns, prevUsed would resolve to the wrong record and the
# 20%->26% crossing would be missed.
$l = @((New-AttTokenUsage 1000000), (New-Usage 200000), (New-RealUser))
1..10 | ForEach-Object { $l += New-ToolResult; $l += New-Usage (200000 + $_ * 6000) }
$p = Join-Path $tmp 'noise.jsonl'
Set-Content -LiteralPath $p -Value $l -Encoding UTF8
Assert-Eq 'tool_result turns are not mistaken for user turns' `
    'ctx 26% (260/1000k) - switch point' `
    ((Get-SysMsg (Invoke-Hook 'Stop' $p)) -replace [char]0x2014, '-')

Write-Host "`n=== 6. UserPromptSubmit warning ===" -ForegroundColor Cyan
$t = New-Transcript -Name 'warn-cross' -PrevUsed 240000 -CurrUsed 260000 -Prefix @(New-AttTokenUsage 1000000)
$w = Invoke-Hook 'UserPromptSubmit' $t
Assert-Eq 'crossing the switch point emits a warning' $true ($w -like '*reached 26%*')
Assert-Eq 'warning names the configured switch point' $true ($w -like '*is 25%*')
Assert-Eq 'warning names the session-handoff skill' $true ($w -like '*session-handoff*')
Assert-Eq 'warning is plain text, not JSON' $false ($w -like '{*')

$t = New-Transcript -Name 'warn-below' -PrevUsed 100000 -CurrUsed 200000 -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 'below the switch point stays silent' '' (Invoke-Hook 'UserPromptSubmit' $t)

$t = New-Transcript -Name 'warn-already' -PrevUsed 260000 -CurrUsed 270000 -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 'already above the switch point does not nag again' '' (Invoke-Hook 'UserPromptSubmit' $t)

# Re-arm: dropped below (compaction), then back up across the line.
$t = New-Transcript -Name 'warn-rearm' -PrevUsed 80000 -CurrUsed 260000 -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 're-arms after dropping below and crossing again' $true ((Invoke-Hook 'UserPromptSubmit' $t) -like '*reached 26%*')

# Fail loud on the warning branch too.
$t = New-Transcript -Name 'warn-noprev' -PrevUsed 0 -CurrUsed 260000 -NoUserTurn -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 'no previous turn above the point - warns rather than staying silent' $true ((Invoke-Hook 'UserPromptSubmit' $t) -like '*reached 26%*')

Write-Host "`n=== 7. Config ===" -ForegroundColor Cyan
Set-Content -LiteralPath (Join-Path $fakeCfgDir 'ctx-watch.json') -Value '{"switchPoint": 40}' -Encoding UTF8
# 15% -> 26%, so it crosses a switchPoint of 20 but not one of 40 or 50. A
# 24% -> 26% transcript would sit above 20 on BOTH turns, and the "already
# above, don't nag" rule would suppress the project-config case for the wrong
# reason.
$t = New-Transcript -Name 'cfg-user' -PrevUsed 150000 -CurrUsed 260000 -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 'user config raises the switch point - no warning at 26%' '' (Invoke-Hook 'UserPromptSubmit' $t)

# Project config overrides user config.
$projDir = Join-Path $tmp 'proj/.claude'
New-Item -ItemType Directory -Force -Path $projDir | Out-Null
Set-Content -LiteralPath (Join-Path $projDir 'ctx-watch.json') -Value '{"switchPoint": 20}' -Encoding UTF8
Assert-Eq 'project config overrides user config' $true `
    ((Invoke-Hook 'UserPromptSubmit' $t (Join-Path $tmp 'proj')) -like '*is 20%*')

# Env beats both.
$env:CTX_WATCH_SWITCHPOINT = '50'
Assert-Eq 'env beats project and user config' '' (Invoke-Hook 'UserPromptSubmit' $t (Join-Path $tmp 'proj'))
Remove-Item Env:\CTX_WATCH_SWITCHPOINT

# Kill switches.
$env:CTX_WATCH_WARN = 'false'
Assert-Eq 'warn=false silences the suggestion' '' (Invoke-Hook 'UserPromptSubmit' $t (Join-Path $tmp 'proj'))
Remove-Item Env:\CTX_WATCH_WARN
$env:CTX_WATCH_ENABLED = 'false'
Assert-Eq 'enabled=false silences the readout too' '' (Invoke-Hook 'Stop' $t (Join-Path $tmp 'proj'))
Remove-Item Env:\CTX_WATCH_ENABLED
Remove-Item (Join-Path $fakeCfgDir 'ctx-watch.json') -Force

Write-Host "`n=== 8. Zero-config and safety ===" -ForegroundColor Cyan
$t = New-Transcript -Name 'zeroconf' -PrevUsed 240000 -CurrUsed 260000 -Prefix @(New-AttTokenUsage 1000000)
Assert-Eq 'works with no config file at all' 'ctx 26% (260/1000k)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $t)))

Assert-Eq 'missing transcript - silent, empty stdout' '' (Invoke-Hook 'Stop' (Join-Path $tmp 'nope.jsonl'))
Assert-Eq 'missing transcript on UserPromptSubmit - empty stdout' '' (Invoke-Hook 'UserPromptSubmit' (Join-Path $tmp 'nope.jsonl'))

$garbage = Join-Path $tmp 'garbage.jsonl'
Set-Content -LiteralPath $garbage -Value @('not json at all','{"broken":', '}{') -Encoding UTF8
Assert-Eq 'unparsable transcript - empty stdout, no crash' '' (Invoke-Hook 'UserPromptSubmit' $garbage)

$empty = Join-Path $tmp 'empty.jsonl'
Set-Content -LiteralPath $empty -Value '' -Encoding UTF8
Assert-Eq 'empty transcript - empty stdout' '' (Invoke-Hook 'UserPromptSubmit' $empty)

$out = '' | & $psExe -NoProfile -ExecutionPolicy Bypass -File $script 2>$null
Assert-Eq 'empty stdin - empty stdout' '' (("$out").Trim())

$out = '{"hook_event_name":"PreToolUse","transcript_path":"x"}' | & $psExe -NoProfile -ExecutionPolicy Bypass -File $script 2>$null
Assert-Eq 'unknown hook event - empty stdout' '' (("$out").Trim())

Write-Host "`n=== 9. Stdout discipline ===" -ForegroundColor Cyan
$t = New-Transcript -Name 'discipline' -PrevUsed 240000 -CurrUsed 260000 -Prefix @(New-AttTokenUsage 1000000)
$s = Invoke-Hook 'Stop' $t
Assert-Eq 'Stop branch emits JSON only' $true ($s.StartsWith('{') -and $s.EndsWith('}'))
$u = Invoke-Hook 'UserPromptSubmit' $t
Assert-Eq 'UserPromptSubmit branch never emits JSON' $false ($u.StartsWith('{'))
Assert-Eq 'UserPromptSubmit output is a single line' 1 (@($u -split "`n").Count)

Write-Host "`n=== 10. Tail read ===" -ForegroundColor Cyan
# Previous usage beyond 256 KB and beyond 400 lines: 600 x 1 KB of filler.
# 26.0% -> 26.05% is the same 1% bucket, so a found previous means silence.
$l = @((New-AttTokenUsage 1000000), (New-Usage 260000), (New-RealUser)) + (New-Filler 600) + @((New-Usage 260500))
$p = Write-Lines 'wide-prev' $l
Assert-Eq 'widening finds a previous usage record beyond 256 KB' '' (Invoke-Hook 'Stop' $p)

# token_usage attachment 300 KB back: exact denominator still found.
$l = @((New-AttTokenUsage 980000)) + (New-Filler 300) + @((New-Usage 200000), (New-RealUser), (New-Usage 260000))
$p = Write-Lines 'wide-att' $l
Assert-Eq 'widening finds the token_usage attachment beyond 256 KB' `
    'ctx 26% (260/980k)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $p)))

# BOM at the start, attachment on the first line, file under 256 KB.
$l = @((New-AttTokenUsage 980000), (New-Usage 200000), (New-RealUser), (New-Usage 260000))
$p = Write-Lines 'bom' $l -Bom
Assert-Eq 'BOM file - first record still parsed' `
    'ctx 26% (260/980k)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $p)))

# Boundary cut: size the filler so the 256 KB window starts exactly at a line start.
$tailLines = @((New-Usage 200000), (New-RealUser), (New-Usage 260000))
$tailBytes = [System.Text.Encoding]::UTF8.GetByteCount((($tailLines -join "`n") + "`n"))
# @() because a one-element array returned from a function unrolls to a string.
$fillBytes = [System.Text.Encoding]::UTF8.GetByteCount(@(New-Filler 1 -Size 1000)[0] + "`n")
$overhead  = $fillBytes - 1000                    # JSON wrapper + newline around the text
$room = 262144 - $tailBytes                       # bytes the window holds before the tail lines
$n    = [math]::Floor($room / $fillBytes)
$odd  = $room - $n * $fillBytes                   # one odd-sized line takes up the rest
if ($odd -le $overhead) { $odd += $fillBytes; $n -= 1 }
$l = @((New-AttTokenUsage 1000000)) + (New-Filler 400) + (New-Filler 1 -Size ($odd - $overhead)) + (New-Filler $n) + $tailLines
$p = Write-Lines 'boundary' $l
$bytes = [System.IO.File]::ReadAllBytes($p)
# Self-check: the window's first byte must be the start of the odd line.
Assert-Eq 'fixture: byte before the window is a newline' 10 $bytes[$bytes.Length - 262144 - 1]
Assert-Eq 'window starting on a line boundary keeps that line' `
    'ctx 26% (260/1000k)' (Remove-Band (Get-SysMsg (Invoke-Hook 'Stop' $p)))

# File held open for writing by another handle, as Claude Code does.
$t = New-Transcript -Name 'locked' -PrevUsed 200000 -CurrUsed 260000 -Prefix @(New-AttTokenUsage 1000000)
$h = [System.IO.File]::Open($t, 'Open', 'ReadWrite', 'ReadWrite')
try { $s = Invoke-Hook 'Stop' $t } finally { $h.Dispose() }
Assert-Eq 'reads a transcript another handle holds open for writing' 'ctx 26% (260/1000k)' (Remove-Band (Get-SysMsg $s))

Write-Host "`n=== 11. Stop block ===" -ForegroundColor Cyan
function T { param($n, $prev, $curr, [switch]$NoUser, [string[]]$Mid = @())
    $p = Join-Path $tmp "$n.jsonl"
    $l = @((New-AttTokenUsage 1000000))
    if ($prev -gt 0) { $l += New-Usage $prev }
    if (-not $NoUser) { $l += New-RealUser }
    $l += $Mid; $l += New-ToolResult; $l += New-Usage $curr
    Set-Content -LiteralPath $p -Value $l -Encoding UTF8; return $p }

Assert-Eq 'block off by default - no decision at the crossing' '' (Get-Decision (Invoke-Hook 'Stop' (T 'b-off' 240000 260000)))

$env:CTX_WATCH_BLOCK = 'true'
Assert-Eq 'below the switch point - no block' '' (Get-Decision (Invoke-Hook 'Stop' (T 'b-below' 100000 200000)))
Assert-Eq 'entering 25 blocks'  'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-25' 240000 260000)))
Assert-Eq 'entering 30 blocks'  'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-30' 270000 310000)))
Assert-Eq 'entering 35 blocks'  'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-35' 340000 355000)))
Assert-Eq 'jumping two bands blocks once' 'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-jump' 260000 360000)))
Assert-Eq 'within a band - no block' '' (Get-Decision (Invoke-Hook 'Stop' (T 'b-within' 260000 290000)))
Assert-Eq 'drop after compaction - no block' '' (Get-Decision (Invoke-Hook 'Stop' (T 'b-drop' 400000 260000)))
Assert-Eq 'climb back over the switch point - blocks again' 'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-reclimb' 100000 260000)))

# Bands counted from the switch point
$env:CTX_WATCH_SWITCHPOINT = '22'
Assert-Eq 'switch 22: 23 -> 26 is band 22 -> 22, no block' '' (Get-Decision (Invoke-Hook 'Stop' (T 'b-22a' 230000 260000)))
Assert-Eq 'switch 22: 26 -> 27 enters band 27, blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-22b' 260000 275000)))
Remove-Item Env:\CTX_WATCH_SWITCHPOINT

# Invalid blockStep falls back to 5 and still prints
$env:CTX_WATCH_BLOCKSTEP = '0'
Assert-Eq 'invalid blockStep - falls back to 5, blocks at 25' 'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-step0' 240000 260000)))
Assert-Eq 'invalid blockStep - within band still prints the readout' $true ((Invoke-Hook 'Stop' (T 'b-step0b' 260000 290000)) -like '*ctx 29%*')
Remove-Item Env:\CTX_WATCH_BLOCKSTEP

# Guards
$t = T 'b-guard' 240000 260000
Assert-Eq 'stop_hook_active true - no block' '' (Get-Decision (Invoke-Hook 'Stop' $t -Extra @{ stop_hook_active = $true }))
Assert-Eq 'stop_hook_active true - readout still printed' $true ((Invoke-Hook 'Stop' $t -Extra @{ stop_hook_active = $true }) -like '*ctx 26%*')
Assert-Eq 'stop_hook_active false - blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' $t -Extra @{ stop_hook_active = $false }))
Assert-Eq 'absent stop_hook_active - blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' $t))
# Background work does not hold the block back: the reason says to hand over once it is done (D-008).
Assert-Eq 'background_tasks array non-empty - blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' $t -Extra @{ background_tasks = @(@{ id = 'b1'; type = 'shell' }) }))
Assert-Eq 'background_tasks count 1 - blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' $t -Extra @{ background_tasks = @{ count = 1; running = @(@{ id = 'b1' }) } }))
Assert-Eq 'background_tasks empty array - blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' $t -Extra @{ background_tasks = @() }))
Assert-Eq 'background_tasks count 0, running empty - blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' $t -Extra @{ background_tasks = @{ count = 0; running = @() } }))

# Queued messages are mid-turn: Stop ignores them. 24% -> 25.5% -> queued -> 26%.
$t = T 'b-queued' 240000 260000 -Mid @((New-ToolResult), (New-Usage 255000), (New-Queued))
Assert-Eq 'queued message mid-turn - crossing earlier in the turn still blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' $t))

# Previous unknown: block above the switch point, nothing extra below it
Assert-Eq 'previous unknown above the switch point - blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-unk' 0 260000 -NoUser)))
Assert-Eq 'previous unknown below the switch point - no block' '' (Get-Decision (Invoke-Hook 'Stop' (T 'b-unk2' 0 140000 -NoUser)))

# Output shape
$s = Invoke-Hook 'Stop' (T 'b-shape' 240000 260000)
$o = $s | ConvertFrom-Json
Assert-Eq 'block output is one line of JSON' 1 (@($s -split "`n").Count)
Assert-Eq 'block output has exactly decision, reason, systemMessage' 'decision,reason,systemMessage' ((($o.PSObject.Properties.Name) | Sort-Object) -join ',')
Assert-Eq 'reason names the percentage and the switch point' $true ($o.reason -like '*usage is 26% (260k/1000k), past the switch point of 25%*')
Assert-Eq 'reason defers the hand-over until the step, background work included, is done' $true ($o.reason -like '*once the current step is complete, including any background work it started*')
Assert-Eq 'reason says to end the turn to wait for running work' $true ($o.reason -like '*end this turn to wait for it*')
Assert-Eq 'reason: with nothing running, act before the turn ends (D-003)' $true ($o.reason -like '*handled; otherwise act before you end this turn.*')
$acct = [Environment]::UserName
Assert-Eq 'reason names no person' $false ([bool]$acct -and $o.reason.ToLower().Contains($acct.ToLower()))
Assert-Eq 'systemMessage carries the readout' $true ($o.systemMessage -like 'ctx 26% (260/1000k)*')

# Config file path, and enabled false wins
Set-Content -LiteralPath (Join-Path $fakeCfgDir 'ctx-watch.json') -Value '{"block": false}' -Encoding UTF8
Assert-Eq 'env CTX_WATCH_BLOCK beats the config file' 'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-cfg' 240000 260000)))
Remove-Item Env:\CTX_WATCH_BLOCK
Set-Content -LiteralPath (Join-Path $fakeCfgDir 'ctx-watch.json') -Value '{"block": true}' -Encoding UTF8
Assert-Eq 'config file block true - blocks' 'block' (Get-Decision (Invoke-Hook 'Stop' (T 'b-cfg2' 240000 260000)))
$env:CTX_WATCH_ENABLED = 'false'
Assert-Eq 'enabled false - no output at all' '' (Invoke-Hook 'Stop' (T 'b-dis' 240000 260000))
Remove-Item Env:\CTX_WATCH_ENABLED
Remove-Item (Join-Path $fakeCfgDir 'ctx-watch.json') -Force

Write-Host "`n=== 12. Prompt note ===" -ForegroundColor Cyan
# A queued message after the note already fired this turn: silent.
$t = T 'n-queued' 240000 262000 -Mid @((New-ToolResult), (New-Usage 255000), (New-Queued))
Assert-Eq 'queued message after a crossing earlier in the turn - note not repeated' '' (Invoke-Hook 'UserPromptSubmit' $t)
Assert-Eq 'crossing without a queued message - note fires' $true ((Invoke-Hook 'UserPromptSubmit' (T 'n-plain' 240000 260000)) -like '*reached 26%*')
$env:CTX_WATCH_BLOCK = 'true'
Assert-Eq 'block on - note suppressed' '' (Invoke-Hook 'UserPromptSubmit' (T 'n-supp' 240000 260000))
Remove-Item Env:\CTX_WATCH_BLOCK

Write-Host "`n=== 13. Timing ===" -ForegroundColor Cyan
# ~1.4 MB: 140 blocks of 9 x 1 KB filler + tool_result + usage.
$l = @((New-AttTokenUsage 1000000), (New-Usage 200000), (New-RealUser))
1..140 | ForEach-Object { $l += New-Filler 9; $l += New-ToolResult; $l += New-Usage (200000 + $_ * 400) }
$p = Write-Lines 'timing' $l
$best = (1..3 | ForEach-Object { (Measure-Command { Invoke-Hook 'Stop' $p | Out-Null }).TotalMilliseconds } | Measure-Object -Minimum).Minimum
Write-Host "        best of 3: $([math]::Round($best)) ms, file $([math]::Round((Get-Item $p).Length / 1MB, 2)) MB"
Assert-Eq 'full Stop run on a 1.4 MB transcript under 500 ms' $true ($best -lt 500)

Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Write-Host "  $pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
