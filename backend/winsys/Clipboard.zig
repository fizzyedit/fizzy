//! The system clipboard's contents identity. The clipboard has no event stream to read from:
//! contents are fetched on demand (`Platform.clipboardText`) and replaced by
//! `Platform.setClipboardText`. The file is the "replaced by someone else" event payload.
//!
//! Text only, because that is all fizzy reads or writes (`dvui` `clipboardText`). Other
//! representations (files, images, several offers per item, lazily produced data) are deferred;
//! the seam is `Format` plus a second pair of `Platform` functions, not a change to this one.
//! `docs/window-notes/clipboard.md` records what the platforms differ on.

const Clipboard = @This();

/// The clipboard's change counter after the replacement. It changes when anyone, this app
/// included, replaces the contents; equal serials mean the same contents. It lets an app cache
/// what it pasted last and ask the clipboard again only when this moved. The app's own
/// `setClipboardText` sends no event.
serial: u64,

/// The representations the interface can ask for. One today; see the file comment.
pub const Format = enum { text };
