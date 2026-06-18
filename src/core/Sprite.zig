//! A sub-rect within an atlas texture: pixel `source` rect + optional `origin`.
//!
//! Used by the shell for UI icons and by the pixel-art renderer as the sprite-rect
//! type. Distinct from the plugin's build-time `Atlas.zig` (JSON loader with animations).
const std = @import("std");
const dvui = @import("dvui");

const Sprite = @This();

origin: [2]f32 = .{ 0.0, 0.0 },
source: [4]u32,

/// Draw this sprite from `atlas_source` as a dvui widget (static textured quad).
pub fn draw(
    self: Sprite,
    src: std.builtin.SourceLocation,
    atlas_source: dvui.ImageSource,
    scale: f32,
    opts: dvui.Options,
) dvui.WidgetData {
    const source_size: dvui.Size = dvui.imageSize(atlas_source) catch .{ .w = 0, .h = 0 };

    const uv = dvui.Rect{
        .x = @as(f32, @floatFromInt(self.source[0])) / source_size.w,
        .y = @as(f32, @floatFromInt(self.source[1])) / source_size.h,
        .w = @as(f32, @floatFromInt(self.source[2])) / source_size.w,
        .h = @as(f32, @floatFromInt(self.source[3])) / source_size.h,
    };

    const options = (dvui.Options{ .name = "sprite" }).override(opts);

    const size: dvui.Size = if (options.min_size_content) |msc| msc else .{
        .w = @as(f32, @floatFromInt(self.source[2])) * scale,
        .h = @as(f32, @floatFromInt(self.source[3])) * scale,
    };

    var wd = dvui.WidgetData.init(src, .{}, options.override(.{ .min_size_content = size }));
    wd.register();

    const cr = wd.contentRect();
    const ms = wd.options.min_size_contentGet();

    var too_big = false;
    if (ms.w > cr.w or ms.h > cr.h) too_big = true;

    var e = wd.options.expandGet();
    const g = wd.options.gravityGet();
    var rect = dvui.placeIn(cr, ms, e, g);

    if (too_big and e != .ratio) {
        if (ms.w > cr.w and !e.isHorizontal()) {
            rect.w = ms.w;
            rect.x -= g.x * (ms.w - cr.w);
        }
        if (ms.h > cr.h and !e.isVertical()) {
            rect.h = ms.h;
            rect.y -= g.y * (ms.h - cr.h);
        }
    }

    wd.rect = rect.outset(wd.options.paddingGet()).outset(wd.options.borderGet()).outset(wd.options.marginGet());

    if (wd.options.rotationGet() == 0.0) {
        wd.borderAndBackground(.{});
    } else if (wd.options.borderGet().nonZero()) {
        dvui.log.debug("image {x} can't render border while rotated\n", .{wd.id});
    }

    const rs = wd.contentRectScale();
    dvui.renderImage(atlas_source, rs, .{
        .uv = uv,
        .fade = 0.0,
    }) catch {
        dvui.log.err("Failed to render sprite", .{});
    };

    if (opts.color_border) |border| {
        var path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
        defer path.deinit();
        const r = wd.contentRectScale().r;
        path.addPoint(r.topLeft());
        path.addPoint(r.topRight());
        path.addPoint(r.bottomRight());
        path.addPoint(r.bottomLeft());
        path.build().stroke(.{ .color = border, .thickness = 1.0, .closed = true });
    }

    wd.minSizeSetAndRefresh();
    wd.minSizeReportToParent();
    return wd;
}
