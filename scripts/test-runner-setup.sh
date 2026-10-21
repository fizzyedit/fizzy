#!/bin/sh
# Checks the pure parts of scripts/runner-setup.sh through --dry-run: RUNNER_URL defaults to the
# private work repo, a public or unverifiable repo is refused, and the unchecked override works.
# A fake gh on PATH answers `gh auth status` and `gh api`; its answer is in $T/private.
cd "$(dirname "$0")" || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat >"$T/bin/gh" <<FAKE
#!/bin/sh
[ "\$1" = auth ] && exit 0
echo "\$2" >"$T/asked"
cat "$T/private"
FAKE
chmod +x "$T/bin/gh"
fail() { echo "FAIL: $1"; exit 1; }
setup() { PATH="$T/bin:$PATH" bash ./runner-setup.sh --dry-run 2>&1; }

echo true >"$T/private"
out=$(setup) || fail "private default refused: $out"
grep -qx 'repos/fizzyedit/work' "$T/asked" || fail "default is not fizzyedit/work: $(cat "$T/asked")"

echo false >"$T/private"
out=$(setup) && fail "public repo accepted"
echo "$out" | grep -q 'Refusing' || fail "no refusal line: $out"

echo true >"$T/private"
out=$(RUNNER_URL=https://github.com/fizzyedit sh -c 'PATH="$1/bin:$PATH" bash ./runner-setup.sh --dry-run 2>&1' _ "$T") &&
    fail "org URL accepted"

# gh absent from PATH's front is not enough (the host may have one): hide it behind a failing stub.
printf '#!/bin/sh\nexit 1\n' >"$T/bin/gh"
out=$(setup) && fail "unverifiable repo accepted"
out=$(FIZZY_RUNNER_ALLOW_UNCHECKED=1 setup) || fail "override refused: $out"
echo "$out" | grep -q 'skip the private-repo check' || fail "override not reported"
echo ok
