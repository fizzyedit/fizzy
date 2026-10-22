# Checks the pure parts of scripts/runner-setup.ps1 through -DryRun, as test-runner-setup.sh does
# for the Ubuntu script. Needs pwsh and a POSIX or Windows host; skips cleanly without pwsh.
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh) { Write-Host 'skip: pwsh not installed'; exit 0 }
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('runner-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
function Fail($m) { Write-Host "FAIL: $m"; Remove-Item -Recurse -Force $tmp; exit 1 }
# Fake gh on PATH: `gh auth` succeeds, `gh api` prints the contents of the private file.
if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    Set-Content "$tmp\gh.cmd" "@echo off`r`nif `"%1`"==`"auth`" exit /b 0`r`necho %2> `"$tmp\asked`"`r`ntype `"$tmp\private`""
} else {
    Set-Content "$tmp/gh" "#!/bin/sh`n[ `"`$1`" = auth ] && exit 0`necho `"`$2`" >'$tmp/asked'`ncat '$tmp/private'"
    chmod +x "$tmp/gh"
}
$sep = [IO.Path]::PathSeparator
function Setup($extraEnv) {
    $env:PATH = "$tmp$sep$script:origPath"
    foreach ($k in $extraEnv.Keys) { Set-Item "Env:$k" $extraEnv[$k] }
    $out = & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File "$dir/runner-setup.ps1" -DryRun 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($k in $extraEnv.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    return @{ Out = $out; Code = $code }
}
$origPath = $env:PATH

Set-Content "$tmp/private" 'true'
$r = Setup @{}
if ($r.Code -ne 0) { Fail "private default refused: $($r.Out)" }
if ((Get-Content "$tmp/asked").Trim() -ne 'repos/fizzyedit/work') { Fail 'default is not fizzyedit/work' }
if ($r.Out -notmatch 'Dry run complete') { Fail "no completion line: $($r.Out)" }

Set-Content "$tmp/private" 'false'
$r = Setup @{}
if ($r.Code -eq 0) { Fail 'public repo accepted' }
if ($r.Out -notmatch 'Refusing') { Fail "no refusal line: $($r.Out)" }

Set-Content "$tmp/private" 'true'
$r = Setup @{ RUNNER_URL = 'https://github.com/fizzyedit' }
if ($r.Code -eq 0) { Fail 'org URL accepted' }

# Token and password never appear in the dry-run output.
$r = Setup @{ RUNNER_TOKEN = 'SECRET-TOKEN-VALUE' }
if ($r.Out -match 'SECRET-TOKEN-VALUE') { Fail 'token echoed' }

# A failing gh stub is an unverifiable repo: a dry run says so and goes on (it must not need a gh
# login); a real run refuses (not testable off Windows). The override is reported.
if ($IsWindows -or $env:OS -eq 'Windows_NT') { Set-Content "$tmp\gh.cmd" "@exit /b 1" } else { Set-Content "$tmp/gh" "#!/bin/sh`nexit 1" }
$r = Setup @{}
if ($r.Code -ne 0) { Fail "dry run needs a gh login: $($r.Out)" }
if ($r.Out -notmatch 'a real run would refuse') { Fail "unverifiable repo not reported: $($r.Out)" }
$r = Setup @{ FIZZY_RUNNER_ALLOW_UNCHECKED = '1' }
if ($r.Code -ne 0) { Fail "override refused: $($r.Out)" }
if ($r.Out -notmatch 'skip the private-repo check') { Fail 'override not reported' }

# Static checks: pwsh parses these files, so the Windows PowerShell 5.1 rules are enforced here.
# (a) no pwsh-7-only syntax or parameter names (a denylist: only known-bad names fail);
# (b) for the module cmdlets below, whose full parameter lists are written out, every named
# parameter must exist in Windows PowerShell 5.1. A dry run under pwsh 7 cannot catch either, and a wrong parameter only fails on
# the Windows box (-UserCannotChangePassword did). Add a cmdlet here when a script starts using it.
$common = 'ErrorAction', 'ErrorVariable', 'WarningAction', 'Verbose', 'Debug', 'OutVariable', 'InformationAction'
$pwsh7Only = 'AsHashtable', 'NoEmphasis', 'Parallel', 'ThrottleLimit', 'SkipCertificateCheck', 'SkipHttpErrorCheck',
    'SkipHeaderValidation', 'Authentication', 'Token', 'Form', 'NoProxy', 'MaximumRetryCount', 'RetryIntervalSec',
    'StatusCodeVariable', 'ResponseHeadersVariable', 'AllowUnencryptedAuthentication', 'PreserveAuthorizationOnRedirect',
    'Resume', 'UseQuotes'
$allowed = @{
    'New-LocalUser' = 'Name', 'Password', 'FullName', 'Description', 'PasswordNeverExpires', 'UserMayNotChangePassword', 'AccountNeverExpires', 'AccountExpires', 'Disabled', 'NoPassword'
    'Set-LocalUser' = 'Name', 'Password', 'FullName', 'Description', 'PasswordNeverExpires', 'UserMayChangePassword', 'AccountNeverExpires'
    'Get-LocalUser' = 'Name', 'SID'
    'Register-ScheduledTask' = 'TaskName', 'Action', 'Trigger', 'Principal', 'Settings', 'Description', 'Force', 'TaskPath', 'User', 'Password', 'RunLevel'
    'New-ScheduledTaskAction' = 'Execute', 'Argument', 'WorkingDirectory'
    'New-ScheduledTaskTrigger' = 'Daily', 'Weekly', 'Once', 'AtLogOn', 'AtStartup', 'At', 'RandomDelay', 'DaysInterval'
    'New-ScheduledTaskPrincipal' = 'UserId', 'LogonType', 'RunLevel', 'GroupId', 'Id'
    'New-ScheduledTaskSettingsSet' = 'StartWhenAvailable', 'ExecutionTimeLimit', 'MultipleInstances', 'AllowStartIfOnBatteries', 'DontStopIfGoingOnBatteries', 'Hidden'
    'Start-ScheduledTask' = 'TaskName', 'TaskPath'
    'Get-ScheduledTask' = 'TaskName', 'TaskPath'
    'Get-ScheduledTaskInfo' = 'TaskName', 'TaskPath'
    'Add-MpPreference' = 'ExclusionPath', 'ExclusionExtension', 'ExclusionProcess'
}
foreach ($name in 'runner-setup.ps1', 'runner-clean.ps1') {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile("$dir/$name", [ref]$tokens, [ref]$errors)
    if ($errors.Count) { Fail "$name does not parse: $($errors[0].Message)" }
    foreach ($t in $tokens) {
        if ("$($t.Kind)" -in 'AndAnd', 'OrOr', 'QuestionQuestion', 'QuestionDot', 'QuestionMark') { Fail "$name uses $($t.Kind) at line $($t.Extent.StartLineNumber): pwsh 7 only" }
    }
    $bad = $ast.FindAll({ param($n) $n.GetType().Name -in 'TernaryExpressionAst', 'PipelineChainAst', 'NullConditionalMemberExpressionAst' }, $true)
    if ($bad) { Fail "$name uses pwsh 7 syntax at line $($bad[0].Extent.StartLineNumber)" }
    foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $cmd = $c.GetCommandName()
        foreach ($e in $c.CommandElements) {
            if ($e -isnot [Management.Automation.Language.CommandParameterAst]) { continue }
            if ($pwsh7Only -contains $e.ParameterName) {
                Fail "$name line $($e.Extent.StartLineNumber): -$($e.ParameterName) exists only in pwsh 7"
            }
            if ($cmd -and $allowed.ContainsKey($cmd) -and (@($allowed[$cmd]) + $common) -notcontains $e.ParameterName) {
                Fail "$name line $($e.Extent.StartLineNumber): $cmd has no parameter -$($e.ParameterName) in Windows PowerShell 5.1"
            }
        }
    }
}

$env:PATH = $origPath
$out = & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File "$dir/runner-clean.ps1" -DryRun 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "runner-clean dry run failed: $out" }
Remove-Item -Recurse -Force $tmp
Write-Host 'ok'
