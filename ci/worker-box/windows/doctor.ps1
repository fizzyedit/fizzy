# Read-only Windows worker diagnostics. Unknown or inaccessible evidence is AMBER.
# -DryRun lists checks without probing; normal execution never changes system configuration.
# Exit status is the number of RED results. JSON is an array of status/item/detail objects.
#requires -Version 5.1
[CmdletBinding()]
param([switch]$Json, [switch]$DryRun, [string]$ConfigPath)
Set-StrictMode -Version 2
# $PSScriptRoot is empty inside a param() default in Windows PowerShell 5.1, so resolve it here.
if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.psd1' }
$ErrorActionPreference = 'Stop'
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
# RunnerRoot and ZigCache come from Root unless a config names them (the test fixtures do).
$runnerRoot = ''; $zigCache = ''
if ($config.ContainsKey('Root')) { $runnerRoot = $config.Root.TrimEnd('\') + '\actions-runner'; $zigCache = $config.Root.TrimEnd('\') + '\zig-cache' }
if ($config.ContainsKey('RunnerRoot')) { $runnerRoot = $config.RunnerRoot }
if ($config.ContainsKey('ZigCache')) { $zigCache = $config.ZigCache }
$results = New-Object 'Collections.Generic.List[object]'
function Result($status, $item, $detail) {
    $results.Add([pscustomobject]@{ status = $status; item = $item; detail = ("$detail" -replace '[\r\n]+', ' ') })
}
function Check($item, [scriptblock]$probe) {
    if ($DryRun) { Result AMBER $item 'probe skipped (DryRun)'; return }
    try { & $probe } catch { Result AMBER $item 'evidence unavailable (query failed or access denied)' }
}
function Native([string]$exe, [string[]]$arguments) {
    # Native stderr is a terminating error under Stop in Windows PowerShell 5.1.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $exe @arguments 2>$null; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw 'native query failed' }
    return ($output -join ' ').Trim()
}
foreach ($spec in $config.Services) {
    $item = "service $($spec.Name)"
    Check $item {
        $services = @(Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -like $spec.Name })
        if ($services.Count -ne 1) { Result RED $item "expected one service; found $($services.Count)"; return }
        $s = $services[0]
        $account = $s.StartName -replace "^$([regex]::Escape([Environment]::MachineName))\\", '.\'
        $status = 'RED'
        $wantMode = 'Auto'; if ($spec.ContainsKey('StartMode')) { $wantMode = $spec.StartMode }
        # State = 'Any' is the worker switch's own service: Running (On) and Stopped (Off) are both healthy.
        $stateOk = ($s.State -eq 'Running'); if ($spec.ContainsKey('State') -and $spec.State -eq 'Any') { $stateOk = ($s.State -eq 'Running' -or $s.State -eq 'Stopped') }
        if ($stateOk -and $s.StartMode -eq $wantMode -and $account -ieq $spec.Account) { $status = 'GREEN' }
        $delayed = 'unknown'
        if ($s.PSObject.Properties['DelayedAutoStart']) { $delayed = "$($s.DelayedAutoStart)" }
        Result $status $item "state=$($s.State); start=$($s.StartMode); delayed=$delayed; account=$($s.StartName)"
    }
}
Check 'runner Online' {
    if (-not ($env:GH_TOKEN -or $env:GITHUB_TOKEN)) { Result AMBER 'runner Online' 'no token environment; API not queried'; return }
    $gh = (Get-Command gh.exe -CommandType Application).Source
    $raw = Native $gh @('api', '--paginate', '--slurp', "repos/$($config.RunnerRepo)/actions/runners?per_page=100")
    $pages = $raw | ConvertFrom-Json
    $runners = @($pages | ForEach-Object { $_.runners } | Where-Object { $_.name -eq $config.RunnerName })
    $status = 'RED'
    if ($runners.Count -eq 1 -and $runners[0].status -eq 'online') { $status = 'GREEN' }
    if ($status -eq 'RED') {
        # An Off worker is offline on purpose.
        $svc = @(Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -like 'actions.runner.*' })
        if ($svc.Count -eq 1 -and $svc[0].State -eq 'Stopped') { Result GREEN 'runner Online' 'worker is Off (service stopped), so offline is expected'; return }
    }
    Result $status 'runner Online' "repo=$($config.RunnerRepo); name=$($config.RunnerName); matching online=$(@($runners | Where-Object { $_.status -eq 'online' }).Count)"
}
Check 'power plan' {
    Result GREEN 'power plan' (Native "$env:SystemRoot\System32\powercfg.exe" @('/getactivescheme'))
}
# GUIDs and hex indices avoid localized powercfg setting names.
foreach ($setting in @(
    @{ Name = 'sleep'; Guid = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' },
    @{ Name = 'hibernate'; Guid = '9d7815a6-7ee4-497e-8888-515a05f02364' }
)) {
    $item = "power $($setting.Name)"
    Check $item {
        $raw = Native "$env:SystemRoot\System32\powercfg.exe" @('/query', 'SCHEME_CURRENT', '238c9fa8-0aad-41ed-83f4-97be242c8f20', $setting.Guid)
        $indices = [regex]::Matches($raw, '0x[0-9a-fA-F]{8}')
        if ($indices.Count -lt 2) { throw 'cannot read AC/DC indices' }
        $indices = @($indices)[-2..-1]
        $status = 'RED'
        if ($indices[0].Value -eq '0x00000000' -and $indices[1].Value -eq '0x00000000') { $status = 'GREEN' }
        Result $status $item "AC=$($indices[0].Value); DC=$($indices[1].Value); expected never (zero)"
    }
}
Check 'hibernation enabled' {
    $v = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled
    $status = 'RED'; if ($v -eq 0) { $status = 'GREEN' }
    Result $status 'hibernation enabled' "HibernateEnabled=$v"
}
Check 'Fast Startup' {
    $v = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled
    $status = 'RED'; if ($v -eq 0) { $status = 'GREEN' }
    Result $status 'Fast Startup' "HiberbootEnabled=$v"
}
Check 'last boot' {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Result GREEN 'last boot' ($os.LastBootUpTime.ToString('o') + '; BIOS power recovery is not inspected')
}
Check 'unclean shutdowns' {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'; Id = @(41, 6008); StartTime = (Get-Date).AddDays(-30)
        })
    } catch {
        # An empty event query is not an access failure.
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
        $events = @()
    }
    $bad = @($events | Where-Object { ($_.Id -eq 41 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power') -or ($_.Id -eq 6008 -and $_.ProviderName -eq 'EventLog') })
    $status = 'GREEN'; if ($bad.Count) { $status = 'AMBER' }
    Result $status 'unclean shutdowns' "30-day event records=$($bad.Count) (41/6008 may describe the same shutdown)"
}
Check 'pending reboot' {
    $pending = @()
    foreach ($key in @('SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending', 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath "HKLM:\$key") { $pending += $key }
    }
    $session = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if ($session.PSObject.Properties['PendingFileRenameOperations'] -and $session.PendingFileRenameOperations) { $pending += 'PendingFileRenameOperations' }
    $status = 'GREEN'; if ($pending.Count) { $status = 'AMBER' }
    Result $status 'pending reboot' "indicators=$($pending -join ',')"
}
Check 'last patch' {
    $patch = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if (-not $patch) { throw 'no patch date' }
    $days = [int]((Get-Date) - $patch.InstalledOn).TotalDays
    $status = 'GREEN'; if ($days -gt $config.MaxPatchDays -or $days -lt 0) { $status = 'AMBER' }
    Result $status 'last patch' "$($patch.HotFixID); days=$days; limit=$($config.MaxPatchDays) (Get-HotFix coverage)"
}
Check 'disk inventory' {
    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')
    if (-not $disks.Count) { throw 'no fixed disks' }
    foreach ($d in $disks) {
        $free = [math]::Round($d.FreeSpace / 1GB, 1)
        $status = 'GREEN'; if ($free -lt $config.MinDiskFreeGiB) { $status = 'RED' }
        # With a Root, only its drive is the agents' home: low space there is RED (AMBER within 50% of
        # the minimum); another drive is the person's own.
        if ($config.ContainsKey('Root')) {
            if ($d.DeviceID -ieq [IO.Path]::GetPathRoot($config.Root).TrimEnd('\')) {
                if ($free -ge $config.MinDiskFreeGiB) { $status = 'GREEN' } else { $status = 'RED' }
                if ($status -eq 'GREEN' -and $free -lt $config.MinDiskFreeGiB * 1.5) { $status = 'AMBER' }
            } elseif ($free -lt $config.MinDiskFreeGiB) { $status = 'AMBER' }
        }
        Result $status "disk $($d.DeviceID)" "free=$free GiB; minimum=$($config.MinDiskFreeGiB) GiB"
    }
}
Check 'RAM' {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $free = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $status = 'GREEN'; if ($free -lt $config.MinAvailableRamGiB) { $status = 'AMBER' }
    Result $status 'RAM' "available=$free GiB; total=$total GiB; slots=$($config.BuildSlots)"
}
Check 'zig-cache' {
    if (-not (Test-Path -LiteralPath $zigCache -PathType Container)) { Result RED 'zig-cache' 'configured directory missing'; return }
    # Never follow junctions, even when they occur inside a cache.
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($zigCache)
    $bytes = [long]0
    while ($stack.Count) {
        $path = $stack.Pop()
        $entry = Get-Item -LiteralPath $path -Force
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reparse point prevents complete sizing' }
        foreach ($child in Get-ChildItem -LiteralPath $path -Force) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'reparse point prevents complete sizing' }
            if ($child.PSIsContainer) { $stack.Push($child.FullName) } else { $bytes += $child.Length }
        }
    }
    $size = [math]::Round($bytes / 1GB, 2)
    $status = 'GREEN'; if ($size -gt $config.MaxCacheGiB) { $status = 'AMBER' }
    Result $status 'zig-cache' "$zigCache; size=$size GiB; limit=$($config.MaxCacheGiB) GiB"
}
$runnerPath = $null
Check 'runner PATH' {
    $lines = @(Get-Content -LiteralPath (Join-Path $runnerRoot '.env') | Where-Object { $_ -match '^PATH=' })
    if ($lines.Count -ne 1) { throw 'runner PATH missing or ambiguous' }
    $script:runnerPath = $lines[0].Substring(5)
    if (-not $runnerPath -or $runnerPath -match '%|\$') { $script:runnerPath = $null; throw 'unexpanded PATH' }
    Result GREEN 'runner PATH' 'using saved runner .env PATH; account access and job overrides require a runner job to verify'
}
foreach ($tool in $config.Tools) {
    $item = "tool $($tool.Name)"
    Check $item {
        if (-not $runnerPath) { Result AMBER $item 'runner PATH unavailable'; return }
        $exe = $null
        foreach ($dir in $runnerPath.Split(';')) {
            if (-not [IO.Path]::IsPathRooted($dir.Trim('"'))) { throw 'relative runner PATH entry' }
            $candidate = Join-Path $dir.Trim('"') ($tool.Name + '.exe')
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $exe = $candidate; break }
        }
        if (-not $exe) { Result RED $item 'not found on saved runner PATH'; return }
        $version = Native $exe $tool.Args
        $status = 'AMBER'
        if ($tool.Version) {
            $status = 'RED'
            if ($version -match ('(^|\s)v?' + [regex]::Escape($tool.Version) + '(?=\s|$)')) { $status = 'GREEN' }
        }
        Result $status $item "path=$exe; version=$version; pin=$($tool.Version); executed as diagnostic caller"
    }
}
foreach ($task in $config.Tasks) {
    $item = "task $task"
    Check $item {
        $found = @(Get-ScheduledTask | Where-Object { $_.TaskName -eq $task })
        $status = 'RED'; if ($found.Count) { $status = 'GREEN' }
        Result $status $item "present=$($found.Count -gt 0)"
    }
}
Check 'local users' {
    $strays = @(Get-LocalUser | Where-Object { $_.SID.Value -notmatch '-(500|501|503|504)$' -and $config.AllowedUsers -notcontains $_.Name })
    $status = 'GREEN'; if ($strays.Count) { $status = 'AMBER' }
    Result $status 'local users' "unexpected=$(@($strays | ForEach-Object { $_.Name }) -join ','); includes disabled accounts"
}
# --- the worker switch and the agents' home (policy in config.psd1; absent from minimal fixtures) ---
function ConvertTo-Sid($name) {
    return (New-Object Security.Principal.NTAccount($name)).Translate([Security.Principal.SecurityIdentifier])
}
$readRights = [Security.AccessControl.FileSystemRights]::ListDirectory
# Whether the worker could read $path, from its ACL: a deny for the worker (or a broad group) first,
# then any allow for the worker, Users, Authenticated Users or Everyone. Effective access also depends
# on group policy, so this is the file system's half of the answer.
function Test-WorkerRead($path, $workerSid) {
    $broad = @($workerSid.Value, 'S-1-5-32-545', 'S-1-5-11', 'S-1-1-0')
    foreach ($rule in (Get-Acl -LiteralPath $path).Access) {
        try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if ($broad -notcontains $sid) { continue }
        if (-not ($rule.FileSystemRights -band $readRights)) { continue }
        if ($rule.AccessControlType -eq 'Deny' -and $sid -eq $workerSid.Value) { return $false }
        if ($rule.AccessControlType -eq 'Allow') { return $true }
    }
    return $false
}
if ($config.ContainsKey('Worker')) {
    Check 'worker switch' {
        $svc = @(Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -like 'actions.runner.*' })
        if ($svc.Count -ne 1) { throw 'runner service not found' }
        $jobs = @(Get-Process -Name Runner.Worker -ErrorAction SilentlyContinue).Count
        $state = 'ON'; if ($svc[0].State -eq 'Stopped') { $state = 'OFF' } elseif ($svc[0].State -ne 'Running') { $state = $svc[0].State }
        # On and Off are both policy: report which, GREEN either way.
        $status = 'GREEN'; if ($state -notin 'ON', 'OFF') { $status = 'AMBER' }
        Result $status 'worker switch' "worker=$state; service=$($svc[0].State); running jobs=$jobs"
    }
    $workerSid = $null
    Check 'worker account' {
        $script:workerSid = ConvertTo-Sid $config.Worker
        Result GREEN 'worker account' "$($config.Worker) = $($script:workerSid.Value)"
    }
    # Tasks run as SYSTEM, in a folder the worker cannot write; the maintainer may run all three,
    # the worker the drain only. Write-like rights: DELETE, WRITE_DAC, WRITE_OWNER, FILE_WRITE_DATA, GW, GA.
    $writeMask = 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x2 -bor 0x40000000 -bor 0x10000000
    foreach ($t in @(
        @{ Name = 'FizzyWorkerOn'; Maintainer = $true; Worker = $false },
        @{ Name = 'FizzyWorkerOff'; Maintainer = $true; Worker = $true },
        @{ Name = 'FizzyWorkerForceOff'; Maintainer = $true; Worker = $false }
    )) {
        $item = "task access $($t.Name)"
        Check $item {
            if (-not $script:workerSid) { Result AMBER $item 'worker account unknown'; return }
            $maintainerSid = ConvertTo-Sid $config.Maintainer
            $com = New-Object -ComObject 'Schedule.Service'
            $com.Connect()
            $folder = $com.GetFolder($config.WorkerTaskPath.TrimEnd('\'))
            $sd = New-Object Security.AccessControl.RawSecurityDescriptor ($folder.GetTask($t.Name).GetSecurityDescriptor(4))
            $canRun = @{}; $canWrite = $false; $runsAsSystem = $true
            foreach ($ace in $sd.DiscretionaryAcl) {
                if ($ace.AceType -ne 'AccessAllowed') { continue }
                $sid = $ace.SecurityIdentifier.Value
                if ($sid -in $script:workerSid.Value, 'S-1-5-32-545', 'S-1-5-11', 'S-1-1-0') {
                    $canRun[$sid] = $true
                    if ($ace.AccessMask -band $writeMask) { $canWrite = $true }
                }
                if ($sid -eq $maintainerSid.Value) { $canRun['maintainer'] = $true }
            }
            $workerRuns = [bool]$canRun[$script:workerSid.Value] -or [bool]$canRun['S-1-5-32-545'] -or [bool]$canRun['S-1-5-11'] -or [bool]$canRun['S-1-1-0']
            $info = $folder.GetTask($t.Name).Definition.Principal
            if ($info.UserId -notin 'SYSTEM', 'S-1-5-18', 'NT AUTHORITY\SYSTEM') { $runsAsSystem = $false }
            $ok = $runsAsSystem -and -not $canWrite -and ($workerRuns -eq $t.Worker)
            $status = 'RED'; if ($ok) { $status = 'GREEN' }
            Result $status $item "runs as SYSTEM=$runsAsSystem; worker can trigger=$workerRuns (want $($t.Worker)); worker can write=$canWrite"
        }
    }
    Check 'task folder not writable by worker' {
        if (-not $script:workerSid) { Result AMBER 'task folder not writable by worker' 'worker account unknown'; return }
        $com = New-Object -ComObject 'Schedule.Service'
        $com.Connect()
        $sd = New-Object Security.AccessControl.RawSecurityDescriptor ($com.GetFolder($config.WorkerTaskPath.TrimEnd('\')).GetSecurityDescriptor(4))
        $bad = @($sd.DiscretionaryAcl | Where-Object {
            $_.AceType -eq 'AccessAllowed' -and ($_.AccessMask -band $writeMask) -and
            $_.SecurityIdentifier.Value -in $script:workerSid.Value, 'S-1-5-32-545', 'S-1-5-11', 'S-1-1-0'
        })
        $status = 'GREEN'; if ($bad.Count) { $status = 'RED' }
        Result $status 'task folder not writable by worker' "folder=$($config.WorkerTaskPath); writable ACEs=$($bad.Count)"
    }
    foreach ($exe in 'Runner.Listener.exe', 'Runner.Worker.exe') {
        $item = "priority $exe"
        Check $item {
            $v = Get-ItemPropertyValue -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe\PerfOptions" -Name CpuPriorityClass
            $status = 'RED'; if ($v -eq 5) { $status = 'GREEN' }
            Result $status $item "CpuPriorityClass=$v; expected 5 (BelowNormal); children inherit it; core cap=$($config.CoreCap) applied by the switch"
        }
    }
    Check 'heartbeat' {
        $file = ($config.Root.TrimEnd('\') + '\state\heartbeat.txt')
        if (-not (Test-Path -LiteralPath $file)) { Result AMBER 'heartbeat' 'no heartbeat recorded yet'; return }
        $age = [int]((Get-Date) - (Get-Item -LiteralPath $file).LastWriteTime).TotalMinutes
        $status = 'GREEN'; if ($age -gt 30) { $status = 'AMBER' }
        Result $status 'heartbeat' "last written $age minutes ago"
    }
    Check 'root access' {
        if (-not $script:workerSid) { Result AMBER 'root access' 'worker account unknown'; return }
        # The root is closed to everyone but SYSTEM and Administrators, and to the worker's read but
        # for the traversal grant; no broad group may appear on it.
        $broad = @((Get-Acl -LiteralPath $config.Root).Access | Where-Object {
            try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in 'S-1-5-32-545', 'S-1-5-11', 'S-1-1-0' } catch { $false }
        })
        $status = 'GREEN'; if ($broad.Count) { $status = 'RED' }
        Result $status 'root access' "root=$($config.Root); entries for Users/Authenticated Users/Everyone=$($broad.Count)"
    }
    Check 'worker isolation' {
        if (-not $script:workerSid) { Result AMBER 'worker isolation' 'worker account unknown'; return }
        $homeDrive = [IO.Path]::GetPathRoot($config.Root).TrimEnd('\')
        $reachable = @()
        foreach ($d in @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3')) {
            if ($d.DeviceID -ieq $homeDrive -or $d.DeviceID -ieq $env:SystemDrive) { continue }
            if (Test-WorkerRead ($d.DeviceID + '\') $script:workerSid) { $reachable += "drive $($d.DeviceID)" }
        }
        $users = Join-Path $env:SystemDrive 'Users'
        foreach ($p in @(Get-ChildItem -LiteralPath $users -Directory -Force -ErrorAction Stop)) {
            if ($p.Name -in 'Public', 'Default', 'Default User', 'All Users', $config.Worker) { continue }
            if ($p.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if (Test-WorkerRead $p.FullName $script:workerSid) { $reachable += 'a user profile' }
        }
        $status = 'GREEN'; if ($reachable.Count) { $status = 'RED' }
        # Profiles are not named: this output may end up in a public place.
        Result $status 'worker isolation' "other fixed drives and user profiles readable by the worker=$($reachable.Count): $(($reachable | Sort-Object -Unique) -join ', ')"
    }
}
if ($Json) { ConvertTo-Json -InputObject @($results.ToArray()) -Depth 4 }
else { foreach ($r in $results) { Write-Output "$($r.status) $($r.item): $($r.detail)" } }
exit @($results | Where-Object { $_.status -eq 'RED' }).Count
