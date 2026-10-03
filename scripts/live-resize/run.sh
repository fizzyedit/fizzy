#!/bin/bash
# One recorded live-resize drag of a sandboxed fizzy, measured: how many of the frames the screen
# showed during the drag were drawn for a size other than the one shown (stretched).
# docs/MACOS_LIVE_RESIZE.md.
#
# usage: scripts/live-resize/run.sh <fizzy-binary> <out-dir> <edge r|l|t|b|tr> [amp-pt=250]
#            [period-s=2] [cycles=2] [-- VAR=value ...]
#   e.g. scripts/live-resize/run.sh zig-out/arm64-macos/fizzy /tmp/lr-old r -- SDL_VIDEO_MAC_SYNC_LIVE_RESIZE=0
# Arguments after `--` go into fizzy's environment. Files to open can go in FIZZY_ARGS.
#
# The fizzy runs with its own HOME and lock (beside yours), and is quit when the drag is done.
# Posting the drag's mouse events needs Accessibility for the app running this (the terminal), and
# recording needs Screen Recording. The pointer moves during the drag: leave the mouse alone. The
# recorder brings fizzy to the front and presses only when fizzy's window is the topmost one under
# the pointer, and stops if anything else comes over it.
set -e
here=$(cd "$(dirname "$0")" && pwd)
bin=$1; out=$2; edge=$3; amp=${4:-250}; period=${5:-2}; cycles=${6:-2}
shift 3; for _ in 1 2 3; do [ $# -gt 0 ] && [ "$1" != "--" ] && shift; done; [ "$1" == "--" ] && shift
tool=${TMPDIR:-/tmp}/fizzy-live-resize-record
[ "$tool" -nt "$here/record.swift" ] || swiftc -O "$here/record.swift" -o "$tool"

mkdir -p "$out"
home=$out/home; lock=/tmp/fzlr.$$
mkdir -p "$home/Library/Application Support" "$lock"
rm -f "$home/Library/Application Support/fizzy/layout.zon" "$home/Library/Application Support/fizzy/recents.zon"
env "$@" HOME="$home" TMPDIR="$lock" FIZZY_LIVE_RESIZE_TRACE=1 "$bin" $FIZZY_ARGS > "$out/app.log" 2>&1 &
pid=$!
sleep 1.5
recorded=0
"$tool" "$pid" "$edge" "$amp" "$period" "$cycles" 120 > "$out/rec.txt" 2> "$out/rec.err" || recorded=$?
sleep 0.3
"$tool" quit "$pid"
for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
kill -0 "$pid" 2>/dev/null && kill -9 "$pid"
rm -rf "$lock"
if [ "$recorded" != 0 ]; then grep "^record:" "$out/rec.err" || cat "$out/rec.err"; exit 1; fi
python3 "$here/analyze.py" "$out"
