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
const dvui = @import("dvui");
const Editor = fizzy.Editor;
const KeybindSettings = @import("../KeybindSettings.zig");

/// One row in the settings tree: a labelled control the user can search for.
pub const Item = struct {
    label: []const u8,
    /// Extra search terms that never appear on screen — synonyms and the words a user is likely
    /// to type instead of the label ("dark" for Theme, "trackpad" for the control scheme).
    keywords: []const u8 = "",
    draw: *const fn () void,
};

/// A category branch under "Fizzy".
pub const Group = struct {
    title: []const u8,
    items: []const Item,
};

pub const groups = [_]Group{
    .{
        .title = "Appearance",
        .items = &.{
            .{ .label = "Theme", .keywords = "color colour dark light scheme", .draw = drawTheme },
            .{ .label = "Body Font Size", .keywords = "text size", .draw = drawBodyFontSize },
            .{ .label = "Heading Font Size", .keywords = "text size", .draw = drawHeadingFontSize },
            .{ .label = "Title Font Size", .keywords = "text size", .draw = drawTitleFontSize },
            .{ .label = "Monospace Font Size", .keywords = "text size code mono", .draw = drawMonoFontSize },
            .{ .label = "Window Opacity", .keywords = "transparency alpha blur", .draw = drawWindowOpacity },
            .{ .label = "Content Opacity", .keywords = "transparency alpha", .draw = drawContentOpacity },
        },
    },
    .{
        .title = "Input",
        .items = &.{
            .{ .label = "Context Menu Hold", .keywords = "right click long press duration delay", .draw = drawHoldMenuDuration },
            .{ .label = "Canvas Control Scheme", .keywords = "mouse trackpad pan zoom scroll", .draw = drawInputScheme },
        },
    },
    .{
        .title = "Keyboard Shortcuts",
        .items = &.{
            .{
                .label = "Bindings",
                .keywords = "keybind shortcut hotkey chord keyboard remap keys",
                .draw = drawKeybinds,
            },
        },
    },
    .{
        .title = "Debugging",
        .items = &.{
            .{ .label = "Frame Rate", .keywords = "fps performance diagnostics", .draw = drawFps },
        },
    },
};

fn drawKeybinds() void {
    KeybindSettings.draw();
}

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
