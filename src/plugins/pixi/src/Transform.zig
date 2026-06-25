const std = @import("std");
const dvui = @import("dvui");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");

pub const Transform = @This();

/// Points of the transform
/// 1-4: the corner vertices of the transform
/// 5: the pivot point, defaulted to the center of the transform
/// 6: the rotation point
target_texture: dvui.Texture.Target,
data_points: [6]dvui.Point,
track_pivot: bool = false,
dragging: bool = false,
active_point: ?TransformPoint = null,
rotation: f32 = 0.0,
start_rotation: f32 = 0.0,
radius: f32 = 0.0,
file_id: u64,
layer_id: u64,
source: dvui.ImageSource,
ortho: bool = true,

pub fn point(self: *Transform, transform_point: TransformPoint) *dvui.Point {
    return &self.data_points[@intFromEnum(transform_point)];
}

/// Accepts the current transform and applies it to the currently selected layer
/// Actively transformed pixels are being copied to the temporary layer for display
/// During a transform, the temporary layer is not used for anything else
/// Transform layer contains the pixels being transformed prior to transformation,
/// and the active layer has had those pixels removed.
///
/// Note: `textureReadTarget` reads the full render target; the dominant cost is often GPU→CPU
/// bandwidth rather than the merge loops below.
pub fn accept(self: *Transform) void {
    if (runtime.state().docs.fileById(self.file_id)) |file| {
        var layer = file.getLayer(self.layer_id) orelse return;

        const t_all: i128 = if (pixi_mod.perf.record) pixi_mod.perf.nanoTimestamp() else 0;
        const layer_px: u64 = @as(u64, file.width()) * @as(u64, file.height());

        const pix = dvui.textureReadTarget(dvui.currentWindow().arena(), self.target_texture) catch {
            dvui.log.err("Failed to read target texture", .{});
            return;
        };
        const t_after_gpu: i128 = if (pixi_mod.perf.record) pixi_mod.perf.nanoTimestamp() else 0;

        file.buffers.stroke.clearAndReserveCapacity(@intCast(layer_px)) catch {
            dvui.log.err("Failed to reserve stroke map for transform accept", .{});
            return;
        };

        const t_loop: i128 = if (pixi_mod.perf.record) pixi_mod.perf.nanoTimestamp() else 0;
        // Two passes: undo keys use the pre-write layer; writes are independent per index, so order
        // matches the original interleaved loop without mutating layer between undo decisions.
        for (pix, file.editor.transform_layer.pixels(), layer.pixels(), 0..) |temp_pixel, transform_pixel, layer_pixel, pixel_index| {
            if (layer_pixel[3] != 0) {
                file.buffers.stroke.appendAssumeCapacity(pixel_index, layer_pixel);
            } else if (transform_pixel[3] != 0 or temp_pixel.a != 0) {
                file.buffers.stroke.appendAssumeCapacity(pixel_index, transform_pixel);
            }
        }
        for (pix, 0..) |temp_pixel, pixel_index| {
            if (temp_pixel.a != 0) {
                @memcpy(&layer.pixels()[pixel_index], &[_]u8{ temp_pixel.r, temp_pixel.g, temp_pixel.b, temp_pixel.a });
            }
        }

        // Paste / transform accept writes new pixels but does not go through `processSelection`; the
        // overlay uses `selection_layer.mask ∩ active_layer.mask`. Keep the mask aligned with the
        // committed transform so copied/pasted (and moved) pixels show the selection outline.
        if (runtime.state().tools.current == .selection) {
            file.editor.selection_layer.clearMask();
            for (pix, 0..) |temp_pixel, pixel_index| {
                if (temp_pixel.a != 0) {
                    file.editor.selection_layer.mask.set(pixel_index);
                }
            }
        }

        const t_after_loop: i128 = if (pixi_mod.perf.record) pixi_mod.perf.nanoTimestamp() else 0;

        const t_to_change: i128 = if (pixi_mod.perf.record) pixi_mod.perf.nanoTimestamp() else 0;
        const change = file.buffers.stroke.toChange(self.layer_id) catch null;
        const t_after_to_change: i128 = if (pixi_mod.perf.record) pixi_mod.perf.nanoTimestamp() else 0;

        const t_hist: i128 = if (pixi_mod.perf.record) pixi_mod.perf.nanoTimestamp() else 0;
        if (change) |c| {
            file.history.append(c) catch {
                dvui.log.err("Failed to append stroke change to history", .{});
            };
        }
        const t_end: i128 = if (pixi_mod.perf.record) pixi_mod.perf.nanoTimestamp() else 0;

        if (pixi_mod.perf.record) {
            pixi_mod.perf.transform_accept_last_total_ns = @intCast(t_end - t_all);
            pixi_mod.perf.transform_accept_last_gpu_read_ns = @intCast(t_after_gpu - t_all);
            pixi_mod.perf.transform_accept_last_merge_loop_ns = @intCast(t_after_loop - t_loop);
            pixi_mod.perf.transform_accept_last_to_change_ns = @intCast(t_after_to_change - t_to_change);
            pixi_mod.perf.transform_accept_last_history_append_ns = @intCast(t_end - t_hist);
            pixi_mod.perf.transform_accept_last_layer_pixels = layer_px;
            pixi_mod.perf.logTransformAcceptIf();
        }

        layer.invalidate();
        file.invalidateActiveLayerTransparencyMaskCache();
        file.editor.transform_layer.clear();
        file.editor.transform_layer.clearMask();
        file.editor.transform_layer.invalidate();
        file.editor.transform = null;
        runtime.allocator().free(pixi_mod.image.bytes(self.source));
        self.* = undefined;
    }
}

/// Cancels the transform and restores the layer to its original state
pub fn cancel(self: *Transform) void {
    if (runtime.state().docs.fileById(self.file_id)) |file| {
        var layer = file.getLayer(self.layer_id) orelse return;
        var iterator = file.editor.transform_layer.mask.iterator(.{ .kind = .set, .direction = .forward });
        while (iterator.next()) |pixel_index| {
            @memcpy(&layer.pixels()[pixel_index], &file.editor.transform_layer.pixels()[pixel_index]);
        }
        layer.invalidate();
        file.invalidateActiveLayerTransparencyMaskCache();

        file.editor.transform_layer.clear();
        file.editor.transform_layer.clearMask();
        file.editor.transform_layer.invalidate();
        file.editor.transform = null;
        runtime.allocator().free(pixi_mod.image.bytes(self.source));
        self.* = undefined;
    }
}

pub fn updateRadius(self: *Transform) void {
    var radius: f32 = 0.0;
    for (self.data_points[0..4]) |*p| {
        const diff = p.diff(self.point(.pivot).*);
        if (diff.length() > radius) {
            radius = diff.length() + 4;
        }
    }
    self.radius = radius;
}

pub fn centroid(self: *Transform) dvui.Point {
    var ret = self.data_points[0];
    for (self.data_points[1..4]) |*p| {
        ret.x += p.x;
        ret.y += p.y;
    }
    ret.x /= 4;
    ret.y /= 4;
    return ret;
}

pub fn move(self: *Transform, delta: dvui.Point) void {
    self.point(.top_left).* = self.point(.top_left).plus(delta);
    self.point(.top_right).* = self.point(.top_right).plus(delta);
    self.point(.bottom_right).* = self.point(.bottom_right).plus(delta);
    self.point(.bottom_left).* = self.point(.bottom_left).plus(delta);
    self.point(.pivot).* = self.point(.pivot).plus(delta);
    self.point(.rotate).* = self.point(.rotate).plus(delta);
}

pub fn hovered(self: *Transform, data_point: dvui.Point) bool {
    var is_hovered = false;

    var path = dvui.Path.Builder.init(dvui.currentWindow().arena());
    path.addPoint(.{ .x = self.point(.top_left).x, .y = self.point(.top_left).y });
    path.addPoint(.{ .x = self.point(.top_right).x, .y = self.point(.top_right).y });
    path.addPoint(.{ .x = self.point(.bottom_right).x, .y = self.point(.bottom_right).y });
    path.addPoint(.{ .x = self.point(.bottom_left).x, .y = self.point(.bottom_left).y });

    const cent = self.centroid();

    var triangles = path.build().fillConvexTriangles(dvui.currentWindow().arena(), .{
        .center = .{ .x = cent.x, .y = cent.y },
        .color = .white,
    }) catch null;

    if (triangles) |*t| {
        t.rotate(.{ .x = self.point(.pivot).x, .y = self.point(.pivot).y }, self.rotation);

        const top_left = t.vertexes[0];
        const top_right = t.vertexes[1];
        const bottom_right = t.vertexes[2];
        const bottom_left = t.vertexes[3];

        {
            const triangle_1 = [3]dvui.Point{
                .{ .x = top_left.pos.x, .y = top_left.pos.y },
                .{ .x = top_right.pos.x, .y = top_right.pos.y },
                .{ .x = data_point.x, .y = data_point.y },
            };

            const triangle_2 = [3]dvui.Point{
                .{ .x = top_right.pos.x, .y = top_right.pos.y },
                .{ .x = bottom_right.pos.x, .y = bottom_right.pos.y },
                .{ .x = data_point.x, .y = data_point.y },
            };

            const triangle_3 = [3]dvui.Point{
                .{ .x = bottom_right.pos.x, .y = bottom_right.pos.y },
                .{ .x = top_left.pos.x, .y = top_left.pos.y },
                .{ .x = data_point.x, .y = data_point.y },
            };

            const triangle_4 = [3]dvui.Point{
                .{ .x = top_left.pos.x, .y = top_left.pos.y },
                .{ .x = top_right.pos.x, .y = top_right.pos.y },
                .{ .x = bottom_right.pos.x, .y = bottom_right.pos.y },
            };

            const area_1 = area(triangle_1);
            const area_2 = area(triangle_2);
            const area_3 = area(triangle_3);
            const area_4 = area(triangle_4);

            const combined = area_1 + area_2 + area_3;
            const diff = @abs(combined - area_4);

            if (!is_hovered)
                is_hovered = diff < 0.1;
        }
        {
            const triangle_1 = [3]dvui.Point{
                .{ .x = bottom_right.pos.x, .y = bottom_right.pos.y },
                .{ .x = bottom_left.pos.x, .y = bottom_left.pos.y },
                .{ .x = data_point.x, .y = data_point.y },
            };

            const triangle_2 = [3]dvui.Point{
                .{ .x = bottom_left.pos.x, .y = bottom_left.pos.y },
                .{ .x = top_left.pos.x, .y = top_left.pos.y },
                .{ .x = data_point.x, .y = data_point.y },
            };

            const triangle_3 = [3]dvui.Point{
                .{ .x = top_left.pos.x, .y = top_left.pos.y },
                .{ .x = bottom_right.pos.x, .y = bottom_right.pos.y },
                .{ .x = data_point.x, .y = data_point.y },
            };

            const triangle_4 = [3]dvui.Point{
                .{ .x = top_left.pos.x, .y = top_left.pos.y },
                .{ .x = bottom_right.pos.x, .y = bottom_right.pos.y },
                .{ .x = bottom_left.pos.x, .y = bottom_left.pos.y },
            };

            const area_1 = area(triangle_1);
            const area_2 = area(triangle_2);
            const area_3 = area(triangle_3);
            const area_4 = area(triangle_4);

            const combined = area_1 + area_2 + area_3;
            const diff = @abs(combined - area_4);

            if (!is_hovered)
                is_hovered = diff < 0.1;
        }
    }

    return is_hovered;
}

fn area(triangle: [3]dvui.Point) f32 {
    return @abs((triangle[0].x * (triangle[1].y - triangle[2].y) + triangle[1].x * (triangle[2].y - triangle[0].y) + triangle[2].x * (triangle[0].y - triangle[1].y)) / 2.0);
}

pub const TransformPoint = enum(usize) {
    top_left = 0,
    top_right = 1,
    bottom_right = 2,
    bottom_left = 3,
    pivot = 4,
    rotate = 5,
};
