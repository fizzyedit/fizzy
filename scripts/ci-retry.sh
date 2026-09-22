#!/usr/bin/env bash
# Run a command, retrying it only when it failed for a *network* reason.
#
# Zig 0.16's HTTP client does not retry, and codeload.github.com closes connections often enough
# that a CI run hits `HttpConnectionClosing` every few builds. The pre-fetch step in `ci.yml`
# covers the eager dependency tree, but a `.lazy = true` dependency is fetched by the build step
# that first asks for it (`icons` is only reached through `build/web.zig`'s `lazyDependency`), and
# `--fetch=all` cannot stand in for that: it walks lazy dependencies of dependencies this build
# never reaches and dies on their old-format hashes.
#
# So the build steps themselves retry. Deliberately *not* a blind retry: a failing test or a
# compile error must fail on the first attempt, at its own speed, or CI stops telling the truth.
# Only output matching a fetch failure is retried.
set -uo pipefail

attempts="${CI_RETRY_ATTEMPTS:-4}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

n=1
while :; do
  "$@" 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  [ "$status" -eq 0 ] && exit 0

  if ! grep -qE 'HttpConnectionClosing|invalid HTTP response|ConnectionResetByPeer|ConnectionTimedOut|TemporaryNameServerFailure|unable to fetch|TlsInitializationFailed|UnexpectedEndOfStream' "$log"; then
    echo "::notice::not a fetch failure — not retrying"
    exit "$status"
  fi

  if [ "$n" -ge "$attempts" ]; then
    echo "::error::fetch kept failing after $n attempts"
    exit "$status"
  fi

  sleep=$((n * 10))
  echo "::warning::attempt $n failed while fetching a dependency; retrying in ${sleep}s"
  sleep "$sleep"
  n=$((n + 1))
done
