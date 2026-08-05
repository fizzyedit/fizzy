const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const icons = @import("icons");
const assets = @import("assets");
const update_notify = @import("../backend/update_notify.zig");
const Dialogs = fizzy.Editor.Dialogs;
const Constants = @import("Constants.zig");

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

pub fn draw(_: Infobar) !void {
    const font = dvui.Font.theme(.body).larger(-1.0);
    const bar_h = Constants.infobar_height;

    // Fizzy owns height: pin min+max so plugin (or icon) content cannot grow the bar.
    // Horizontal scroll covers overflow width; vertical overflow is clipped.
    var scrollarea = dvui.scrollArea(@src(), .{ .vertical = .none, .horizontal = .auto }, .{
        .expand = .horizontal,
        .background = false,
        .color_fill = dvui.themeGet().color(.control, .fill),
        .gravity_y = 1.0,
        .padding = .all(0),
        .margin = .all(0),
        .min_size_content = .{ .h = bar_h },
        .max_size_content = .height(bar_h),
    });
    defer scrollarea.deinit();

    last_top_y_physical = scrollarea.data().rectScale().r.y;
    var infobox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = false,
        .padding = .all(0),
        .margin = .all(0),
        .min_size_content = .{ .h = bar_h },
        .max_size_content = .height(bar_h),
    });
    defer infobox.deinit();

    {
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .gravity_y = 0.5,
            .margin = .all(0),
            .padding = .all(0),
            .color_fill = fizzy.dvui.hoverRestFill(dvui.themeGet().color(.control, .fill_hover)),
            .color_fill_hover = dvui.themeGet().color(.control, .fill_hover),
            .color_fill_press = dvui.themeGet().color(.control, .fill_press),
        });
        defer button.deinit();
        button.processEvents();
        button.drawBackground();

        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .all(0), .padding = .all(0) });
        defer box.deinit();

        // The pixel-art F (`icon.png`, not `fox.png`), same logo the settings tree and file
        // explorer use. `.imageFile` so dvui caches the texture — `fromImageFileBytes`
        // re-decodes every frame. Sized off the bar height so it never grows the infobar.
        const logo_side = bar_h - 8;
        const logo: dvui.ImageSource = .{ .imageFile = .{
            .bytes = assets.files.@"icon.png",
            .name = "icon.png",
            .interpolation = .nearest,
        } };
        {
            // Fixed slot (min == max) so the artwork fits the bar instead of dictating its
            // height, same shape as `treeRowGlyph` but sized off `infobar_height`.
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
        dvui.label(@src(), "fizzy", .{}, .{ .font = font, .gravity_y = 0.5, .margin = .all(0) });

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
            dot.fill(dvui.CornerRect.Physical.all(4.5 * brs.s), .{
                .color = dvui.themeGet().color(.highlight, .fill),
                .fade = 0,
            });
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

    if (fizzy.editor.folder) |folder| {
        dvui.icon(
            @src(),
            "project_icon",
            icons.tvg.entypo.folder,
            .{ .stroke_color = dvui.themeGet().color(.window, .text), .fill_color = dvui.themeGet().color(.window, .text) },
            .{ .gravity_y = 0.5 },
        );
        dvui.label(@src(), "{s}", .{std.fs.path.basename(folder)}, .{ .font = font, .gravity_y = 0.5 });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12 } });

    // Remaining width is the plugin slot: fizzy-sized, clipped, rect handed to the owner.
    {
        var plugin_slot = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = false,
            .padding = .all(0),
            .margin = .all(0),
            .min_size_content = .{ .h = bar_h },
            .max_size_content = .height(bar_h),
        });
        defer plugin_slot.deinit();

        const rect = plugin_slot.data().contentRect();
        const prev_clip = dvui.clip(plugin_slot.data().contentRectScale().r);
        defer dvui.clipSet(prev_clip);

        if (fizzy.editor.activeDoc()) |doc| {
            doc.owner.drawDocumentInfobar(doc, rect) catch {
                dvui.log.err("Failed to draw document infobar", .{});
            };
        }
    }
}
