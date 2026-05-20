#!/usr/bin/env sh
# Local wasm preview: http://127.0.0.1:8765/
set -e

root="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ ! -f zig-out/web/web.wasm ] || [ ! -f zig-out/web/index.html ]; then
  echo "serve-web: building wasm (zig build web)…"
  zig build web
fi

port=8765
if command -v lsof >/dev/null 2>&1; then
  pids=$(lsof -ti :"$port" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    echo "serve-web: stopping existing listener on :$port ($pids)"
    kill $pids 2>/dev/null || true
    sleep 0.2
  fi
fi

echo "serve-web: http://127.0.0.1:$port/"
exec python3 -m http.server "$port" --directory "$root/zig-out/web"
