//! The fizzy's own settings, as data.
//!
//! A flat declarative table: `SettingsTree` renders them as branches/leaves of the settings tree and matches the
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
const restart = @import("app").restart;
const Editor = fizzy.Editor;
const KeybindSettings = @import("../KeybindSettings.zig");
const FileTypeSettings = @import("../FileTypeSettings.zig");
const LayoutSettings = @import("../LayoutSettings.zig");

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
/// (`sdk.settings.Setting`), and `SettingRow` draws them identically — a fizzy setting and a
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
            .{
                .label = "Modal dim",
                .key = "modal_dim",
                .description = "How much a dialog or the command palette darkens everything " ++
                    "behind it while it is open.",
                .keywords = "dialog palette scrim dark shade overlay",
                .draw = drawModalDim,
            },
            .{
                .label = "Dialog opacity",
                .key = "dialog_opacity",
                .description = "How much of a dialog or the command palette is its own colour " ++
                    "rather than the frosted view behind it. At 1 it matches a plain panel " ++
                    "like the explorer; lower shows more of the blur.",
                .keywords = "dialog palette transparency alpha glass frost",
                .draw = drawDialogOpacity,
            },
            .{
                .label = "Dialog blur",
                .key = "dialog_blur",
                .description = "How strongly the frosted backdrop under dialogs and the command " ++
                    "palette blurs what is behind it. 0 turns the frost off.",
                .keywords = "dialog palette blur frost glass radius",
                .draw = drawDialogBlur,
            },
            .{
                .label = "Dialog blur detail",
                .key = "dialog_detail",
                .description = "How much of what is behind a dialog or the command palette " ++
                    "stays readable through its blur. 0 is a plain frost; higher keeps shapes " ++
                    "and edges visible under the same softness.",
                .keywords = "dialog palette blur frost glass detail definition clarity",
                .draw = drawDialogDetail,
            },
            .{
                .label = "Dialog brightness",
                .key = "dialog_lift",
                .description = "How much lighter a dialog or the command palette is than what " ++
                    "is behind it — the lift a glass material has. 0 is none.",
                .keywords = "dialog palette light bright glass frost lift",
                .draw = drawDialogLift,
            },
            .{
                .label = "Dialog refraction",
                .key = "dialog_refraction",
                .description = "How far the bevelled edge of frosted glass — dialogs, menus, " ++
                    "the command palette, drop zones — bends what is behind it. 0 is a flat " ++
                    "edge; the middle is as designed.",
                .keywords = "dialog palette glass frost refraction bevel edge lens liquid",
                .draw = drawDialogRefraction,
            },
            .{
                .label = "Corner roundness",
                .key = "corner_roundness",
                .description = "How round the corners of windows, panels, dialogs and buttons " ++
                    "are, from square to twice as round. The middle is as designed.",
                .keywords = "corner radius rounding round square shape theme",
                .draw = drawCornerRoundness,
            },
            .{
                .label = "Motion",
                .key = "motion",
                .description = "How the interface moves. 0 is off — nothing animates. Up to " ++
                    "Minimal, motion is plain and even; toward Playful things carry on past " ++
                    "where they are going and settle back. Every level arrives on time — " ++
                    "Motion speed sets how fast. A system request for reduced motion turns it off.",
                .keywords = "animation motion reduce reduced accessibility bounce spring playful minimal glass bevel easing",
                .draw = drawMotion,
            },
            .{
                .label = "Motion speed",
                .key = "motion_speed",
                .description = "How fast the interface moves, from half as fast to twice as fast. " ++
                    "The middle is as designed. It never stops motion; Motion at 0 does that.",
                .keywords = "animation motion speed fast slow duration",
                .draw = drawMotionSpeed,
            },
        },
    },
    .{
        .title = "Windows",
        .icon = icons.tvg.lucide.@"app-window",
        .items = &.{
            .{
                .label = "Floats in their own windows",
                .key = "float_windows",
                .description = "A view floated out of its place can leave the main window into a " ++
                    "window of its own, and a view carried past the main window opens one there. " ++
                    "Takes effect after a restart.",
                .keywords = "float popout pop out window detach tear off native restart",
                .draw = drawFloatWindows,
                .inline_control = true,
            },
            .{
                .label = "Native glass",
                .key = "native_glass",
                .description = "A dragged view and the drop zones are the system's own glass " ++
                    "(Liquid Glass on macOS 26) rather than fizzy's, where floats have windows " ++
                    "of their own.",
                .keywords = "glass liquid native drag drop zones blur material",
                .draw = drawNativeGlass,
                .inline_control = true,
            },
            .{
                .label = "Native menus",
                .key = "native_menus",
                .description = "Menus open in windows of their own — the system's material, " ++
                    "shadow and corners, over every window and past the window's edge — rather " ++
                    "than drawn inside the window, where floats have windows of their own.",
                .keywords = "menu context native window popup material",
                .draw = drawNativeMenus,
                .inline_control = true,
            },
            .{
                .label = "Native dialogs",
                .key = "native_dialogs",
                .description = "Dialogs open in windows of their own — the system's material, " ++
                    "shadow and corners, moving with the main window — rather than drawn inside " ++
                    "it, where floats have windows of their own.",
                .keywords = "dialog modal alert native window material",
                .draw = drawNativeDialogs,
                .inline_control = true,
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
        .title = "Plugins",
        .icon = icons.tvg.lucide.package,
        .items = &.{
            .{
                .label = "Plugin updates",
                .key = "plugin_update_mode",
                .description = "What happens when the store has newer builds of your plugins. " ++
                    "Prompt collects them into a window shortly after launch; Silent installs " ++
                    "them for you. Either way, a plugin can opt out on its own card in the " ++
                    "Plugins tab.",
                .keywords = "plugin store update upgrade automatic silent prompt background",
                .draw = drawPluginUpdateMode,
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
        .title = "File Types",
        .icon = icons.tvg.lucide.file,
        .items = &.{
            .{
                .label = "Defaults",
                .key = "file_types",
                .description = "The below extensions can be handled by multiple plugins, the " ++
                    "active plugin determines how the file will be opened and displayed. " ++
                    "Unlisted extensions will be opened with the built-in text plugin.",
                .keywords = "file type extension default open association plugin",
                // Every extension is individually searchable — see `FileTypeSettings`.
                .search = .{ .score = FileTypeSettings.score, .draw = FileTypeSettings.draw },
            },
        },
    },
    .{
        .title = "Layout",
        .icon = icons.tvg.lucide.@"panel-left",
        .items = &.{
            .{
                .label = "Regions",
                .key = "regions",
                .description = "What each region of the window shows. A plugin declares the kind " ++
                    "of place its panels belong and this layout's regions declare what they " ++
                    "accept; where the two agree is where a panel lands by default. Choose a " ++
                    "region's contents yourself and that choice is remembered — the same panel " ++
                    "in two places, or a region left empty, are both allowed.",
                .keywords = "region placement move panel sidebar surface unplaced keywords",
                // Every panel is individually searchable — see `LayoutSettings`.
                .search = .{ .score = LayoutSettings.score, .draw = LayoutSettings.draw },
            },
        },
    },
    .{
        .title = "Debugging",
        .icon = icons.tvg.lucide.bug,
        .items = &.{
            .{
                .label = "Layout rate",
                .key = "fps",
                .description = "Frames per second this window is currently drawing. Read-only.",
                .keywords = "fps performance diagnostics",
                .draw = drawFps,
            },
            .{
                .label = "Glass shader",
                .key = "glass_shader",
                .description = "Glass: Shader instead of mesh",
                .keywords = "glass shader sdf liquid frost blur performance",
                .draw = drawGlassShader,
                .inline_control = true,
            },
        },
    },
};

// ---- Appearance -------------------------------------------------------------------------

fn drawTheme() void {
    var dropdown: core.widgets.DropdownWidget = undefined;
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
    core.icon.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });

    hbox.deinit();

    if (dropdown.dropped()) {
        for (fizzy.editor().themes.items) |theme| {
            if (dropdown.addChoiceLabel(theme.name)) {
                Editor.Settings.setThemeName(&fizzy.editor().app.settings, fizzy.entry().allocator, theme.name) catch {
                    dvui.log.err("Failed to store theme name", .{});
                    break;
                };
                fizzy.editor().applySettingsTheme() catch {
                    dvui.log.err("Failed to apply theme", .{});
                };
                fizzy.editor().markSettingsDirty();
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
        fizzy.editor().applyFontSizesFromSettings();
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawBodyFontSize() void {
    fontSizeSlider(@src(), &fizzy.editor().app.settings.font_body_size);
}

fn drawHeadingFontSize() void {
    fontSizeSlider(@src(), &fizzy.editor().app.settings.font_heading_size);
}

fn drawTitleFontSize() void {
    fontSizeSlider(@src(), &fizzy.editor().app.settings.font_title_size);
}

fn drawMonoFontSize() void {
    fontSizeSlider(@src(), &fizzy.editor().app.settings.font_mono_size);
}

fn drawWindowOpacity() void {
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &if (dvui.themeGet().dark) fizzy.editor().app.settings.window_opacity_dark else fizzy.editor().app.settings.window_opacity_light,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.backend.setTitlebarColor(dvui.currentWindow(), dvui.themeGet().color(.content, .fill).opacity(if (dvui.themeGet().dark) fizzy.editor().app.settings.window_opacity_dark else fizzy.editor().app.settings.window_opacity_light));
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawContentOpacity() void {
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &fizzy.editor().app.settings.content_opacity,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.backend.setTitlebarColor(dvui.currentWindow(), dvui.themeGet().color(.content, .fill).opacity(fizzy.editor().app.settings.content_opacity));
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawModalDim() void {
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &fizzy.editor().app.settings.modal_dim,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawDialogOpacity() void {
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &fizzy.editor().app.settings.dialog_opacity,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawDialogBlur() void {
    if (dvui.sliderEntry(@src(), "{d:0.0}", .{
        .value = &fizzy.editor().app.settings.dialog_blur,
        .interval = 1,
        .max = 48,
        .min = 0,
    }, .{ .expand = .horizontal })) {
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawDialogDetail() void {
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &fizzy.editor().app.settings.dialog_detail,
        .interval = 0.01,
        .max = 0.9,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawDialogLift() void {
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &fizzy.editor().app.settings.dialog_lift,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawCornerRoundness() void {
    const editor = fizzy.editor();
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &editor.app.settings.corner_roundness,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        // The theme carries dvui's own corner; re-apply it at the new roundness.
        editor.applySettingsTheme() catch {};
        editor.markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
    var row = dvui.overlay(@src(), .{ .expand = .horizontal });
    defer row.deinit();
    const text = dvui.themeGet().color(.control, .text).opacity(0.6);
    for ([_][]const u8{ "Square", "As designed", "Round" }, [_]f32{ 0, 0.5, 1 }, 0..) |name, at, i| {
        dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = i, .gravity_x = at, .font = dvui.Font.theme(.body).larger(-1), .color_text = .{ .color = text }, .padding = .{} });
    }
}

fn drawDialogRefraction() void {
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &fizzy.editor().app.settings.dialog_refraction,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawMotion() void {
    const settings = &fizzy.editor().app.settings;
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &settings.motion,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
    // The three names along the slider's length, the one it is nearest lit.
    var row = dvui.overlay(@src(), .{ .expand = .horizontal });
    defer row.deinit();
    const names = [_][]const u8{ "Off", "Minimal", "Playful" };
    const at = [_]f32{ 0, 0.5, 1 };
    const system_off = dvui.currentWindow().backend.prefersReducedMotion();
    const v: f32 = if (system_off) 0 else settings.motion;
    var nearest: usize = 0;
    for (at, 0..) |a, i| {
        if (@abs(v - a) < @abs(v - at[nearest])) nearest = i;
    }
    const text = dvui.themeGet().color(.control, .text);
    for (names, at, 0..) |name, a, i| {
        dvui.labelNoFmt(@src(), name, .{}, .{
            .id_extra = i,
            .gravity_x = a,
            .font = dvui.Font.theme(.body).larger(-1),
            .color_text = .{ .color = if (i == nearest) text else text.opacity(0.45) },
            .padding = .{},
        });
    }
    if (system_off) {
        dvui.labelNoFmt(@src(), "Off: the system asks for reduced motion.", .{}, .{
            .font = dvui.Font.theme(.body).larger(-1),
            .color_text = .{ .color = text.opacity(0.6) },
        });
    }
}

fn drawMotionSpeed() void {
    const settings = &fizzy.editor().app.settings;
    if (dvui.sliderEntry(@src(), "{d:0.01}", .{
        .value = &settings.motion_speed,
        .interval = 0.01,
        .max = 1.0,
        .min = 0.0,
    }, .{ .expand = .horizontal })) {
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
    var row = dvui.overlay(@src(), .{ .expand = .horizontal });
    defer row.deinit();
    const text = dvui.themeGet().color(.control, .text).opacity(0.6);
    const rate = fizzy.core.motion.rateFor(settings.motion_speed);
    for ([_][]const u8{ "Slow", "Fast" }, [_]f32{ 0, 1 }, 0..) |name, at, i| {
        dvui.labelNoFmt(@src(), name, .{}, .{ .id_extra = i, .gravity_x = at, .font = dvui.Font.theme(.body).larger(-1), .color_text = .{ .color = text }, .padding = .{} });
    }
    dvui.label(@src(), "{d:.2}×", .{rate}, .{ .gravity_x = 0.5, .font = dvui.Font.theme(.body).larger(-1), .color_text = .{ .color = text }, .padding = .{} });
}

// ---- Input ------------------------------------------------------------------------------

fn drawHoldMenuDuration() void {
    var hold_menu_ms: f32 = @floatFromInt(fizzy.editor().app.settings.hold_menu_duration_ms);
    if (dvui.sliderEntry(@src(), "{d:0.0} ms", .{
        .value = &hold_menu_ms,
        .interval = 50,
        .max = 1500,
        .min = 100,
    }, .{ .expand = .horizontal })) {
        fizzy.editor().app.settings.hold_menu_duration_ms = @intFromFloat(hold_menu_ms);
        fizzy.editor().applyHoldMenuDuration();
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawInputScheme() void {
    var dropdown: core.widgets.DropdownWidget = undefined;
    dropdown.init(@src(), .{}, .{
        .expand = .horizontal,
        .corners = dvui.CornerRect.all(1000),
    });
    defer dropdown.deinit();

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .vertical,
        .gravity_x = 1.0,
    });

    const label_text: []const u8 = switch (fizzy.editor().app.settings.input_scheme) {
        .auto => switch (dvui.mouseType()) {
            .unknown => "Auto",
            .mouse, .trackpad => |hint| std.fmt.allocPrint(dvui.currentWindow().arena(), "Auto ({s})", .{@tagName(hint)}) catch "Auto",
        },
        .mouse => "Mouse",
        .trackpad => "Trackpad",
    };
    dvui.label(@src(), "{s}", .{label_text}, .{ .margin = .all(0), .padding = .all(0) });
    core.icon.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });

    hbox.deinit();

    if (dropdown.dropped()) {
        inline for (.{
            .{ "Auto", Editor.Settings.InputScheme.auto },
            .{ "Mouse", Editor.Settings.InputScheme.mouse },
            .{ "Trackpad", Editor.Settings.InputScheme.trackpad },
        }) |choice| {
            if (dropdown.addChoiceLabel(choice[0])) {
                fizzy.editor().app.settings.input_scheme = choice[1];
                fizzy.editor().markSettingsDirty();
                dvui.refresh(null, @src(), null);
            }
        }
    }
}

// ---- Plugins ----------------------------------------------------------------------------

/// The one app-wide choice of how store updates land. Per-plugin participation is a checkbox on
/// the plugin's own card in the Plugins tab (`PluginStore`), not a row here — there is one of
/// those per installed plugin, and the tree is fizzy's own settings.
fn drawPluginUpdateMode() void {
    var dropdown: core.widgets.DropdownWidget = undefined;
    dropdown.init(@src(), .{}, .{
        .expand = .horizontal,
        .corners = dvui.CornerRect.all(1000),
    });
    defer dropdown.deinit();

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .vertical,
        .gravity_x = 1.0,
    });

    const label_text: []const u8 = switch (fizzy.editor().app.settings.plugin_update_mode) {
        .prompt => "Prompt",
        .silent => "Silent",
    };
    dvui.label(@src(), "{s}", .{label_text}, .{ .margin = .all(0), .padding = .all(0) });
    core.icon.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });

    hbox.deinit();

    if (dropdown.dropped()) {
        inline for (.{
            .{ "Prompt", Editor.Settings.PluginUpdateMode.prompt },
            .{ "Silent", Editor.Settings.PluginUpdateMode.silent },
        }) |choice| {
            if (dropdown.addChoiceLabel(choice[0])) {
                fizzy.editor().app.settings.plugin_update_mode = choice[1];
                fizzy.editor().markSettingsDirty();
                dvui.refresh(null, @src(), null);
            }
        }
    }
}

// ---- Windows ----------------------------------------------------------------------------

fn drawFloatWindows() void {
    const editor = fizzy.editor();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_y = 0.5 });
    defer row.deinit();
    drawToggle(&editor.app.settings.float_windows);
    // Taken at launch: changed, it waits for a restart, offered here and in the info bar.
    if (editor.restartPending()) {
        if (dvui.button(@src(), "Restart", .{}, .{ .gravity_y = 0.5, .margin = .{ .x = 6 }, .padding = .{ .x = 8, .w = 8, .y = 2, .h = 2 } })) {
            restart.request();
        }
    }
}

fn drawNativeGlass() void {
    drawToggle(&fizzy.editor().app.settings.native_glass);
}

fn drawNativeMenus() void {
    drawToggle(&fizzy.editor().app.settings.native_menus);
}

fn drawNativeDialogs() void {
    drawToggle(&fizzy.editor().app.settings.native_dialogs);
}

/// A setting's checkbox, saved and applied as it changes.
fn drawToggle(value: *bool) void {
    if (dvui.checkbox(@src(), value, null, .{
        .expand = .none,
        .gravity_y = 0.5,
        .margin = .{ .x = 4, .w = 4 },
        .padding = .{ .x = 2, .w = 4, .y = 2, .h = 2 },
    })) {
        fizzy.editor().markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

// ---- Debugging --------------------------------------------------------------------------

fn drawGlassShader() void {
    const editor = fizzy.editor();
    if (dvui.checkbox(@src(), &editor.app.settings.glass_shader, null, .{
        .expand = .none,
        .gravity_y = 0.5,
        .margin = .{ .x = 4, .w = 4 },
        .padding = .{ .x = 2, .w = 4, .y = 2, .h = 2 },
    })) {
        editor.markSettingsDirty();
        dvui.refresh(null, @src(), null);
    }
}

fn drawFps() void {
    // `perf_logging` / `debug_simulate_update_available` live in Constants.zig (build-time flags,
    // not user settings), so this category is read-only diagnostics for now.
    dvui.label(@src(), "{d:0>3.0} fps", .{dvui.FPS()}, .{});
}
