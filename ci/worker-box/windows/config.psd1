# Desired worker policy; reading this file never converges the machine.
@{
    # The agents' home, on a drive of its own: runner, workspaces, zig-cache, tools, bin and worker
    # state all live under it. The doctor derives RunnerRoot and ZigCache from it.
    Root = 'C:\fizzy'
    RunnerRepo = 'fizzyedit/work'
    RunnerName = 'FOXNNE-DESKTOP'
    BuildSlots = 2
    Services = @(
        @{ Name = 'Tailscale'; Account = 'LocalSystem' }
        @{ Name = 'sshd'; Account = 'LocalSystem' }
        # Manual: the FizzyWorker* tasks start and stop it, so Stopped is the worker being Off, not a fault.
        @{ Name = 'actions.runner.fizzyedit-work.*'; Account = '.\fizzy-worker'; StartMode = 'Manual'; State = 'Any' }
    )
    Tasks = @('FizzyRunnerClean', 'FizzyHeartbeat', 'FizzyUpdate', 'FizzyWorkerOn', 'FizzyWorkerOff', 'FizzyWorkerForceOff')
    # SYSTEM tasks in a folder fizzy-worker cannot write. Maintainer may trigger all three over SSH
    # (`schtasks /run`); the worker account may trigger Off only.
    WorkerTaskPath = '\Fizzy\'
    Maintainer = 'foxnn'
    Worker = 'fizzy-worker'
    # Runner and its children run at BelowNormal on at most this many logical cores (the highest
    # numbered ones); a machine with fewer cores than the cap is not restricted.
    CoreCap = 8
    AllowedUsers = @('foxnn', 'fizzy-worker')
    MinDiskFreeGiB = 100
    MinAvailableRamGiB = 4
    MaxPatchDays = 30
    MaxCacheGiB = 40
    # Empty pins report AMBER until the maintainer chooses a version in a policy PR.
    Tools = @(
        @{ Name = 'zig'; Args = @('version'); Version = '0.17.0' }
        @{ Name = 'git'; Args = @('--version'); Version = '' }
        @{ Name = 'jj'; Args = @('--version'); Version = '' }
        @{ Name = 'node'; Args = @('--version'); Version = '' }
        @{ Name = 'gh'; Args = @('--version'); Version = '' }
    )
}
