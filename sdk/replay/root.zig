//! The dvui half of tapes: playing one into a running dvui app as real input, aiming by widget
//! names rather than pixels. `tape` (std-only) is the format and the engine; this is what drives
//! a window with it, and needs nothing but `dvui` and `tape` — any dvui app can take it, as fizzy
//! does (`app.automation`, which adds fizzy's own overlay and plugin service on top).
//!
//! - `Player` plays a demo: keyframed, seekable, paced by the tape's own times.
//! - `LiveDriver` plays a live tape: on the app as it is, each step once the last has landed.
//! - `Input` turns tape ops into dvui events; both share it.
//! - `Stage` is the seam an app fills in: what its state is, how to run a command, whether it is
//!   idle.
//! - `anchor` names widgets for a tape to aim at (`dvui.tag`, with names built from data).
//! - `Snapshot` says what is on screen, as text: roles, names, tags, rects.
//! - `overlay` draws the tape's pointer and its clicks, plainly — an app may draw its own.
//!
//! See `docs/AUTOMATION.md` and `plans/AUTOMATION_PLAN.md`.
pub const Player = @import("Player.zig");
pub const LiveDriver = @import("LiveDriver.zig");
pub const Input = @import("Input.zig");
pub const Stage = @import("Stage.zig");
pub const anchor = @import("anchor.zig");
pub const Snapshot = @import("Snapshot.zig");
pub const overlay = @import("overlay.zig");

test {
    _ = Player;
    _ = LiveDriver;
    _ = Input;
    _ = Stage;
    _ = anchor;
    _ = Snapshot;
    _ = overlay;
}
