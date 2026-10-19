//! What a fizzy program written in Zig reads and writes, and the few GPU operations the Zig
//! compiler does not give a shader yet — a spike (`README.md` beside this): the interface of
//! `program_example.fragment.hlsl`, for Zig 0.17's self-hosted SPIR-V backend
//! (`-target spirv32-vulkan -fno-llvm`).
//!
//! * Inputs: the default vertex shader's colour and uv, locations 0 and 1.
//! * Textures: the draw's own at set 2, binding 0; `begin`'s at bindings 1 and 2.
//! * Uniforms: one block at set 3, binding 0, of `N` vec4s, read with `data(i)`.
//! * Output: one premultiplied colour, location 0.
const std = @import("std");

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

pub const Image2D = @SpirvType(.{ .image = .{
    .usage = .{ .sampled = f32 },
    .format = .unknown,
    .dim = .@"2d",
    .depth = .not_depth,
    .access = .unknown,
    .arrayed = false,
    .multisampled = false,
} });
pub const Texture = @SpirvType(.{ .sampled_image = Image2D });

pub const color = @extern(*addrspace(.input) Vec4, .{ .name = "color", .decoration = .{ .location = 0 } });
pub const uv = @extern(*addrspace(.input) Vec2, .{ .name = "uv", .decoration = .{ .location = 1 } });
pub const out = @extern(*addrspace(.output) Vec4, .{ .name = "out_color", .decoration = .{ .location = 0 } });

/// The draw's own texture (white where it has none), and `begin`'s two. Constants, made once at
/// comptime: `texture(binding)` called from the shader, returning the `@extern`, crashed the
/// compiler.
pub const texture0 = textureAt("uSampler", 0);
pub const texture1 = textureAt("uTex1", 1);
pub const texture2 = textureAt("uTex2", 2);

fn textureAt(comptime name: []const u8, comptime binding: u32) *addrspace(.constant) Texture {
    return @extern(*addrspace(.constant) Texture, .{
        .name = name,
        .decoration = .{ .descriptor = .{ .set = 2, .binding = binding } },
    });
}

/// The program's uniforms: `n` vec4s.
pub fn Uniforms(comptime n: u32) type {
    return struct {
        const Block = extern struct { data: [n]Vec4 };
        const block = @extern(*addrspace(.uniform) Block, .{
            .name = "uData",
            .decoration = .{ .descriptor = .{ .set = 3, .binding = 0 } },
        });

        /// `data[i]`. Written as SPIR-V by hand: indexing an array in a uniform block
        /// (`block.data[i]`) gives the element's pointer the array's type — the module fails
        /// `spirv-val` — and copying the block out first (`block.*`) needs SPIR-V 1.4
        /// (`OpCopyLogical`) and a copy of every vec4 at every pixel. The zero is passed as a
        /// value: as a `"c"` constant here, it came out as id 0.
        pub fn data(i: u32) Vec4 {
            return asm volatile (
                \\%p   = OpAccessChain %Ptr %block %zero %i
                \\%ret = OpLoad %Vec4 %p
                : [ret] "" (-> Vec4),
                : [Ptr] "t" (*addrspace(.uniform) Vec4),
                  [Vec4] "t" (Vec4),
                  [block] "" (block),
                  [zero] "" (@as(u32, 0)),
                  [i] "" (i),
            );
        }
    };
}

/// Sample with an implicit level (derivatives: not after a `discard`).
pub fn sample(tex: *addrspace(.constant) Texture, at: Vec2) Vec4 {
    return std.spirv.imageSampleImplicitLod(tex, at);
}

/// Sample level `lod` — HLSL's `SampleLevel`, which `std.spirv` does not have.
pub fn sampleLevel(tex: *addrspace(.constant) Texture, at: Vec2, lod: f32) Vec4 {
    return asm volatile (
        \\%t   = OpLoad %Texture %tex
        \\%ret = OpImageSampleExplicitLod %Vec4 %t %at Lod %lod
        : [ret] "" (-> Vec4),
        : [Texture] "t" (Texture),
          [Vec4] "t" (Vec4),
          [tex] "" (tex),
          [at] "" (at),
          [lod] "" (lod),
    );
}

/// HLSL's `discard`: the pixel is not written. `OpKill` ends its block; the label after it opens
/// one for the `unreachable` Zig emits next. Called, not inlined: inlined, what follows it depends
/// on the function round it and on `-fstrip`, and came out as an instruction after a block's end.
pub noinline fn discard() noreturn {
    asm volatile (
        \\OpKill
        \\%dead = OpLabel
    );
    unreachable;
}

// What HLSL and GLSL have built in and Zig does not: no swizzles, no scalar-vector arithmetic,
// no `lerp`, `dot`, `length`, `normalize`, `smoothstep`, `frac`.

pub fn splat2(x: f32) Vec2 {
    return @splat(x);
}
pub fn splat4(x: f32) Vec4 {
    return @splat(x);
}
pub fn dot(a: anytype, b: @TypeOf(a)) f32 {
    return @reduce(.Add, a * b);
}
pub fn length(a: anytype) f32 {
    return @sqrt(dot(a, a));
}
pub fn normalize(a: anytype) @TypeOf(a) {
    return a / @as(@TypeOf(a), @splat(length(a)));
}
pub fn lerp(a: anytype, b: @TypeOf(a), t: f32) @TypeOf(a) {
    return switch (@typeInfo(@TypeOf(a))) {
        .vector => a + (b - a) * @as(@TypeOf(a), @splat(t)),
        else => a + (b - a) * t,
    };
}
pub fn clamp(x: f32, lo: f32, hi: f32) f32 {
    return @min(@max(x, lo), hi);
}
pub fn clamp01(v: anytype) @TypeOf(v) {
    const T = @TypeOf(v);
    return @min(@max(v, @as(T, @splat(0))), @as(T, @splat(1)));
}
pub fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}
pub fn frac(x: f32) f32 {
    return x - @floor(x);
}
