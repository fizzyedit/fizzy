# The worker's switch. The FizzyWorker* scheduled tasks (SYSTEM) run this from <root>\bin; nobody
# needs to be logged in, so `schtasks /run /tn \Fizzy\FizzyWorkerOn` works over SSH.
#   On        start the runner service (it is Manual, so only this starts it) and cap it.
#   Off       drain: take no more work, let the running job finish, then stop the service.
#   ForceOff  stop the service now and kill the job and everything it started.
#   Apply     (heartbeat) re-apply priority and core cap, write state\heartbeat.txt.
#   Update    refresh Git and gh with winget when no job is running.
# Windows PowerShell 5.1 only syntax: see the pitfall note in scripts/runner-setup.ps1.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('On', 'Off', 'ForceOff', 'Apply', 'Update')][string]$Mode,
    [Parameter(Mandatory)][string]$Root,
    [int]$CoreCap = 0,
    [int]$DrainHours = 12,
    [switch]$DryRun
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$runner = Join-Path $Root 'actions-runner'
$state = Join-Path $Root 'state'
$log = Join-Path $state 'worker.log'

function Write-Log($text) {
    $line = "$((Get-Date).ToString('o')) $Mode $text"
    Write-Output $line
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $state)) { New-Item -ItemType Directory -Path $state | Out-Null }
        Add-Content -LiteralPath $log -Value $line
    }
}
function Get-RunnerService {
    $file = Join-Path $runner '.service'
    if (-not (Test-Path -LiteralPath $file)) { throw "no runner service recorded at $file; run setup first" }
    return (Get-Content -LiteralPath $file -Raw).Trim()
}
function Get-Jobs { return @(Get-Process -Name Runner.Worker -ErrorAction SilentlyContinue) }
# The cap is the highest-numbered logical cores, leaving the low ones (where Windows schedules its
# own work first) to the machine's owner. Children inherit affinity and BelowNormal priority.
function Set-Cap {
    $count = [Environment]::ProcessorCount
    $mask = $null
    # Bit 63 would overflow Int64, so a 64-core machine is left uncapped.
    if ($CoreCap -gt 0 -and $CoreCap -lt $count -and $count -le 63) {
        $mask = (([int64]1 -shl $CoreCap) - 1) -shl ($count - $CoreCap)
    }
    foreach ($p in @(Get-Process -Name Runner.Listener, Runner.Worker -ErrorAction SilentlyContinue)) {
        try {
            $p.PriorityClass = 'BelowNormal'
            if ($mask) { $p.ProcessorAffinity = [IntPtr]$mask }
        } catch { Write-Log "cannot cap $($p.Name) $($p.Id): $_" }
    }
    Write-Log "cap applied: BelowNormal, cores=$CoreCap of $count"
}

if ($DryRun) {
    Write-Output "Would $Mode the runner under $Root (core cap $CoreCap); no changes made."
    exit 0
}

switch ($Mode) {
    'On' {
        $name = Get-RunnerService
        $svc = Get-Service -Name $name
        if ($svc.Status -ne 'Running') {
            Start-Service -Name $name
            $svc.WaitForStatus('Running', (New-TimeSpan -Seconds 60))
        }
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Get-Process -Name Runner.Listener -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
        Write-Log "service $name running"
        Set-Cap
    }
    'Off' {
        $name = Get-RunnerService
        # The runner has no drain command, so poll. After a job ends the listener may take the next
        # queued job within a moment, so a job counts as finished only after three quiet polls; a job
        # accepted in that window is cancelled by the stop, which GitHub shows as a cancelled run.
        $deadline = (Get-Date).AddHours($DrainHours)
        $quiet = 0
        Write-Log "draining; $(@(Get-Jobs).Count) job(s) running"
        while ($quiet -lt 3 -and (Get-Date) -lt $deadline) {
            if (@(Get-Jobs).Count) { $quiet = 0 } else { $quiet++ }
            if ($quiet -lt 3) { Start-Sleep -Seconds 2 }
        }
        if ($quiet -lt 3) { Write-Log "job still running after $DrainHours h; leaving the service up (use ForceOff)"; exit 1 }
        Stop-Service -Name $name -ErrorAction Stop
        (Get-Service -Name $name).WaitForStatus('Stopped', (New-TimeSpan -Seconds 60))
        Write-Log "service $name stopped"
    }
    'ForceOff' {
        $name = Get-RunnerService
        $svc = Get-Service -Name $name
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
        # /T takes the job's whole process tree (zig, git, shells) with it.
        foreach ($p in @(Get-Process -Name Runner.Worker, Runner.Listener -ErrorAction SilentlyContinue)) {
            & cmd.exe /c "taskkill.exe /F /T /PID $($p.Id) >nul 2>&1"
        }
        Write-Log "service $name stopped; processes killed"
    }
    'Apply' {
        if (-not (Test-Path -LiteralPath $state)) { New-Item -ItemType Directory -Path $state | Out-Null }
        Set-Cap
        $name = Get-RunnerService
        $status = (Get-Service -Name $name).Status
        Set-Content -LiteralPath (Join-Path $state 'heartbeat.txt') -Value "$((Get-Date).ToString('o')) service=$status jobs=$(@(Get-Jobs).Count)"
    }
    'Update' {
        if (@(Get-Jobs).Count) { Write-Log 'a job is running; skipping this week'; exit 0 }
        $winget = @(Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1)
        if (-not $winget.Count) { Write-Log 'winget not available to SYSTEM; nothing updated'; exit 0 }
        foreach ($id in 'Git.Git', 'GitHub.cli') {
            # Native stderr is a terminating error under Stop in Windows PowerShell 5.1.
            $ErrorActionPreference = 'Continue'
            & cmd.exe /c "`"$($winget[0].FullName)`" upgrade --id $id --exact --silent --accept-source-agreements --accept-package-agreements >nul 2>&1"
            $code = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            Write-Log "winget upgrade $id exit $code"
        }
    }
}
