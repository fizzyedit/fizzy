//! A **surface**: a named thing a plugin can draw.
//!
//! This replaces the `SidebarView` / `BottomView` / `CenterProvider` trio, which differed only
//! in *where the host chose to call them*. Those names were fizzy's furniture leaking into the
//! plugin contract; an app built on fizzy as a library has its own furniture, or none.
//!
//! A surface says what it *is*, never where it goes:
//!
//!   * `id` is identity — unique, stable, plugin-namespaced.
//!   * `keywords` say what *kind of place* the content belongs, e.g. `.{"sidebar","explorer"}`.
//!     An app's regions declare which keywords they accept, and a surface draws in a region when
//!     the two intersect. Keywords are free-form strings, so a plugin inventing a new kind of
//!     panel never touches this ABI — and they are only defaults: the user overrides them
//!     per-plugin in `settings.zon`, so a wrong guess costs two clicks rather than a release.
//!
//! Contrast with a *document*, the other half of plugin drawing, unchanged by this:
//! `Plugin.VTable.drawDocument` renders one open file, routed by `DocHandle.owner`. Workbench is
//! itself a surface whose draw subdivides its area into tabs and splits and then invokes the
//! document half per pane.
const std = @import("std");
const dvui = @import("dvui");
const Plugin = @import("Plugin.zig");
const kw = @import("keywords.zig");

const Surface = @This();

/// Stable, unique, plugin-namespaced: "workbench.panes", "pixi.sprites".
id: []const u8,
owner: ?*Plugin = null,
/// User-facing, shown wherever the app chooses to name this surface.
title: []const u8,
icon: ?Icon = null,
/// The kinds of place this content belongs. Defaults; the user's `settings.zon` overrides win.
/// An empty list means the surface is never matched by keyword and must be placed by id — which
/// is what an app does for a plugin it ships with and therefore knows by name.
keywords: []const []const u8 = &.{},
ctx: ?*anyopaque = null,
/// Draw the content into the parent the host has established. Immediate mode: expand into the
/// space you are given.
draw: *const fn (ctx: ?*anyopaque) anyerror!dvui.App.Result,
/// A surface shown **only while another is selected**: the id of that other surface. While it
/// is the selection of its region, this one is drawn in place of whatever a region accepting
/// *this* one's keywords would otherwise show, and it is invisible the rest of the time.
///
/// This is how a sidebar tab annexes the main area for as long as it is the tab: pixi's packer
/// (`keywords = {"main"}, takeover_when = "pixi.project"`) fills the workspace while "Project"
/// is selected in the rail, and a plugin's README fills it while its store card is. One rule in
/// the layout, declared by the surface, instead of a hook per place it can happen.
takeover_when: ?[]const u8 = null,
/// Runtime state, not registration data: the plugin store toggles a built-in off without
/// unloading it. Set through `Host.setSurfaceHidden`.
hidden: bool = false,
/// Keep drawing this surface's region even with no active document. Was
/// `BottomView.persistent`.
persistent: bool = false,

/// How a surface asks to be depicted where an app chooses to list it (an icon rail, a tab
/// strip). Format-tagged so fizzy's tvg is not imposed on an app that wants something else, and
/// entirely ignorable — an app may resolve its own icon by surface id, or draw no icons at all.
pub const Icon = union(enum) {
    tvg: []const u8,
    png: []const u8,
    none,
};

/// Does this region accept this surface? The whole binding rule, and `keywords.accepts` is the
/// one implementation of it — the region's vocabulary is the first argument because the question
/// is asymmetric once keywords can name a place inside another (`keywords.Fit`).
pub fn matches(self: *const Surface, region_keywords: []const []const u8) bool {
    return kw.accepts(region_keywords, self.keywords);
}

/// How strongly this region accepts this surface, for the ambiguity rule: where two regions both
/// accept a surface, the more specific one claims it (`Layout.claimedElsewhere`).
pub fn matchStrength(self: *const Surface, region_keywords: []const []const u8) kw.Fit {
    return kw.strength(region_keywords, self.keywords);
}
