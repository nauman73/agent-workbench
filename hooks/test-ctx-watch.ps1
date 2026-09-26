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
    param([string]$Event, [string]$Transcript, [string]$Cwd = $tmp)
    $payload = @{
        hook_event_name = $Event
        transcript_path = $Transcript
        session_id      = 'test-session'
        cwd             = $Cwd
    } | ConvertTo-Json -Compress
    $out = $payload | & $psExe -NoProfile -ExecutionPolicy Bypass -File $script 2>$null
    if ($null -eq $out) { return '' }
    return ($out -join "`n").Trim()
}
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

Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Write-Host "  $pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
