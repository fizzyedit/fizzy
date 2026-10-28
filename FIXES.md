macos/agy F1 declined: remains a valid open blocker; this worker has no physical input device access and cannot launch a window under docs/AGENT_WORK.md. A device-enabled worker must record the before/after release-velocity error; see BLOCKED.md.
macos/agy F2 fixed: replaced the copied range with SDLBackend.addEvent delivering direct touch motion into a headless dvui.Window; reverting only the production range fails (0/1 tests), restoring it passes (1/1 tests); included in harness commit.
macos/claude F1 declined: the recorded physical flick evidence remains unavailable for the same device/window restrictions as macos/agy F1.
macos/claude F2 fixed: the regression now invokes SDLBackend.addEvent and fails when its production range fix is reverted; included in harness commit.
macos/claude F3 fixed: PR_SUMMARY.md identifies the node test as forwarding coverage only, not evidence for this fix; included in harness commit.
macos/claude F4 fixed: both backend comments already explain harmless restamping of the trailing position slot at the supplied head 923c9e80.
