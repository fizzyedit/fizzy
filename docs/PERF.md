# Measuring compile time

`scripts/perf-compile` is the repeatable measurement behind the compile-speed numbers we trend.
It runs headless on Linux (it needs `bc`, GNU `/usr/bin/time` and `/proc`, and says so up front) and prints one JSON line per metric:

```json
{"date":"…","commit":"79dec396","machine":"host/16cpu/27GiB","zig":"0.17.0","os":"Linux …","scenario":"touch_core","metric":"rebuild_time","value":8.1,"unit":"s"}
```

Every value is the **median of 5 runs** (`--runs N` changes it). Progress goes to stderr, the JSON
to stdout, so `scripts/perf-compile > run.jsonl` keeps a clean record. `--only a,b` runs some
scenarios, `--list` names them all.

Run it on a quiet machine, one at a time. It times `zig` directly (not through `scripts/zb`, whose
wait for a slot would count), waits for the 1-minute load average to drop under `nproc/4`
(`FIZZY_PERF_MAX_LOAD`) and gives up after `FIZZY_PERF_WAIT` seconds. Each build uses a scratch
cache dir and install prefix, so it never touches your `.zig-cache` or `zig-out`; the global
cache keeps the fetched dependencies, so **no number includes a download**. Plugin builds install
into a scratch `FIZZY_PROFILE`. The files a rebuild changes are restored on exit.
`FIZZY_PERF_TMP` names the directory the scratch space is made under; the script creates and
deletes its own child there and never touches the rest.

## Scenarios and metrics

| scenario | what is timed | metric |
|---|---|---|
| `cold_debug`, `cold_releasefast` | `zig build` with an empty local cache: the app and every bundled plugin | `wall_time`, `compiler_peak_rss` (MiB, the largest resident set of any process in the build, from `/usr/bin/time`) |
| `noop` | `zig build` again on a warm cache, nothing changed: the build graph's fixed cost | `wall_time` |
| `touch_app` | warm Debug build, then a change to `src/editor/CommandPalette.zig` | `rebuild_time` |
| `touch_core` | the same for `core/anim.zig`, which every plugin and the app build in | `rebuild_time` |
| `touch_plugin` | the plugin's own `zig build` in `plugins/text`, after a change to `plugins/text/src/Settings.zig` | `rebuild_time` |
| `incr_app`, `incr_core`, `incr_plugin` | the same changes against a running `zig build -fincremental --watch`: time from the edit to the next Build Summary | `rebuild_time_incremental` |
| `plugin_roundtrip` | the headless half of a plugin hot reload: change a plugin, build its dylib, install it into a profile | `build_install_time` |
| `test_build` | `zig build check` cold: compiles the unit tests without running them | `wall_time`, `compiler_peak_rss` |

The change a rebuild makes is an appended `pub const perf_compile_probe_N = N;`: new content, so
the cache is invalid and the file is parsed again, but nothing refers to it. A *full* rebuild
pays for that anyway; an *incremental* one is therefore a floor (it re-parses and relinks, but
re-analyzes nothing that depended on the file). Read `rebuild_time_incremental` as the cost of
the machinery, and the absolute edit-to-binary time of a real edit as somewhat higher.

`plugin_roundtrip` stops at the installed dylib. The agent plugin's `fizzy_build` also has the
running app `dlopen` the result, which needs a window and so is not part of a headless run; the
dylib build is where the time goes.

## Does incremental compilation work here?

Yes, on Zig 0.17.0 and this build graph: `zig build -fincremental --watch` rebuilds the app, and
each plugin, and reports a successful summary after an edit; `incr_core` and `incr_plugin` give
the edit-to-summary times. The script fails the
run if a watched build's summary reports a failed step. Watched builds run with `--summary line`
(the default prints nothing on success), and each edit is one rename of a complete file over the original, after the watcher has gone
idle, so the next summary is the build that edit caused. The cost of the first build under
`-fincremental` and `--watch`'s inotify use on a tree this size are not measured separately.
What is not yet known is how it behaves for edits that change analyzed code (see the probe
note above); extend the probe before relying on incremental numbers as a target.

See a run's numbers in the PR that last changed this file, and append new runs there rather than
here: they depend on the machine.
