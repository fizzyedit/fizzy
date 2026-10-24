# Pester-free doctor contract tests. Runs on pwsh 7 and Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$doctor = [IO.Path]::GetFullPath("$PSScriptRoot/../ci/worker-box/windows/doctor.ps1")
$engine = (Get-Process -Id $PID).Path
function Assert($condition, $message) { if (-not $condition) { throw $message } }
# Windows PowerShell 5.1 emits a JSON array as ONE object (pwsh 7 unrolls it), and joins nothing
# from piped lines, so join first and enumerate the parsed array explicitly.
function ConvertFrom-JsonRows($lines) {
    $parsed = ConvertFrom-Json -InputObject (@($lines) -join "`n")
    $rows = @(); foreach ($row in $parsed) { $rows += $row }
    return , $rows
}
$preview = & $engine -NoProfile -ExecutionPolicy Bypass -File $doctor -DryRun
Assert ($LASTEXITCODE -eq 0) 'DryRun must have no reds'
Assert (@($preview).Count -ge 20) 'DryRun omitted checks'
foreach ($line in $preview) { Assert ($line -match '^AMBER [^:]+: .+$') "Invalid preview line: $line" }
$previewJson = ConvertFrom-JsonRows (& $engine -NoProfile -ExecutionPolicy Bypass -File $doctor -DryRun -Json)
Assert ($previewJson.Count -eq @($preview).Count) 'JSON and text checks differ'
Assert (@($previewJson | Where-Object { $_.status -ne 'AMBER' }).Count -eq 0) 'DryRun queried a probe'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('doctor-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # Isolate policy and query providers. No registry, services, credentials or installs are changed.
    $fixture = @'
@{
    Services = @(@{ Name = 'test-service'; Account = 'LocalSystem' })
    RunnerRoot = 'missing-runner'; RunnerRepo = 'test/repo'; RunnerName = 'test'
    Tasks = @('test-task'); AllowedUsers = @('allowed')
    Tools = @(@{ Name = 'missing-tool'; Args = @('--version'); Version = '1.0' })
    MinDiskFreeGiB = 100; MinAvailableRamGiB = 4; MaxPatchDays = 30
    MaxCacheGiB = 40; ZigCache = 'missing-cache'; BuildSlots = 2
}
'@
    Set-Content -LiteralPath "$tmp/config.psd1" -Value $fixture
    $harness = @'
param($doctor, $config, $mode, $local = 'missing-local.psd1')
$env:GH_TOKEN = ''; $env:GITHUB_TOKEN = ''
function Get-CimInstance {
    param($ClassName, $Filter)
    switch ($ClassName) {
        'Win32_Service' {
            [pscustomobject]@{ Name = 'test-service'; State = 'Stopped'; StartMode = 'Manual'; StartName = 'LocalSystem' }
        }
        'Win32_OperatingSystem' {
            [pscustomobject]@{ LastBootUpTime = (Get-Date).AddDays(-1); FreePhysicalMemory = 8MB; TotalVisibleMemorySize = 32MB }
        }
        'Win32_LogicalDisk' { [pscustomobject]@{ DeviceID = 'X:'; FreeSpace = 10GB } }
    }
}
function Get-LocalUser {
    [pscustomobject]@{ Name = 'stray'; SID = [pscustomobject]@{ Value = 'S-1-5-21-123-1001' } }
}
function Get-ScheduledTask { param($TaskName, $ErrorAction) return }
function Get-HotFix { [pscustomobject]@{ HotFixID = 'fixture'; InstalledOn = (Get-Date).AddDays(-40) } }
function Get-WinEvent { param($FilterHashtable) throw 'fixture denied' }
function Get-ItemProperty { param($LiteralPath) throw 'fixture denied' }
function Get-ItemPropertyValue { param($LiteralPath, $Name) return 1 }
if ($mode -eq 'json') { & $doctor -ConfigPath $config -LocalConfigPath $local -Json }
else { & $doctor -ConfigPath $config -LocalConfigPath $local }
exit $LASTEXITCODE
'@
    Set-Content -LiteralPath "$tmp/harness.ps1" -Value $harness
    $raw = & $engine -NoProfile -ExecutionPolicy Bypass -File "$tmp/harness.ps1" $doctor "$tmp/config.psd1" json
    $code = $LASTEXITCODE
    $rows = ConvertFrom-JsonRows $raw
    $reds = @($rows | Where-Object { $_.status -eq 'RED' }).Count
    Assert ($reds -ge 5 -and $code -eq $reds) "Fixture exit=$code; reds=$reds"
    foreach ($pair in @(
        @('service test-service', 'RED'), @('disk X:', 'RED'), @('task test-task', 'RED'),
        @('local users', 'AMBER'), @('last patch', 'AMBER'), @('unclean shutdowns', 'AMBER'),
        @('runner Online', 'AMBER'), @('RAM', 'GREEN'), @('tool missing-tool', 'AMBER')
    )) {
        $row = @($rows | Where-Object { $_.item -eq $pair[0] })
        Assert ($row.Count -eq 1 -and $row[0].status -eq $pair[1]) "Wrong fixture result: $($pair[0])"
    }
    # A local file overrides the repo policy key by key.
    Set-Content -LiteralPath "$tmp/local.psd1" -Value "@{ Tasks = @('other-task') }"
    $rows = ConvertFrom-JsonRows (& $engine -NoProfile -ExecutionPolicy Bypass -File "$tmp/harness.ps1" $doctor "$tmp/config.psd1" json "$tmp/local.psd1")
    Assert (@($rows | Where-Object { $_.item -eq 'task other-task' }).Count -eq 1) 'Local override ignored'
    Assert (@($rows | Where-Object { $_.item -eq 'task test-task' }).Count -eq 0) 'Local override did not replace the key'
    $text = & $engine -NoProfile -ExecutionPolicy Bypass -File "$tmp/harness.ps1" $doctor "$tmp/config.psd1" text
    Assert ($LASTEXITCODE -eq $reds) 'Text exit differs'
    Assert (@($text).Count -eq $rows.Count) 'Text and JSON counts differ'
    foreach ($line in $text) { Assert ($line -match '^(GREEN|RED|AMBER) .+: .+$') "Invalid line: $line" }
    Write-Output "ok: preview, JSON, fixture statuses, text and exit count ($reds reds)"
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }

if ($env:OS -eq 'Windows_NT') {
    # Hosted VM health is evidence about these probes, not the dedicated worker's health.
    $raw = & $engine -NoProfile -ExecutionPolicy Bypass -File $doctor -Json
    $code = $LASTEXITCODE
    Write-Output $raw
    $rows = ConvertFrom-JsonRows $raw
    Assert ($code -eq @($rows | Where-Object { $_.status -eq 'RED' }).Count) 'Hosted VM exit count differs'
    Assert ($rows.Count -ge 20) 'Hosted VM omitted checks'
    Write-Output "ok: hosted VM read-only probes; exit=$code (worker policy reds are expected here)"
}
# Successful contract checks must not inherit the expected unhealthy probe exit status.
exit 0
