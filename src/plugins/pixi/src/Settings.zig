//! Pixel-art plugin settings: the canvas / sprite-editing preferences formerly stored
//! as top-level fields on the shell `Settings`. Persisted via the shell's per-plugin
//! settings store (the `Host`), keyed by the plugin id, as an opaque JSON blob the shell
//! never interprets.
const std = @import("std");
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");
const sdk = pixi_mod.sdk;

const PixelArtSettings = @This();

/// Per-plugin settings store key (matches `plugin.id`).
pub const plugin_id = "pixi";

pub const InputScheme = enum { auto, mouse, trackpad };

/// Resolved zoom/pan control style after applying `auto` (`dvui.mouseType`).
pub const ResolvedPanZoomScheme = enum { mouse, trackpad };

/// How sprite-cell transparency (checkerboard) is tinted behind the canvas.
pub const TransparencyEffect = enum {
    /// Uniform default tone only (no hue gradient).
    none,
    /// Mouse-smoothed corner gradient.
    rainbow,
    /// Per-cell tone shifted toward the animation's palette color.
    animation,
};

/// Zoom/pan control scheme (`auto` picks mouse vs trackpad from `dvui.mouseType()` after scroll events).
input_scheme: InputScheme = .auto,

/// Whether or not to show rulers on each canvas.
show_rulers: bool = true,

/// Sprites panel: when true, show side cards in the cover-flow strip; when false,
/// fly them away for single-card focus (snap scroll).
scrolling_cards: bool = true,

/// Padding to include in the size of the ruler outside of the font height.
ruler_padding: f32 = 4.0,

/// Overall zoom sensitivity (0 - 1).
zoom_sensitivity: f32 = 1.0,

/// Predetermined zoom steps, each pixel perfect.
zoom_steps: [23]f32 = [_]f32{ 0.125, 0.167, 0.2, 0.25, 0.333, 0.5, 1, 2, 3, 4, 5, 6, 8, 12, 18, 28, 38, 50, 70, 90, 128, 256, 512 },

/// Maximum file size.
max_file_size: [2]i32 = .{ 4096, 4096 },

/// Color for the even squares of the checkerboard pattern.
checker_color_even: [4]u8 = .{ 255, 255, 255, 255 },
/// Color for the odd squares of the checkerboard pattern.
checker_color_odd: [4]u8 = .{ 175, 175, 175, 255 },

/// Checkerboard / transparency tint behind sprites (grid cells).
transparency_effect: TransparencyEffect = .none,

pub fn resolvedPanZoomScheme(settings: *const PixelArtSettings, host: *sdk.Host) ResolvedPanZoomScheme {
    return switch (settings.input_scheme) {
        .auto => switch (dvui.mouseType()) {
            // Runtime platform detection so macOS web users get the trackpad default.
            .unknown => if (host.isMacOS()) .trackpad else .mouse,
            .mouse => .mouse,
            .trackpad => .trackpad,
        },
        .mouse => .mouse,
        .trackpad => .trackpad,
    };
}

/// Load from the host's per-plugin store, or defaults if absent/unparsable. Unknown keys
/// are ignored, so the one-time legacy-migration blob (which still carries shell fields)
/// parses fine — only the pixel-art fields are picked up.
pub fn load(host: *sdk.Host) PixelArtSettings {
    const blob = host.loadPluginSettings(plugin_id) orelse return .{};
    const parsed = std.json.parseFromSlice(PixelArtSettings, host.allocator, blob, .{
        .ignore_unknown_fields = true,
    }) catch return .{};
    defer parsed.deinit();
    // PixelArtSettings has no heap-owned fields (all values/arrays/enums), so the parsed
    // value is safe to return after freeing the parse arena.
    return parsed.value;
}

/// Serialize and persist to the host store (marks shell settings dirty for autosave).
pub fn save(settings: *const PixelArtSettings, host: *sdk.Host) void {
    const json = std.json.Stringify.valueAlloc(host.allocator, settings, .{}) catch return;
    defer host.allocator.free(json);
    host.storePluginSettings(plugin_id, json) catch {};
}

/// The plugin's Settings section body (registered as a `SettingsSection`). Renders the
/// canvas / control prefs and persists on change.
pub fn draw(_: ?*anyopaque) !void {
    const pa = runtime.state();

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer vbox.deinit();

    {
        var box = dvui.groupBox(@src(), "Canvas", .{ .expand = .horizontal });
        defer box.deinit();

        {
            var dropdown: dvui.DropdownWidget = undefined;
            dropdown.init(@src(), .{ .label = "Transparency effect" }, .{
                .expand = .horizontal,
                .corner_radius = dvui.Rect.all(1000),
            });
            defer dropdown.deinit();

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .vertical,
                .gravity_x = 1.0,
            });

            const label_text = switch (pa.settings.transparency_effect) {
                .none => "None",
                .rainbow => "Rainbow",
                .animation => "Animation",
            };
            dvui.label(@src(), "{s}", .{label_text}, .{ .margin = .all(0), .padding = .all(0) });

            dvui.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });

            hbox.deinit();

            if (dropdown.dropped()) {
                if (dropdown.addChoiceLabel("None")) {
                    pa.settings.transparency_effect = .none;
                    pa.settings.save(pa.host);
                    dvui.refresh(null, @src(), vbox.data().id);
                }
                if (dropdown.addChoiceLabel("Rainbow")) {
                    pa.settings.transparency_effect = .rainbow;
                    pa.settings.save(pa.host);
                    dvui.refresh(null, @src(), vbox.data().id);
                }
                if (dropdown.addChoiceLabel("Animation")) {
                    pa.settings.transparency_effect = .animation;
                    pa.settings.save(pa.host);
                    dvui.refresh(null, @src(), vbox.data().id);
                }
            }

            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 10 } });
        }

        if (dvui.checkbox(@src(), &pa.settings.show_rulers, "Show Rulers", .{ .expand = .none })) {
            pa.settings.save(pa.host);
        }

        if (dvui.checkbox(@src(), &pa.settings.scrolling_cards, "Show sprite cover-flow cards", .{ .expand = .none })) {
            pa.settings.save(pa.host);
        }
    }

    {
        var box = dvui.groupBox(@src(), "Controls", .{ .expand = .horizontal });
        defer box.deinit();

        var dropdown: dvui.DropdownWidget = undefined;
        dropdown.init(@src(), .{ .label = "Control scheme" }, .{
            .expand = .horizontal,
            .corner_radius = dvui.Rect.all(1000),
        });
        defer dropdown.deinit();

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .vertical,
            .gravity_x = 1.0,
        });

        const label_text: []const u8 = switch (pa.settings.input_scheme) {
            .auto => switch (dvui.mouseType()) {
                // Pre-classification (no scroll events seen yet) — drop the parenthetical.
                .unknown => "Auto",
                .mouse, .trackpad => |hint| try std.fmt.allocPrint(dvui.currentWindow().lifo(), "Auto ({s})", .{@tagName(hint)}),
            },
            .mouse => "Mouse",
            .trackpad => "Trackpad",
        };
        dvui.label(@src(), "{s}", .{label_text}, .{ .margin = .all(0), .padding = .all(0) });

        dvui.icon(@src(), "dropdown_triangle", dvui.entypo.triangle_down, .{}, .{ .gravity_y = 0.5 });

        hbox.deinit();

        if (dropdown.dropped()) {
            if (dropdown.addChoiceLabel("Auto")) {
                pa.settings.input_scheme = .auto;
                pa.settings.save(pa.host);
                dvui.refresh(null, @src(), vbox.data().id);
            }
            if (dropdown.addChoiceLabel("Mouse")) {
                pa.settings.input_scheme = .mouse;
                pa.settings.save(pa.host);
                dvui.refresh(null, @src(), vbox.data().id);
            }
            if (dropdown.addChoiceLabel("Trackpad")) {
                pa.settings.input_scheme = .trackpad;
                pa.settings.save(pa.host);
                dvui.refresh(null, @src(), vbox.data().id);
            }
        }

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 10 } });
    }
}
