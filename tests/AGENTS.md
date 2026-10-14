# tests/

`README.md` here is the guide: running, filtering (`-Dtest-filter`), and how Zig collects tests.
The rules that bite:

- **A `test` block runs only if a test root's module analyzes its file.** `zig build
  check-tests-reached` fails naming any block that is compiled nowhere. Run it after adding a
  test file.
- **Read the Build Summary, not the test count.** `test-integration` prints `failed command:`
  when a test logs a warning, even on a pass; only `N/N steps succeeded` is a pass.
- **`integration.zig` drives the real app headless** against dvui's testing backend. Add a test
  beside the ones for the same feature rather than at the end.
- **Demo tapes** (`tapes/`, `docs/demos/`) replay real input through the app. How to write one,
  and the anchors widgets publish: `docs/AUTOMATION.md`.
- **Benchmarks** (`bench/`) are test binaries run by `zig build bench-*`. They print timings and
  never gate CI.
