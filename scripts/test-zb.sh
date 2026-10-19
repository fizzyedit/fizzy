#!/bin/sh
# Checks scripts/zb: N slots hold, a third build waits, a dead holder's slot is reclaimed, the load
# ceiling holds a build back, and zig's exit status comes through. A fake zig stands in: it records
# its arguments in $T/ran and sleeps until $T/go exists, then exits with $T/status (default 0).
cd "$(dirname "$0")" || exit 1
T=$(mktemp -d)
trap 'touch "$T/go"; kill $(cat "$T"/pids 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT
cat >"$T/zig" <<FAKE
#!/bin/sh
echo "\$*" >>"$T/ran"
while [ ! -e "$T/go" ]; do sleep 0.1; done
exit \$(cat "$T/status" 2>/dev/null || echo 0)
FAKE
chmod +x "$T/zig"
export FIZZY_BUILD_ZIG=$T/zig FIZZY_BUILD_SLOTS=2 FIZZY_BUILD_MAX_LOAD=100000 \
    FIZZY_BUILD_SLOTS_DIR=$T/slots FIZZY_BUILD_POLL=0.2
fail() { echo "FAIL: $1"; exit 1; }
alive() { kill -0 "$1" 2>/dev/null; }

# Two builds hold the two slots; the third waits, then runs when they finish.
./zb build a >"$T/o1" 2>&1 & echo $! >>"$T/pids"
./zb build b >"$T/o2" 2>&1 & echo $! >>"$T/pids"
sleep 1
./zb build c >"$T/o3" 2>&1 & p3=$!; echo $p3 >>"$T/pids"
sleep 1
alive $p3 || fail "third build did not wait"
grep -q 'zb: waiting for a build slot' "$T/o3" || fail "no waiting line: $(cat "$T/o3")"
grep -q '^build c' "$T/ran" && fail "third build ran while both slots were held"
echo 3 >"$T/status"
touch "$T/go"
wait $p3; [ $? = 3 ] || fail "zig's exit status not passed on"
grep -q '^build c' "$T/ran" || fail "third build never ran"
wait
[ -z "$(ls "$T/slots")" ] || fail "slots not released: $(ls "$T/slots")"

# A slot whose holder is dead is reclaimed.
rm -f "$T/go" "$T/status" "$T/ran"; : >"$T/pids"
sh -c : & dead=$!; wait $dead
ln -s $dead "$T/slots/slot.0"; ln -s $dead "$T/slots/slot.1"
touch "$T/go"
./zb build d >"$T/o4" 2>&1 || fail "dead slot not reclaimed: $(cat "$T/o4")"
grep -q '^build d' "$T/ran" || fail "build d did not run"

# Over the load ceiling, a build waits (and says so) until it is lifted.
FIZZY_BUILD_MAX_LOAD=-1 ./zb build e >"$T/o5" 2>&1 & p5=$!; echo $p5 >>"$T/pids"
sleep 1
alive $p5 || fail "build ran above the load ceiling"
grep -q 'waiting for load' "$T/o5" || fail "no load line: $(cat "$T/o5")"
kill $p5

# Light commands pass straight through, and FIZZY_BUILD_SKIP bypasses the wait.
./zb fmt x >/dev/null 2>&1 || fail "fmt did not pass through"
grep -q '^fmt x' "$T/ran" || fail "fmt not run"
FIZZY_BUILD_SKIP=1 FIZZY_BUILD_MAX_LOAD=-1 ./zb build f >/dev/null 2>&1 || fail "SKIP waited"
echo ok
