//! One step of a document's history, as its owner reports it to whoever records (`Host.recordStep`):
//! what the document became, not the input that made it, so it replays exactly at any window size
//! and in any layout (`plans/RECORDING_PLAN.md`).
//!
//! Every step is applied **forward**: a step taken back is reported as its reverse (`undone`), so a
//! replay is the effects in the order they came, and never asks an owner to run one backwards.
//! The bytes are the owner's (`Plugin.step_format` numbers its encoding), applied by its
//! `Plugin.VTable.applyStep`, and only valid for the call: whoever records copies them.
const Self = @This();

kind: Kind,
/// The history entry this step is, or joins, or takes back (`Plugin.HistoryLine.Entry.id`). 0 for
/// `restarted`.
id: u64,
/// What the step did, in the owner's encoding, ready to apply forward. Empty for `restarted`.
effect: []const u8 = "",
/// How it was made, when the owner knows (a pen's path and timing, in the document's own
/// coordinates). Empty: a replay shows the effect made the owner's own way.
motion: []const u8 = "",
/// How long it took to make, as the owner saw it (a stroke from press to release). 0: at once.
ms: u32 = 0,

pub const Kind = enum {
    /// A new entry on the history.
    added,
    /// More of the entry on top: a keystroke joining a run of typing. `effect` is only what this
    /// part did.
    joined,
    /// Entry `id` was taken back; `effect` is its reverse.
    undone,
    /// Entry `id` was put back.
    redone,
    /// The history started over (a reload from disk, a restore): nothing before this applies to
    /// what the document is now, and whoever records takes it as it is from here.
    restarted,
};
