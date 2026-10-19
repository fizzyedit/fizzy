#!/usr/bin/env bash
# Capture fizzy's window as it looks in each glass case, or compare two such captures.
#
# What a window is made of (`core.material`) and how it is dressed is about to move into one path
# for every app (fizzyedit/plans#27): fizzy must look the same after as before. This records the
# look: fizzy launched in a profile of its own at each theme, material (`FIZZY_GLASS`) and window
# opacity, its main window captured alone (`screencapture -l`), so what lies behind it on the
# desktop never enters the picture. macOS.
#
#   scripts/window-look.sh capture <fizzy binary> <out dir>
#   scripts/window-look.sh compare <before dir> <after dir>
#
# compare prints, per case, the mean difference of the two pictures' pixels (0–255, all
# channels), and the largest, and exits 1 when any case's mean is over the tolerance
# (`WINDOW_LOOK_TOLERANCE`, default 2): glass is drawn by the OS and moves a little between runs.
set -euo pipefail

themes=("Fizzy Dark" "Fizzy Light")
materials=(liquid frost transparent none)
opacities=(0.3 0.7 1.0)
settle="${WINDOW_LOOK_SETTLE:-6}"

slug() { echo "$1" | tr 'A-Z ' 'a-z-'; }

capture() {
  local fizzy="$1" out="$2"
  mkdir -p "$out"
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  # The window, by the process that owns it: the largest on screen.
  cat >"$work/window.swift" <<'EOF'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
var best: (Int, Int) = (0, 0)
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] {
  guard (w[kCGWindowOwnerPID as String] as? Int) == pid, (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
  let b = w[kCGWindowBounds as String] as! [String: Any]
  let area = (b["Width"] as! Int) * (b["Height"] as! Int)
  if area > best.1 { best = (w[kCGWindowNumber as String] as! Int, area) }
}
print(best.0)
EOF
  for theme in "${themes[@]}"; do
    for material in "${materials[@]}"; do
      for opacity in "${opacities[@]}"; do
        local name profile
        name="$(slug "$theme")-$material-$opacity"
        profile="$work/profile-$name"
        mkdir -p "$profile"
        printf '.{\n    .theme = "%s",\n    .window_opacity_dark = %s,\n    .window_opacity_light = %s,\n}\n' "$theme" "$opacity" "$opacity" >"$profile/settings.zon"
        FIZZY_GLASS="$material" "$fizzy" --profile "$profile" >"$work/$name.log" 2>&1 &
        local pid=$!
        sleep "$settle"
        local wid
        wid="$(swift "$work/window.swift" "$pid")"
        if [[ "$wid" != 0 ]]; then
          screencapture -x -o -l "$wid" "$out/$name.png"
          echo "$name"
        else
          echo "$name: no window" >&2
        fi
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        sleep 1
      done
    done
  done
}

compare() {
  local before="$1" after="$2"
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  cat >"$work/diff.swift" <<'EOF'
import AppKit
func pixels(_ path: String) -> NSBitmapImageRep? {
  guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation else { return nil }
  return NSBitmapImageRep(data: tiff)
}
let a = pixels(CommandLine.arguments[1]), b = pixels(CommandLine.arguments[2])
guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
      let pa = a.bitmapData, let pb = b.bitmapData else { print("size"); exit(0) }
let n = a.bytesPerRow * a.pixelsHigh
var total = 0, most = 0
for i in 0..<n { let d = abs(Int(pa[i]) - Int(pb[i])); total += d; if d > most { most = d } }
print(String(format: "%.2f %d", Double(total) / Double(n), most))
EOF
  local tolerance="${WINDOW_LOOK_TOLERANCE:-2}" failed=0
  for f in "$before"/*.png; do
    local name
    name="$(basename "$f")"
    if [[ ! -f "$after/$name" ]]; then
      echo "$name: missing after"
      failed=1
      continue
    fi
    local result
    result="$(swift "$work/diff.swift" "$f" "$after/$name")"
    echo "$name: $result"
    if [[ "$result" == size ]] || awk -v m="${result%% *}" -v t="$tolerance" 'BEGIN { exit !(m > t) }'; then failed=1; fi
  done
  return "$failed"
}

case "${1:-}" in
  capture) capture "$2" "$3" ;;
  compare) compare "$2" "$3" ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
