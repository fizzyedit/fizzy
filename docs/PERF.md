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
| `glass_bench_*` | `scripts/glass-bench.sh <gpu-name>`: fixed grid at repeat 1 and 9, or scrolling list at repeat 1 | `glass_pane_us` (grid), `work_p50_us`, `frame_p50_us`, `frame_p99_us`, `target_switches_peak`, `program_px_peak`; extra key `gpu` |
| `test_build` | `zig build check` cold: compiles the unit tests without running them | `wall_time`, `compiler_peak_rss` |

The change a rebuild makes is an appended `pub const perf_compile_probe_N = N;`: new content, so
the cache is invalid and the file is parsed again, but nothing refers to it. A *full* rebuild
pays for that anyway; an *incremental* one is therefore a floor (it re-parses and relinks, but
re-analyzes nothing that depended on the file). Read `rebuild_time_incremental` as the cost of
the machinery, and the absolute edit-to-binary time of a real edit as somewhat higher.

`plugin_roundtrip` stops at the installed dylib. The agent plugin's `fizzy_build` also has the
running app `dlopen` the result, which needs a window and so is not part of a headless run; the
dylib build is where the time goes.

## Which edits stay incremental

Yes, on Zig 0.17.0 and this build graph: `zig build -fincremental --watch` (`scripts/watch`)
rebuilds the app, core, the SDK and every in-tree plugin after a save, and no edit kind falls
back with a message or fails to rebuild. `scripts/perf-incremental` measures it: for each target
one watch process, and per edit kind the time from the save to the next Build Summary, against
the same edits in a plain `zig build`. Median of 3, Linux x86_64 (16 CPUs, 27 GiB), Zig 0.17.0,
Debug; macOS and Windows are unmeasured.

| edit kind | what the script appends |
|---|---|
| `new_decl` | a new `pub const` nothing uses |
| `body` | a different literal in a function body |
| `sig` | a function's return type changes, with a caller |
| `comptime_const` | a `pub const` used as an array length changes |
| `import` | a `comptime { _ = @import(..) }` added and removed |
| `compile_error` | a `@compileError`; the build must fail, and the next edit must recover |
| `build_zig` | a comment appended to the target's `build.zig` |

Seconds, watch / full (`-` where not run):

| target | new_decl | body | sig | comptime_const | import | compile_error | build_zig |
|---|---|---|---|---|---|---|---|
| app | 0.38 / 11.2 | 0.50 / 8.7 | 0.93 / 10.7 | 0.83 / 8.5 | 0.82 / 14.3 | 0.17 / 7.1 | 37.0 / 1.2 |
| core | 1.6 / 16.5 | 2.8 / 12.6 | 2.4 / 13.5 | 2.4 / 19.5 | 0.44 / 28.9 | 0.23 / 12.2 | - |
| sdk | 0.45 / 24.3 | 2.5 / 9.6 | 5.8 / 15.3 | 4.8 / 24.2 | 12.5 / 28.5 | 0.53 / 9.9 | - |
| plugin archive | 0.17 / 1.8 | 0.16 / 1.7 | 0.30 / 1.7 | 0.30 / 1.8 | 0.83 / 1.7 | 0.17 / 1.6 | 7.4 / 1.2 |
| plugin devtools | 0.31 / 2.0 | 0.19 / 1.9 | 0.32 / 2.0 | 0.19 / 2.0 | 0.30 / 2.0 | 0.12 / 1.8 | 10.4 / 1.2 |
| plugin guides | 0.72 / 1.7 | 0.29 / 1.8 | 0.67 / 1.7 | 0.16 / 1.7 | 0.73 / 1.7 | 0.12 / 1.6 | 8.6 / 1.3 |
| plugin image | 0.28 / 1.8 | 0.18 / 1.8 | 0.29 / 1.8 | 0.29 / 1.8 | 0.28 / 1.8 | 0.13 / 1.6 | 7.8 / 1.0 |
| plugin markdown | 0.33 / 4.5 | 0.18 / 4.5 | 0.49 / 15.7 | 1.2 / 4.4 | 4.5 / 4.3 | 0.13 / 2.7 | 10.8 / 3.3 |
| plugin text | 0.40 / 2.1 | 0.33 / 2.1 | 0.18 / 2.1 | 0.33 / 2.1 | 1.4 / 2.1 | 0.17 / 1.9 | 12.5 / 1.2 |
| plugin workbench | 0.33 / 4.8 | 0.19 / 3.5 | 0.33 / 3.7 | 0.32 / 5.9 | 0.19 / 2.2 | 0.13 / 1.9 | 8.0 / 1.7 |

(The first eight rows were measured at commit `5fc11d83`, text and workbench at current `main`;
no later commit touched the build graph. The `text` `comptime_const` watch figure was rerun, 5
runs, after a first sample coalesced with the previous build and read 0.01 s.)

What the table says:

- **A saved `.zig` file is fast everywhere**, from 0.1 s (a plugin) to a few seconds (core and the
  SDK, which everything imports), 5 to 60 times quicker than a full rebuild, and a compile error
  and its fix both stay incremental.
- **A change to `build.zig` is the exception, and a loss**: 7 to 37 s under `--watch` against
  1 to 3 s for a plain rebuild. The build runner restarts and the watched compilations start over (the
  app's 37 s is about a full Debug build); the cause is not isolated. Stop and restart `scripts/watch` after editing a `build.zig` or
  `build.zig.zon`, or accept the one slow rebuild.
- **An SDK `import` or `sig` edit costs seconds**, because every plugin and the app depend on it:
  that is analysis the compiler really has to redo, not a fallback.
- Nothing printed a fallback or "unsupported" line, so there is no compiler bug to report.

The numbers depend on the machine: rerun `scripts/perf-incremental` before relying on them, and
put new runs in the PR that changes the build graph as well as here.

## Recording frame causes

`scripts/perf-frame-record` reads a profiler ZON report from stdin (request both `hitches > 0`
and `causes > 0`) and appends each retained frame to the same monthly JSONL store. For example:

```sh
scripts/perf-frame-record --commit fa1402da --machine host/16cpu/27GiB --scenario tour < report.zon
```

Use the commit, machine and OS of the measured app (`--os` overrides the local OS). These rows
use metric `frame_work`, unit `ms`, and the optional `causes` array of input/refresh flags.
The report lists retained frames newest first; overlapping reports repeat samples, so export
once per recording. This is a bounded history sample, not a continuous recording or a median.
`--store DIR`, `$FIZZY_PERF_STORE`, then `$XDG_DATA_HOME/fizzy/perf` (defaulting to
`~/.local/share/fizzy/perf`) select the store as for `perf-compile`. The script prints the same
lines it appends and rejects reports without retained frame rows.

The glass benchmark accepts `--store DIR`, `$FIZZY_PERF_STORE` and `--no-store` as above.
Set `FIZZY_BIN` to the built executable if it is not on PATH. Its GPU budgets live in
`tests/tapes/glass-bench.budget.zon`; an unknown GPU records a baseline without a time gate.
The list measures every row, including those outside the viewport, until the virtual-list arm ships.
