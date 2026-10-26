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
unset FIZZY_BUILD_SKIP FIZZY_BUILD_WAIT
export FIZZY_BUILD_ZIG=$T/zig FIZZY_BUILD_SLOTS=2 FIZZY_BUILD_MAX_LOAD=100000 \
    FIZZY_BUILD_SLOTS_DIR=$T/slots FIZZY_BUILD_POLL=0.2
fail() { echo "FAIL: $1"; exit 1; }
alive() { kill -0 "$1" 2>/dev/null; }
# poll <what> <file> <pattern>: poll for the pattern in the file (a slow runner is not a failure),
# failing after 20s with what the file held.
poll() {
    i=0
    while ! grep -q "$3" "$2" 2>/dev/null; do
        i=$((i + 1))
        [ $i -le 200 ] || fail "$1 never showed '$3' in $2 after 20s: $(cat "$2" 2>/dev/null) ran: $(cat "$T/ran" 2>/dev/null) slots: $(cat "$T"/slots/*/pid 2>/dev/null) env: $(env | grep FIZZY_BUILD | tr '\n' ' ')"
        sleep 0.1
    done
}

# Two builds hold the two slots; the third waits, then runs when they finish.
./zb build a >"$T/o1" 2>&1 & echo $! >>"$T/pids"
./zb build b >"$T/o2" 2>&1 & echo $! >>"$T/pids"
poll "builds a and b" "$T/ran" '^build b'
poll "builds a and b" "$T/ran" '^build a'
poll "slot 0 held" "$T/slots/slot.0/pid" '^[0-9]'
poll "slot 1 held" "$T/slots/slot.1/pid" '^[0-9]'
./zb build c >"$T/o3" 2>&1 & p3=$!; echo $p3 >>"$T/pids"
poll "third build" "$T/o3" 'zb: waiting for a build slot'
alive $p3 || fail "third build did not wait: $(cat "$T/o3") ran: $(cat "$T/ran")"
grep -q '^build c' "$T/ran" && fail "third build ran while both slots were held: $(cat "$T/ran")"
echo 3 >"$T/status"
touch "$T/go"
wait $p3; [ $? = 3 ] || fail "zig's exit status not passed on"
grep -q '^build c' "$T/ran" || fail "third build never ran"
wait
[ -z "$(ls "$T/slots")" ] || fail "slots not released: $(ls "$T/slots")"

# A slot whose holder is dead is reclaimed.
rm -f "$T/go" "$T/status" "$T/ran"; : >"$T/pids"
sh -c : & dead=$!; wait $dead
for n in 0 1; do mkdir -p "$T/slots/slot.$n"; echo $dead >"$T/slots/slot.$n/pid"; done
touch "$T/go"
./zb build d >"$T/o4" 2>&1 || fail "dead slot not reclaimed: $(cat "$T/o4")"
grep -q '^build d' "$T/ran" || fail "build d did not run"

# With every slot held by a live pid, a build gives up after FIZZY_BUILD_WAIT, loudly, naming the pids.
rm -rf "$T/slots"; mkdir -p "$T/slots/slot.0" "$T/slots/slot.1"
for n in 0 1; do echo $$ >"$T/slots/slot.$n/pid"; done
FIZZY_BUILD_WAIT=1 ./zb build g >"$T/o6" 2>&1 && fail "build ran with every slot held"
grep -q "zb: no build slot after 1s" "$T/o6" || fail "no wait-limit line: $(cat "$T/o6")"
grep -q "pids $$ $$" "$T/o6" || fail "wait-limit line does not name the holders: $(cat "$T/o6")"
grep -q '^build g' "$T/ran" && fail "build g ran while both slots were held"

# A slot with no pid file is its taker between mkdir and the write: held while young, reclaimed once
# a minute old.
rm -f "$T"/slots/slot.*/pid
FIZZY_BUILD_WAIT=1 ./zb build h >"$T/o7" 2>&1 && fail "build reclaimed a young pid-less slot"
grep -q "zb: no build slot after 1s" "$T/o7" || fail "young pid-less slot not held: $(cat "$T/o7")"
touch -t 200001010000 "$T/slots/slot.0" "$T/slots/slot.1"
./zb build i >"$T/o8" 2>&1 || fail "old pid-less slot not reclaimed: $(cat "$T/o8")"
grep -q '^build i' "$T/ran" || fail "build i did not run"

# Over the load ceiling, a build waits (and says so) until it is lifted.
FIZZY_BUILD_MAX_LOAD=-1 ./zb build e >"$T/o5" 2>&1 & p5=$!; echo $p5 >>"$T/pids"
poll "build above the load ceiling" "$T/o5" 'waiting for load'
alive $p5 || fail "build ran above the load ceiling"
kill $p5

# Light commands pass straight through, and FIZZY_BUILD_SKIP bypasses the wait.
./zb fmt x >/dev/null 2>&1 || fail "fmt did not pass through"
grep -q '^fmt x' "$T/ran" || fail "fmt not run"
FIZZY_BUILD_SKIP=1 FIZZY_BUILD_MAX_LOAD=-1 ./zb build f >/dev/null 2>&1 || fail "SKIP waited"
echo ok
