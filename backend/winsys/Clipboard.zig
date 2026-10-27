//! The clipboard's contents identity: the payload of the event that says someone else replaced
//! them, and what `Platform.clipboardSerial` returns.
//!
//! The clipboard has no stream to read from: contents are fetched on demand
//! (`Platform.clipboardText`) and replaced by `Platform.setClipboardText`.
//!
//! Text only, because that is all fizzy reads or writes. Other representations (files, images,
//! several offers per item, lazily produced data) are deferred; the seam is a format argument on,
//! or a second pair of, those `Platform` functions. `docs/window-notes/clipboard.md` records
//! where the platforms differ.

const Clipboard = @This();

/// The clipboard's change counter. It changes when anyone, this app included, replaces the
/// contents; equal serials mean the same contents, so an app can cache what it pasted and ask
/// again only when this moved. The app's own `setClipboardText` changes it but sends no event.
serial: u64,
