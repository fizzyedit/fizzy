# Converge the Windows worker box to config.psd1. Run from an elevated PowerShell (5.1 or newer):
#   powershell -ExecutionPolicy Bypass -File .\ci\worker-box\windows\setup.ps1 [-DryRun]
# Idempotent: every item is checked, fixed if wrong, and rechecked by doctor.ps1 at the end.
# -DryRun prints each step and changes nothing (no elevation, token or downloads needed).
# The runner itself (account, folders, tools, service) is scripts/runner-setup.ps1, run first with the
# root from config.psd1; this adds the on/off switch and the machine settings around it. The worker
# is ON after setup and after every reboot; the maintainer turns it Off by hand (docs/AGENT_WORK.md).
# Needs RUNNER_TOKEN in the environment on the first run, as runner-setup.ps1 does.
[CmdletBinding()]
param([switch]$DryRun)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $here 'config.psd1')
$repoScripts = Join-Path $here '..\..\..\scripts'
$root = $config.Root.TrimEnd('\')
$bin = "$root\bin"
$worker = $config.Worker
$taskPath = $config.WorkerTaskPath
$engine = (Get-Process -Id $PID).Path

function Fail($msg) { [Console]::Error.WriteLine("ERROR: $msg"); exit 1 }
function Step($text, [scriptblock]$action) {
    Write-Host "+ $text"
    if (-not $DryRun) { & $action }
}
# Native stderr is a terminating error under Stop in Windows PowerShell 5.1: run under Continue.
function Native([scriptblock]$cmd) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $cmd; $script:nativeExit = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    return $out
}
$nativeExit = 0

if (-not $DryRun) {
    if ($env:OS -ne 'Windows_NT') { Fail 'Run on Windows.' }
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail 'Run from an elevated (Administrator) PowerShell.' }
}

# --- the runner: account, folders under the root, tools, service, FizzyRunnerClean ------------------
Write-Host "+ scripts/runner-setup.ps1 with FIZZY_WORKER_ROOT=$root"
$env:FIZZY_WORKER_ROOT = $root
$setupArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repoScripts 'runner-setup.ps1'))
if ($DryRun) { $setupArgs += '-DryRun' }
& $engine @setupArgs
if ($LASTEXITCODE -ne 0) { Fail "runner-setup.ps1 failed ($LASTEXITCODE)" }

# --- the agents' home ------------------------------------------------------------------------------
Step "worker state folder $root\state (the worker may read it, not write it)" {
    New-Item -ItemType Directory -Force -Path "$root\state" | Out-Null
    $null = Native { & icacls "$root\state" /grant "${worker}:(OI)(CI)RX" /C /Q 2>&1 }
    if ($nativeExit -ne 0) { Fail "icacls on $root\state failed ($nativeExit)" }
}
Step "$worker may not read any other fixed drive (a deny on each drive root; the OS drive's profiles are private by default and the doctor checks them)" {
    $homeDrive = [IO.Path]::GetPathRoot($root).TrimEnd('\')
    foreach ($d in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')) {
        if ($d.DeviceID -ieq $homeDrive -or $d.DeviceID -ieq $env:SystemDrive) { continue }
        $null = Native { & icacls "$($d.DeviceID)\" /deny "${worker}:(OI)(CI)(F)" /C /Q 2>&1 }
        if ($nativeExit -ne 0) { Write-Warning "could not deny $worker on $($d.DeviceID) (icacls $nativeExit); the doctor will report it" }
    }
}
Step "disk free space on the root's drive (minimum $($config.MinDiskFreeGiB) GiB)" {
    $drive = [IO.Path]::GetPathRoot($root).TrimEnd('\')
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$drive'"
    $free = [math]::Round($disk.FreeSpace / 1GB, 1)
    if ($free -lt $config.MinDiskFreeGiB) { Write-Warning "only $free GiB free on the root's drive" } else { Write-Host "  $free GiB free" }
}

# --- the machine stays up and awake ---------------------------------------------------------------
Step 'Fast Startup off (HiberbootEnabled=0), hibernation off, never sleep or hibernate' {
    Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
    $null = Native { & "$env:SystemRoot\System32\powercfg.exe" /hibernate off 2>&1 }
    foreach ($t in 'standby-timeout-ac', 'standby-timeout-dc', 'hibernate-timeout-ac', 'hibernate-timeout-dc') {
        $null = Native { & "$env:SystemRoot\System32\powercfg.exe" /change $t 0 2>&1 }
        if ($nativeExit -ne 0) { Fail "powercfg /change $t failed ($nativeExit)" }
    }
}
Step 'sshd and Tailscale start automatically when present (the way in when nobody is logged on)' {
    foreach ($name in 'sshd', 'Tailscale') {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
            Set-Service -Name $name -StartupType Automatic
            if ((Get-Service -Name $name).Status -ne 'Running') { Start-Service -Name $name }
        } else { Write-Warning "service $name is not installed; install it by hand (setup does not install software)" }
    }
}

# --- the switch ------------------------------------------------------------------------------------
Step 'runner and its children at BelowNormal priority (Image File Execution Options CpuPriorityClass=5; children inherit it)' {
    foreach ($exe in 'Runner.Listener.exe', 'Runner.Worker.exe') {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe\PerfOptions"
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -LiteralPath $key -Name CpuPriorityClass -Value 5 -Type DWord
    }
}
Step "install worker-switch.ps1 to $bin (admin-write only)" {
    Copy-Item (Join-Path $here 'worker-switch.ps1') "$bin\worker-switch.ps1" -Force
}
Step "register the SYSTEM tasks in $taskPath : FizzyWorkerOn (at boot and on demand), FizzyWorkerOff (drain), FizzyWorkerForceOff, FizzyHeartbeat (5 min), FizzyUpdate (weekly)" {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 13) -MultipleInstances IgnoreNew
    $quick = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    function New-SwitchAction($mode) {
        New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"$bin\worker-switch.ps1`" -Mode $mode -Root `"$root`" -CoreCap $($config.CoreCap)")
    }
    $specs = @(
        @{ Name = 'FizzyWorkerOn'; Mode = 'On'; Trigger = (New-ScheduledTaskTrigger -AtStartup); Settings = $quick }
        @{ Name = 'FizzyWorkerOff'; Mode = 'Off'; Trigger = $null; Settings = $settings }
        @{ Name = 'FizzyWorkerForceOff'; Mode = 'ForceOff'; Trigger = $null; Settings = $quick }
        @{ Name = 'FizzyHeartbeat'; Mode = 'Apply'; Trigger = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)); Settings = $quick }
        @{ Name = 'FizzyUpdate'; Mode = 'Update'; Trigger = (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3am); Settings = $settings }
    )
    foreach ($s in $specs) {
        $reg = @{ TaskName = $s.Name; TaskPath = $taskPath; Action = (New-SwitchAction $s.Mode); Principal = $principal; Settings = $s.Settings; Force = $true }
        if ($s.Trigger) { $reg.Trigger = $s.Trigger }
        Register-ScheduledTask @reg | Out-Null
    }
}
Step "task security: $($config.Maintainer) may run all three switch tasks, $worker the drain only, neither may change them" {
    function Get-Sid($name) { return (New-Object Security.Principal.NTAccount($name)).Translate([Security.Principal.SecurityIdentifier]).Value }
    $maintainer = Get-Sid $config.Maintainer
    $workerSid = Get-Sid $worker
    $system = 'D:P(A;;FA;;;SY)(A;;FA;;;BA)'
    $com = New-Object -ComObject 'Schedule.Service'
    $com.Connect()
    $folder = $com.GetFolder($taskPath.TrimEnd('\'))
    # GR|GX lets a caller read and run a task, not change or delete it.
    $folder.SetSecurityDescriptor("$system(A;;GRGX;;;$maintainer)(A;;GRGX;;;$workerSid)", 0)
    $folder.GetTask('FizzyWorkerOn').SetSecurityDescriptor("$system(A;;GRGX;;;$maintainer)", 0)
    $folder.GetTask('FizzyWorkerForceOff').SetSecurityDescriptor("$system(A;;GRGX;;;$maintainer)", 0)
    $folder.GetTask('FizzyWorkerOff').SetSecurityDescriptor("$system(A;;GRGX;;;$maintainer)(A;;GRGX;;;$workerSid)", 0)
}
Step 'runner service to Manual, then On: the worker is ON after setup and, through FizzyWorkerOn at boot, after every reboot' {
    $name = (Get-Content "$root\actions-runner\.service" -Raw).Trim()
    Set-Service -Name $name -StartupType Manual
    Start-ScheduledTask -TaskPath $taskPath -TaskName FizzyWorkerOn
    $deadline = (Get-Date).AddSeconds(120)
    do { Start-Sleep -Seconds 2 } while ((Get-ScheduledTask -TaskPath $taskPath -TaskName FizzyWorkerOn).State -eq 'Running' -and (Get-Date) -lt $deadline)
    $result = (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName FizzyWorkerOn).LastTaskResult
    if ($result -ne 0) { Fail ("FizzyWorkerOn last result 0x{0:X}" -f $result) }
}

# --- report, never delete ---------------------------------------------------------------------------
Step 'local accounts outside the allowed list (reported only; setup never deletes an account)' {
    $strays = @(Get-LocalUser | Where-Object { $_.SID.Value -notmatch '-(500|501|503|504)$' -and $config.AllowedUsers -notcontains $_.Name })
    if ($strays.Count) { Write-Warning "unexpected local accounts: $(@($strays | ForEach-Object { $_.Name }) -join ', ') (remove by hand if not wanted)" }
    else { Write-Host '  none' }
}

# --- recheck -----------------------------------------------------------------------------------------
Write-Host '+ recheck with doctor.ps1'
if ($DryRun) {
    & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'doctor.ps1') -DryRun | Select-Object -First 3
    Write-Host 'Dry run complete; no changes made.'
    exit 0
}
$doctor = @(& $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'doctor.ps1'))
$doctor | Where-Object { $_ -notmatch '^GREEN ' } | ForEach-Object { Write-Host $_ }
$reds = @($doctor | Where-Object { $_ -match '^RED ' }).Count
if ($reds) { Fail "$reds doctor check(s) still RED after setup (listed above)" }
Write-Host 'Worker box converged; doctor has no RED.'
