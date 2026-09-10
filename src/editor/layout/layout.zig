//! `fizzy.layout` — everything an application uses to lay itself out.
//!
//! Grouped rather than scattered so it is obvious what this material is *for*: these are the
//! pieces you build an app's base layout from, and nothing here knows what a document, an
//! explorer or a panel is.
//!
//!   `Frame`   the live view — which surfaces exist, which match a region, which is selected
//!   `Region`  a named area accepting keywords, drawing whatever matches (`Frame.region`)
//!   `Split`   a resizable, collapsible division, addressable by the keywords it shows
//!   `Tabs`    a reorderable strip of tabs (`core.dvui.Tabs`)
//!   `keywords` the conventional keyword sets fizzy's shipped shapes use
//!
//! ## Who draws the tabs
//!
//! There are two forms, both supported, and the difference is *what the tabs represent*:
//!
//! **The app draws them** when the tabs represent surfaces — several plugins each contributing
//! a pane to one region. The app owns the strip because no single plugin can: they must share
//! it. Fizzy's bottom panel is this. A shape writes `chrome.tabs(f, kw)` then draws the
//! selected surface, or passes `.content = chrome.tabbed` to the region.
//!
//! **The plugin draws them** when the tabs represent something only the plugin knows about —
//! its own documents, timelines, layers. Then the plugin registers *one* surface and draws the
//! entire region: its own tab strip, its own splits, its own content. Fizzy's main area is
//! already exactly this: `workbench` registers one surface and draws document tabs and splits
//! inside it (`Workspace.drawTabs`), and neither fizzy nor any shape knows how many tabs there
//! are.
//!
//! Nothing distinguishes the two at registration — a surface is a surface, and drawing a tab
//! strip inside your own area needs no permission. That is why `core.dvui.Tabs` lives in `core`
//! rather than here: a plugin dylib reaches for the same widget the app does.
//! Note the core pieces come through the named `core` module, never by relative path: a file
//! may belong to only one module, and `@import("../../core/...")` here would claim it for the
//! root build module and break `core` as a dependency outright (CLAUDE.md).
//! ## The shape of a layout
//!
//! ```zig
//! var l = f.layout(@src(), .{ .dir = .horizontal });
//! defer l.end();
//!
//! l.region(.{ .name = "Sidebar", .keywords = kw.ide.sidebar });
//! l.split(.{ .resize = true, .collapsible = true });
//! l.region(.{ .name = "Main", .keywords = kw.ide.main });
//! ```
//!
//! One object with two verbs: declare a region, or put a draggable split between the last one
//! and the next. Reads top to bottom, no `showFirst` / `showSecond` / `rest()` branching, and N
//! regions on an axis rather than a forced tree of two-child panes. Nesting still works and is
//! still how you cross axes — a region's content can be another layout.
//!
//! ## Target: only `region` and `split`
//!
//! The intended end state is that a layout function contains *nothing else* — no `dvui.box`, no
//! `dvui.label`, no fizzy widgets intermixed. Two verbs subdivide the window, with either static
//! or draggable edges:
//!
//! ```zig
//! var body = f.region(@src(), .{ .dir = .horizontal });
//! defer body.end();
//!
//!     f.region(@src(), .{ .name = "Sidebar", .keywords = kw.ide.sidebar, .size = .{ .ratio = 0.2 } });
//!     f.split(@src(), .{ .resize = true, .collapsible = true });
//!
//!     var right = f.region(@src(), .{ .dir = .vertical });
//!     defer right.end();
//!         f.region(@src(), .{ .name = "Main",  .keywords = kw.ide.main });
//!         f.split(@src(), .{ .resize = true });
//!         f.region(@src(), .{ .name = "Panel", .keywords = kw.ide.panel });
//! ```
//!
//! `region` therefore does double duty, and that is deliberate rather than an overload: a region
//! **with** keywords is a place surfaces draw; a region **without** is a plain container you nest
//! more regions in — so it takes box-like options (`dir`, `expand`) as well as placement ones.
//! There is no third concept, and no reason for an app author to reach past this API into dvui.
//!
//! `dir` is what a container region orients — **its child regions and splits**, not content. A
//! horizontal region lays its children left to right, and a `split` inside it is therefore a
//! vertical bar you drag left and right. The split inherits the containing region's axis rather
//! than restating it, so direction is declared in exactly one place; an explicit `dir` on a
//! split is available for the rare case that has to differ.
//!
//! ## How a region gets its size
//!
//! From `expand`, which is dvui's existing meaning rather than a new concept — so there is no
//! separate sizing vocabulary to learn, and the three cases fall out of one field:
//!
//! **Fit to content.** A region that does not expand along its parent's axis takes its size from
//! its content's minimum. In a horizontal container, `.expand = .vertical` means "as wide as
//! what is in me". This is the answer to "a region only large enough to contain its content":
//! you do not size it, and there is no split position to store, because the content decides.
//!
//! **Stretch, with a draggable boundary.** `.expand = .both` on both neighbours means neither
//! has an opinion, so the `split` between them owns the boundary and persists it. A split
//! position is only meaningful when both sides stretch — which is why size belongs on the split
//! rather than on the region.
//!
//! **Fixed.** Fit-to-content plus a minimum: the icon rail is `.expand = .vertical` with a 40pt
//! minimum width, and needs no split at all.
//!
//! The hazard in fit-to-content is that it hands size control to whatever plugin draws there —
//! a surface with a wide minimum makes the region wide. So a fitting region should carry a
//! `max_size` guard, again dvui's existing `max_size_content`. An app that does not want a
//! plugin dictating its proportions uses the stretch form instead.
//!
//! ## Two audiences, two levels
//!
//! **App authors** use only this: `region` and `split`, with keywords assigned per region. They
//! never touch dvui. That is the whole point of the level existing, and it is why the surface
//! is two verbs rather than a widget toolkit — a small enough vocabulary to hold in your head
//! and, prospectively, to check at comptime (a layout that declares a region twice, or splits
//! outside a container, is a compile error rather than a confusing frame).
//!
//! **Plugin authors** work a level down: raw dvui for their own content, plus fizzy's mid-level
//! constructs where one exists — `Viewport` for zoom/pan surfaces, `Tabs`, the dialog chrome in
//! `core.dvui.dialog`, scroll areas with edge shadows, context menus. Those are content blocks,
//! not layout, and they live in `core` precisely so a dylib can reach them.
//!
//! It also leaves room for the thing this is ultimately for: once regions are the only unit, a
//! region can be dragged to move or re-split it at runtime, which is how a Premiere- or
//! Blender-style app would work. Fizzy itself stays rigid — its shape is fixed by `ide.zig` —
//! but nothing in the model prevents an app from letting the user rearrange.
//!
//! ## Where this stands
//!
//! Built. A region **is** a `dvui.box` and a `split` is a `core.dvui.Sash` between two of them,
//! so the sizing is dvui's own and there is no second model to learn. Every shipped shape uses
//! it; the edge-docking form and its `rest()` branching are gone.
//!
//! ## Layered regions and blur
//!
//! A tray that blurs what is behind it (the bottom panel over the editor; a scroll edge over its
//! own overflowing content) is designed but not built — see `LAYERS.md` in this directory. The
//! short version, because it is the decision most likely to be re-derived wrongly: blur is a
//! **property of a region** (`.blur_behind`), never a layout verb that reverses render order. An
//! app author must not have to reason about paint order to place a panel, and reversing paint
//! order does not reverse dvui's event routing — declaration order and hit-test order would stop
//! agreeing.
const std = @import("std");
const core = @import("core");
const build_opts = @import("build_opts");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

pub const Frame = @import("Frame.zig");
pub const Region = Frame.Region;
pub const RegionOptions = Frame.RegionOptions;
pub const Tabs = core.dvui.Tabs;
pub const keywords = @import("fizzy_sdk").keywords;
pub const chrome = @import("chrome.zig");

// ── The shipped shapes, and the dispatcher ──────────────────────────────────────────────────
//
// Shapes are **meant to be copied**, on dvui's model for widgets: an app picks one as-is and
// writes no layout code at all, or copies the closest one into its own source and edits it.
// Each is ordinary code over the public API above, so copying is editing rather than forking.

pub const ide = @import("ide.zig");
pub const minimal = @import("minimal.zig");
pub const studio = @import("studio.zig");

/// Run the shape `-Dlayout=` selected. All of them load the same plugins; only the layout differs.
pub fn run(editor: *fizzy.Editor, f: *Frame) !dvui.App.Result {
    return switch (build_opts.layout) {
        .ide => ide.layout(editor, f),
        .minimal => minimal.layout(editor, f),
        .studio => studio.layout(editor, f),
    };
}

// ── Content-side reusable blocks ────────────────────────────────────────────────────────────
//
// The counterparts to the layout pieces above: layout decides where an area is, these fill it.
// Both already exist in `core` and are already shared across the plugin boundary, so they are
// re-exported here rather than rebuilt.

/// A zoom/pan viewport with inertial panning — the block behind any artboard-style view (the
/// image plugin's canvas today; an atlas view, a pixel-art artboard or a node graph equally).
/// Already consumes `Fling` internally for the coast-after-flick.
pub const Viewport = core.dvui.CanvasWidget;

/// Inertial coasting after a flick, one per axis. Used by `Viewport`; available directly for a
/// scroll area that wants the same feel.
pub const Fling = core.Fling;
