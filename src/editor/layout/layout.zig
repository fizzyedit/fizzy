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
//! it. Fizzy's bottom panel is this. A shape writes `widgets.tabs(f, kw)` then draws the
//! selected surface, or asks a region for `.chooser = .tabs`.
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
const std = @import("std");
const core = @import("core");

pub const Frame = @import("../shell/Frame.zig");
pub const Region = Frame.Region;
pub const RegionOptions = Frame.RegionOptions;
pub const Side = @import("../shell/split.zig").Side;
pub const Split = @import("../shell/split.zig").Split;
pub const split = @import("../shell/split.zig").split;
pub const Tabs = core.dvui.Tabs;
pub const boundaries = core.split_layout;
pub const keywords = @import("fizzy_sdk").keywords;
pub const widgets = @import("../shell/widgets.zig");
