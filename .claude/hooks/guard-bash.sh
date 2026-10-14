#!/usr/bin/env bash
# PreToolUse hook for Bash: refuse the commands CONTRIBUTING.md's "jj" section forbids, before
# they run. Exit 2 blocks the command and hands the message on stderr back to the agent.
#
#   - git write commands (commit, checkout, restore, reset, …) in a jj repo: they act on the last
#     *git* commit, which can be far behind jj's working copy, and take undescribed work with them.
#     A plain git checkout (a cloud session, the plans repo) is left alone.
#   - `jj workspace add` into /tmp or a session scratchpad, which the OS clears under you.
#
# Reads the hook input from stdin (`.tool_input.command`, `.cwd`). Without jq it lets everything
# through: the written rules still hold, this only enforces them.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd=$PWD

deny() {
  printf '%s\n' "$1" >&2
  exit 2
}

# A command word at the start of a line or after `;`, `&`, `|`, `(` or `$(`, so text that only
# mentions git (a commit message, a grep pattern) doesn't count.
at_command='(^|[;&|(]|\$\()[[:space:]]*'

git_write='(commit|checkout|switch|restore|reset|stash|rebase|merge|cherry-pick|revert|am|clean|pull)'
if printf '%s\n' "$cmd" | grep -Eq "${at_command}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+${git_write}([[:space:]]|\$)"; then
  # Where the git command runs: its `-C <dir>`, else the last `cd <dir>` before it, else the
  # session's directory.
  dir=$(printf '%s\n' "$cmd" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:];&|]+).*/\1/p' | tail -1)
  [ -n "$dir" ] || dir=$(printf '%s\n' "$cmd" | sed -nE 's/.*(^|[;&|(][[:space:]]*)cd[[:space:]]+([^[:space:];&|]+).*/\2/p' | tail -1)
  [ -n "$dir" ] || dir=$cwd
  dir=${dir/#\~/$HOME}
  case "$dir" in /*) ;; *) dir="$cwd/$dir" ;; esac
  dir=${dir%\"}; dir=${dir#\"}; dir=${dir%\'}; dir=${dir#\'}

  # The nearest repo root above it decides: a .jj there means jj owns the working copy.
  d=$dir
  while [ -n "$d" ] && [ "$d" != / ]; do
    if [ -d "$d/.jj" ]; then
      deny "Blocked: git write commands are off in a jj repo ($d). They act on the last git commit, which can be far behind jj's working copy, and take undescribed work with them. Use jj (jj new, jj describe, jj restore, jj abandon); if something was clobbered, jj op log and jj undo bring it back. See CONTRIBUTING.md, \"jj\"."
    fi
    [ -e "$d/.git" ] && break
    d=$(dirname "$d")
  done
fi

if printf '%s\n' "$cmd" | grep -Eq "${at_command}jj[[:space:]]+workspace[[:space:]]+add([[:space:]]|\$)" &&
  printf '%s\n' "$cmd" | grep -Eq '[[:space:]](/tmp|/private/tmp|/private/var/folders|/var/folders|\$TMPDIR)'; then
  deny "Blocked: a jj workspace under /tmp or a scratchpad gets its files cleared by the OS, and jj's next snapshot records the deletions into your change. Put it beside the main checkout: jj workspace add --name <task> -r main@origin ../fizzy-<task>. See CONTRIBUTING.md, \"jj\"."
fi

exit 0
