//! The keyword sets fizzy's own regions accept.
//!
//! Documented conventions rather than an enum: a plugin author can rely on these in any app that
//! keeps fizzy's shape, an app is free to accept entirely different keywords, and adding to this
//! list never bumps the ABI. That is the whole reason matching is by string — see
//! `Surface.keywords` and docs/PLUGINS.md.
pub const sidebar: []const []const u8 = &.{ "sidebar", "explorer" };
pub const bottom: []const []const u8 = &.{ "bottom", "panel", "output" };
pub const main: []const []const u8 = &.{ "main", "center", "workspace" };
