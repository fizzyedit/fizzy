//! A plugin's hold on an open document while it works on it: an agent drawing, a demo playing
//! into it, a long operation. While a document is claimed, the person's input to it is held back
//! (its panes take no pointer or keys, and the commands a person runs on it are refused), the
//! panes say who holds it, and the person can stop it. Everything else stays theirs to use, and
//! their undo, redo and going back always run: on a held document they stop the holder first
//! (`fizzy.claim.stopped`), so it is never left dirty with work they cannot take back.
//!
//! The holder's own calls are not gated: a claim says who may change the document, and the
//! holder changes it through commands (`Host.callCommand`). Claims are made and released with
//! `Host.claimDocument` / `Host.releaseClaim`; the host drops them when the document closes or
//! the holder unloads.
const Plugin = @import("Plugin.zig");

const Self = @This();

/// Unique for the life of the host; never 0.
id: u32,
/// The claimed document (`DocHandle.id`).
doc_id: u64,
/// Who holds it, as the person reads it on the panes ("Claude"). Owned by the host.
label: []const u8,
/// The plugin that took it.
owner: *Plugin,
