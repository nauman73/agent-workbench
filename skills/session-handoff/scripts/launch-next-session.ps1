<#
.SYNOPSIS
    Start the next session of a session chain (session-handoff skill).

.DESCRIPTION
    Clears the session variables inherited from the calling Claude Code session
    (otherwise the new session is treated as its child, with transcript saving
    off), restores any CLAUDE_CODE_* variable the user set at User or Machine
    scope, finds the standalone claude CLI, and opens it in the project folder:
    a Windows Terminal tab when wt.exe is on PATH, else a console window.
    Off Windows nothing is launched: the command is printed and the exit code
    is 3, so the skill reports that the chain paused.

.PARAMETER ProjectRoot
    Folder the next session starts in.

.PARAMETER Prompt
    First prompt of the next session. Must not contain ';' (Windows Terminal's
    command separator) or '"'.

.PARAMETER DryRun
    Print what would be done as one JSON object, and launch nothing.
#>
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
function Fail { param([int]$Code, [string]$Msg) [Console]::Error.WriteLine("launch-next-session: $Msg"); exit $Code }

if ($Prompt.Contains(';') -or $Prompt.Contains('"')) { Fail 2 'the prompt must not contain ; or "' }
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { Fail 2 "no such folder: $ProjectRoot" }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath.TrimEnd('\', '/')

# 1. Environment: drop the parent session's variables, keep the user's own.
$cleared = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_CODE_*' -or $_.Name -eq 'CLAUDECODE' } |
    ForEach-Object { $_.Name })
foreach ($n in $cleared) { Remove-Item -LiteralPath "Env:\$n" }
$restored = @()
$onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
if ($onWindows) {
    foreach ($scope in 'Machine', 'User') {
        $vars = [Environment]::GetEnvironmentVariables($scope)
        foreach ($k in @($vars.Keys)) {
            if ($k -like 'CLAUDE_CODE_*') { Set-Item -LiteralPath "Env:\$k" -Value $vars[$k]; if ($restored -notcontains $k) { $restored += $k } }
        }
    }
}
$env:CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = '1'

# 2. The standalone CLI, never a copy bundled inside an editor extension.
$claude = Get-Command claude -CommandType Application -All -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -notmatch '[\\/]extensions[\\/]' } | Select-Object -First 1
$wt = if ($onWindows) { Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
$launcher = if (-not $onWindows -or -not $claude) { 'none' } elseif ($wt) { 'wt' } else { 'start-process' }

if ($DryRun) {
    Write-Output (@{ launcher = $launcher; claude = $(if ($claude) { $claude.Source } else { $null })
        projectRoot = $ProjectRoot; prompt = $Prompt; cleared = $cleared; restored = $restored } | ConvertTo-Json -Compress)
    if ($launcher -eq 'none') { exit 3 } else { exit 0 }
}

# 3. Launch.
switch ($launcher) {
    'wt'            { & $wt.Source -w 0 new-tab -d $ProjectRoot $claude.Source $Prompt }
    'start-process' { Start-Process -FilePath $claude.Source -ArgumentList ('"' + $Prompt + '"') -WorkingDirectory $ProjectRoot }
    default {
        Write-Output "cd `"$ProjectRoot`" && claude `"$Prompt`""
        if (-not $claude) { Fail 3 'no standalone claude CLI on PATH' }
        Fail 3 'automatic launch is Windows-only; start the next session with the command above'
    }
}
exit 0
