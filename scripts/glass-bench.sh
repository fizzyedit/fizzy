#!/usr/bin/env bash
# Measure the existing glass benchmark on lavapipe, or the host GPU with --gpu.
set -euo pipefail
cd "$(dirname "$0")/.."
out=glass-bench-out
gpu=false
while (($#)); do
    case "$1" in
        --gpu) gpu=true; shift ;;
        --out) out=${2:?--out requires a directory}; shift 2 ;;
        *) echo "Usage: $0 [--gpu] [--out dir]" >&2; exit 1 ;;
    esac
done
mkdir -p "$out"
out=$(cd "$out" && pwd)
scripts/zb build
shopt -s nullglob
bins=(zig-out/*/fizzy)
[[ ${#bins[@]} == 1 && -x ${bins[0]} ]] || { echo 'expected one built fizzy executable' >&2; exit 1; }
if ! "$gpu"; then
    shopt -s nullglob
    drivers=(/usr/share/vulkan/icd.d/lvp_icd*.json)
    ((${#drivers[@]})) || { echo 'lavapipe ICD not found' >&2; exit 1; }
    export VK_DRIVER_FILES="${drivers[0]}"
fi
: > "$out/cost.jsonl"
for arm in scene sheet; do
    for panes in 1 4 8 15; do
        profile=$(mktemp -d)
        if ! SDL_VIDEO_DRIVER=x11 FIZZY_PROFILE="$profile" \
            FIZZY_GLASS_BENCH="$arm:$panes" FIZZY_GLASS_BENCH_OUT="$out/cost.jsonl" \
            timeout 180 xvfb-run -a -s '-screen 0 1280x1024x24' "${bins[0]}" \
            > "$out/$arm-$panes.log" 2>&1; then
            rm -rf "$profile"
            echo "Benchmark failed: $arm:$panes (see $out/$arm-$panes.log)" >&2
            exit 1
        fi
        rm -rf "$profile"
    done
done
python3 - "$out/cost.jsonl" <<'PY'
import json
import sys
rows = [json.loads(line) for line in open(sys.argv[1])]
expected = [(arm, n) for arm in ('scene', 'sheet') for n in (1, 4, 8, 15)]
if [(r['arm'], r['panes']) for r in rows] != expected:
    sys.exit('Missing or unexpected benchmark rows')
print('| arm | panes | p50 ms | p95 ms | program_draws | program_px | passes | target_switches | targets |')
print('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
for r in rows:
    print('| {arm} | {panes} | {frame_ms_p50:.3f} | {frame_ms_p95:.3f} | {program_draws} | {program_px} | {passes} | {target_switches} | {targets} |'.format(**r))
if any(r['program_draws'] == 0 for r in rows):
    sys.exit('Glass program did not draw in every row')
PY
