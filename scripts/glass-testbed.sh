#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scene=${1:?usage: glass-testbed.sh <scene> [--gpu] [--out dir]}
shift
gpu=0
out=""
while (($#)); do
    case "$1" in
        --gpu) gpu=1; shift ;;
        --out) out=${2:?missing output directory}; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done
[[ $scene == pair || $scene == shadow || $scene == pulldown ]] || { echo "unknown scene: $scene" >&2; exit 1; }
if [[ -z $out ]]; then out=$(mktemp -d /tmp/fizzy-glass-testbed.XXXXXX); fi
mkdir -p "$out"
out=$(cd "$out" && pwd)
scripts/zb build
export FIZZY_GLASS_TESTBED="$scene:$out"
FIZZY_PROFILE=$(mktemp -d /tmp/fizzy-glass-profile.XXXXXX)
export FIZZY_PROFILE
trap 'rm -rf "$FIZZY_PROFILE"' EXIT
if (( ! gpu )); then
    drivers=(/usr/share/vulkan/icd.d/lvp_icd*.json)
    [[ -f ${drivers[0]} ]] || { echo "lavapipe driver not found" >&2; exit 1; }
    export VK_DRIVER_FILES=${drivers[0]}
fi
bins=(zig-out/*/fizzy)
[[ ${#bins[@]} == 1 && -x ${bins[0]} ]] || { echo "expected one built fizzy executable" >&2; exit 1; }
SDL_VIDEO_DRIVER=x11 xvfb-run -a -s "-screen 0 1280x1024x24" "${bins[0]}"
python3 - "$out/frames.jsonl" "$scene" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    rows = [json.loads(line) for line in f]
if sys.argv[2] == 'pulldown':
    # Steps after the first whose frame read more than one capture, and the nearest-rank p95 frame time.
    over = [row['step'] for row in rows if row['step'] > 0 and row['captures'] > 1]
    ms = sorted(row['frame_ms'] for row in rows)
    p95 = ms[max(-(-len(ms) * 95 // 100), 1) - 1]
    print(json.dumps({'scene': 'pulldown', 'rows': len(rows), 'steps_captures_over_1': len(over), 'over_steps': over, 'frame_ms_p95': p95}))
else:
    key = {'pair': 'ghost_max', 'shadow': 'dark_max'}[sys.argv[2]]
    print(json.dumps(max(rows, key=lambda row: row[key])))
PY
echo "Pictures and measurements: $out"
