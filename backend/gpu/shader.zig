//! Shaders by format: what a device accepts, what a program ships, and the pick between them.
//!
//! A device compiles one *format* of shader code and says which (`Caps.shader_formats`). A
//! program is shipped as a `Set`, the same shader in as many formats as its author made;
//! `resolve` picks the code a device takes. A format missing from the set can be
//! derived from SPIR-V by a `Translator` (SPIRV-Cross to MSL or HLSL, then `D3DCompile` for
//! DXBC), which is how a shader written in Zig, compiled to SPIR-V alone (`fizzyedit/fizzy#658`),
//! reaches Metal and D3D12 with no other offline step.
const std = @import("std");
const types = @import("types.zig");

pub const Format = enum {
    /// Vulkan's; also what Zig's SPIR-V backend emits.
    spirv,
    /// Metal source. The entry point is `main0` where SPIRV-Cross or shadercross made it.
    msl,
    /// D3D12's compiled shaders (DXC).
    dxil,
    /// D3D12 through `D3DCompile` (shader model 5.1): no DXC to ship.
    dxbc,

    /// The name a shader written for fizzy's programs calls its entry point.
    pub fn defaultEntry(self: Format) [:0]const u8 {
        return if (self == .msl) "main0" else "main";
    }
};

pub const Formats = std.EnumSet(Format);

/// Compiled code in one format.
pub const Code = struct {
    format: Format,
    bytes: []const u8,
    entry: [:0]const u8,
};

/// A shader in each format its author made. Borrowed: the bytes outlive the set (`@embedFile`
/// data does).
///
/// Resource binding is one convention for every format: a vertex shader's sampled textures are
/// set 0 and uniform buffers set 1, a fragment shader's are sets 2 and 3, each numbered from
/// binding 0 (the numbering SDL_GPU documents for SPIR-V, and the registers SPIRV-Cross keeps
/// when it makes HLSL: `t0/s0, space2` and `b0, space3`). A shader that breaks it fails to
/// create, not to compile.
pub const Set = struct {
    spirv: ?[]const u8 = null,
    msl: ?[]const u8 = null,
    dxil: ?[]const u8 = null,
    dxbc: ?[]const u8 = null,

    pub fn get(self: Set, format: Format) ?[]const u8 {
        const bytes = switch (format) {
            .spirv => self.spirv,
            .msl => self.msl,
            .dxil => self.dxil,
            .dxbc => self.dxbc,
        } orelse return null;
        return if (bytes.len == 0) null else bytes;
    }
};

/// Makes `to` from SPIR-V. The result is borrowed from the translator until its next call, so a
/// caller that keeps it copies it. Null: it cannot (no translator for `to`, or the module was
/// refused).
pub const Translator = struct {
    ctx: *anyopaque,
    translate: *const fn (ctx: *anyopaque, spirv: []const u8, to: Format, stage: types.ShaderStage) ?[]const u8,
};

/// What fizzy's renderer prefers when a device takes several: the order `GpuRenderer.create`
/// picks in, with DXBC last (only a device that lists it, and only for derived code).
pub const default_preference = [_]Format{ .msl, .spirv, .dxil, .dxbc };

/// The code in the first of `preference` that `supported` has: shipped, else made from the
/// set's SPIR-V by `translator`. Null when there is none.
pub fn resolve(
    set: Set,
    supported: Formats,
    preference: []const Format,
    stage: types.ShaderStage,
    translator: ?Translator,
) ?Code {
    for (preference) |format| {
        if (!supported.contains(format)) continue;
        if (set.get(format)) |bytes| return .{ .format = format, .bytes = bytes, .entry = format.defaultEntry() };
    }
    const tr = translator orelse return null;
    const spirv = set.get(.spirv) orelse return null;
    for (preference) |format| {
        if (format == .spirv or !supported.contains(format)) continue;
        if (tr.translate(tr.ctx, spirv, format, stage)) |bytes| {
            return .{ .format = format, .bytes = bytes, .entry = format.defaultEntry() };
        }
    }
    return null;
}

test "resolve takes the first preferred format the device has and the set ships" {
    const set: Set = .{ .spirv = "spv", .dxil = "dx" };
    const vulkan = Formats.initOne(.spirv);
    const code = resolve(set, vulkan, &default_preference, .fragment, null).?;
    try std.testing.expectEqual(Format.spirv, code.format);
    try std.testing.expectEqualStrings("main", code.entry);

    const both = Formats.init(.{ .spirv = true, .dxil = true });
    try std.testing.expectEqual(Format.spirv, resolve(set, both, &default_preference, .fragment, null).?.format);
    try std.testing.expectEqual(Format.dxil, resolve(set, both, &.{ .dxil, .spirv }, .fragment, null).?.format);
}

test "resolve never hands out a format the device lacks, or an empty one" {
    const metal = Formats.initOne(.msl);
    try std.testing.expect(resolve(.{ .spirv = "spv" }, metal, &default_preference, .fragment, null) == null);
    try std.testing.expect(resolve(.{ .msl = "" }, metal, &default_preference, .fragment, null) == null);
    const code = resolve(.{ .msl = "msl" }, metal, &default_preference, .fragment, null).?;
    try std.testing.expectEqualStrings("main0", code.entry);
}

test "resolve derives a missing format from SPIR-V through the translator" {
    const Fake = struct {
        calls: u32 = 0,
        fn translate(ctx: *anyopaque, spirv: []const u8, to: Format, _: types.ShaderStage) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            std.debug.assert(std.mem.eql(u8, spirv, "spv"));
            return if (to == .msl) "from-spirv" else null;
        }
    };
    var fake: Fake = .{};
    const tr: Translator = .{ .ctx = &fake, .translate = Fake.translate };
    // A Zig-compiled shader: SPIR-V only. Metal gets MSL; D3D12 (no DXBC translation) gets none.
    const zig_shader: Set = .{ .spirv = "spv" };
    const code = resolve(zig_shader, Formats.initOne(.msl), &default_preference, .fragment, tr).?;
    try std.testing.expectEqual(Format.msl, code.format);
    try std.testing.expectEqualStrings("from-spirv", code.bytes);
    try std.testing.expect(resolve(zig_shader, Formats.initOne(.dxbc), &default_preference, .fragment, tr) == null);
    // Shipped code wins, and the translator is not asked.
    fake.calls = 0;
    _ = resolve(.{ .spirv = "spv", .msl = "m" }, Formats.initOne(.msl), &default_preference, .fragment, tr);
    try std.testing.expectEqual(@as(u32, 0), fake.calls);
}
