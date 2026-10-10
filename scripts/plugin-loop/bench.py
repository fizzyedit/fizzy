#!/usr/bin/env python3
"""Time each stage of a plugin's rebuild loop: from an edit saved to the plugin running again.

`plans/AGENTS_PLAN.md`, "Fast enough to watch": every stage is measured before it is called fast.
This measures them for one plugin (default: `plugins/image`, a real plugin in the shape a
third-party one has, depending only on `sdk/`):

  build    `zig build` of the plugin into a scratch profile (`FIZZY_PROFILE`): a cold build (the
           plugin's own cache empty, the global Zig cache warm, as for a new plugin on a machine that
           has built fizzy), a rebuild with nothing changed, and a rebuild after a one-line edit —
           each with Zig's per-step times (compile, install).
  watch    with `--watch N`: a long-running `zig build --watch -fincremental`, and N edits, each
           timed from the save to the rebuilt binary installed. What incremental compilation buys
           depends on the Zig version and the backend (`--backend`).
  reload   with `--app <fizzy>`: a sandbox fizzy runs on that profile, and each edit and rebuild is
           picked up by its plugin watcher. fizzy logs how long after the binary was written it
           noticed, how long the new binary took to open off the UI thread, and how long the swap
           on the UI thread took (unload, register) — `PluginReloads`. Needs a plugin fizzy does
           not bundle (fizzy skips a user copy of a bundled one): pass `--plugin` and `--id`.

`--backend llvm|self-hosted` forces the code generator for the plugin (`FIZZY_PLUGIN_USE_LLVM`,
read by `sdk/plugin_sdk.zig`); `default` leaves it to Zig. Compiler experiments like this run on
Linux CI (`.github/workflows/plugin-loop.yml`), not on a shared workstation: an experimental
backend on a large compile can take far more memory than LLVM.

The plugin is copied to `zig-out/plugin-loop/` first, so the repo's copy is never edited, and it
installs into a scratch profile, never the real plugins directory. With `--app`, a fizzy window
opens for the length of the run: leave it alone, a click on it is a person's input.

  scripts/plugin-loop/bench.py [--plugin plugins/image] [--optimize Debug,ReleaseFast]
                               [--backend default|llvm|self-hosted] [--watch 3]
                               [--app zig-out/arm64-macos/fizzy --plugin <dir> --id <id>]
                               [--summary $GITHUB_STEP_SUMMARY]
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
EXT = {"darwin": ".dylib", "win32": ".dll"}.get(sys.platform, ".so")


def step_times(summary: str) -> dict:
    """Zig's `--summary all` per-step durations, by step kind ("compile", "install"), in ms.
    Zig prints a step of a second or more in whole seconds, so these are coarse above 1 s."""
    out = {}
    for line in summary.splitlines():
        m = re.search(r"\b(compile|install)\b.*?\bsuccess\s+([\d.]+)(ms|s|us|m)\b", line)
        if not m:
            continue
        value = float(m.group(2)) * {"us": 0.001, "ms": 1, "s": 1000, "m": 60000}[m.group(3)]
        out[m.group(1)] = out.get(m.group(1), 0) + value
    return out


def env_for(profile: str, backend: str) -> dict:
    env = dict(os.environ, FIZZY_PROFILE=profile)
    if backend == "llvm":
        env["FIZZY_PLUGIN_USE_LLVM"] = "1"
    elif backend == "self-hosted":
        env["FIZZY_PLUGIN_USE_LLVM"] = "0"
    return env


class BuildFailed(Exception):
    pass


def build(plugin_dir: str, optimize: str, profile: str, backend: str) -> tuple:
    start = time.monotonic()
    proc = subprocess.run(
        ["zig", "build", f"-Doptimize={optimize}", "--summary", "all"],
        cwd=plugin_dir, env=env_for(profile, backend), capture_output=True, text=True,
    )
    wall = (time.monotonic() - start) * 1000
    if proc.returncode != 0:
        print(proc.stderr[-4000:], file=sys.stderr)
        errors = [l.strip() for l in proc.stderr.splitlines() if "error:" in l]
        raise BuildFailed(errors[0] if errors else f"exit {proc.returncode}")
    return wall, step_times(proc.stderr)


def edit(plugin_dir: str, n: int) -> None:
    # A comment is enough: Zig hashes the file, so the plugin's module compiles again.
    with open(os.path.join(plugin_dir, "plugin.zig"), "a") as f:
        f.write(f"// plugin-loop bench edit {n}\n")


def copy_plugin(src: str) -> str:
    dst = os.path.join(ROOT, "zig-out", "plugin-loop", os.path.basename(src))
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns(".zig-cache", "zig-out", "zig-pkg"), dirs_exist_ok=True)
    # The copy sits one level deeper than `<dir>/<name>`: its path to the SDK does too.
    zon = os.path.join(dst, "build.zig.zon")
    with open(zon) as f:
        text = f.read()
    with open(zon, "w") as f:
        f.write(text.replace('"../../sdk"', '"../../../sdk"'))
    return dst


def fmt(ms: float) -> str:
    return f"{ms / 1000:.2f} s" if ms >= 1000 else f"{ms:.0f} ms"


class Report:
    """What the run measured, printed as it goes and kept for `--summary`."""

    def __init__(self) -> None:
        self.rows = []

    def add(self, label: str, value: str, detail: str = "") -> None:
        print(f"  {label:<44} {value:>9}   {detail}", flush=True)
        self.rows.append((label, value, detail))

    def markdown(self, title: str) -> str:
        lines = [f"### {title}", "", "| | | |", "|---|---|---|"]
        lines += [f"| {a} | {b} | {c} |" for a, b, c in self.rows]
        return "\n".join(lines) + "\n\n"


def bench_builds(report: Report, plugin_dir: str, optimize: str, profile: str, backend: str) -> None:
    shutil.rmtree(os.path.join(plugin_dir, ".zig-cache"), ignore_errors=True)
    for name, change in (("cold", False), ("nothing changed", False), ("one-line edit", True)):
        if change:
            edit(plugin_dir, 0)
        wall, steps = build(plugin_dir, optimize, profile, backend)
        report.add(f"{optimize}, {backend}: {name}", fmt(wall), ", ".join(f"{k} {fmt(v)}" for k, v in steps.items()))


def installed(profile: str, plugin_id: str) -> str:
    return os.path.join(profile, "plugins", plugin_id, plugin_id + EXT)


def wait_mtime_change(path: str, before: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if os.stat(path).st_mtime_ns != before:
                return True
        except FileNotFoundError:
            pass
        time.sleep(0.01)
    return False


def bench_watch(report: Report, plugin_dir: str, optimize: str, profile: str, backend: str, edits: int, plugin_id: str) -> None:
    target = installed(profile, plugin_id)
    build(plugin_dir, optimize, profile, backend)  # installed once, so each edit is a change to it
    log = open(os.path.join(profile, "watch.log"), "w")
    proc = subprocess.Popen(
        ["zig", "build", "--watch", "-fincremental", f"-Doptimize={optimize}"],
        cwd=plugin_dir, env=env_for(profile, backend), stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        # The first pass under --watch builds what the incremental cache does not have yet.
        wait_mtime_change(target, os.stat(target).st_mtime_ns, 300)
        time.sleep(1)
        for n in range(1, edits + 1):
            before = os.stat(target).st_mtime_ns
            start = time.monotonic()
            edit(plugin_dir, 100 + n)
            if not wait_mtime_change(target, before, 300):
                report.add(f"{optimize}, {backend}: watch edit {n}", "timeout", "no rebuild within 300 s")
                continue
            report.add(f"{optimize}, {backend}: --watch -fincremental edit {n}", fmt((time.monotonic() - start) * 1000), "save to installed")
            time.sleep(0.5)
    finally:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait()
        log.close()


def bench_reload(report: Report, plugin_dir: str, optimize: str, profile: str, app: str, edits: int, plugin_id: str) -> None:
    with open(os.path.join(profile, "settings.zon"), "w") as f:
        f.write(".{ .plugins = .{ .%s = .{ .enabled = true } } }\n" % plugin_id)
    build(plugin_dir, optimize, profile, "default")
    log_path = os.path.join(profile, "fizzy.log")
    log = open(log_path, "w")
    proc = subprocess.Popen([app, "--profile", profile], stdout=log, stderr=subprocess.STDOUT)
    try:
        if not wait_for(log_path, rf"user plugin '{plugin_id}' loaded", 30):
            sys.exit(f"fizzy never loaded '{plugin_id}' — see {log_path} (a bundled plugin is skipped)")
        for n in range(1, edits + 1):
            seen = count(log_path, "swapped in")
            edit(plugin_dir, 200 + n)
            start = time.monotonic()
            wall, steps = build(plugin_dir, optimize, profile, "default")
            if not wait_for(log_path, r"swapped in", 30, after=seen):
                sys.exit(f"fizzy never reloaded the rebuild — see {log_path}")
            total = (time.monotonic() - start) * 1000
            noticed = last(log_path, r"noticed ([\d.]+)ms after it was written")
            swap = last(log_path, r"swapped in ([\d.]+)ms on the UI thread \(unload ([\d.]+)ms, register ([\d.]+)ms\), opened off it in ([\d.]+)ms")
            report.add(f"{optimize}: reload {n}", fmt(total),
                       f"build {fmt(wall)}, noticed {noticed[0]} ms after written, opened off the UI thread "
                       f"{swap[3]} ms, swap on it {swap[0]} ms (unload {swap[1]}, register {swap[2]})")
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
    p.add_argument("--plugin", default="plugins/image", help="plugin directory, relative to the repo")
    p.add_argument("--id", default="image", help="the plugin's id")
    p.add_argument("--optimize", default="Debug,ReleaseFast", help="comma-separated optimize modes")
    p.add_argument("--backend", default="default", help="comma-separated: default, llvm, self-hosted")
    p.add_argument("--watch", type=int, default=0, help="edits to time under `zig build --watch -fincremental`")
    p.add_argument("--edits", type=int, default=3, help="edit/rebuild/reload cycles with --app")
    p.add_argument("--app", help="a fizzy executable, for the reload stage")
    p.add_argument("--app-optimize", default="Debug", help="the mode --app was built in: a plugin loads only into a build of its own mode")
    p.add_argument("--summary", help="append the results as a markdown table to this file (CI: $GITHUB_STEP_SUMMARY)")
    args = p.parse_args()

    report = Report()
    zig = subprocess.run(["zig", "version"], capture_output=True, text=True).stdout.strip()
    print(f"zig {zig}, {sys.platform}, plugin {args.plugin}", flush=True)
    for optimize in args.optimize.split(","):
        for backend in args.backend.split(","):
            plugin_dir = copy_plugin(os.path.join(ROOT, args.plugin))
            profile = tempfile.mkdtemp(prefix="fizzy-plugin-loop-")
            try:
                try:
                    bench_builds(report, plugin_dir, optimize, profile, backend)
                except BuildFailed as err:
                    # A backend that cannot build this (self-hosted at ReleaseFast, say) is a row,
                    # not the end of the run.
                    report.add(f"{optimize}, {backend}", "failed", str(err)[:200].replace("|", "/"))
                    continue
                if args.watch:
                    bench_watch(report, plugin_dir, optimize, profile, backend, args.watch, args.id)
                if args.app and optimize == args.app_optimize and backend == "default":
                    bench_reload(report, plugin_dir, optimize, profile, os.path.abspath(args.app), args.edits, args.id)
            finally:
                shutil.rmtree(profile, ignore_errors=True)
    if args.summary:
        with open(args.summary, "a") as f:
            f.write(report.markdown(f"Plugin rebuild loop: `{args.plugin}`, zig {zig}, {sys.platform}"))


if __name__ == "__main__":
    main()
