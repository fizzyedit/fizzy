# Clean only this dedicated worker's disposable build data (.zig-cache, zig-out, zig-pkg) that its
# jj/git checkouts do not track. Mirrors scripts/runner-clean.sh; the opt-in deletion of merged
# PR workspaces (the *.pr enrollment) is not ported to Windows.
[CmdletBinding()]
param([switch]$DryRun)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$root = if ($env:FIZZY_WORKER_ROOT) { $env:FIZZY_WORKER_ROOT } else { 'C:\fizzy' }
$cacheNames = @('.zig-cache', 'zig-out', 'zig-pkg')

if ($DryRun -and $env:OS -ne 'Windows_NT') {
    Write-Host "Would inspect running zig, zls and Runner.Worker processes."
    Write-Host "Would clean untracked caches under $root\workspaces and $root\actions-runner\_work."
    exit 0
}
if (-not (Test-Path $root -PathType Container)) { exit 0 }

# One sweep at a time; the lock is released if this process dies.
# (A dry run creates nothing.) The lock lives in workspaces, the one place the worker may write.
$lock = $null
if (-not $DryRun) {
    try {
        $lock = [IO.File]::Open("$root\workspaces\.runner-clean.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    } catch { exit 0 }
}

# A whole-sweep veto also protects builds whose compiler's cwd is outside the project.
function Test-Busy {
    $p = Get-Process -Name zig, zls, Runner.Worker -ErrorAction SilentlyContinue
    if ($p) { Write-Host "Busy process $($p[0].Id) ($($p[0].Name)); retaining all data"; return $true }
    return $false
}
if (Test-Busy) { exit 0 }

function Test-Reparse($path) {
    return ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0
}
function Long($path) { if ($path.StartsWith('\\?\')) { $path } else { '\\?\' + $path } }

# Walk a base: collect repositories (a directory holding .git or .jj) and cache directories,
# never entering caches, repository metadata or reparse points (symlinks and junctions).
function Find-Items($base) {
    $repos = New-Object Collections.Generic.List[string]
    $caches = New-Object Collections.Generic.List[string]
    $stack = New-Object Collections.Generic.Stack[string]
    $stack.Push($base)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        if ((Test-Path -LiteralPath "$dir\.git") -or (Test-Path -LiteralPath "$dir\.jj")) { $repos.Add($dir) }
        try { $children = [IO.Directory]::GetDirectories((Long $dir)) } catch { continue }
        foreach ($c in $children) {
            $c = $c -replace '^\\\\\?\\', ''
            $leaf = Split-Path -Leaf $c
            if ($leaf -eq '.git' -or $leaf -eq '.jj') { continue }
            if (Test-Reparse (Long $c)) { continue }
            if ($cacheNames -contains $leaf) { $caches.Add($c); continue }
            $stack.Push($c)
        }
    }
    return @{ Repos = $repos; Caches = $caches }
}

# Windows PowerShell 5.1 turns native stderr into a terminating error under 'Stop'; run natives under 'Continue'.
$nativeExit = 0
function Native([scriptblock]$cmd) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $cmd; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    $script:nativeExit = $code
    return $out
}
function Get-Tracked($repo) {
    # A successful, non-empty tracked-file query is required; a parent repo is not evidence.
    Push-Location $repo
    try {
        if (Test-Path -LiteralPath "$repo\.jj") { $out = Native { & jj --ignore-working-copy file list 2>$null } }
        else { $out = Native { & git ls-files 2>$null } }
        if ($nativeExit -ne 0 -or -not $out) { return $null }
        return @($out | ForEach-Object { ($_ -replace '\\', '/').Trim('"') })
    } catch { return $null } finally { Pop-Location }
}

# Walk a tree without following reparse points (symlinks, junctions). Returns the links found,
# the size, and whether any repository metadata (.git or .jj) is inside.
function Scan-Tree($path) {
    $links = New-Object Collections.Generic.List[string]
    $bytes = [long]0
    $meta = $false
    $readonly = New-Object Collections.Generic.List[string]
    $stack = New-Object Collections.Generic.Stack[string]
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $files = [IO.Directory]::GetFiles((Long $dir)) } catch { $files = @() }
        foreach ($f in $files) {
            $f = $f -replace '^\\\\\?\\', ''
            if (Test-Reparse (Long $f)) { $links.Add($f); continue }
            if ((Split-Path -Leaf $f) -in '.git', '.jj') { $meta = $true }
            try {
                $fi = New-Object IO.FileInfo (Long $f)
                $bytes += $fi.Length
                if ($fi.IsReadOnly) { $readonly.Add($f) }
            } catch {}
        }
        try { $dirs = [IO.Directory]::GetDirectories((Long $dir)) } catch { $dirs = @() }
        foreach ($d in $dirs) {
            $d = $d -replace '^\\\\\?\\', ''
            if (Test-Reparse (Long $d)) { $links.Add($d); continue }
            if ((Split-Path -Leaf $d) -in '.git', '.jj') { $meta = $true; continue }
            $stack.Push($d)
        }
    }
    return @{ Links = $links; Bytes = $bytes; Meta = $meta; ReadOnly = $readonly }
}

$freed = 0
function Remove-Cache($path, $scan) {
    if (Test-Busy) { return }
    $kb = [long]($scan.Bytes / 1KB)
    if ($DryRun) { Write-Host "Would remove $path ($kb KiB, $($scan.Links.Count) links)"; return }
    try {
        # .NET Framework (Windows PowerShell 5.1) may follow links in a recursive delete, so each
        # link goes first, by itself, and only then the now link-free tree.
        foreach ($l in $scan.Links) {
            if ([IO.Directory]::Exists((Long $l))) { [IO.Directory]::Delete((Long $l), $false) } else { [IO.File]::Delete((Long $l)) }
        }
        foreach ($f in $scan.ReadOnly) { [IO.File]::SetAttributes((Long $f), [IO.FileAttributes]::Normal) }
        [IO.Directory]::Delete((Long $path), $true)
        $script:freed += $kb
        Write-Host "Removed $path ($kb KiB)"
    } catch { Write-Host "Cannot remove $path ($_); retaining" }
}

foreach ($base in "$root\workspaces", "$root\actions-runner\_work") {
    if (-not (Test-Path -LiteralPath $base -PathType Container) -or (Test-Reparse $base)) { continue }
    $found = Find-Items $base
    $trackedByRepo = @{}
    foreach ($cache in $found.Caches) {
        # The nearest enclosing repository decides what is tracked.
        $repo = $null
        foreach ($r in ($found.Repos | Sort-Object Length -Descending)) {
            if ($cache.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { $repo = $r; break }
        }
        if (-not $repo) { Write-Host "Retaining $cache (no repository)"; continue }
        if (-not $trackedByRepo.ContainsKey($repo)) { $trackedByRepo[$repo] = Get-Tracked $repo }
        $tracked = $trackedByRepo[$repo]
        if ($null -eq $tracked) { Write-Host "Retaining $cache (cannot list tracked files)"; continue }
        $relative = $cache.Substring($repo.Length + 1) -replace '\\', '/'
        if ($tracked | Where-Object { $_ -eq $relative -or $_.StartsWith($relative + '/') }) {
            Write-Host "Retaining tracked cache $cache"; continue
        }
        $scan = Scan-Tree $cache
        if ($scan.Meta) { Write-Host "Retaining cache containing repository metadata $cache"; continue }
        Remove-Cache $cache $scan
    }
}
Write-Host "Cleanup freed $freed KiB"
if ($lock) { $lock.Dispose() }
