//! A **region a plugin declares**: a place inside the region it is already drawing in, which the
//! app's layout then treats as one of its own.
//!
//! The app declares the shape — rail, sidebar, main, panel — and until now that was the only way a
//! region could exist, so everything the framework grew around regions (the corner button and its
//! picker, `shows`, assignments persisted by name, the settings table, keyword claiming) stopped
//! at the surface a plugin draws. Inside it a plugin had to invent its own subdivision, which is
//! exactly what the workbench did with workspaces and tab strips: a second implementation of the
//! same idea, addressable by nothing.
//!
//! A plugin's region is not a hole in that design, because it is not a new place in the app's
//! vocabulary: its keywords are **qualified by the region it is declared inside**
//! (`sdk.keywords.Fit`), so a workbench pane declaring `{"document"}` inside the main area
//! accepts `main.document` and nothing else. A plugin cannot name, collide with or steal another
//! app region by accident — it can only subdivide the place it was given.
//!
//! ```zig
//! var pane = host.region(.{
//!     .name = "Pane 1",
//!     .keywords = &.{"document"},
//!     .shows = .one,
//!     .key = grouping,
//! }) orelse return .ok;
//! defer pane.deinit();
//!
//! drawTabStrip();      // the plugin's own chrome
//! pane.drawContents();  // and the surfaces the region accepts, where the plugin wants them
//! ```
const std = @import("std");
const dvui = @import("dvui");

const RegionSpec = @This();

/// How many accepted surfaces this region shows at once. The region telling the truth about how
/// it draws, which is the one thing nothing else can work out — everything that offers the user a
/// choice reads it (over `.one` the picker's cards swap, over `.many` they toggle).
///
/// Here rather than in the app's `Region` because a plugin declaring a region has to be able to
/// say it, and there must be exactly one definition of what it means.
pub const Shows = enum { one, many };

/// The app's handle to an open plugin region. Opaque: it indexes a stack the app owns, and its
/// only valid use is the `deinit` that closes it, in the frame that opened it.
pub const Token = enum(u32) { _ };

/// Human-facing name, and the key an assignment persists under — so it is worth a real word. A
/// per-pane region should name the pane ("Pane 2"), not the plugin.
name: []const u8 = "",
/// What kinds of surface this region accepts, *unqualified*: write `{"document"}`, not
/// `{"main.document"}`. The enclosing region's name is prefixed for you, because a sub-region
/// should not have to know — or repeat — what it is nested in.
keywords: []const []const u8 = &.{},
shows: Shows = .one,
/// The axis this region lays its own children along, exactly as `dvui.box`'s `dir`.
dir: dvui.enums.Direction = .vertical,
/// Distinguishes regions declared from the same code path: a loop over three document panes
/// passes each pane's stable id. Must be unique among the regions the caller declares under one
/// parent, and stable across frames — it is half of the widget id, so a `key` that changes is a
/// region that forgets its size and its selection.
key: u64 = 0,
/// Draw nothing and take no space while no accepted surface exists.
hide_when_empty: bool = false,
/// How this region is laid out inside its parent, in the parent's terms — `dvui.Options`, cut
/// down to what makes sense for something the app is ultimately arranging.
expand: dvui.Options.Expand = .both,
/// A minimum along the parent's axis, in points. Zero means "take what is left".
min_extent: f32 = 0,

test {
    std.testing.refAllDecls(@This());
}
