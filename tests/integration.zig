//! Layer 2 (headless integration) test target.
//!
//! These tests run real fizzy drawing functions against a *headless*
//! `dvui.Window` provided by dvui's testing backend. The shim in
//! `fizzy_shim.zig` brings up just enough of `fizzy.app` / `fizzy.editor`
//! for the code paths exercised here to read the globals they need
//! without booting the full editor (no assets, no themes, no SDL).
//!
//! See `tests/README.md` for the overall layering.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("fizzy");
const shim = @import("fizzy_shim.zig");
const pixelart = fizzy.pixelart_mod;

const Internal = pixelart.internal;

/// Create a small in-memory `Internal.File` suitable for tests. The
/// caller must already have a live shim context (so `fizzy.app` /
/// `fizzy.editor` / `dvui.currentWindow()` are valid). The returned
/// file must be torn down with `deinitFile` (not `file.deinit()`).
fn makeBlankFile(width_: u32, height_: u32) !Internal.File {
    return Internal.File.init("untitled-test", .{
        .columns = 1,
        .rows = 1,
        .column_width = width_,
        .row_height = height_,
    });
}

/// Tear down a file constructed with `makeBlankFile`. `Internal.File.deinit`
/// is leak-tolerant in production (the editor's higher-level close
/// paths free the rest via routes we don't take here): specifically
/// it does NOT release per-layer `mask` bit-sets and pixel buffers
/// for entries in `file.layers`, nor `editor.selected_sprites`,
/// `editor.checkerboard`. Note also that
/// `Internal.File.deinit` already frees each layer's `name`, so
/// calling `layer.deinit()` here would double-free it. We free the
/// leaked-in-tests pieces by hand.
fn deinitFile(file: *Internal.File) void {
    var i: usize = 0;
    while (i < file.layers.len) : (i += 1) {
        var layer = file.layers.get(i);
        switch (layer.source) {
            .imageFile => |image| fizzy.app.allocator.free(image.bytes),
            .pixels => |p| fizzy.app.allocator.free(p.rgba),
            .pixelsPMA => |p| fizzy.app.allocator.free(p.rgba),
            .texture => |t| dvui.textureDestroyLater(t),
        }
        layer.mask.deinit();
    }
    file.editor.selected_sprites.deinit();
    file.editor.checkerboard.deinit();
    // `file.editor.checkerboard_tile` is an optional GPU `dvui.Texture`
    // now; `file.deinit()` destroys it (and nulls it) on its own.
    file.deinit();
}

test "shim brings up a dvui.testing window with usable fizzy globals" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const arena = dvui.currentWindow().arena();
    const buf = try arena.alloc(u8, 16);
    @memset(buf, 0);

    try std.testing.expect(fizzy.app == ctx.app);
    try std.testing.expect(fizzy.editor == ctx.editor);
}

test "Internal.File.init constructs a usable blank file" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try makeBlankFile(8, 8);
    defer deinitFile(&file);

    try std.testing.expectEqual(@as(u32, 8), file.width());
    try std.testing.expectEqual(@as(u32, 8), file.height());
    try std.testing.expectEqual(@as(usize, 1), file.layers.len);
    try std.testing.expectEqual(@as(usize, 0), file.selected_layer_index);
}

// -------------------------------------------------------------------
// Regression: bug #131 — fill tool followed by selection-mask tools
// did not show the alternating selection pattern until deselect+select
// because `Internal.File.fillPoint` modifies layer pixels but
// `ImageSource.hash()` is pointer-based, so
// `FileWidget.updateActiveLayerMask` saw a still-warm cache and
// skipped rebuilding the mask.
//
// The fix is `file.invalidateActiveLayerTransparencyMaskCache()` at
// the end of `fillPoint` for the selected layer. This test pins that
// behavior so we don't regress.
// -------------------------------------------------------------------
test "fillPoint invalidates active layer mask cache (regression #131)" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try makeBlankFile(8, 8);
    defer deinitFile(&file);

    // Pretend the mask cache was warmed by a prior frame.
    file.editor.mask_built_for_layer = file.selected_layer_index;
    file.editor.mask_built_source_hash = 0xdeadbeef;

    // Bucket fill at (1, 1) with red.
    file.fillPoint(.{ .x = 1, .y = 1 }, .selected, .{
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .invalidate = false,
        .to_change = false,
    });

    try std.testing.expectEqual(@as(?usize, null), file.editor.mask_built_for_layer);
}

// -------------------------------------------------------------------
// `selectColorFloodFromPoint`: scanline-flood fills the selection mask
// for every pixel reachable through orthogonal neighbours that share
// the seed pixel's exact color, and stops at color boundaries. We
// arrange a 4x4 layer with two solid color regions split down the
// middle:
//
//   A A B B
//   A A B B
//   A A B B
//   A A B B
//
// then assert that flooding from inside the A region selects the 8 A
// pixels and nothing else, and similarly for B.
// -------------------------------------------------------------------
test "selectColorFloodFromPoint covers a connected region and stops at color boundaries" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try makeBlankFile(4, 4);
    defer deinitFile(&file);

    // Paint the two regions directly into the active layer's pixel
    // buffer. (Bypass `drawPoint` to keep the test focused on flood
    // semantics.)
    const layer_a = file.layers.get(file.selected_layer_index);
    const px = layer_a.pixels();
    const color_a: [4]u8 = .{ 200, 0, 0, 255 };
    const color_b: [4]u8 = .{ 0, 0, 200, 255 };
    var y: usize = 0;
    while (y < 4) : (y += 1) {
        var x: usize = 0;
        while (x < 4) : (x += 1) {
            px[y * 4 + x] = if (x < 2) color_a else color_b;
        }
    }

    // Flood A from (0, 0) and count selected bits.
    try file.selectColorFloodFromPoint(.{ .x = 0, .y = 0 }, true);

    var selected: usize = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (file.editor.selection_layer.mask.isSet(i)) selected += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), selected);

    // Sanity-check that the selected indices are exactly the A column.
    i = 0;
    while (i < 16) : (i += 1) {
        const x = i % 4;
        const expected = x < 2;
        try std.testing.expectEqual(expected, file.editor.selection_layer.mask.isSet(i));
    }

    // Flooding from a B pixel with `value = false` is a no-op on A
    // bits. Toggle the test: clear the mask, flood B, verify only B
    // bits are set.
    file.editor.selection_layer.clearMask();
    try file.selectColorFloodFromPoint(.{ .x = 3, .y = 3 }, true);
    selected = 0;
    i = 0;
    while (i < 16) : (i += 1) {
        if (file.editor.selection_layer.mask.isSet(i)) selected += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), selected);
    i = 0;
    while (i < 16) : (i += 1) {
        const x = i % 4;
        const expected = x >= 2;
        try std.testing.expectEqual(expected, file.editor.selection_layer.mask.isSet(i));
    }
}

test "selectColorFloodFromPoint out-of-bounds is a no-op" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try makeBlankFile(4, 4);
    defer deinitFile(&file);

    try file.selectColorFloodFromPoint(.{ .x = -1, .y = 0 }, true);
    try file.selectColorFloodFromPoint(.{ .x = 0, .y = 4 }, true);

    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try std.testing.expect(!file.editor.selection_layer.mask.isSet(i));
    }
}

// -------------------------------------------------------------------
// `.pixi` JSON parser fallbacks. The on-disk format has been bumped
// three times. `fromPathFizzy` first tries the current `pixelart.File`
// shape and, on failure, retries against `FileV3`, `FileV2`, and
// `FileV1`. This test exercises just the JSON layer (no zip, no
// `Internal.File` materialization) by parsing a small in-memory
// fixture for each version. It catches the kind of bug where someone
// renames or retypes a field on the public `pixelart.File` types and
// silently breaks loading older saves.
// -------------------------------------------------------------------
test "pixelart.File parses current-format JSON and round-trips" {
    const json =
        \\{
        \\  "version": { "major": 1, "minor": 0, "patch": 0, "pre": null, "build": null },
        \\  "columns": 2,
        \\  "rows": 1,
        \\  "column_width": 8,
        \\  "row_height": 8,
        \\  "layers": [{ "name": "Layer", "visible": true, "collapse": false }],
        \\  "sprites": [
        \\    { "origin": [0.0, 0.0] },
        \\    { "origin": [0.0, 0.0] }
        \\  ],
        \\  "animations": [
        \\    { "name": "idle", "frames": [{ "sprite_index": 0, "ms": 100 }] }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(
        pixelart.File,
        std.testing.allocator,
        json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 2), parsed.value.columns);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.rows);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.layers.len);
    try std.testing.expectEqualStrings("Layer", parsed.value.layers[0].name);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.sprites.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.animations.len);
    try std.testing.expectEqualStrings("idle", parsed.value.animations[0].name);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.animations[0].frames.len);
    try std.testing.expectEqual(@as(u32, 100), parsed.value.animations[0].frames[0].ms);

    // Re-serialize and re-parse — the second parse must equal the
    // first along every observable axis. This is the round-trip
    // guarantee that protects against asymmetric (de)serialization.
    const round_tripped = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(round_tripped);

    const reparsed = try std.json.parseFromSlice(
        pixelart.File,
        std.testing.allocator,
        round_tripped,
        .{ .ignore_unknown_fields = true },
    );
    defer reparsed.deinit();

    try std.testing.expectEqual(parsed.value.columns, reparsed.value.columns);
    try std.testing.expectEqual(parsed.value.rows, reparsed.value.rows);
    try std.testing.expectEqual(parsed.value.column_width, reparsed.value.column_width);
    try std.testing.expectEqual(parsed.value.row_height, reparsed.value.row_height);
    try std.testing.expectEqual(parsed.value.layers.len, reparsed.value.layers.len);
    try std.testing.expectEqualStrings(parsed.value.layers[0].name, reparsed.value.layers[0].name);
    try std.testing.expectEqual(parsed.value.animations[0].frames[0].sprite_index, reparsed.value.animations[0].frames[0].sprite_index);
    try std.testing.expectEqual(parsed.value.animations[0].frames[0].ms, reparsed.value.animations[0].frames[0].ms);
}

test "pixelart.File.FileV3 fixture parses" {
    // V3 keeps the columns/rows shape but uses the older `AnimationV2`
    // (frame indices + fps) form.
    const json =
        \\{
        \\  "version": { "major": 0, "minor": 7, "patch": 0, "pre": null, "build": null },
        \\  "columns": 2,
        \\  "rows": 1,
        \\  "column_width": 8,
        \\  "row_height": 8,
        \\  "layers": [{ "name": "Layer", "visible": true, "collapse": false }],
        \\  "sprites": [
        \\    { "origin": [0.0, 0.0] },
        \\    { "origin": [0.0, 0.0] }
        \\  ],
        \\  "animations": [{ "name": "idle", "frames": [0, 1], "fps": 10.0 }]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(
        pixelart.File.FileV3,
        std.testing.allocator,
        json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 2), parsed.value.columns);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.animations[0].frames.len);
    try std.testing.expectEqual(@as(f32, 10.0), parsed.value.animations[0].fps);
}

test "pixelart.File.FileV2 fixture parses (width/height + tile_size shape)" {
    const json =
        \\{
        \\  "version": { "major": 0, "minor": 5, "patch": 0, "pre": null, "build": null },
        \\  "width": 16,
        \\  "height": 8,
        \\  "tile_width": 8,
        \\  "tile_height": 8,
        \\  "layers": [{ "name": "Layer", "visible": true, "collapse": false }],
        \\  "sprites": [
        \\    { "origin": [0.0, 0.0] },
        \\    { "origin": [0.0, 0.0] }
        \\  ],
        \\  "animations": [{ "name": "idle", "frames": [0, 1], "fps": 12.0 }]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(
        pixelart.File.FileV2,
        std.testing.allocator,
        json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 16), parsed.value.width);
    try std.testing.expectEqual(@as(u32, 8), parsed.value.tile_width);
}

test "pixelart.File.FileV1 fixture parses (start/length animation shape)" {
    const json =
        \\{
        \\  "version": { "major": 0, "minor": 1, "patch": 0, "pre": null, "build": null },
        \\  "width": 16,
        \\  "height": 8,
        \\  "tile_width": 8,
        \\  "tile_height": 8,
        \\  "layers": [{ "name": "Layer", "visible": true, "collapse": false }],
        \\  "sprites": [
        \\    { "origin": [0.0, 0.0] },
        \\    { "origin": [0.0, 0.0] }
        \\  ],
        \\  "animations": [{ "name": "idle", "start": 0, "length": 2, "fps": 8.0 }]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(
        pixelart.File.FileV1,
        std.testing.allocator,
        json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.value.animations[0].start);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.animations[0].length);
    try std.testing.expectEqual(@as(f32, 8.0), parsed.value.animations[0].fps);
}

// -------------------------------------------------------------------
// `Layer.reduce`: thin wrapper over `fizzy.algorithms.reduce.reduce`. The pure module has its
// own exhaustive tests; this test pins the wrapper conversion (dvui.Rect ↔ u32 rect).
// -------------------------------------------------------------------
test "Layer.reduce tightens a painted rectangle and returns the bounding rect" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try makeBlankFile(8, 8);
    defer deinitFile(&file);

    var layer = file.layers.get(0);
    const px = layer.pixels();
    // Paint a 2x3 block at (1, 2) — the surrounding pixels stay transparent.
    var y: u32 = 2;
    while (y < 5) : (y += 1) {
        var x: u32 = 1;
        while (x < 3) : (x += 1) {
            px[y * 8 + x] = .{ 200, 50, 30, 255 };
        }
    }

    const r = layer.reduce(.{ .x = 0, .y = 0, .w = 8, .h = 8 }) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(@as(f32, 1.0), r.x);
    try std.testing.expectEqual(@as(f32, 2.0), r.y);
    try std.testing.expectEqual(@as(f32, 2.0), r.w);
    try std.testing.expectEqual(@as(f32, 3.0), r.h);
}

test "Layer.reduce returns null on a fully transparent layer" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try makeBlankFile(4, 4);
    defer deinitFile(&file);

    var layer = file.layers.get(0);
    try std.testing.expect(layer.reduce(.{ .x = 0, .y = 0, .w = 4, .h = 4 }) == null);
}

// Regression: row slice advancement used `next_row_end < len`, so the last row of a
// full-height blit never received a fresh `d` slice and the final source row was written
// into the wrong row (transform + reduce looked like the bottom pixel row was missing).
test "Layer.blit copies the bottom row when the destination spans full layer height" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var layer = try Internal.Layer.init(1, "t", 4, 4, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .ptr);
    defer layer.deinit();

    const marker: [4]u8 = .{ 99, 88, 77, 255 };
    var src: [16][4]u8 = undefined;
    @memset(&src, .{ 0, 0, 0, 0 });
    var xi: usize = 0;
    while (xi < 4) : (xi += 1) {
        src[3 * 4 + xi] = marker;
    }

    layer.blit(&src, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{ .transparent = false, .mask = false });

    const out = layer.pixels();
    try std.testing.expectEqual(marker, out[3 * 4 + 0]);
    try std.testing.expectEqual(marker, out[3 * 4 + 3]);
}

// -------------------------------------------------------------------
// `Packer.append`: end-to-end check that a painted file becomes:
//
//   1) one Packer sprite per file sprite (with `image == null` or a tightened bitmap),
//   2) frame rect dimensions equal to the reduced rect's w/h,
//   3) sprite origin shifted by (reduced_x - cell_x, reduced_y - cell_y) so the in-game
//      anchor still lands on the same world pixel.
//
// This is exactly the pipeline the user called out: "make sure we can reduce sprites
// accurately" + "origin math as it gets packed tightly is accurate". Together with the
// pure-module tests on `fizzy.algorithms.reduce`, regressions in either layer fail loudly.
// -------------------------------------------------------------------
test "Packer.append reduces painted sprite and offsets origin to keep anchor aligned" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // 16×8 layer, sliced as 2 columns × 1 row of 8×8 cells. Sprite 0 lives at cell (0,0),
    // sprite 1 at cell (8, 0).
    var file = try Internal.File.init("untitled-packer", .{
        .columns = 2,
        .rows = 1,
        .column_width = 8,
        .row_height = 8,
    });
    defer deinitFile(&file);

    // Cell-local origin for sprite 0 — pivot at (4, 4).
    file.sprites.items(.origin)[0] = .{ 4.0, 4.0 };
    // Cell-local origin for sprite 1 — pivot at (4, 4).
    file.sprites.items(.origin)[1] = .{ 4.0, 4.0 };

    var layer = file.layers.get(0);
    const px = layer.pixels();
    // Cell 0: paint a single opaque pixel at (3, 3) — reducer should return rect (3,3,1,1)
    // and the origin should shift by (3, 3) → new origin (1, 1).
    px[3 * 16 + 3] = .{ 255, 0, 0, 255 };
    // Cell 1: leave fully transparent so the packer skips the bitmap (image == null).

    var packer = try pixelart.Packer.init(std.testing.allocator);
    defer packer.deinit();

    try packer.append(&file);

    // One Packer sprite per file sprite: sprite 0 has a bitmap, sprite 1 is transparent.
    try std.testing.expectEqual(@as(usize, 1), packer.sprites.items.len);
    try std.testing.expectEqual(@as(usize, 1), packer.frames.items.len);

    const sprite0 = packer.sprites.items[0];
    const image0 = sprite0.image orelse return error.UnexpectedNullImage;
    try std.testing.expectEqual(@as(usize, 1), image0.width);
    try std.testing.expectEqual(@as(usize, 1), image0.height);
    try std.testing.expectEqual(@as(f32, 1.0), sprite0.origin[0]);
    try std.testing.expectEqual(@as(f32, 1.0), sprite0.origin[1]);

    const frame0 = packer.frames.items[0];
    try std.testing.expectEqual(@as(c_ushort, 1), frame0.w);
    try std.testing.expectEqual(@as(c_ushort, 1), frame0.h);
}

test "Packer.append: tighten preserves world-space anchor across cells" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // Single 16×16 cell, origin halfway across (8, 8).
    var file = try Internal.File.init("untitled-anchor", .{
        .columns = 1,
        .rows = 1,
        .column_width = 16,
        .row_height = 16,
    });
    defer deinitFile(&file);
    file.sprites.items(.origin)[0] = .{ 8.0, 8.0 };

    var layer = file.layers.get(0);
    const px = layer.pixels();
    // Paint a 4×2 block at (10, 9). Reducer should return (10, 9, 4, 2) — origin shifts by
    // (10, 9) → (-2, -1), which means "the pivot pixel sits 2 to the left and 1 above the
    // bitmap's top-left corner".
    var y: u32 = 9;
    while (y < 11) : (y += 1) {
        var x: u32 = 10;
        while (x < 14) : (x += 1) {
            px[y * 16 + x] = .{ 0, 0, 0, 255 };
        }
    }

    var packer = try pixelart.Packer.init(std.testing.allocator);
    defer packer.deinit();
    try packer.append(&file);

    try std.testing.expectEqual(@as(usize, 1), packer.sprites.items.len);
    const s = packer.sprites.items[0];
    try std.testing.expectEqual(@as(f32, -2.0), s.origin[0]);
    try std.testing.expectEqual(@as(f32, -1.0), s.origin[1]);

    // World-space pivot must equal the original (8, 8). Reduced rect starts at (10, 9), so
    // the new origin (-2, -1) plus that offset lands exactly on (8, 8).
    try std.testing.expectEqual(@as(f32, 8.0), s.origin[0] + 10.0);
    try std.testing.expectEqual(@as(f32, 8.0), s.origin[1] + 9.0);
}

test "Packer.append: tightened bitmap content matches the source pixels" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try Internal.File.init("untitled-bitmap", .{
        .columns = 1,
        .rows = 1,
        .column_width = 8,
        .row_height = 8,
    });
    defer deinitFile(&file);

    // Paint a 2x2 block of distinct colors at (3, 4).
    var layer = file.layers.get(0);
    const px = layer.pixels();
    px[4 * 8 + 3] = .{ 1, 2, 3, 255 };
    px[4 * 8 + 4] = .{ 11, 12, 13, 255 };
    px[5 * 8 + 3] = .{ 21, 22, 23, 255 };
    px[5 * 8 + 4] = .{ 31, 32, 33, 255 };

    var packer = try pixelart.Packer.init(std.testing.allocator);
    defer packer.deinit();
    try packer.append(&file);

    try std.testing.expectEqual(@as(usize, 1), packer.sprites.items.len);
    const img = packer.sprites.items[0].image orelse return error.UnexpectedNullImage;
    try std.testing.expectEqual(@as(usize, 2), img.width);
    try std.testing.expectEqual(@as(usize, 2), img.height);
    try std.testing.expectEqual(@as([4]u8, .{ 1, 2, 3, 255 }), img.pixels[0]);
    try std.testing.expectEqual(@as([4]u8, .{ 11, 12, 13, 255 }), img.pixels[1]);
    try std.testing.expectEqual(@as([4]u8, .{ 21, 22, 23, 255 }), img.pixels[2]);
    try std.testing.expectEqual(@as([4]u8, .{ 31, 32, 33, 255 }), img.pixels[3]);
}

test "Packer.append skips invisible layers" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try Internal.File.init("untitled-invis", .{
        .columns = 1,
        .rows = 1,
        .column_width = 4,
        .row_height = 4,
    });
    defer deinitFile(&file);

    var layer = file.layers.get(0);
    layer.pixels()[0] = .{ 255, 0, 0, 255 };
    file.layers.set(0, .{
        .id = layer.id,
        .name = layer.name,
        .source = layer.source,
        .mask = layer.mask,
        .visible = false,
        .collapse = layer.collapse,
        .dirty = layer.dirty,
    });

    var packer = try pixelart.Packer.init(std.testing.allocator);
    defer packer.deinit();
    try packer.append(&file);

    try std.testing.expectEqual(@as(usize, 0), packer.sprites.items.len);
    try std.testing.expectEqual(@as(usize, 0), packer.frames.items.len);
}

test "Packer.packRects: produced rects fit inside the texture and never overlap" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // Build several distinct sprites of varying sizes.
    var file = try Internal.File.init("untitled-pack", .{
        .columns = 4,
        .rows = 2,
        .column_width = 16,
        .row_height = 16,
    });
    defer deinitFile(&file);

    var layer = file.layers.get(0);
    const px = layer.pixels();
    const layer_w: u32 = file.width();
    // For each sprite cell paint a block whose size depends on the cell index. This produces
    // a mix of small/large reduced rects that exercise the rect-packer's bin selection.
    var s: u32 = 0;
    while (s < file.spriteCount()) : (s += 1) {
        const cell_col = s % file.columns;
        const cell_row = s / file.columns;
        const cell_x = cell_col * file.column_width;
        const cell_y = cell_row * file.row_height;
        const block_w: u32 = @as(u32, @intCast(s + 1)) * 2;
        const block_h: u32 = @as(u32, @intCast(s + 1));
        var y: u32 = 0;
        while (y < block_h) : (y += 1) {
            var x: u32 = 0;
            while (x < block_w) : (x += 1) {
                px[(cell_y + y) * layer_w + (cell_x + x)] = .{ 50, 100, 150, 255 };
            }
        }
    }

    var packer = try pixelart.Packer.init(std.testing.allocator);
    defer packer.deinit();
    try packer.append(&file);

    const tex_size = (try packer.packRects()) orelse return error.UnexpectedPackFailure;
    const tex_w: i32 = @intCast(tex_size[0]);
    const tex_h: i32 = @intCast(tex_size[1]);

    // Every frame must fit inside the texture and have w*h matching its image's pixel count.
    for (packer.frames.items, packer.sprites.items) |frame, sprite| {
        try std.testing.expect(frame.x >= 0);
        try std.testing.expect(frame.y >= 0);
        try std.testing.expect(@as(i32, frame.x) + @as(i32, frame.w) <= tex_w);
        try std.testing.expect(@as(i32, frame.y) + @as(i32, frame.h) <= tex_h);
        if (sprite.image) |img| {
            try std.testing.expectEqual(@as(usize, frame.w), img.width);
            try std.testing.expectEqual(@as(usize, frame.h), img.height);
        }
    }

    // No two frames overlap (axis-aligned rect intersection check on each pair).
    for (packer.frames.items, 0..) |a, ai| {
        for (packer.frames.items[ai + 1 ..]) |b| {
            const overlap_x = a.x < b.x + b.w and b.x < a.x + a.w;
            const overlap_y = a.y < b.y + b.h and b.y < a.y + a.h;
            try std.testing.expect(!(overlap_x and overlap_y));
        }
    }
}

// -------------------------------------------------------------------
// `applyGridLayout`: re-grids the document. The user called out origin math as a place where
// regressions silently corrupt downstream packing — for grow-with-anchor the cell-local pixel
// content must shift by `cellAnchoredBlit`'s offset and end up in the same anchored position.
// We paint a recognizable pixel, grow the cell, and assert it lands at the anchored location.
// -------------------------------------------------------------------
test "applyGridLayout grow with .c anchor centers the old cell content" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // 1×1 cell of 4×4 — paint the top-left corner red, then grow to 1×1 cell of 8×8 with
    // anchor .c. The 4×4 source should land at offset (2, 2) inside the new 8×8 cell.
    var file = try Internal.File.init("untitled-grid-grow", .{
        .columns = 1,
        .rows = 1,
        .column_width = 4,
        .row_height = 4,
    });
    defer deinitFile(&file);

    file.layers.get(0).pixels()[0] = .{ 7, 8, 9, 255 };

    try file.applyGridLayout(.{
        .column_width = 8,
        .row_height = 8,
        .columns = 1,
        .rows = 1,
        .anchor = .c,
        .history = false,
    });

    try std.testing.expectEqual(@as(u32, 8), file.column_width);
    try std.testing.expectEqual(@as(u32, 8), file.row_height);
    try std.testing.expectEqual(@as(usize, 1), file.layers.len);

    const new_px = file.layers.get(0).pixels();
    // Centered: the (0,0) pixel of the old cell is now at (2, 2) of the new cell.
    try std.testing.expectEqual(@as([4]u8, .{ 7, 8, 9, 255 }), new_px[2 * 8 + 2]);
    // Surrounding pixels are still the cleared default (alpha 0).
    try std.testing.expectEqual(@as(u8, 0), new_px[0][3]);
    try std.testing.expectEqual(@as(u8, 0), new_px[7 * 8 + 7][3]);
}

test "applyGridLayout shrink with .nw anchor keeps the top-left and crops south/east" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try Internal.File.init("untitled-grid-shrink", .{
        .columns = 1,
        .rows = 1,
        .column_width = 8,
        .row_height = 8,
    });
    defer deinitFile(&file);

    // Paint distinct pixels at the four corners of the 8×8 cell.
    const px = file.layers.get(0).pixels();
    px[0] = .{ 1, 1, 1, 255 }; // (0,0) NW
    px[7] = .{ 2, 2, 2, 255 }; // (7,0) NE
    px[7 * 8] = .{ 3, 3, 3, 255 }; // (0,7) SW
    px[7 * 8 + 7] = .{ 4, 4, 4, 255 }; // (7,7) SE

    try file.applyGridLayout(.{
        .column_width = 4,
        .row_height = 4,
        .columns = 1,
        .rows = 1,
        .anchor = .nw,
        .history = false,
    });

    try std.testing.expectEqual(@as(u32, 4), file.column_width);
    const new_px = file.layers.get(0).pixels();
    // NW anchor: kept the top-left 4x4 block. NW corner pixel survives, the other three were cropped.
    try std.testing.expectEqual(@as([4]u8, .{ 1, 1, 1, 255 }), new_px[0]);
    try std.testing.expectEqual(@as(u8, 0), new_px[3][3]); // bottom-right of new cell unpainted
}

test "applyGridLayout slice-only (same total pixels) preserves the bitmap and re-tiles cells" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    // 16×16 single cell with a recognizable pattern.
    var file = try Internal.File.init("untitled-slice-only", .{
        .columns = 1,
        .rows = 1,
        .column_width = 16,
        .row_height = 16,
    });
    defer deinitFile(&file);

    var i: usize = 0;
    const layer = file.layers.get(0);
    const px = layer.pixels();
    while (i < px.len) : (i += 1) {
        px[i] = .{ @as(u8, @intCast(i & 0xFF)), 0, 0, 255 };
    }

    // Re-grid as 2×2 cells of 8×8 — total pixel dims unchanged, so the bitmap must be
    // bit-identical (the slice path memcpys the whole layer rather than re-anchoring).
    try file.applyGridLayout(.{
        .column_width = 8,
        .row_height = 8,
        .columns = 2,
        .rows = 2,
        .anchor = .nw,
        .history = false,
    });

    try std.testing.expectEqual(@as(u32, 2), file.columns);
    try std.testing.expectEqual(@as(u32, 2), file.rows);
    try std.testing.expectEqual(@as(usize, 4), file.spriteCount());

    const after = file.layers.get(0).pixels();
    try std.testing.expectEqual(px.len, after.len);
    var j: usize = 0;
    while (j < after.len) : (j += 1) {
        try std.testing.expectEqual(@as(u8, @intCast(j & 0xFF)), after[j][0]);
        try std.testing.expectEqual(@as(u8, 255), after[j][3]);
    }
}

test "fillPoint on temporary layer leaves selected-layer mask cache alone" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try makeBlankFile(8, 8);
    defer deinitFile(&file);

    file.editor.mask_built_for_layer = file.selected_layer_index;

    // Drawing on the temporary layer never touches the selected
    // layer's pixels and so must NOT invalidate the cache.
    file.fillPoint(.{ .x = 1, .y = 1 }, .temporary, .{
        .color = .{ .r = 0, .g = 255, .b = 0, .a = 255 },
        .invalidate = false,
        .to_change = false,
    });

    try std.testing.expectEqual(
        @as(?usize, file.selected_layer_index),
        file.editor.mask_built_for_layer,
    );
}

test "Internal.Animation appendFrame, insertFrame, removeFrame" {
    const alloc = std.testing.allocator;

    var initial_frames = [_]pixelart.Animation.Frame{.{
        .sprite_index = 0,
        .ms = 100,
    }};
    var anim = try Internal.Animation.init(alloc, 1, "walk", initial_frames[0..]);
    defer anim.deinit(alloc);

    try anim.appendFrame(alloc, .{ .sprite_index = 1, .ms = 50 });
    var expect_two = [_]pixelart.Animation.Frame{
        .{ .sprite_index = 0, .ms = 100 },
        .{ .sprite_index = 1, .ms = 50 },
    };
    try std.testing.expect(anim.eqlFrames(expect_two[0..]));

    try anim.insertFrame(alloc, 1, .{ .sprite_index = 9, .ms = 12 });
    var expect_three = [_]pixelart.Animation.Frame{
        .{ .sprite_index = 0, .ms = 100 },
        .{ .sprite_index = 9, .ms = 12 },
        .{ .sprite_index = 1, .ms = 50 },
    };
    try std.testing.expect(anim.eqlFrames(expect_three[0..]));

    anim.removeFrame(alloc, 0);
    var expect_after_remove = [_]pixelart.Animation.Frame{
        .{ .sprite_index = 9, .ms = 12 },
        .{ .sprite_index = 1, .ms = 50 },
    };
    try std.testing.expect(anim.eqlFrames(expect_after_remove[0..]));
}

test "applyGridSliceOnly rejects degenerate and mismatched canvas proposals" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try makeBlankFile(8, 8);
    defer deinitFile(&file);

    try std.testing.expectError(error.InvalidGridLayout, file.applyGridSliceOnly(.{
        .column_width = 0,
        .row_height = 8,
        .columns = 1,
        .rows = 1,
        .history = false,
    }));

    try std.testing.expectError(error.InvalidGridLayout, file.applyGridSliceOnly(.{
        .column_width = 4,
        .row_height = 4,
        .columns = 1,
        .rows = 1,
        .history = false,
    }));

    try std.testing.expectError(error.InvalidGridLayout, file.applyGridSliceOnly(.{
        .column_width = 16,
        .row_height = 8,
        .columns = 1,
        .rows = 1,
        .history = false,
    }));
}

test "applyGridLayout history: undo and redo restore grid and pixels" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try Internal.File.init("untitled-grid-undo", .{
        .columns = 1,
        .rows = 1,
        .column_width = 4,
        .row_height = 4,
    });
    defer deinitFile(&file);

    file.editor.canvas.id = .zero;

    file.layers.get(0).pixels()[0] = .{ 7, 8, 9, 255 };

    try file.applyGridLayout(.{
        .column_width = 8,
        .row_height = 8,
        .columns = 1,
        .rows = 1,
        .anchor = .c,
        .history = true,
    });

    try std.testing.expectEqual(@as(u32, 8), file.column_width);
    const grown = file.layers.get(0).pixels();
    try std.testing.expectEqual(@as([4]u8, .{ 7, 8, 9, 255 }), grown[2 * 8 + 2]);

    try file.undo();

    try std.testing.expectEqual(@as(u32, 4), file.column_width);
    try std.testing.expectEqual(@as(u32, 4), file.row_height);
    const undone = file.layers.get(0).pixels();
    try std.testing.expectEqual(@as([4]u8, .{ 7, 8, 9, 255 }), undone[0]);

    try file.redo();

    try std.testing.expectEqual(@as(u32, 8), file.column_width);
    const redone = file.layers.get(0).pixels();
    try std.testing.expectEqual(@as([4]u8, .{ 7, 8, 9, 255 }), redone[2 * 8 + 2]);
}

test "saveZip / fromPathFizzy round-trip preserves grid metadata and layer pixels" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try Internal.File.init("untitled-zip", .{
        .columns = 2,
        .rows = 1,
        .column_width = 8,
        .row_height = 8,
    });
    defer deinitFile(&file);

    const px = file.layers.get(0).pixels();
    px[3 * 16 + 3] = .{ 11, 22, 33, 255 };

    fizzy.app.allocator.free(file.path);
    file.path = try fizzy.app.allocator.dupe(u8, ".zig-cache/fizzy_integration_zip_rt.pixi");

    try file.saveZip(ctx.app.window);

    const loaded_opt = try Internal.File.fromPathFizzy(file.path);
    var loaded = loaded_opt orelse return error.TestUnexpectedNull;
    defer deinitFile(&loaded);

    try std.testing.expectEqual(file.columns, loaded.columns);
    try std.testing.expectEqual(file.rows, loaded.rows);
    try std.testing.expectEqual(file.column_width, loaded.column_width);
    try std.testing.expectEqual(file.row_height, loaded.row_height);
    try std.testing.expectEqual(file.layers.len, loaded.layers.len);

    const round_px = loaded.layers.get(0).pixels();
    try std.testing.expectEqual(px.len, round_px.len);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(px), std.mem.sliceAsBytes(round_px));
}

test "Packer.append merges collapsed layer stack before reducing sprites" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try Internal.File.init("untitled-collapse-pack", .{
        .columns = 1,
        .rows = 1,
        .column_width = 8,
        .row_height = 8,
    });
    defer deinitFile(&file);

    file.layers.items(.collapse)[0] = true;

    const layer2 = try Internal.Layer.init(
        file.newLayerID(),
        "L2",
        file.width(),
        file.height(),
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .ptr,
    );
    try file.layers.append(fizzy.app.allocator, layer2);

    file.layers.items(.collapse)[1] = false;

    file.layers.items(.visible)[0] = true;
    file.layers.items(.visible)[1] = true;

    file.layers.get(0).pixels()[0] = .{ 255, 0, 0, 255 };
    file.layers.get(1).pixels()[7 * 8 + 7] = .{ 0, 255, 0, 255 };

    var packer = try pixelart.Packer.init(std.testing.allocator);
    defer packer.deinit();

    try packer.append(&file);

    try std.testing.expectEqual(@as(usize, 1), packer.sprites.items.len);
    const sprite0 = packer.sprites.items[0];
    const image0 = sprite0.image orelse return error.UnexpectedNullImage;
    try std.testing.expectEqual(@as(usize, 8), image0.width);
    try std.testing.expectEqual(@as(usize, 8), image0.height);
    try std.testing.expectEqual(@as([4]u8, .{ 255, 0, 0, 255 }), image0.pixels[0]);
    try std.testing.expectEqual(@as([4]u8, .{ 0, 255, 0, 255 }), image0.pixels[7 * 8 + 7]);
}

test "drawPoint with to_change records history; undo restores pixels" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    var file = try makeBlankFile(8, 8);
    defer deinitFile(&file);

    file.editor.canvas.id = .zero;

    // `drawPoint` reads plugin tools stroke size for stamps smaller than `min_full_stroke_size`;
    // the shim zero-fills the editor, so brush size must be set explicitly.
    pixelart.Globals.state.tools.stroke_size = 1;
    pixelart.Globals.state.tools.pencil_stroke_size = 1;

    const idx: usize = 3 * 8 + 4;

    try std.testing.expectEqual(@as(u8, 0), file.layers.get(0).pixels()[idx][3]);

    file.drawPoint(.{ .x = 4, .y = 3 }, .selected, .{
        .stroke_size = 1,
        .to_change = true,
        .invalidate = false,
        .mask_only = false,
        .color = .{ .r = 200, .g = 10, .b = 99, .a = 255 },
    });

    try std.testing.expectEqual(@as([4]u8, .{ 200, 10, 99, 255 }), file.layers.get(0).pixels()[idx]);

    try file.undo();

    try std.testing.expectEqual(@as(u8, 0), file.layers.get(0).pixels()[idx][3]);
}
