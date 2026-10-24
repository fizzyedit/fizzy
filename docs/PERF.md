# Performance data: one store

Every performance number fizzy keeps goes in **one store, in one format**: the superfans' perf
findings (`plans/` #58), `scripts/perf-compile`, and the project manager's CI history all append to
it, and the dashboard and the recaps read it. Nothing keeps a private file of its own.

## Where it lives

**Not in this repo.** Measurements are data that only grows, and the library repo stays lean. The
store is the repo `fizzyedit/perf-data` (private, like `fizzyedit/plans`), holding only:

```
YYYY-MM.jsonl     one file per month, append-only
```

Monthly files keep each one small (a full `perf-compile` run is 17 lines), bound a clone's cost to
what is read, and make a write a plain append. A line is never edited or deleted; a wrong run is
answered by a later line, or by dropping the file's tail in a PR to that repo.

Until that repo exists, the PM machine's `perf/history.jsonl` is the only copy and is imported
as-is into the store (its lines already fit the format below).

## Format

JSON Lines, UTF-8, one object per line, keys in this order:

```json
{"date":"2026-10-24T10:00:00Z","commit":"79dec396","machine":"host/16cpu/27GiB","os":"Linux 6.9.3","scenario":"touch_core","metric":"rebuild_time","value":8.1,"unit":"s"}
```

| key | meaning |
|---|---|
| `date` | UTC, ISO 8601, to the second: when the run started. Names the file (`YYYY-MM.jsonl`) |
| `commit` | short hash of the tree measured |
| `machine` | `host/<N>cpu/<M>GiB`: numbers are only comparable on one machine |
| `os` | `uname -sr` (or the OS name and version off Linux) |
| `scenario` | what was run (a table row below, or a fan's or CI job's own stable name) |
| `metric` | what was read from it (`wall_time`, `rebuild_time`, `compiler_peak_rss`, ...) |
| `value` | a JSON number, median of the run's samples where there are several |
| `unit` | `s`, `MiB`, `ms`, `B`, `count` |

Optional extra keys (`zig`, `runs`, `source`) are allowed and readers ignore keys they do not know.
`perf-compile` writes `zig`. Names are lowercase `snake_case`, and a scenario keeps its name for
good so a series stays one series.

## Who appends, who reads

- **Writers** append whole lines to the month's file. `scripts/perf-compile` writes to a local
  store directory (`--store DIR`, else `$FIZZY_PERF_STORE`, else
  `~/.local/share/fizzy/perf`; `--no-store` writes none) and still prints the same lines on stdout.
  That local directory is a checkout-shaped working copy: the PM's job and CI commit its new lines
  to `fizzyedit/perf-data` (a rebase-and-push of an append never conflicts on content). A fan
  files its findings as issues as before, and records the numbers behind them as lines here.
- **Readers** take the store as read-only text: the dashboard (`plugins/devtools`) and the
  recaps read `*.jsonl`, group by `machine`, `scenario` and `metric`, and order by `date`.
  A trend compares like with like only: the same machine and the same scenario.

# Measuring compile time

`scripts/perf-compile` is the repeatable measurement behind the compile-speed numbers we trend.
It runs headless on Linux (it needs `bc`, GNU `/usr/bin/time` and `/proc`, and says so up front) and prints one line per metric, in the store's format above (and appends it to the local store):

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
