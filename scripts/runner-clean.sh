#!/usr/bin/env bash
# Clean only this dedicated worker's disposable build data and enrolled PR workspaces.
set -euo pipefail

dry_run=false
case "${1:-}" in
    --dry-run) dry_run=true ;;
    '') ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || exit 2
worker_home=${FIZZY_WORKER_HOME:-/home/fizzy-worker}
if [ "$(uname -s)" != Linux ]; then
    if "$dry_run"; then
        echo "Would inspect Linux /proc for active Zig, ZLS and Actions jobs."
        echo "Would clean untracked caches under $worker_home/{workspaces,actions-runner/_work}."
        echo "Would check enrolled PRs in $worker_home/.config/fizzy/workspaces/*.pr."
        exit 0
    fi
    echo 'runner-clean requires Linux /proc' >&2; exit 1
fi
[ -d "$worker_home" ] && [ ! -L "$worker_home" ] || exit 0
worker_home=$(realpath -e "$worker_home")
exec 9>"$worker_home/.runner-clean.lock"
flock -n 9 || exit 0

# A whole-sweep veto also protects builds whose compiler's cwd is outside the project.
# Check all users: a root-started build can still be using a worker's packages.
busy() {
    local proc comm
    if [ ! -r /proc/self/comm ]; then
        echo 'Cannot inspect /proc; retaining all data'
        return 0
    fi
    for proc in /proc/[0-9]*; do
        if ! IFS= read -r comm 2>/dev/null < "$proc/comm"; then
            [ ! -d "$proc" ] && continue
            echo "Cannot inspect $proc; retaining all data"
            return 0
        fi
        case "$comm" in
            zig|zls|Runner.Worker*) echo "Busy process ${proc##*/} ($comm); retaining all data"; return 0 ;;
        esac
    done
    return 1
}
busy && exit 0
tracked_file=$(mktemp "$worker_home/.runner-clean.XXXXXX")
trap 'rm -f -- "$tracked_file"' EXIT
freed=0
remove() {
    local path=$1 kb
    busy && return 0
    kb=$(du -sk -- "$path" | cut -f1)
    if "$dry_run"; then
        printf 'Would remove %q (%s KiB)\n' "$path" "$kb"
    else
        rm -rf --one-file-system -- "$path"
        freed=$((freed + kb))
        printf 'Removed %q (%s KiB)\n' "$path" "$kb"
    fi
}

# A successful tracked-file query is required; an unrelated parent git repo is not evidence.
clean_caches() {
    local repo=$1 cache relative file is_tracked parent nested
    local -a tracked
    if [ -d "$repo/.jj" ]; then
        jj -R "$repo" --ignore-working-copy file list -T 'path ++ "\0"' > "$tracked_file" || return 0
    elif [ -e "$repo/.git" ]; then
        git -C "$repo" ls-files -z > "$tracked_file" || return 0
    else
        return 0
    fi
    mapfile -d '' -t tracked < "$tracked_file"
    while IFS= read -r -d '' cache; do
        # Nested repositories must use their own tracked-file list.
        parent=${cache%/*}
        nested=false
        while [ "$parent" != "$repo" ]; do
            if [ -e "$parent/.git" ] || [ -d "$parent/.jj" ]; then nested=true; break; fi
            parent=${parent%/*}
        done
        "$nested" && continue
        nested=$(find "$cache" \( -name .git -o -name .jj \) -print -quit)
        if [ -n "$nested" ]; then
            printf 'Retaining cache containing repository metadata %q\n' "$cache"
            continue
        fi
        relative=${cache#"$repo/"}
        is_tracked=false
        for file in "${tracked[@]}"; do
            case "$file" in "$relative"|"$relative"/*) is_tracked=true; break ;; esac
        done
        if "$is_tracked"; then
            printf 'Retaining tracked cache %q\n' "$cache"
            continue
        fi
        remove "$cache"
    done < <(find "$repo" -type d \( -name .git -o -name .jj \) -prune -o \
        -type d \( -name .zig-cache -o -name zig-out -o -name zig-pkg \) -prune -print0)
}

for base in "$worker_home/workspaces" "$worker_home/actions-runner/_work"; do
    [ -d "$base" ] && [ ! -L "$base" ] || continue
    # Discover nested Actions checkouts as well as top-level jj workspaces, without entering caches.
    while IFS= read -r -d '' metadata; do
        clean_caches "${metadata%/*}"
    done < <(find "$base" -type d \( -name .zig-cache -o -name zig-out -o -name zig-pkg \) -prune -o \
        \( -name .git -o -name .jj \) -print0 -prune)
done

for enrollment in "$worker_home"/.config/fizzy/workspaces/*.pr; do
    [ -f "$enrollment" ] && [ ! -L "$enrollment" ] || continue
    name=${enrollment##*/}; name=${name%.pr}
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || continue
    workspace=$worker_home/workspaces/$name
    [ -d "$workspace" ] && [ ! -L "$workspace" ] || continue
    # Nested symlinks could otherwise make metadata checks inspect a different checkout.
    [ "$(realpath -e "$workspace")" = "$workspace" ] || continue
    pr=$(cat "$enrollment")
    [[ "$pr" =~ ^https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/pull/[0-9]+$ ]] || continue
    if ! result=$(gh pr view "$pr" --json state,headRefOid --jq '[.state,.headRefOid] | @tsv'); then
        echo "Cannot look up $pr; retaining $workspace"; continue
    fi
    read -r state head <<< "$result"
    [ "$state" = MERGED ] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || continue
    # Nested repositories and submodules have their own changes; retain their container.
    nested=$(find "$workspace" -mindepth 1 \( -path "$workspace/.git" -o -path "$workspace/.jj" \) -prune -o \
        \( -name .git -o -name .jj \) -print -quit)
    [ -z "$nested" ] || continue
    if [ -d "$workspace/.jj" ]; then
        # Shared repo storage must live outside the directory being removed.
        [ -f "$workspace/.jj/repo" ] && [ ! -L "$workspace/.jj" ] || continue
        repo_pointer=$(cat "$workspace/.jj/repo")
        repo_path=$(realpath -e "$workspace/.jj/$repo_pointer") || continue
        case "$repo_path/" in "$workspace/"*) continue ;; esac
        # Snapshot first, so edits made after the last jj command cannot be discarded.
        if "$dry_run"; then
            echo "Would snapshot $workspace, check for edits and match its parent to $head; forget and remove only if clean"
            continue
        fi
        diff=$(jj -R "$workspace" diff --summary) || continue
        [ -z "$diff" ] || continue
        parent=$(jj -R "$workspace" log --no-graph -r @- -T 'commit_id') || continue
        [ "$parent" = "$head" ] || continue
        # Ignored files are disposable only because the maintainer explicitly enrolled this workspace.
        busy && break
        if ! "$dry_run"; then jj -R "$workspace" workspace forget || continue; fi
    elif [ -d "$workspace/.git" ] && [ ! -L "$workspace/.git" ]; then
        status=$(git -C "$workspace" status --porcelain --untracked-files=all) || continue
        [ -z "$status" ] || continue
        current=$(git -C "$workspace" rev-parse HEAD) || continue
        [ "$current" = "$head" ] || continue
        # A clone with other worktrees owns metadata they need; retain it.
        worktrees=$(git -C "$workspace" worktree list --porcelain | awk '/^worktree / { n++ } END {print n}')
        [ "$worktrees" = 1 ] || continue
    else
        echo "Retaining unsupported workspace $workspace"; continue
    fi
    remove "$workspace"
    if ! "$dry_run" && [ ! -e "$workspace" ]; then rm -- "$enrollment"; fi
done
printf 'Cleanup freed %s KiB\n' "$freed"
