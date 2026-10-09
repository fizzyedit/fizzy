#!/usr/bin/env python3
"""Time each stage of a plugin's rebuild loop: from an edit saved to the plugin running again.

`docs/AGENTS_PLAN.md`, "Fast enough to watch": every stage is measured before it is called fast.
This measures them for one plugin (default: `examples/hello-plugin`, the smallest third-party-shaped
plugin, depending only on `sdk/`):

  build    `zig build` of the plugin into a scratch profile (`FIZZY_PROFILE`): a cold build (the
           plugin's own cache empty, the global Zig cache warm, as for a new plugin on a machine that
           has built fizzy), a rebuild with nothing changed, and a rebuild after a one-line edit —
           each with Zig's per-step times (compile, install).
  reload   with `--app <fizzy>`: a sandbox fizzy runs on that profile, and each edit and rebuild is
           picked up by its plugin watcher. fizzy logs how long after the binary was written it
           noticed, how long the new binary took to open off the UI thread, and how long the swap
           on the UI thread took (unload, register) — `PluginReloads`.

The plugin is copied to `zig-out/plugin-loop/` first, so the repo's copy is never edited, and it
installs into a scratch profile, never the real plugins directory. With `--app`, a fizzy window
opens for the length of the run: leave it alone, a click on it is a person's input.

  scripts/plugin-loop/bench.py [--optimize Debug,ReleaseFast] [--edits 3] [--app zig-out/arm64-macos/fizzy]
"""
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def step_times(summary: str) -> dict:
    """Zig's `--summary all` per-step durations, by step kind ("compile", "install"), in ms."""
    out = {}
    for line in summary.splitlines():
        m = re.search(r"\b(compile|install)\b.*?\bsuccess\s+([\d.]+)(ms|s|us|m)\b", line)
        if not m:
            continue
        value = float(m.group(2)) * {"us": 0.001, "ms": 1, "s": 1000, "m": 60000}[m.group(3)]
        out[m.group(1)] = out.get(m.group(1), 0) + value
    return out


def build(plugin_dir: str, optimize: str, profile: str) -> tuple[float, dict]:
    env = dict(os.environ, FIZZY_PROFILE=profile)
    start = time.monotonic()
    proc = subprocess.run(
        ["zig", "build", f"-Doptimize={optimize}", "--summary", "all"],
        cwd=plugin_dir, env=env, capture_output=True, text=True,
    )
    wall = (time.monotonic() - start) * 1000
    if proc.returncode != 0:
        sys.exit(f"build failed:\n{proc.stderr}")
    return wall, step_times(proc.stderr)


def edit(plugin_dir: str, n: int) -> None:
    # A comment is enough: Zig hashes the file, so the plugin's module compiles again.
    with open(os.path.join(plugin_dir, "plugin.zig"), "a") as f:
        f.write(f"// plugin-loop bench edit {n}\n")


def copy_plugin(src: str, name: str) -> str:
    dst = os.path.join(ROOT, "zig-out", "plugin-loop", name)
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns(".zig-cache", "zig-out", "zig-pkg"), dirs_exist_ok=True)
    # The copy sits one level deeper than `examples/<name>`: its path to the SDK does too.
    zon = os.path.join(dst, "build.zig.zon")
    with open(zon) as f:
        text = f.read()
    text = text.replace('"../../sdk"', '"../../../sdk"')
    with open(zon, "w") as f:
        f.write(text)
    return dst


def fmt(ms: float) -> str:
    return f"{ms / 1000:.2f} s" if ms >= 1000 else f"{ms:.0f} ms"


def bench_builds(plugin_dir: str, optimize: str, profile: str) -> None:
    shutil.rmtree(os.path.join(plugin_dir, ".zig-cache"), ignore_errors=True)
    rows = []
    rows.append(("cold", *build(plugin_dir, optimize, profile)))
    rows.append(("nothing changed", *build(plugin_dir, optimize, profile)))
    edit(plugin_dir, 0)
    rows.append(("one-line edit", *build(plugin_dir, optimize, profile)))
    print(f"\n{optimize}: zig build of {os.path.basename(plugin_dir)}")
    for name, wall, steps in rows:
        detail = ", ".join(f"{k} {fmt(v)}" for k, v in steps.items())
        print(f"  {name:<16} {fmt(wall):>9}   {detail}")


def bench_reload(plugin_dir: str, optimize: str, profile: str, app: str, edits: int, plugin_id: str) -> None:
    with open(os.path.join(profile, "settings.zon"), "w") as f:
        f.write(".{ .plugins = .{ .%s = .{ .enabled = true } } }\n" % plugin_id)
    build(plugin_dir, optimize, profile)
    log_path = os.path.join(profile, "fizzy.log")
    log = open(log_path, "w")
    proc = subprocess.Popen([app, "--profile", profile], stdout=log, stderr=subprocess.STDOUT)
    try:
        if not wait_for(log_path, rf"user plugin '{plugin_id}' loaded", 30):
            sys.exit(f"fizzy never loaded '{plugin_id}' — see {log_path}")
        print(f"\n{optimize}: edit, rebuild and reload in a running fizzy ({os.path.basename(app)})")
        for n in range(1, edits + 1):
            seen = count(log_path, "swapped in")
            edit(plugin_dir, n)
            start = time.monotonic()
            wall, steps = build(plugin_dir, optimize, profile)
            if not wait_for(log_path, r"swapped in", 30, after=seen):
                sys.exit(f"fizzy never reloaded the rebuild — see {log_path}")
            total = (time.monotonic() - start) * 1000
            noticed = last(log_path, r"noticed ([\d.]+)ms after it was written")
            swap = last(log_path, r"swapped in ([\d.]+)ms on the UI thread \(unload ([\d.]+)ms, register ([\d.]+)ms\), opened off it in ([\d.]+)ms")
            print(f"  edit {n}: build {fmt(wall)} (compile {fmt(steps.get('compile', 0))}), "
                  f"noticed {noticed[0]} ms after written, opened off the UI thread in {swap[3]} ms, "
                  f"swap on it {swap[0]} ms (unload {swap[1]}, register {swap[2]}) — {fmt(total)} from the edit to running")
    finally:
        proc.send_signal(signal.SIGKILL)
        proc.wait()
        log.close()


def count(path: str, needle: str) -> int:
    with open(path, errors="replace") as f:
        return f.read().count(needle)


def wait_for(path: str, pattern: str, timeout: float, after: int = 0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with open(path, errors="replace") as f:
            if len(re.findall(pattern, f.read())) > after:
                return True
        time.sleep(0.02)
    return False


def last(path: str, pattern: str) -> tuple:
    with open(path, errors="replace") as f:
        found = re.findall(pattern, f.read())
    if not found:
        return ("?", "?", "?", "?")
    return found[-1] if isinstance(found[-1], tuple) else (found[-1],)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--plugin", default="examples/hello-plugin", help="plugin directory, relative to the repo")
    p.add_argument("--id", default="hello", help="the plugin's id")
    p.add_argument("--optimize", default="Debug,ReleaseFast", help="comma-separated optimize modes")
    p.add_argument("--edits", type=int, default=3, help="edit/rebuild/reload cycles with --app")
    p.add_argument("--app", help="a fizzy executable, for the reload stage")
    p.add_argument("--app-optimize", default="Debug", help="the mode --app was built in: a plugin loads only into a build of its own mode")
    args = p.parse_args()

    for optimize in args.optimize.split(","):
        plugin_dir = copy_plugin(os.path.join(ROOT, args.plugin), os.path.basename(args.plugin))
        profile = tempfile.mkdtemp(prefix="fizzy-plugin-loop-")
        try:
            bench_builds(plugin_dir, optimize, profile)
            if args.app and optimize == args.app_optimize:
                bench_reload(plugin_dir, optimize, profile, os.path.abspath(args.app), args.edits, args.id)
        finally:
            shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    main()
