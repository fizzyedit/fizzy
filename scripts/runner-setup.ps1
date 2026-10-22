# Provision a dedicated Windows 11 Actions worker. Run from an elevated PowerShell (5.1 or newer);
# -DryRun needs no elevation and runs on any OS with pwsh. Mirrors scripts/runner-setup.sh.
# Invoke as: powershell -ExecutionPolicy Bypass -File .\scripts\runner-setup.ps1 [-DryRun]
# (the default Restricted policy refuses to run any script file).
#
# Environment (all optional except RUNNER_TOKEN on first run): RUNNER_TOKEN, RUNNER_URL,
# RUNNER_NAME, RUNNER_LABELS, FIZZY_BUILD_SLOTS, FIZZY_BUILD_MAX_LOAD, ZIG_VERSION, ZIG_SHA256,
# JJ_VERSION, RUNNER_VERSION, DEPS_CACHE_URL, DEPS_CACHE_SHA256, ZSTD_VERSION, ZSTD_SHA256, FIZZY_RUNNER_ALLOW_UNCHECKED,
# FIZZY_RUNNER_DEPS_PARTIAL_OK, FIZZY_RUNNER_NO_DEFENDER_EXCLUSION.
#
# Windows PowerShell 5.1 pitfall: with $ErrorActionPreference = 'Stop', a native command that
# writes anything to stderr (even `2>$null`) raises a terminating NativeCommandError. Every native
# call therefore goes through Native, which runs it under 'Continue'; callers check $nativeExit.
# CI exercises this file only under pwsh 7, which has no such behaviour, so keep that pattern.
[CmdletBinding()]
param([switch]$DryRun)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# Registration credentials must not enter traces, command arguments, or generated files:
# take the token out of the environment now; it goes back only into the one child that needs it.
$registrationToken = $env:RUNNER_TOKEN
Remove-Item Env:\RUNNER_TOKEN -ErrorAction SilentlyContinue

function Get-Setting($name, $default) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrEmpty($v)) { return $default }
    return $v
}
function Fail($msg) { [Console]::Error.WriteLine("ERROR: $msg"); exit 1 }
$nativeExit = 0
function Native([scriptblock]$cmd) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $cmd; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    $script:nativeExit = $code
    return $out
}

$worker = 'fizzy-worker'
$root = 'C:\fizzy'
$runner = "$root\actions-runner"
$workspaces = "$root\workspaces"
$tools = "$root\tools"
$bin = "$root\bin"
$zigCache = "$root\zig-cache"
$sourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$runnerUrl = Get-Setting 'RUNNER_URL' 'https://github.com/fizzyedit/work'
$buildSlots = Get-Setting 'FIZZY_BUILD_SLOTS' '2'
$buildMaxLoad = Get-Setting 'FIZZY_BUILD_MAX_LOAD' (Get-Setting 'NUMBER_OF_PROCESSORS' '4')
$runnerName = Get-Setting 'RUNNER_NAME' ([Environment]::MachineName)
$labels = Get-Setting 'RUNNER_LABELS' 'fizzy'

# Read the cloud bootstrap's default so the entry points cannot drift.
$zigVersion = Get-Setting 'ZIG_VERSION' ''
if (-not $zigVersion) {
    $m = Select-String -Path (Join-Path $sourceDir 'cloud-setup.sh') -Pattern '^zig_version="\$\{ZIG_VERSION:-([^}]*)\}"'
    if ($m) { $zigVersion = $m.Matches[0].Groups[1].Value }
}
if (-not $zigVersion) { Fail 'Cannot read cloud-setup.sh Zig version' }

function Step($text, [scriptblock]$action) {
    Write-Host "+ $text"
    if (-not $DryRun) { & $action }
}
function Invoke-GitHubApi($url) {
    try { return Invoke-RestMethod -UseBasicParsing -Uri $url -Headers @{ 'User-Agent' = 'fizzy-runner-setup' } }
    catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -eq 403 -or $status -eq 429) {
            Fail "GitHub refused $url (HTTP $status): the anonymous API rate limit is 60 requests an hour per address. Wait and rerun, or pin RUNNER_VERSION and JJ_VERSION to skip lookups."
        }
        Fail "GitHub API request failed: $url ($_)"
    }
}
function Get-Latest($repo) {
    return (Invoke-GitHubApi "https://api.github.com/repos/$repo/releases/latest").tag_name.TrimStart('v')
}
# The sha256 GitHub records for a release asset, or $null where it publishes none.
function Get-AssetDigest($release, $name) {
    foreach ($a in $release.assets) {
        if ($a.name -eq $name -and $a.PSObject.Properties['digest'] -and "$($a.digest)" -match '^sha256:([0-9a-fA-F]{64})$') {
            return $Matches[1]
        }
    }
    return $null
}
# $required: refuse a download with no digest (anything an administrator then executes or unpacks).
function Get-Verified($url, $dest, $sha, $what, [bool]$required = $false) {
    if ($required -and -not $sha) { Fail "$what has no published sha256 and is run as administrator; not downloading $url unverified." }
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
    if ($sha) {
        $actual = (Get-FileHash -Algorithm SHA256 -Path $dest).Hash.ToLower()
        if ($actual -ne $sha.ToLower()) { Remove-Item $dest -Force; Fail "$what sha256 mismatch: expected $sha, got $actual ($url)" }
        Write-Host "  $what sha256 verified"
    } else {
        Write-Warning "$what has no published digest; downloaded from $url without verification"
    }
}
function Unzip($zip, $dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
}
function Grant($path, $rights) {
    $null = Native { & icacls $path /grant $rights /C /Q 2>&1 }
    if ($script:nativeExit -ne 0) { Fail "icacls /grant $rights on $path failed ($script:nativeExit)" }
}

# The runner executes whatever the repository's workflows say, so it may only serve a private repo.
if ((Get-Setting 'FIZZY_RUNNER_ALLOW_UNCHECKED' '') -eq '1') {
    Write-Host "+ skip the private-repo check for $runnerUrl (FIZZY_RUNNER_ALLOW_UNCHECKED=1)"
} else {
    if ($runnerUrl -notmatch '^https://github\.com/([^/]+/[^/]+)/?$') {
        Fail "RUNNER_URL must be https://github.com/<owner>/<repo>: $runnerUrl"
    }
    $repoPath = $Matches[1]
    $verdict = $null
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $null = Native { & gh auth status 2>$null }
        if ($nativeExit -eq 0) {
            $out = Native { & gh api "repos/$repoPath" --jq .private 2>$null }
            if ($nativeExit -eq 0) { $verdict = "$out".Trim() }
        }
    }
    if ($verdict -eq 'true') {
        Write-Host "+ confirmed $repoPath is private"
    } elseif ($verdict) {
        Fail "Refusing $runnerUrl`: not confirmed private. Never register a runner on a public repo."
    } elseif ($DryRun) {
        Write-Host "+ (dry run) cannot verify $repoPath is private: gh is missing or not logged in; a real run would refuse"
    } else {
        [Console]::Error.WriteLine('Cannot verify the repository is private: gh is missing, not logged in, or cannot read it.')
        Fail 'Log in with gh (gh auth login), or set FIZZY_RUNNER_ALLOW_UNCHECKED=1 after checking by hand.'
    }
}

Write-Host '+ verify Windows 11, elevation, architecture, Git for Windows, and no active builds or Actions jobs'
$arch = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture
switch ($arch) {
    'X64'   { $zigArch = 'x86_64';  $jjArch = 'x86_64';  $runnerArch = 'x64' }
    'Arm64' { $zigArch = 'aarch64'; $jjArch = 'aarch64'; $runnerArch = 'arm64' }
    default { Fail 'Only x64 and arm64 are supported.' }
}
$gitRoot = 'C:\Program Files\Git'
if (-not $DryRun) {
    if ($env:OS -ne 'Windows_NT') { Fail 'Run on Windows 11.' }
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'Run from an elevated (Administrator) PowerShell.'
    }
    if ([Environment]::OSVersion.Version.Build -lt 22000) { Fail 'Windows 11 (build 22000) or newer is required.' }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) { Fail 'Install Git for Windows first (winget install Git.Git); the runner and scripts/zb need it.' }
    # git.exe is <root>\cmd\git.exe (or <root>\bin\git.exe); the root holds Git's bash.
    $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
    if (-not (Test-Path "$gitRoot\bin\bash.exe")) { Fail "Git for Windows' bash.exe not found at $gitRoot\bin; reinstall Git for Windows." }
    if (Get-Process -Name zig, zls, Runner.Worker -ErrorAction SilentlyContinue) {
        Fail 'Stop active builds and Actions jobs before provisioning.'
    }
}

# The runner's state: .runner is written by config.cmd, .service by the service install.
$configured = (Test-Path "$runner\.runner") -and (Test-Path "$runner\.service")
$partial = (Test-Path "$runner\.runner") -and -not (Test-Path "$runner\.service")
if (-not $DryRun -and -not $configured -and -not $registrationToken) {
    Fail 'Set RUNNER_TOKEN to a fresh GitHub runner registration token.'
}

# Pause the listener during a rerun so a queued job cannot start while tools are replaced.
if ($configured) {
    $serviceName = (Get-Content "$runner\.service" -Raw).Trim()
    Step "stop service $serviceName and wait for it to stop" {
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -ErrorAction Stop
            try { $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 60)) }
            catch { Fail "Service $serviceName did not stop within 60 seconds; not replacing tools under a live listener." }
        }
    }
}

# --- the dedicated, unprivileged account ------------------------------------------------------
$password = $null
function New-Password {
    $junk = New-Object byte[] 24
    (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($junk)
    return [Convert]::ToBase64String($junk) + 'aA1!'
}
Step "create local user $worker (not an administrator) if missing" {
    if (-not (Get-LocalUser -Name $worker -ErrorAction SilentlyContinue)) {
        $script:password = New-Password
        New-LocalUser -Name $worker -Password (ConvertTo-SecureString $script:password -AsPlainText -Force) `
            -FullName 'Fizzy Actions worker' -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires | Out-Null
    }
    # Refuse a privileged existing account rather than silently repurposing it. `net localgroup`
    # lists members as text, where Get-LocalGroupMember throws on an orphaned SID in 5.1.
    $adminSid = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $adminGroup = $adminSid.Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    $members = Native { & net localgroup $adminGroup 2>$null }
    if ($nativeExit -ne 0) { Fail "Cannot list the $adminGroup group (net localgroup exit $nativeExit); not creating or reusing $worker unchecked." }
    if ($members | Where-Object { $_.Trim() -ieq $worker -or $_.Trim() -like "*\$worker" }) {
        Fail "$worker must be an unprivileged dedicated account"
    }
}
# The scheduled cleanup runs as the worker without a stored password (S4U), which needs this right.
Step "grant $worker the right to log on as a batch job (LsaAddAccountRights, then LsaEnumerateAccountRights to verify)" {
    if (-not ('FizzyLsa' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class FizzyLsa {
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public int Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr policy, byte[] sid, ref LSA_UNICODE_STRING rights, uint count);
    [DllImport("advapi32.dll")] static extern uint LsaEnumerateAccountRights(IntPtr policy, byte[] sid, out IntPtr rights, out uint count);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr p);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr p);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    static IntPtr Open() {
        LSA_OBJECT_ATTRIBUTES attrs = new LSA_OBJECT_ATTRIBUTES();
        attrs.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr policy;
        uint st = LsaOpenPolicy(IntPtr.Zero, ref attrs, 0x810, out policy); // LOOKUP_NAMES | CREATE_ACCOUNT
        if (st != 0) throw new Exception("LsaOpenPolicy failed: win32 " + LsaNtStatusToWinError(st));
        return policy;
    }
    static byte[] Sid(string sid) {
        byte[] b = new byte[new SecurityIdentifier(sid).BinaryLength];
        new SecurityIdentifier(sid).GetBinaryForm(b, 0);
        return b;
    }
    public static void Add(string sid, string right) {
        IntPtr policy = Open();
        IntPtr text = Marshal.StringToHGlobalUni(right);
        try {
            LSA_UNICODE_STRING s = new LSA_UNICODE_STRING();
            s.Length = (ushort)(right.Length * 2);
            s.MaximumLength = (ushort)(s.Length + 2);
            s.Buffer = text;
            uint st = LsaAddAccountRights(policy, Sid(sid), ref s, 1);
            if (st != 0) throw new Exception("LsaAddAccountRights failed: win32 " + LsaNtStatusToWinError(st));
        } finally { Marshal.FreeHGlobal(text); LsaClose(policy); }
    }
    public static string[] Rights(string sid) {
        IntPtr policy = Open();
        try {
            IntPtr arr; uint count;
            uint st = LsaEnumerateAccountRights(policy, Sid(sid), out arr, out count);
            if (st == 0xC0000034) return new string[0]; // no rights at all
            if (st != 0) throw new Exception("LsaEnumerateAccountRights failed: win32 " + LsaNtStatusToWinError(st));
            string[] result = new string[count];
            int size = Marshal.SizeOf(typeof(LSA_UNICODE_STRING));
            try {
                for (int i = 0; i < count; i++) {
                    LSA_UNICODE_STRING s = (LSA_UNICODE_STRING)Marshal.PtrToStructure(new IntPtr(arr.ToInt64() + i * size), typeof(LSA_UNICODE_STRING));
                    result[i] = Marshal.PtrToStringUni(s.Buffer, s.Length / 2);
                }
            } finally { LsaFreeMemory(arr); }
            return result;
        } finally { LsaClose(policy); }
    }
}
'@
    }
    $sid = (Get-LocalUser -Name $worker).SID.Value
    [FizzyLsa]::Add($sid, 'SeBatchLogonRight')
    if ([FizzyLsa]::Rights($sid) -notcontains 'SeBatchLogonRight') { Fail "$worker did not get SeBatchLogonRight (LsaEnumerateAccountRights does not list it)" }
    if ([FizzyLsa]::Rights($sid) -contains 'SeDenyBatchLogonRight') { Fail "$worker is denied batch logon (SeDenyBatchLogonRight); remove it in local policy" }
}

# --- the directory layout and its access rules ------------------------------------------------
# C:\ gives Users Modify by inheritance, so the root drops inheritance first, before anything
# is created in it. Only SYSTEM and Administrators write the tools (they are on the machine PATH)
# and bin; the worker gets Modify on exactly the directories jobs write to.
Step "create $root with only SYSTEM and Administrators, then grant $worker per directory" {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $null = Native { & icacls $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /C /Q 2>&1 }
    if ($nativeExit -ne 0) { Fail "icacls on $root failed ($nativeExit)" }
    foreach ($d in $runner, $workspaces, $tools, "$tools\bin", $bin, $zigCache) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    # The runner checks execute permission on every parent directory, so the service account must
    # be able to open the root itself: read/execute on this folder only (no inheritance flag), so the
    # children stay locked.
    Grant $root "${worker}:(RX)"
    foreach ($d in $runner, $workspaces, $zigCache) { Grant $d "${worker}:(OI)(CI)M" }
    foreach ($d in $tools, $bin) { Grant $d "${worker}:(OI)(CI)RX" }
}

# --- Zig's dependency cache holds long paths and links ------------------------------------------
Step 'enable long paths (registry LongPathsEnabled, git core.longpaths)' {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -Type DWord
    $null = Native { & git config --system core.longpaths true 2>&1 }
    if ($nativeExit -ne 0) { Fail "git config --system core.longpaths failed ($nativeExit)" }
}
if ((Get-Setting 'FIZZY_RUNNER_NO_DEFENDER_EXCLUSION' '') -ne '1') {
    Step "exclude $root from Microsoft Defender real-time scanning (optional; FIZZY_RUNNER_NO_DEFENDER_EXCLUSION=1 skips)" {
        try { Add-MpPreference -ExclusionPath $root }
        catch { Write-Warning "Defender exclusion not added ($_); builds work without it, only slower" }
    }
}

# --- Zig, jj, zstd, all hash-checked where a digest is published ---------------------------------
# Short, admin-only path: archives unpack deep trees and powershell.exe has the 260-character limit.
$scratch = "$root\tmp\DRY-RUN"
if (-not $DryRun) {
    $scratch = "$root\tmp\" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    New-Item -ItemType Directory -Path $scratch | Out-Null
}
$jjVersion = Get-Setting 'JJ_VERSION' 'latest'
$runnerVersion = Get-Setting 'RUNNER_VERSION' 'latest'
$zstdVersion = $null
try {
    $haveZig = $false
    if (Test-Path "$tools\zig\zig.exe") {
        $haveZig = ("$(Native { & "$tools\zig\zig.exe" version 2>$null })".Trim() -eq $zigVersion)
    }
    if ($haveZig) { Write-Host "+ zig $zigVersion already installed" } else {
        Step "download zig $zigVersion for $zigArch-windows (sha256 from ziglang.org/download/index.json) to $tools\zig" {
            $url = "https://ziglang.org/download/$zigVersion/zig-$zigArch-windows-$zigVersion.zip"
            $sha = Get-Setting 'ZIG_SHA256' ''
            # The index is large; Windows PowerShell 5.1's ConvertFrom-Json can hit its size limit,
            # so fall back to a serializer with no limit.
            $raw = (Invoke-WebRequest -UseBasicParsing -Uri 'https://ziglang.org/download/index.json').Content
            $tarball = $null; $shasum = $null
            try {
                $r = ($raw | ConvertFrom-Json).PSObject.Properties[$zigVersion]
                if ($r -and $r.Value.PSObject.Properties["$zigArch-windows"]) {
                    $e = $r.Value.PSObject.Properties["$zigArch-windows"].Value
                    $tarball = $e.tarball; $shasum = $e.shasum
                }
            } catch {
                Add-Type -AssemblyName System.Web.Extensions
                $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                $ser.MaxJsonLength = [int]::MaxValue
                $d = $ser.DeserializeObject($raw)
                if ($d.ContainsKey($zigVersion) -and $d[$zigVersion].ContainsKey("$zigArch-windows")) {
                    $tarball = $d[$zigVersion]["$zigArch-windows"]['tarball']; $shasum = $d[$zigVersion]["$zigArch-windows"]['shasum']
                }
            }
            if ($tarball) { $url = $tarball }
            if (-not $sha) { $sha = $shasum }
            if (-not $sha) { Fail "No sha256 for zig $zigVersion in ziglang.org's index.json; set ZIG_SHA256 to the expected value." }
            Get-Verified $url "$scratch\zig.zip" $sha 'zig'
            Unzip "$scratch\zig.zip" "$scratch\zig"
            $inner = Get-ChildItem "$scratch\zig" -Directory | Select-Object -First 1
            if (Test-Path "$tools\zig") { Remove-Item -Recurse -Force "$tools\zig" }
            Move-Item $inner.FullName "$tools\zig"
        }
    }

    if ($jjVersion -eq 'latest') {
        Step 'resolve latest jj-vcs/jj release via GitHub API' { $script:jjVersion = Get-Latest 'jj-vcs/jj' }
    }
    Step "download jj and install to $tools\bin" {
        $asset = "jj-v$jjVersion-$jjArch-pc-windows-msvc.zip"
        $rel = Invoke-GitHubApi "https://api.github.com/repos/jj-vcs/jj/releases/tags/v$jjVersion"
        Get-Verified "https://github.com/jj-vcs/jj/releases/download/v$jjVersion/$asset" "$scratch\jj.zip" (Get-AssetDigest $rel $asset) 'jj'
        Unzip "$scratch\jj.zip" "$scratch\jj"
        Copy-Item "$scratch\jj\jj.exe" "$tools\bin\jj.exe" -Force
    }
    # tools\zig and tools\bin are admin-only, so they are safe on the machine PATH (for the person's
    # shell). The type of the value (REG_EXPAND_SZ) is kept, and the entries appended, not prepended.
    Step "append $tools\zig and $tools\bin to the machine PATH" {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
        try {
            $path = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind = $key.GetValueKind('Path')
            foreach ($d in "$tools\zig", "$tools\bin") {
                if (-not ($path.Split(';') | Where-Object { $_.TrimEnd('\') -ieq $d })) { $path = $path.TrimEnd(';') + ';' + $d }
            }
            $key.SetValue('Path', $path, $kind)
        } finally { $key.Close() }
    }

    # --- the Actions runner (never unpacked over a configured one: its updater owns it) ----------
    if (-not $configured) {
        if ($runnerVersion -eq 'latest') {
            Step 'resolve latest actions/runner release via GitHub API' { $script:runnerVersion = Get-Latest 'actions/runner' }
        }
        Step "download actions runner, verify its digest, and unpack to $runner" {
            $asset = "actions-runner-win-$runnerArch-$runnerVersion.zip"
            $rel = Invoke-GitHubApi "https://api.github.com/repos/actions/runner/releases/tags/v$runnerVersion"
            $sha = Get-AssetDigest $rel $asset
            if (-not $sha -and "$($rel.body)" -match "<!-- BEGIN SHA win-$runnerArch -->([0-9a-fA-F]{64})<!-- END SHA win-$runnerArch -->") { $sha = $Matches[1] }
            if (-not $sha) { Fail "No published sha256 for $asset; the runner is not installed unverified." }
            Get-Verified "https://github.com/actions/runner/releases/download/v$runnerVersion/$asset" "$scratch\runner.zip" $sha 'actions runner'
            # A partial earlier attempt may have left files; start from a clean runner directory.
            Get-ChildItem $runner -Force | Remove-Item -Recurse -Force
            Unzip "$scratch\runner.zip" $runner
        }
    }

    # --- dependency cache into the Zig global cache --------------------------------------------
    $depsUrl = Get-Setting 'DEPS_CACHE_URL' 'https://github.com/fizzyedit/fizzy/releases/download/deps-cache/zig-deps-linux.tar.zst'
    Step "restore the deps cache from $depsUrl into $zigCache" {
        # zstd publishes no digest, so its version and sha256 are pinned here (override both together).
        $zstdVersion = Get-Setting 'ZSTD_VERSION' '1.5.7'
        $zstdSha = Get-Setting 'ZSTD_SHA256' 'acb4e8111511749dc7a3ebedca9b04190e37a17afeb73f55d4425dbf0b90fad9'
        if ($zstdVersion -ne '1.5.7' -and -not (Get-Setting 'ZSTD_SHA256' '')) { Fail 'ZSTD_VERSION other than 1.5.7 needs ZSTD_SHA256.' }
        Get-Verified "https://github.com/facebook/zstd/releases/download/v$zstdVersion/zstd-v$zstdVersion-win64.zip" "$scratch\zstd.zip" $zstdSha 'zstd' $true
        Unzip "$scratch\zstd.zip" "$scratch\zstd"
        $zstd = Get-ChildItem "$scratch\zstd" -Recurse -Filter zstd.exe | Select-Object -First 1
        $dsha = Get-Setting 'DEPS_CACHE_SHA256' ''
        if (-not $dsha -and $depsUrl -match '^https://github\.com/fizzyedit/fizzy/releases/download/([^/]+)/([^/]+)$') {
            $dsha = Get-AssetDigest (Invoke-GitHubApi "https://api.github.com/repos/fizzyedit/fizzy/releases/tags/$($Matches[1])") $Matches[2]
        }
        # A cache from anywhere else is a different trust root: it needs a digest you supply.
        $depsDefault = ($depsUrl -like 'https://github.com/fizzyedit/fizzy/releases/download/deps-cache/*')
        Get-Verified $depsUrl "$scratch\deps.tar.zst" $dsha 'deps cache (set DEPS_CACHE_SHA256 for a non-default DEPS_CACHE_URL)' (-not $depsDefault)
        $null = Native { & $zstd.FullName -d -q "$scratch\deps.tar.zst" -o "$scratch\deps.tar" 2>&1 }
        if ($nativeExit -ne 0) { Fail "zstd failed ($nativeExit)" }
        # The archive is `p/<hash>/...` (deps-cache.yml: tar -C <cache> -cf - p). List it first so the
        # expected package count is known, and extract where its layout says, not where it is assumed.
        $tar = "$env:SystemRoot\System32\tar.exe"
        $listing = @(Native { & $tar -tf "$scratch\deps.tar" 2>$null } | ForEach-Object { "$_".Replace('\', '/') })
        if ($nativeExit -ne 0 -or $listing.Count -eq 0) { Fail "tar cannot list the deps archive (exit $nativeExit, $($listing.Count) entries, $((Get-Item "$scratch\deps.tar").Length) bytes)" }
        $under = if ($listing[0] -match '^(\./)?p(/|$)') { $zigCache } else { "$zigCache\p" }
        New-Item -ItemType Directory -Force -Path $under | Out-Null
        $expected = @($listing | Where-Object { $_ -match '^(\./)?(p/)?[^/]+/?$' -and $_ -notmatch '^(\./)?p/?$' }).Count
        $log = Native { & $tar -xf "$scratch\deps.tar" -C $under 2>&1 }
        $tarExit = $nativeExit
        $target = "$zigCache\p"
        $count = 0
        # Entries are package archives (p/<hash>.tar.gz files) or unpacked directories: count both.
        if (Test-Path $target) { $count = @([IO.Directory]::GetFileSystemEntries($target)).Count }
        Write-Host "  archive: $($listing.Count) entries ($expected packages), first '$($listing[0])'; extracted with -C $under; $count package entries in $target"
        if ($tarExit -ne 0 -or $count -eq 0 -or $count -lt $expected) {
            $log | Select-Object -First 10 | ForEach-Object { [Console]::Error.WriteLine("tar: $_") }
            if ($count -gt 0 -and (Get-Setting 'FIZZY_RUNNER_DEPS_PARTIAL_OK' '') -eq '1') {
                Write-Warning "PARTIAL RESTORE: $count packages in $zigCache\p, tar exited $tarExit; zig will fetch the rest"
            } else {
                Fail "Restoring the deps cache failed (tar exit $tarExit, $count packages). Set FIZZY_RUNNER_DEPS_PARTIAL_OK=1 to accept a partial restore."
            }
        } else { Write-Host "  restored $count packages" }
    }

    # The runner passes .env to every job, so scripts/zb inherits the slot count and load ceiling.
    # A service reads the machine environment only when the SCM starts, so the job PATH is set here
    # too, with Git for Windows' bash ahead of System32's WSL launcher bash.exe.
    Step "write build limits, ZIG_GLOBAL_CACHE_DIR and PATH to $runner\.env" {
        $keep = @()
        if (Test-Path "$runner\.env") {
            $keep = @(Get-Content "$runner\.env" | Where-Object { $_ -notmatch '^(FIZZY_BUILD_SLOTS|FIZZY_BUILD_MAX_LOAD|ZIG_GLOBAL_CACHE_DIR|PATH)=' })
        }
        $jobPath = "$gitRoot\cmd;$gitRoot\bin;$tools\zig;$tools\bin;" + [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $lines = $keep + @("FIZZY_BUILD_SLOTS=$buildSlots", "FIZZY_BUILD_MAX_LOAD=$buildMaxLoad", "ZIG_GLOBAL_CACHE_DIR=$zigCache", "PATH=$jobPath")
        [IO.File]::WriteAllText("$runner\.env", (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
    }

    # --- register and install the service, as the unprivileged account --------------------------
    if (-not $configured) {
        if ($partial) { Write-Host '+ an earlier run left .runner without the service: clear the local registration and register again with --replace' }
        Write-Host "+ configure runner as a Windows service running as $worker, token and password from the environment (redacted)"
        if (-not $DryRun) {
            if ($partial) { Remove-Item "$runner\.runner", "$runner\.credentials", "$runner\.credentials_rsaparams" -Force -ErrorAction SilentlyContinue }
            if (-not $password) {
                # The account pre-existed but the runner is new: set a fresh password only we know.
                $password = New-Password
                Set-LocalUser -Name $worker -Password (ConvertTo-SecureString $password -AsPlainText -Force)
            }
            $env:ACTIONS_RUNNER_INPUT_TOKEN = $registrationToken
            $env:ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD = $password
            try {
                Push-Location $runner
                $null = Native { & .\config.cmd --unattended --replace --url $runnerUrl --name $runnerName --labels $labels --work _work `
                    --runasservice --windowslogonaccount "$([Environment]::MachineName)\$worker" 2>&1 | ForEach-Object { Write-Host "$_" } }
                if ($nativeExit -ne 0) { Fail "config.cmd failed ($nativeExit); rerun with a fresh token" }
            } finally {
                Pop-Location
                Remove-Item Env:\ACTIONS_RUNNER_INPUT_TOKEN, Env:\ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD -ErrorAction SilentlyContinue
                $registrationToken = $null; $password = $null
            }
            if (-not (Test-Path "$runner\.service")) { Fail 'config.cmd succeeded but installed no service; rerun to register again.' }
        }
    }
} finally {
    if (-not $DryRun -and (Test-Path $scratch)) { Remove-Item -Recurse -Force $scratch }
}

Step 'start the runner service' {
    $svc = (Get-Content "$runner\.service" -Raw).Trim()
    try {
        Start-Service -Name $svc -ErrorAction Stop
        (Get-Service -Name $svc).WaitForStatus('Running', (New-TimeSpan -Seconds 60))
    } catch {
        $log = Get-ChildItem "$runner\_diag" -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $where = if ($log) { $log.FullName } else { "$runner\_diag" }
        Fail "Service $svc did not start ($_). Read $where (the Runner_*.log files in _diag) and the System event log for the service."
    }
}

# --- daily cleanup ----------------------------------------------------------------------------
Step "install runner-clean.ps1 to $bin and register the daily task FizzyRunnerClean (as $worker, S4U: no stored password)" {
    Copy-Item (Join-Path $sourceDir 'runner-clean.ps1') "$bin\runner-clean.ps1" -Force
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$bin\runner-clean.ps1`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 4am -RandomDelay (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId "$([Environment]::MachineName)\$worker" -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName FizzyRunnerClean -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Daily Fizzy worker disk hygiene' -Force | Out-Null
}
Step 'run the task once and check its result (0x80070569 means the batch-logon right is missing)' {
    Start-ScheduledTask -TaskName FizzyRunnerClean
    $deadline = (Get-Date).AddMinutes(3)
    do { Start-Sleep -Seconds 3 } while ((Get-ScheduledTask -TaskName FizzyRunnerClean).State -eq 'Running' -and (Get-Date) -lt $deadline)
    $result = (Get-ScheduledTaskInfo -TaskName FizzyRunnerClean).LastTaskResult
    if ($result -ne 0) { Fail ("FizzyRunnerClean last result 0x{0:X}; the runner is up but the daily cleanup does not run." -f $result) }
    Write-Host '  FizzyRunnerClean ran and returned 0'
}
if ($DryRun) { Write-Host 'Dry run complete; no changes made.' } else {
    Write-Host 'Worker ready. Verify per docs/AGENT_WORK.md, "Self-hosted runner (Windows)".'
}
