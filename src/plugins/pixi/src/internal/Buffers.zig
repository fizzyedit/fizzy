const std = @import("std");

const History = @import("History.zig");
const pixi_mod = @import("../../pixi.zig");
const runtime = @import("../runtime.zig");
const Buffers = @This();

stroke: Stroke,
temporary_stroke: Stroke,

pub const Stroke = struct {
    //indices: std.ArrayList(usize),
    //values: std.ArrayList([4]u8),

    pixels: std.AutoHashMap(usize, [4]u8),
    //canvas: pixi_mod.file.gui.canvas = .primary,

    pub fn init(allocator: std.mem.Allocator) Stroke {
        return .{
            .pixels = .init(allocator),
            // .indices = std.ArrayList(usize).init(allocator),
            // .values = std.ArrayList([4]u8).init(allocator),
        };
    }

    pub fn append(stroke: *Stroke, index: usize, value: [4]u8) !void {
        const ptr = try stroke.pixels.getOrPut(index);
        if (pixi_mod.perf.record) {
            pixi_mod.perf.stroke_append_calls += 1;
            if (!ptr.found_existing) pixi_mod.perf.stroke_append_new_keys += 1;
        }
        if (!ptr.found_existing)
            ptr.value_ptr.* = value;

        // try stroke.indices.append(index);

        // try stroke.values.append(value);
        //stroke.canvas = canvas;
    }

    /// Clears the stroke map and reserves hash buckets for up to `max_keys` entries (no rehash churn
    /// while filling). Call before a known full-layer pass such as transform accept.
    pub fn clearAndReserveCapacity(stroke: *Stroke, max_keys: usize) !void {
        stroke.clearAndFree();
        const cap: u32 = @intCast(@min(max_keys, std.math.maxInt(u32)));
        try stroke.pixels.ensureTotalCapacity(cap);
    }

    /// Like `append` but the map must already have capacity for new keys (see `clearAndReserveCapacity`).
    pub fn appendAssumeCapacity(stroke: *Stroke, index: usize, value: [4]u8) void {
        const gop = stroke.pixels.getOrPutAssumeCapacity(index);
        if (pixi_mod.perf.record) {
            pixi_mod.perf.stroke_append_calls += 1;
            if (!gop.found_existing) pixi_mod.perf.stroke_append_new_keys += 1;
        }
        if (!gop.found_existing)
            gop.value_ptr.* = value;
    }

    pub fn appendSlice(stroke: *Stroke, indices: []usize, values: [][4]u8) !void {
        for (indices, values) |index, value| {
            try stroke.append(index, value);
        }

        //try stroke.indices.appendSlice(indices);
        //try stroke.values.appendSlice(values);
        //stroke.canvas = canvas;
    }

    pub fn toChange(stroke: *Stroke, layer_id: u64) !History.Change {
        const t0: i128 = if (pixi_mod.perf.record) pixi_mod.perf.nanoTimestamp() else 0;
        const n = stroke.pixels.count();

        // Exact-size allocations; transform accept pre-reserves the hash map to avoid rehash during fills.
        var indices = runtime.allocator().alloc(usize, n) catch return error.MemoryAllocationFailed;
        errdefer runtime.allocator().free(indices);
        var values = runtime.allocator().alloc([4]u8, n) catch return error.MemoryAllocationFailed;
        errdefer runtime.allocator().free(values);

        var it = stroke.pixels.iterator();

        var i: usize = 0;
        while (it.next()) |entry| {
            indices[i] = entry.key_ptr.*;
            values[i] = entry.value_ptr.*;
            i += 1;
        }

        stroke.pixels.clearAndFree();

        if (pixi_mod.perf.record) {
            pixi_mod.perf.stroke_to_change_ns +%= @intCast(pixi_mod.perf.nanoTimestamp() - t0);
            pixi_mod.perf.stroke_to_change_calls += 1;
            pixi_mod.perf.stroke_to_change_pixels_out +%= n;
        }

        return .{ .pixels = .{
            .layer_id = layer_id,
            .indices = indices,
            .values = values,
        } };
    }

    pub fn clearAndFree(stroke: *Stroke) void {
        stroke.pixels.clearAndFree();
        // stroke.indices.clearAndFree();
        // stroke.values.clearAndFree();
    }

    pub fn deinit(stroke: *Stroke) void {
        stroke.clearAndFree();
        // stroke.indices.deinit();
        // stroke.values.deinit();
    }
};

pub fn init(allocator: std.mem.Allocator) Buffers {
    return .{
        .stroke = Stroke.init(allocator),
        .temporary_stroke = Stroke.init(allocator),
    };
}

pub fn clearAndFree(buffers: *Buffers) void {
    buffers.stroke.clearAndFree();
    buffers.temporary_stroke.clearAndFree();
}

pub fn deinit(buffers: *Buffers) void {
    buffers.clearAndFree();
    buffers.stroke.deinit();
    buffers.temporary_stroke.deinit();
}
