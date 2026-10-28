# Gates

- `scripts/check-fmt.sh`: PASS (exit 0; 569 files checked). Log: `/tmp/f629-gate-0.log`.
- `scripts/zb build lint --summary all`: Build Summary: 3/3 steps succeeded. Log: `/tmp/f629-gate-1.log`.
- `scripts/zb build --summary all`: Build Summary: 85/85 steps succeeded. Log: `/tmp/f629-gate-2.log`.
- `scripts/zb build test --summary all`: Build Summary: 189/189 steps succeeded. Log: `/tmp/f629-gate-3.log`.
- `scripts/zb build test-integration --summary all`: Build Summary: 98/100 steps succeeded (1 failed); 262/266 tests passed (4 failed). Log: `/tmp/f629-gate-4.log`.
- `scripts/zb build check-web --summary all`: Build Summary: 45/45 steps succeeded. Log: `/tmp/f629-gate-5.log`.
- `scripts/zb build test-sdk-version --summary all`: Build Summary: 35/35 steps succeeded. Log: `/tmp/f629-gate-6.log`.
- `scripts/zb build check-tests-reached --summary all`: Build Summary: 174/174 steps succeeded. Log: `/tmp/f629-gate-7.log`.

- `scripts/zb build test-integration -Dtest-filter="input timestamps cover" --summary all`: PASS, 100/100 steps succeeded; 1/1 tests passed. Log: `/tmp/f629-positive.log`.
- Negative control, same focused command with only SDLBackend.addEvent reverted to the old pre-input length: expected FAIL, 98/100 steps succeeded; 0/1 tests passed. The motion's input_time fell back to frame_time_ns. Production range restored afterward. Log: `/tmp/f629-negative.log`.
- Earlier focused compile attempts while wiring the test: FAIL (undeclared integration_tests, then duplicate glass module); corrected by wiring after integration_module creation and sharing headless materials/platform types. Final focused and reachability gates pass.
- `zig fmt build/app.zig tests/integration.zig`: PASS.
- `git diff --check`: PASS.

The full integration gate's four failures are sandbox Unix-socket bind restrictions (`PermissionDenied` in posixBindUnix), unrelated to timestamp delivery:

- `integration.test.control: a command that answers in a later frame holds its request open until it does`
- `integration.test.control: MCP on the socket lists the commands as tools and calls them, now or later`
- `integration.test.control: an MCP session's id comes back as a header, and DELETE /mcp ends it`
- `integration.test.control: the app's events reach a stream, and the bus listens only while one is open`

No physical flick recording or before/after release-velocity measurement was collected; see BLOCKED.md. Native unit-test results include cached steps; the rebuilt integration binary exercised the new regression.
