# Desired worker policy; reading this file never converges the machine. Machine-specific values
# (runner name, extra users and tasks) belong in a local file the box reads, not here: see
# doctor.ps1 -LocalConfigPath.
@{
    RunnerRoot = 'C:\fizzy\actions-runner'
    RunnerRepo = 'fizzyedit/work'
    # Empty means this machine's name.
    RunnerName = ''
    BuildSlots = 2
    Services = @(
        @{ Name = 'Tailscale'; Account = 'LocalSystem' }
        @{ Name = 'sshd'; Account = 'LocalSystem' }
        @{ Name = 'actions.runner.fizzyedit-work.*'; Account = '.\fizzy-worker' }
    )
    Tasks = @('FizzyRunnerClean')
    AllowedUsers = @('fizzy-worker')
    MinDiskFreeGiB = 100
    MinAvailableRamGiB = 4
    MaxPatchDays = 30
    MaxCacheGiB = 40
    ZigCache = 'C:\fizzy\zig-cache'
    # Empty pins report AMBER until the maintainer chooses a version in a policy PR.
    Tools = @(
        @{ Name = 'zig'; Args = @('version'); Version = '0.17.0' }
        @{ Name = 'git'; Args = @('--version'); Version = '' }
        @{ Name = 'jj'; Args = @('--version'); Version = '' }
        @{ Name = 'node'; Args = @('--version'); Version = '' }
        @{ Name = 'gh'; Args = @('--version'); Version = '' }
    )
}
