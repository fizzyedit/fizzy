# Minimal app measurements

[`hello-numbers.yml`](../.github/workflows/hello-numbers.yml) runs on every push to main and on manual
dispatch, never on pull requests (two release builds and a package on two OSes is too much load
for each one). `python3 scripts/test-hello-numbers.py` and the `--sizes-only` mode are the checks
a pull request runs itself. Each macOS/Linux artifact contains
`hello-numbers.jsonl`: one complete JSON object for each ReleaseFast/ReleaseSmall run.
Download both artifacts from the [workflow runs](https://github.com/fizzyedit/fizzy/actions/workflows/hello-numbers.yml).
A failed measurement fails the job; a partial artifact may contain only the first mode.

The script copies example-app and example-plugin into a disposable directory, repins their
Fizzy dependencies to this tree, and builds example-app's **minimal shape with its normal
plugin list**. Minimal describes the layout, not a plugin-free executable. The scratch build
adds package/web output steps using the dependency's `web-wasm` and `package`
named outputs, and sets the unpublished package version to `0.1.0` (Velopack rejects the library
default `0.0.0`).
`--sizes-only` records the three sizes and never opens a window.
Source checkouts remain untouched. Build commands go through `scripts/zb`.
Scratch sources and build outputs are deleted even on failure.

On a machine where opening a window is acceptable (not a window-free worker session):

```sh
scripts/hello-numbers.sh --output "$PWD/hello-numbers.jsonl" \
  --revision '<fizzy commit; add dirty if edited>' fizzy \
  --example ../example-app --example-revision '<example-app commit>' \
  --plugin ../example-plugin --plugin-revision '<example-plugin commit>'
```

Install Zig 0.17.0 and .NET 10 first. Linux also needs GTK3 development files, Mesa and a display;
CI uses Xvfb with Mesa software rendering. On macOS CI uses the runner's display and Metal.
These are different rendering environments: compare changes within a runner image, and do not
present the two platforms as equivalent hardware. The JSON includes OS, architecture, hostname,
runner image, compiler version, all three source revisions and executable SHA-256.

| JSON field | Method |
| --- | --- |
| `binary_bytes` | Installed `minimalapp`, after host `strip` (and ad-hoc signing on macOS). Excludes resources and plugin libraries. Packaging may link a separate executable with Velopack support. |
| `installer_bytes` | Unsigned macOS `.pkg` or Linux `.AppImage` from the `package` output; includes packaged resources/libraries. A missing or ambiguous installer fails. |
| `first_frame_ms` | `core.profile`'s `main` to `first frame` phase at the end of the first `AppFrame`. Excludes loader work before Zig main; GPU submission, display presentation and window reveal may follow. |
| `idle_rss_bytes` | Sum of `ps` RSS (KiB x 1024) for the process and descendants, sampled 30 seconds after spawn. Shared pages may be counted more than once. |
| `wasm_gzip_bytes` | Installed `web.wasm`, gzip with mtime zero, default compression level 9. Excludes JS, fonts and runtime plugin downloads. |

Each run uses a fresh `FIZZY_PROFILE` and a fresh process, with `FIZZY_QUIET=1` to avoid focus
activation and `FIZZY_STARTUP_REPORT=1`, which makes the app print its first-frame time on stderr
(unset, a shipped build prints nothing). This is **process cold start with warm OS caches**, not a reboot or purged disk-cache
measurement. It is a single sample, not a percentile. `rss_sample_after_s` records the actual
sample time. No input is sent during the 30-second idle interval. The app and its helpers are
terminated after the sample; a missing first-frame marker or an early exit fails the run.

## Electron and Tauri comparison (manual only)

`scripts/compare-hello.sh` measures already-built stock hello-world applications on the **same
machine**, outside CI. Keep framework templates at their defaults, use production packaging,
and record template/source revision and exact framework version. Do not use a development
server or attach developer tools. Supply the executable inside the packaged app and its actual
installer. Strip the executable before packaging, preserving/replacing any required signature.
The executable count excludes Electron's shared Chromium framework and Tauri's system webview;
the installer count describes the distributed payload.

Add only a readiness marker: after the template's first content has rendered, wait for two
`requestAnimationFrame` callbacks and emit `HELLO_FIRST_FRAME` to **native stdout**, once.
For Electron, relay an IPC message from the renderer to `console.log` in the main process;
for Tauri, invoke a Rust command that uses `println!`. A webview console message alone does
not reach the harness. Keep this instrumentation in the recorded source revision. Startup is
measured externally from spawn to observing stdout (10 ms polling), so it includes loader/IPC
work and is **not directly equivalent** to Fizzy's internal main-to-first-frame clock.

Configure each application to put all user data under the `HELLO_PROFILE` environment variable
before creating its window (Electron: `app.setPath('userData', ...)`; Tauri: configure the
webview data directory). This variable is set to a new disposable directory for every run.
The harness includes descendant RSS so Electron's renderer and GPU helpers count. Tauri may
use OS webview services outside its process tree; disclose that limitation with the results.

```sh
scripts/compare-hello.sh --output "$PWD/peers.jsonl" --revision '<instrumented source commit>' \
  compare --app electron --framework-version '<version>' \
  --binary '/path/to/Hello.app/Contents/MacOS/Hello' --installer '/path/to/Hello.dmg'
scripts/compare-hello.sh --output "$PWD/peers.jsonl" --revision '<instrumented source commit>' \
  compare --app tauri --framework-version '<version>' \
  --binary '/path/to/hello' --installer '/path/to/hello.AppImage'
```

Use the same invocation on Linux with that platform's packaged executable/installer paths.
Put the resulting JSON lines and the machine, template versions, packaging commands and marker
instrumentation in the PR. Do not substitute published marketing figures for local samples.
Peer wasm size is `null`: these packaged desktop templates have no matching wasm artifact.

## Verification

`python3 scripts/test-hello-numbers.py` exercises the harness with short-lived console-only
fixtures. RSS command output is mocked in these tests so restricted workers can run them;
production measurements always call `ps`. The macOS/Linux workflow is the end-to-end check of
real packaging, presentation, process memory sampling and cleanup.
