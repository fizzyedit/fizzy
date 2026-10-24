# Read-only Windows worker diagnostics. Unknown or inaccessible evidence is AMBER.
# -DryRun lists checks without probing; normal execution never changes system configuration.
# A local .psd1 (-LocalConfigPath, else FIZZY_DOCTOR_LOCAL, else C:\fizzy\doctor.local.psd1) overrides
# config.psd1 key by key, so one box's names stay off the repo. Exit status is the number of RED results. JSON is an array of status/item/detail objects.
#requires -Version 5.1
[CmdletBinding()]
param([switch]$Json, [switch]$DryRun, [string]$ConfigPath, [string]$LocalConfigPath)
Set-StrictMode -Version 2
# $PSScriptRoot is empty inside a param() default in Windows PowerShell 5.1, so resolve it here.
if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.psd1' }
$ErrorActionPreference = 'Stop'
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
if (-not $LocalConfigPath) { $LocalConfigPath = $env:FIZZY_DOCTOR_LOCAL }
if (-not $LocalConfigPath) { $LocalConfigPath = 'C:\fizzy\doctor.local.psd1' }
if (Test-Path -LiteralPath $LocalConfigPath -PathType Leaf) {
    $local = Import-PowerShellDataFile -LiteralPath $LocalConfigPath
    foreach ($key in $local.Keys) { $config[$key] = $local[$key] }
}
if (-not $config.RunnerName) { $config.RunnerName = $env:COMPUTERNAME }
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
        if ($s.State -eq 'Running' -and $s.StartMode -eq 'Auto' -and $account -ieq $spec.Account) { $status = 'GREEN' }
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
    Result $status 'runner Online' "repo=$($config.RunnerRepo); name=$($config.RunnerName); matching online=$(@($runners | Where-Object { $_.status -eq 'online' }).Count)"
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
    if (-not (Test-Path -LiteralPath $config.ZigCache -PathType Container)) { Result RED 'zig-cache' 'configured directory missing'; return }
    # Never follow junctions, even when they occur inside a cache.
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($config.ZigCache)
    $bytes = [long]0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($stack.Count) {
        if ($clock.Elapsed.TotalSeconds -gt 60) { Result AMBER 'zig-cache' 'sizing stopped after 60 s; cache too large to measure here'; return }
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
    Result $status 'zig-cache' "$($config.ZigCache); size=$size GiB; limit=$($config.MaxCacheGiB) GiB"
}
$runnerPath = $null
Check 'runner PATH' {
    $lines = @(Get-Content -LiteralPath (Join-Path $config.RunnerRoot '.env') | Where-Object { $_ -match '^PATH=' })
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
if ($Json) { ConvertTo-Json -InputObject @($results.ToArray()) -Depth 4 }
else { foreach ($r in $results) { Write-Output "$($r.status) $($r.item): $($r.detail)" } }
exit @($results | Where-Object { $_.status -eq 'RED' }).Count
