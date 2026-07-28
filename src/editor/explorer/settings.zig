//! The shell's own settings, as data.
//!
//! These used to be drawn inline inside nested `dvui.groupBox`es. They're now a flat declarative
//! table: `SettingsTree` renders them as branches/leaves of the settings tree and matches the
//! user's search text against `label` + `keywords` without drawing anything, so a group with no
//! surviving leaves can be skipped entirely.
//!
//! Each `Item.draw` owns only the control body — `SettingsTree` draws `label` above it (and
//! highlights matches while searching). Adding a setting here means adding one entry and one
//! small function; the tree, the search, and the highlighting come for free.
//!
//! Plugin settings do **not** live here — those come from `host.settings_schemas` and are drawn
//! by `PluginSettingsPane` (see `SettingsTree`), so a plugin's controls look identical to these.
const builtin = @import("builtin");
const std = @import("std");

const fizzy = @import("../../fizzy.zig");
const icons = @import("icons");
const dvui = @import("dvui");
const core = @import("core");
const Editor = fizzy.Editor;
const KeybindSettings = @import("../KeybindSettings.zig");

const fuzzy = core.fuzzy;

/// An item that is a searchable list in its own right rather than one labelled control.
///
/// The keybind table is the only one: it holds hundreds of rows, so matching it as a single leaf
/// labelled "Bindings" would be useless. `score` is run during `SettingsTree`'s data pass (it
/// returns the best score among the rows the item *would* draw, or null to drop the row from the
/// tree entirely) and `draw` then renders only what matched, highlighting it itself.
pub const Search = struct {
    score: *const fn (query: *const fuzzy.Query) ?f64,
    draw: *const fn (query: *const fuzzy.Query) void,
};

/// One row in the settings tree: a named, described control the user can search for.
///
/// `label`/`key`/`description` are the same three things a plugin's settings cell carries
/// (`sdk.settings.Setting`), and `SettingRow` draws them identically — a shell setting and a
/// plugin setting must be indistinguishable in the pane.
pub const Item = struct {
    /// One of the two names the search matches on. Not drawn for a `search` item — those label
    /// their own rows.
    label: []const u8,
    /// The field's name in `settings.zon`, drawn under `label` and matched by the search. Kept in
    /// sync with `Editor.Settings` by hand; `search` items that aren't a single field name it
    /// after the section they configure.
    key: []const u8,
    /// What the setting does. Required, exactly as it is for plugin settings.
    description: []const u8,
    /// Extra search terms that never appear on screen — synonyms and the words a user is likely
    /// to type instead of the label ("dark" for Theme, "trackpad" for the control scheme).
    keywords: []const u8 = "",
    /// The control body. Exactly one of this and `search` is set.
    draw: ?*const fn () void = null,
    search: ?Search = null,
    /// Set for a control small enough to share the description's line rather than take a full
    /// width of its own — checkboxes, and nothing else so far.
    inline_control: bool = false,
};

/// A category branch under "Fizzy".
pub const Group = struct {
    title: []const u8,
    /// TVG bytes for the branch's glyph — what the category *is*, not a generic folder. Drawn by
    /// `SettingsTree.drawIdentityIcon`.
    icon: []const u8,
    items: []const Item,
};

pub const groups = [_]Group{
    .{
        .title = "Appearance",
        .icon = icons.tvg.lucide.palette,
        .items = &.{
            .{
                .label = "Theme",
                .key = "theme",
                .description = "Colour theme used across the whole interface.",
                .keywords = "color colour dark light scheme",
                .draw = drawTheme,
            },
            .{
                .label = "Body font size",
                .key = "font_body_size",
                .description = "Size of ordinary interface text — labels, tree rows, menus.",
                .keywords = "text size",
                .draw = drawBodyFontSize,
            },
            .{
                .label = "Heading font size",
                .key = "font_heading_size",
                .description = "Size of section headings, such as the roots of this settings tree.",
                .keywords = "text size",
                .draw = drawHeadingFontSize,
            },
            .{
                .label = "Title font size",
                .key = "font_title_size",
                .description = "Size of window and dialog titles.",
                .keywords = "text size",
                .draw = drawTitleFontSize,
            },
            .{
                .label = "Monospace font size",
                .key = "font_mono_size",
                .description = "Size of fixed-width text: code, file paths, and setting keys.",
                .keywords = "text size code mono",
                .draw = drawMonoFontSize,
            },
            .{
                .label = "Window opacity",
                .key = "window_opacity_dark",
                .description = "How opaque the window background is behind the interface. " ++
                    "Dark and light themes are remembered separately.",
                .keywords = "transparency alpha blur",
                .draw = drawWindowOpacity,
            },
            .{
                .label = "Content opacity",
                .key = "content_opacity",
                .description = "How opaque panels drawn over the window background are.",
                .keywords = "transparency alpha",
                .draw = drawContentOpacity,
            },
        },
    },
    .{
        .title = "Input",
        .icon = icons.tvg.lucide.mouse,
        .items = &.{
            .{
                .label = "Context menu hold",
                .key = "hold_menu_duration_ms",
                .description = "How long a press has to be held before it opens a context menu, " ++
                    "in milliseconds.",
                .keywords = "right click long press duration delay",
                .draw = drawHoldMenuDuration,
            },
            .{
                .label = "Canvas control scheme",
                .key = "input_scheme",
                .description = "Which zoom and pan gestures canvases expect. Auto follows the " ++
                    "pointing device currently in use.",
                .keywords = "mouse trackpad pan zoom scroll",
                .draw = drawInputScheme,
            },
        },
    },
    .{
        .title = "Keyboard Shortcuts",
        .icon = icons.tvg.lucide.keyboard,
        .items = &.{
            .{
                .label = "Bindings",
                .key = "keybinds",
                .description = "Every command and the keys that run it. Click a binding to " ++
                    "record a new one.",
                .keywords = "keybind shortcut hotkey chord keyboard remap keys",
                // Every command is individually searchable — see `KeybindSettings`.
                .search = .{ .score = KeybindSettings.score, .draw = KeybindSettings.draw },
            },
        },
    },
    .{
        .title = "Debugging",
        .icon = icons.tvg.lucide.bug,
        .items = &.{
            .{
                .label = "Frame rate",
                .key = "fps",
                .description = "Frames per second this window is currently drawing. Read-only.",
                .keywords = "fps performance diagnostics",
                .draw = drawFps,
            },
        },
    },
};

// ---- Appearance -------------------------------------------------------------------------

fn drawTheme() void {
    var dropdown: dvui.DropdownWidget = undefined;
    dropdown.init(@src(), .{}, .{
        .expand = .horizontal,
        .corners = dvui.CornerRect.all(1000),
    });
    defer dropdown.deinit();

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .vertical,
        .gravity_x = 1.0,
    });

    dvui.label(@src(), "{s}", .{dvui.themeGet().name}, .{ .margin = .all(0), .padding = .all(0) });
    dvui.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });

    hbox.deinit();

    if (dropdown.dropped()) {
        for (fizzy.editor.themes.items) |theme| {
            if (dropdown.addChoiceLabel(theme.name)) {
                Editor.Settings.setThemeName(&fizzy.editor.settings, fizzy.app.allocator, theme.name) catch {
                    dvui.log.err("Failed to store theme name", .{});
                    break;
                };
                fizzy.editor.applySettingsTheme() catch {
                    dvui.log.err("Failed to apply theme", .{});
                };
                fizzy.editor.markSettingsDirty();
                dvui.refresh(null, @src(), null);
                break;
            }
        }
    }
}

/// The four font sliders differ only in which settings field they drive, so they share one body.
/// Format is value-only — `SettingsTree` draws the setting name above the control.
fn fontSizeSlider(src: std.builtin.SourceLocation, value: *f32) void {
    if (dvui.sliderEntry(src, "{d:0.0}", .{
        .value = value,
        .interval = 1.0,
        .max = 20.0,
        .min = 6.0,
    }, .{ .expand = .horizontal })) {
        fizzy.editor.applyFontSizesFromSettings();
        fizzy.editor.markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawBodyFontSize() void {
    fontSizeSlider(@src(), &fizzy.editor.settings.font_body_size);
}

fn drawHeadingFontSize() void {
    fontSizeSlider(@src(), &fizzy.editor.settings.font_heading_size);
}

fn drawTitleFontSize() void {
    fontSizeSlider(@src(), &fizzy.editor.settings.font_title_size);
}

fn drawMonoFontSize() void {
    fontSizeSlider(@src(), &fizzy.editor.settings.font_mono_size);
}

fn drawWindowOpacity() void {
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &if (dvui.themeGet().dark) fizzy.editor.settings.window_opacity_dark else fizzy.editor.settings.window_opacity_light,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.backend.setTitlebarColor(dvui.currentWindow(), dvui.themeGet().color(.content, .fill).opacity(if (dvui.themeGet().dark) fizzy.editor.settings.window_opacity_dark else fizzy.editor.settings.window_opacity_light));
        fizzy.editor.markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawContentOpacity() void {
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &fizzy.editor.settings.content_opacity,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.backend.setTitlebarColor(dvui.currentWindow(), dvui.themeGet().color(.content, .fill).opacity(fizzy.editor.settings.content_opacity));
        fizzy.editor.markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

// ---- Input ------------------------------------------------------------------------------

fn drawHoldMenuDuration() void {
    var hold_menu_ms: f32 = @floatFromInt(fizzy.editor.settings.hold_menu_duration_ms);
    if (dvui.sliderEntry(@src(), "{d:0.0} ms", .{
        .value = &hold_menu_ms,
        .interval = 50,
        .max = 1500,
        .min = 100,
    }, .{ .expand = .horizontal })) {
        fizzy.editor.settings.hold_menu_duration_ms = @intFromFloat(hold_menu_ms);
        fizzy.editor.applyHoldMenuDuration();
        fizzy.editor.markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawInputScheme() void {
    var dropdown: dvui.DropdownWidget = undefined;
    dropdown.init(@src(), .{}, .{
        .expand = .horizontal,
        .corners = dvui.CornerRect.all(1000),
    });
    defer dropdown.deinit();

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .vertical,
        .gravity_x = 1.0,
    });

    const label_text: []const u8 = switch (fizzy.editor.settings.input_scheme) {
        .auto => switch (dvui.mouseType()) {
            .unknown => "Auto",
            .mouse, .trackpad => |hint| std.fmt.allocPrint(dvui.currentWindow().arena(), "Auto ({s})", .{@tagName(hint)}) catch "Auto",
        },
        .mouse => "Mouse",
        .trackpad => "Trackpad",
    };
    dvui.label(@src(), "{s}", .{label_text}, .{ .margin = .all(0), .padding = .all(0) });
    dvui.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });

    hbox.deinit();

    if (dropdown.dropped()) {
        inline for (.{
            .{ "Auto", Editor.Settings.InputScheme.auto },
            .{ "Mouse", Editor.Settings.InputScheme.mouse },
            .{ "Trackpad", Editor.Settings.InputScheme.trackpad },
        }) |choice| {
            if (dropdown.addChoiceLabel(choice[0])) {
                fizzy.editor.settings.input_scheme = choice[1];
                fizzy.editor.markSettingsDirty();
                dvui.refresh(null, @src(), null);
            }
        }
    }
}

// ---- Debugging --------------------------------------------------------------------------

fn drawFps() void {
    // `perf_logging` / `debug_simulate_update_available` live in Constants.zig (build-time flags,
    // not user settings), so this category is read-only diagnostics for now.
    dvui.label(@src(), "{d:0>3.0} fps", .{dvui.FPS()}, .{});
}
