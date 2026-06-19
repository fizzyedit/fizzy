//! An opaque handle to an open document. The shell stores these per tab/workspace
//! and never inspects `ptr` — it only routes operations to `owner` (the plugin
//! that opened the document and knows how to render/save/undo it). For pixel art
//! `ptr` is a `*pixelart.internal.File`; a text plugin would point it at its own type.
const Plugin = @import("Plugin.zig");

pub const DocHandle = @This();

/// Plugin-owned, opaque document state.
ptr: *anyopaque,
/// The plugin that owns this document.
owner: *Plugin,
/// Shell-assigned stable identifier for tabs/workspaces.
id: u64,
