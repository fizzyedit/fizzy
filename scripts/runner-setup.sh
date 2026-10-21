#!/usr/bin/env bash
# Provision a dedicated Ubuntu Actions worker. Run as root; --dry-run needs no privileges.
set -euo pipefail
# Registration credentials must not enter traces, command arguments, or generated files.
set +x
registration_token=${RUNNER_TOKEN:-}
unset RUNNER_TOKEN

dry_run=false
case "${1:-}" in
    --dry-run) dry_run=true ;;
    '') ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || exit 2
worker=fizzy-worker
worker_home=/home/$worker
runner=$worker_home/actions-runner
source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
runner_url=${RUNNER_URL:-https://github.com/fizzyedit/work}
build_slots=${FIZZY_BUILD_SLOTS:-2}
build_max_load=${FIZZY_BUILD_MAX_LOAD:-$(getconf _NPROCESSORS_ONLN)}
runner_name=${RUNNER_NAME:-$(hostname)}
labels=${RUNNER_LABELS:-fizzy}
# Read the cloud bootstrap's default so these two entry points cannot drift.
# shellcheck disable=SC2016 # Match the literal default expression in cloud-setup.sh.
zig_version=${ZIG_VERSION:-$(sed -n 's/^zig_version="${ZIG_VERSION:-\([^}]*\)}"/\1/p' "$source_dir/cloud-setup.sh")}
[ -n "$zig_version" ] || { echo 'Cannot read cloud-setup.sh Zig version' >&2; exit 1; }

run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if ! "$dry_run"; then "$@"; fi
}
write_file() {
    echo "+ write $1"
    if "$dry_run"; then cat; else cat > "$1"; fi
}
latest() {
    curl -fsSL --retry 4 "https://api.github.com/repos/$1/releases/latest" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].removeprefix("v"))'
}

# The runner executes whatever the repository's workflows say, so it may only serve a private repo.
if [ "${FIZZY_RUNNER_ALLOW_UNCHECKED:-}" = 1 ]; then
    echo "+ skip the private-repo check for $runner_url (FIZZY_RUNNER_ALLOW_UNCHECKED=1)"
else
    repo_path=${runner_url#https://github.com/}
    repo_path=${repo_path%/}
    case "$repo_path" in
        */*/* | */ | /* | "$runner_url") repo_path= ;;
        */*) ;;
        *) repo_path= ;;
    esac
    [ -n "$repo_path" ] || {
        echo "RUNNER_URL must be https://github.com/<owner>/<repo>: $runner_url" >&2; exit 1;
    }
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
        echo 'Cannot verify the repository is private: gh is missing or not logged in.' >&2
        echo 'Log in with gh, or set FIZZY_RUNNER_ALLOW_UNCHECKED=1 after checking by hand.' >&2
        exit 1
    fi
    [ "$(gh api "repos/$repo_path" --jq .private 2>/dev/null)" = true ] || {
        echo "Refusing $runner_url: not confirmed private. Never register a runner on a public repo." >&2
        exit 1
    }
    echo "+ confirmed $repo_path is private"
fi

echo '+ verify Ubuntu >=24.04, root, systemd, architecture, and no active builds or Actions jobs'
if ! "$dry_run"; then
    [ "$(uname -s)" = Linux ] && [ "$(id -u)" -eq 0 ] || {
        echo 'Run as root on Ubuntu with systemd.' >&2; exit 1;
    }
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "$ID" = ubuntu ] && dpkg --compare-versions "$VERSION_ID" ge 24.04 && [ -d /run/systemd/system ] || {
        echo 'Ubuntu 24.04 or newer with systemd is required.' >&2; exit 1;
    }
    if pgrep -x 'zig|zls|Runner.Worker' >/dev/null; then
        echo 'Stop active builds and Actions jobs before provisioning.' >&2; exit 1
    fi
    if [ ! -f "$runner/.runner" ] && [ -z "${registration_token:-}" ]; then
        echo 'Set RUNNER_TOKEN to a fresh GitHub runner registration token.' >&2; exit 1
    fi
fi
case "$(uname -m)" in
    x86_64) runner_arch=x64; jj_arch=x86_64 ;;
    aarch64|arm64) runner_arch=arm64; jj_arch=aarch64 ;;
    *) echo 'Only x86_64 and aarch64 are supported.' >&2; exit 1 ;;
esac

# Pause the listener during a rerun so a queued job cannot start while tools are replaced.
if [ -f "$runner/.service" ]; then
    run bash -c 'cd "$1" && ./svc.sh stop' _ "$runner"
fi
run apt-get update
run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl git gh zstd xz-utils python3 python3-venv jq \
    build-essential pkg-config libwayland-dev libxkbcommon-dev libx11-dev \
    libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxfixes-dev libxss-dev \
    libasound2-dev libpulse-dev libegl-dev libgl-dev \
    mesa-vulkan-drivers libvulkan1 vulkan-tools xvfb xauth
if ! id "$worker" >/dev/null 2>&1; then
    run useradd --create-home --user-group --shell /bin/bash "$worker"
fi
if ! "$dry_run"; then
    [ "$(getent passwd "$worker" | cut -d: -f6)" = "$worker_home" ] || {
        echo "Existing $worker has an unexpected home" >&2; exit 1;
    }
    # Refuse a privileged existing account rather than silently repurposing it.
    [ "$(id -u "$worker")" -ne 0 ] || exit 1
    if id -nG "$worker" | tr ' ' '\n' | grep -Eq '^(sudo|admin|wheel|docker|lxd)$'; then
        echo "$worker must be an unprivileged dedicated account" >&2; exit 1
    fi
fi
run install -d -o "$worker" -g "$worker" "$runner" "$worker_home/workspaces" "$worker_home/.cache/zig"
run python3 -m venv /opt/fizzy-zig
run /opt/fizzy-zig/bin/pip install "ziglang==$zig_version"
if "$dry_run"; then
    echo '+ locate ziglang with /opt/fizzy-zig/bin/python and link its zig into /usr/local/bin'
else
    zig_binary=$(/opt/fizzy-zig/bin/python -I -c 'import pathlib,ziglang; print(pathlib.Path(ziglang.__file__).parent / "zig")')
    run ln -sfn "$zig_binary" /usr/local/bin/zig
fi

scratch=/tmp/fizzy-runner-setup.DRY-RUN
if ! "$dry_run"; then scratch=$(mktemp -d); fi
trap 'if ! "$dry_run"; then rm -rf -- "$scratch"; fi' EXIT
jj_version=${JJ_VERSION:-latest}
if [ "$jj_version" = latest ]; then
    echo '+ resolve latest jj-vcs/jj release via GitHub API'
    if ! "$dry_run"; then jj_version=$(latest jj-vcs/jj); fi
fi
run curl -fL --retry 4 -o "$scratch/jj.tar.gz" \
    "https://github.com/jj-vcs/jj/releases/download/v$jj_version/jj-v$jj_version-$jj_arch-unknown-linux-musl.tar.gz"
run mkdir -p "$scratch/jj"
run tar -xzf "$scratch/jj.tar.gz" -C "$scratch/jj"
run install -m 0755 "$scratch/jj/jj" /usr/local/bin/jj
# Never unpack over a configured runner: its own updater manages that installation.
if [ ! -f "$runner/.runner" ]; then
    runner_version=${RUNNER_VERSION:-latest}
    if [ "$runner_version" = latest ]; then
        echo '+ resolve latest actions/runner release via GitHub API'
        if ! "$dry_run"; then runner_version=$(latest actions/runner); fi
    fi
    run curl -fL --retry 4 -o "$scratch/runner.tar.gz" \
        "https://github.com/actions/runner/releases/download/v$runner_version/actions-runner-linux-$runner_arch-$runner_version.tar.gz"
    run tar -xzf "$scratch/runner.tar.gz" -C "$runner"
    run "$runner/bin/installdependencies.sh"
    run chown -R "$worker:$worker" "$runner"
fi
run curl -fL --retry 4 -o "$scratch/deps.tar.zst" \
    "${DEPS_CACHE_URL:-https://github.com/fizzyedit/fizzy/releases/download/deps-cache/zig-deps-linux.tar.zst}"
run chmod 0755 "$scratch"
run chmod 0644 "$scratch/deps.tar.zst"
run runuser -u "$worker" -- tar --zstd -xf "$scratch/deps.tar.zst" -C "$worker_home/.cache/zig"
if [ ! -f "$runner/.runner" ]; then
    echo '+ configure runner as fizzy-worker using RUNNER_TOKEN from environment (redacted)'
    if ! "$dry_run"; then
        export ACTIONS_RUNNER_INPUT_TOKEN=$registration_token
        unset registration_token
        (cd "$runner" && runuser -u "$worker" -- ./config.sh --unattended \
            --url "$runner_url" --name "$runner_name" --labels "$labels" --work _work)
        unset ACTIONS_RUNNER_INPUT_TOKEN
    fi
fi
# The runner passes .env to every job, so scripts/zb inherits the slot count and load ceiling.
run bash -c 'touch "$1/.env" && sed -i "/^FIZZY_BUILD_\(SLOTS\|MAX_LOAD\)=/d" "$1/.env" &&
    printf "FIZZY_BUILD_SLOTS=%s\nFIZZY_BUILD_MAX_LOAD=%s\n" "$2" "$3" >> "$1/.env" &&
    chown "$4:$4" "$1/.env"' _ "$runner" "$build_slots" "$build_max_load" "$worker"
if [ ! -f "$runner/.service" ]; then
    run bash -c 'cd "$1" && ./svc.sh install "$2"' _ "$runner" "$worker"
fi
run bash -c 'cd "$1" && ./svc.sh start' _ "$runner"
run install -m 0755 "$source_dir/runner-clean.sh" /usr/local/sbin/fizzy-runner-clean
write_file /etc/systemd/system/fizzy-runner-clean.service <<'UNIT'
[Unit]
Description=Clean idle Fizzy worker caches and merged workspaces
[Service]
Type=oneshot
User=fizzy-worker
Environment=HOME=/home/fizzy-worker
ExecStart=/usr/local/sbin/fizzy-runner-clean
Nice=19
UNIT
write_file /etc/systemd/system/fizzy-runner-clean.timer <<'UNIT'
[Unit]
Description=Daily Fizzy worker disk hygiene
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m
[Install]
WantedBy=timers.target
UNIT
run systemctl daemon-reload
run systemctl enable --now fizzy-runner-clean.timer
if "$dry_run"; then echo 'Dry run complete; no changes made.'; else
    echo 'Worker ready. Cleanup logs: journalctl -u fizzy-runner-clean.service'
fi
