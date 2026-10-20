//! Text composition (input methods): one run of provisional text the user is still editing,
//! before it is committed. The file is that run, as an event carries it.
//!
//! Only the provisional side is here. Committed text is `Event.Payload.text`, the same event a
//! plain keystroke makes, so an editor needs no second path to insert. A composition that is
//! cancelled sends an empty `Ime` and no `text`; one committed sends an empty
//! `Ime` (clearing the provisional run) and then the `text`, in that order: an empty `Ime` with a `text`
//! straight after it is a commit, one without is a cancel. See
//! `docs/window-notes/ime.md`: focus loss during composition is unrecorded, so the platform
//! decides until a conformance case fixes it.
const geometry = @import("geometry.zig");

const Ime = @This();

/// Replaces the previous provisional run whole; empty clears it. Valid until the next
/// `Platform.poll`.
text: []const u8,
/// The part of `text` the input method is currently converting (the highlighted clause), as a
/// byte offset and length. The caret sits at `start + len`. All offsets here are **bytes** of
/// UTF-8, never characters; a platform whose native unit differs (UTF-16 on macOS and Windows)
/// converts before sending.
start: u32 = 0,
len: u32 = 0,

/// Where the caret is, so the candidate window can sit beside it: window pixels, from its top
/// left. Given by the app each frame it edits text (`Platform.setImeArea`).
pub const Area = struct {
    caret: geometry.Rect = .{},
};
