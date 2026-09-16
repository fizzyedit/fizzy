const std = @import("std");
const fizzy = @import("../fizzy.zig");
const AppInfo = @import("app").AppInfo;
const dvui = @import("dvui");
const icons = @import("icons");
const assets = @import("assets");
const update_notify = @import("app").update.update_notify;
const Dialogs = fizzy.Editor.Dialogs;
/// Font, height, icon side and spacing — fizzy draws every item with these, including
/// plugin `Entry` chips, so the bar stays uniform as the font setting changes.
const infobar = fizzy.sdk.infobar;

pub const Infobar = @This();

/// Most recent SCREEN-space (physical pixel) Y of the infobar's top edge, set
/// during `draw`. Used by `update_notify.drawAbove` to anchor the launch toast
/// directly above the infobar. Physical coords because FloatingWidget's `from`
/// anchor takes a `Point.Physical`. `null` until the first draw has run.
pub var last_top_y_physical: ?f32 = null;

pub fn init() !Infobar {
    return .{};
}

pub fn deinit() void {
    // TODO: Free memory
}

pub fn draw(_: Infobar, editor: *fizzy.Editor) !void {
    const font = infobar.font();
    const bar_h = infobar.height();

    // Fizzy owns height: pin min+max so content cannot grow the bar. Dedicated items
    // (logo, folder) stay put; plugin chips live in a horizontal scroll to their right.
    // No fill of its own — the explorer (and the rest of the chrome) is the window's
    // `.content.fill` showing through; painting `.control.fill` here left a darker strip.
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .gravity_y = 1.0,
        .padding = .all(0),
        .margin = .all(0),
        .min_size_content = .{ .h = bar_h },
        .max_size_content = .height(bar_h),
    });
    defer bar.deinit();

    last_top_y_physical = bar.data().rectScale().r.y;

    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .gravity_y = 0.5,
            .margin = .all(0),
            .padding = .all(0),
            .color_fill = .{ .color = fizzy.core.widgets.hoverRestFill(dvui.themeGet().color(.control, .fill_hover)) },
            .color_fill_hover = .{ .color = dvui.themeGet().color(.control, .fill_hover) },
            .color_fill_press = .{ .color = dvui.themeGet().color(.control, .fill_press) },
        });
        defer button.deinit();
        button.processEvents();
        button.drawBackground();

        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .all(0), .padding = .all(0) });
        defer box.deinit();

        // The pixel-art F (`icon.png`, not `fox.png`), same logo the settings tree and file
        // explorer use. `.imageFile` so dvui caches the texture — `fromImageFileBytes`
        // re-decodes every frame. Sized off the shared glyph side so it tracks the label beside
        // it and never grows the bar.
        const logo_side = infobar.iconSide();
        const logo: dvui.ImageSource = .{ .imageFile = .{
            .bytes = assets.files.@"icon.png",
            .name = "icon.png",
            .interpolation = .nearest,
        } };
        {
            // Fixed slot (min == max) so the artwork fits the bar instead of dictating its
            // height, same shape as `treeRowGlyph` but sized off `infobar.iconSide`.
            var logo_slot = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .gravity_y = 0.5,
                .expand = .none,
                .background = false,
                .min_size_content = .{ .w = logo_side, .h = logo_side },
                .max_size_content = .size(.{ .w = logo_side, .h = logo_side }),
                .padding = .all(0),
                .margin = .{ .x = 4, .w = 2 },
            });
            defer logo_slot.deinit();

            _ = dvui.image(@src(), .{ .source = logo, .shrink = .ratio }, .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .expand = .ratio,
                .padding = .all(0),
                .margin = .all(0),
                .background = false,
            });
        }
        dvui.label(@src(), AppInfo.current.name, .{}, .{ .font = font, .gravity_y = 0.5, .margin = .all(0) });

        if (button.clicked()) {
            Dialogs.AboutFizzy.request();
        }

        if (update_notify.badgeVisible()) {
            const brs = button.data().rectScale();
            const br = brs.r;
            const tr = br.topRight();
            const center = tr.plus(.{ .x = -5 * brs.s, .y = 5 * brs.s });
            var dot = dvui.Rect.Physical.fromPoint(center).toSize(.{ .w = 9 * brs.s, .h = 9 * brs.s });
            dot.x -= 4.5 * brs.s;
            dot.y -= 4.5 * brs.s;
            dot.fill(dvui.CornerRect.Physical.round(4.5 * brs.s), .{
                .color = .{ .color = dvui.themeGet().color(.highlight, .fill) },
                .fade = 0,
            });
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = infobar.item_spacing } });

    if (editor.app.folder) |folder| {
        fizzy.core.icon.icon(
            @src(),
            "project_icon",
            icons.tvg.entypo.folder,
            .{ .stroke_color = .{ .color = dvui.themeGet().color(.window, .text) }, .fill_color = .{ .color = dvui.themeGet().color(.window, .text) } },
            // Same square every other glyph in the bar gets, rather than the icon's own natural
            // size — that is what keeps it aligned with the label at any font size.
            .{
                .gravity_y = 0.5,
                .min_size_content = .{ .w = infobar.iconSide(), .h = infobar.iconSide() },
                .max_size_content = .size(.{ .w = infobar.iconSide(), .h = infobar.iconSide() }),
            },
        );
        dvui.label(@src(), "{s}", .{std.fs.path.basename(folder)}, .{ .font = font, .gravity_y = 0.5 });
    }

    drawPluginEntries(bar_h);
}

/// Collect every plugin's `infobarEntries` and draw them after the app's items, in a
/// horizontal scroll so overflow never grows or clips the dedicated chips.
fn drawPluginEntries(bar_h: f32) void {
    const entries = collectedEntries();
    if (entries.len == 0) return;

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = infobar.item_spacing } });

    var scrollarea = dvui.scrollArea(@src(), .{ .vertical = .none, .horizontal = .auto }, .{
        .expand = .horizontal,
        .background = false,
        .padding = .all(0),
        .margin = .all(0),
        .min_size_content = .{ .h = bar_h },
        .max_size_content = .height(bar_h),
    });
    defer scrollarea.deinit();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .none,
        .background = false,
        .padding = .all(0),
        .margin = .all(0),
        .min_size_content = .{ .h = bar_h },
        .max_size_content = .height(bar_h),
    });
    defer row.deinit();

    for (entries, 0..) |entry, i| {
        if (i > 0) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = infobar.item_spacing }, .id_extra = i });
        }
        drawEntry(i, entry);
    }
}

fn collectedEntries() []const infobar.Entry {
    const arena = fizzy.editor().app.host.arena();
    var list: std.ArrayList(infobar.Entry) = .empty;
    const active = fizzy.editor().activeDoc();
    const owner: ?*fizzy.sdk.Plugin = if (active) |doc| doc.owner else null;
    if (owner) |o| appendFrom(&list, arena, o, active);
    for (fizzy.editor().app.host.plugins.items) |p| {
        if (p == owner) continue;
        appendFrom(&list, arena, p, active);
    }
    return list.items;
}

fn appendFrom(
    list: *std.ArrayList(infobar.Entry),
    arena: std.mem.Allocator,
    plugin: *fizzy.sdk.Plugin,
    active: ?fizzy.sdk.DocHandle,
) void {
    for (plugin.infobarEntries(active)) |entry| {
        if (entry.icon.len == 0 and entry.text.len == 0) continue;
        list.append(arena, entry) catch return;
    }
}

fn drawEntry(id_extra: usize, entry: infobar.Entry) void {
    const color = dvui.themeGet().color(.window, .text);
    const side = infobar.iconSide();
    if (entry.icon.len > 0) {
        fizzy.core.icon.icon(
            @src(),
            "plugin_infobar_icon",
            entry.icon,
            .{ .stroke_color = .{ .color = color }, .fill_color = .{ .color = color } },
            .{
                .id_extra = id_extra,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = side, .h = side },
                .max_size_content = .size(.{ .w = side, .h = side }),
            },
        );
    }
    if (entry.text.len > 0) {
        dvui.label(@src(), "{s}", .{entry.text}, .{
            .id_extra = id_extra,
            .font = infobar.font(),
            .gravity_y = 0.5,
        });
    }
}
