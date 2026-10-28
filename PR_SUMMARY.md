## Goal
Answer the review findings on PR #967 (fizzyedit/work#629), including macos/agy's review at 923c9e80.

## What changed and why
Replace the copied timestamp-range test with delivery through the real SDLBackend.addEvent. Compile the backend source against the integration harness's headless dvui and materials; wire its platform module to those same types. A direct touch motion exercises trailing position replacement without creating an OS window or GPU. Production code is unchanged in this revision.

## How it was verified
Negative control: reverting only SDLBackend.addEvent's range to the pre-input length fails the new test (98/100 steps succeeded; 0/1 tests passed). Restoring the production fix passes (100/100 steps succeeded; 1/1 tests passed). The assertion reads core.input_time for the delivered motion and rejects the frame-time fallback. Full gates are in GATES.md. The existing node test is forwarding coverage, not evidence for the range fix.

## Not done / follow-ups
The blocker macos/agy F1 (also macos/claude F1) remains open: no recorded physical flick or before/after release-velocity measurement is available in this checkout. Device access is missing and the worker contract forbids launching a window. The prior scripted burst measurement is not a recorded flick and does not isolate this off-by-one change. A device-enabled worker must supply the required evidence before Done is satisfied. The harness handles committing, publishing and the single FIXES comment.

Changed after self-review:
Q1 Goal: partly; backend regression evidence supplied, physical flick evidence still blocked.
Q2 Lean and Zig: removed the duplicated range logic; test calls production delivery with SDL and shares the harness's dvui types.
Q3 Approach: keep.
Q4 Fit: aligned with the timestamp preservation fix; no production behavior or SDK change in this revision.
Risk: test build wiring is verified on Linux only.
Not checked: physical flick behavior and macOS/Windows execution.
Full integration: 98/100 steps succeeded, with four control tests failing at Unix-socket bind with PermissionDenied. These sandbox failures are named in GATES.md; the backend timestamp regression passes.
