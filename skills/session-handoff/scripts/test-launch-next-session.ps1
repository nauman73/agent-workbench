# Tests for launch-next-session.ps1, using -DryRun: nothing is launched.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'launch-next-session.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'launch-next-session-tests'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
$pass = 0; $fail = 0
function Assert-Eq { param($Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name`n        expected: [$Expected]`n        actual:   [$Actual]" -ForegroundColor Red } }

# Fake executables: Get-Command matches by name, so empty files are enough.
$bin = Join-Path $tmp 'bin'; $ext = Join-Path $tmp 'vscode\extensions\anthropic.claude-code-9.9.9\resources\native-binary'
$wtDir = Join-Path $tmp 'wt'; $proj = Join-Path $tmp 'project dir'
foreach ($d in $bin, $ext, $wtDir, $proj) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
foreach ($f in (Join-Path $bin 'claude.exe'), (Join-Path $ext 'claude.exe'), (Join-Path $wtDir 'wt.exe')) { New-Item -ItemType File -Force -Path $f | Out-Null }
$prompt = 'Use the session-handoff skill in RESUME mode on .claude/handoff-x.md and continue per the house rules.'

function Invoke-Launch { param([string]$PathVar, [hashtable]$Env = @{}, [string]$Prompt = $prompt, [string]$Root = $proj)
    # Runs the script in a child process with a controlled PATH and environment.
    # The child first drops any Claude Code variables this harness itself inherited
    # (it may run inside a Claude Code session), so only $Env is in play.
    $reset = "Get-ChildItem Env: | Where-Object { `$_.Name -like 'CLAUDE_CODE_*' -or `$_.Name -eq 'CLAUDECODE' } | ForEach-Object { Remove-Item -LiteralPath ('Env:\' + `$_.Name) };"
    $set = ($Env.GetEnumerator() | ForEach-Object { "`$env:$($_.Key)='$($_.Value)';" }) -join ' '
    $cmd = "$reset $set `$env:PATH='$PathVar'; & '$script' -ProjectRoot '$Root' -Prompt '$Prompt' -DryRun; exit `$LASTEXITCODE"
    # Continue: in Windows PowerShell 5.1 a native command's stderr is an error
    # record, and under Stop it would end this harness before the exit code is read.
    $ErrorActionPreference = 'Continue'
    $out = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>$null
    return @{ Code = $LASTEXITCODE; Out = ($out -join "`n") } }

$sys = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
$r = Invoke-Launch "$ext;$bin;$wtDir;$sys"; $o = $r.Out | ConvertFrom-Json
Assert-Eq 'wt on PATH - uses wt'                         'wt' $o.launcher
Assert-Eq 'skips the extension CLI, takes the standalone' (Join-Path $bin 'claude.exe') $o.claude
Assert-Eq 'project root with a space passed through'     $proj $o.projectRoot
Assert-Eq 'dry run exits 0'                              0 $r.Code
$r = Invoke-Launch "$bin;$sys"; $o = $r.Out | ConvertFrom-Json
Assert-Eq 'no wt - falls back to Start-Process'          'start-process' $o.launcher
$r = Invoke-Launch "$bin;$wtDir;$sys" @{ CLAUDE_CODE_SESSION_ID = 'abc'; CLAUDECODE = '1'; CLAUDE_CODE_ENTRYPOINT = 'cli' }; $o = $r.Out | ConvertFrom-Json
Assert-Eq 'clears CLAUDE_CODE_* and CLAUDECODE'          'CLAUDE_CODE_ENTRYPOINT,CLAUDE_CODE_SESSION_ID,CLAUDECODE' ((@($o.cleared) | Sort-Object) -join ',')
[Environment]::SetEnvironmentVariable('CLAUDE_CODE_LAUNCH_TEST_USERVAR', '1', 'User')
try {
    $r = Invoke-Launch "$bin;$wtDir;$sys" @{ CLAUDE_CODE_LAUNCH_TEST_USERVAR = '1' }; $o = $r.Out | ConvertFrom-Json
    Assert-Eq 'restores a user-scope CLAUDE_CODE_* variable' 'CLAUDE_CODE_LAUNCH_TEST_USERVAR' ((@($o.restored)) -join ',')
} finally { [Environment]::SetEnvironmentVariable('CLAUDE_CODE_LAUNCH_TEST_USERVAR', $null, 'User') }
$r = Invoke-Launch "$ext;$wtDir;$sys"
Assert-Eq 'only the extension CLI - exit 3'              3 $r.Code
$r = Invoke-Launch "$bin;$wtDir;$sys" -Prompt 'a; b'
Assert-Eq 'prompt with ; - exit 2'                       2 $r.Code
$r = Invoke-Launch "$bin;$wtDir;$sys" -Root (Join-Path $tmp 'missing')
Assert-Eq 'missing project root - exit 2'                2 $r.Code

Write-Host "`n  $pass passed, $fail failed" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
