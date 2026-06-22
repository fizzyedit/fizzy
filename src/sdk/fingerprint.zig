//! Compile-time structural fingerprint of the plugin ABI boundary.
//!
//! Host and plugin each compile their own copy of the SDK + dvui types, then each
//! computes this fingerprint from those types. The loader rejects any plugin whose
//! fingerprint differs from the host's, so an incompatible layout — a changed vtable
//! hook signature, a reordered struct field, a different dvui struct size — is caught
//! at load time instead of corrupting memory at runtime. This replaces a hand-bumped
//! `abi_version` integer: there is nothing to remember to bump.
//!
//! **Name-free by design.** The hash folds in only `@sizeOf`, `@alignOf`, field
//! names/offsets, enum tag layout, and function-pointer *signatures* (parameter and
//! return types, recursively). It deliberately never hashes `@typeName`, because the
//! host links `dvui_sdl3` while a plugin links `dvui_proxy`; those carry different
//! module-qualified type names for structurally identical types, and hashing names
//! would reject every plugin. Field names come straight from shared source, so they
//! are safe to hash.
//!
//! **What it catches / misses.** Any change to a listed type's size/alignment, its
//! field set/order/offsets, or a vtable hook's parameter or return *types* changes the
//! fingerprint. A signature change that swaps one parameter type for another of the
//! same size/alignment is not caught — acceptable for a load-time guard. Every data
//! type that crosses the boundary should appear in the caller's root list so its own
//! layout is folded in directly (the per-field walk records a field's structural shape
//! one level down, not the full transitive layout of an arbitrarily nested type).
const std = @import("std");

/// FNV-1a 64-bit offset basis. Callers seed their accumulator with this.
pub const seed: u64 = 0xcbf29ce484222325;

const prime: u64 = 0x00000100000001b3;

fn mixByte(h: u64, b: u8) u64 {
    return (h ^ b) *% prime;
}

fn mixStr(h_in: u64, s: []const u8) u64 {
    var h = h_in;
    for (s) |b| h = mixByte(h, b);
    return h;
}

fn mixU64(h_in: u64, v: u64) u64 {
    var h = h_in;
    var x = v;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        h = mixByte(h, @intCast(x & 0xff));
        x >>= 8;
    }
    return h;
}

/// Fold every type in `types` (an anonymous tuple of `type`) into `h_in` at `depth`.
/// `depth` bounds how far function-pointer signatures and by-value aggregates are
/// followed; data types should be listed at a depth that reaches their fields, while
/// large opaque-by-pointer types (e.g. `dvui.Window`) can be folded at depth 0 (size
/// + alignment only), matching the original size-based dvui check.
pub fn hashAll(h_in: u64, comptime types: anytype, comptime depth: comptime_int) u64 {
    comptime {
        var h = h_in;
        for (types) |T| h = hashType(h, T, depth);
        return h;
    }
}

fn hashType(h_in: u64, comptime T: type, comptime depth: comptime_int) u64 {
    comptime {
        const info = @typeInfo(T);
        var h = mixU64(h_in, @intFromEnum(std.meta.activeTag(info)));
        // Bare function and opaque types are comptime-only / unsized; everything else
        // reached here has a concrete size and alignment worth folding in.
        if (info != .@"fn" and info != .@"opaque") {
            h = mixU64(h, @sizeOf(T));
            h = mixU64(h, @alignOf(T));
        }
        if (depth <= 0) return h;

        switch (info) {
            .@"struct" => |s| {
                h = mixU64(h, s.fields.len);
                for (s.fields, 0..) |f, i| {
                    h = mixStr(h, f.name);
                    // Packed structs have no byte offsets; fall back to declaration order.
                    h = mixU64(h, if (s.layout == .@"packed") i else @offsetOf(T, f.name));
                    h = hashType(h, f.type, depth - 1);
                }
            },
            .@"union" => |u| {
                h = mixU64(h, u.fields.len);
                for (u.fields) |f| {
                    h = mixStr(h, f.name);
                    h = hashType(h, f.type, depth - 1);
                }
            },
            .@"enum" => |e| {
                h = mixU64(h, e.fields.len);
                for (e.fields, 0..) |f, i| {
                    h = mixStr(h, f.name);
                    h = mixU64(h, i);
                }
            },
            .optional => |o| h = hashType(h, o.child, depth - 1),
            .array => |a| {
                h = mixU64(h, a.len);
                h = hashType(h, a.child, depth - 1);
            },
            .pointer => |p| {
                h = mixU64(h, @intFromEnum(p.size));
                h = mixU64(h, @intFromBool(p.is_const));
                // Follow function pointers so vtable hook signatures are part of the
                // hash, but never follow data pointers: that would deep-walk types we
                // only pass by reference (e.g. `*dvui.Window`) and risk reference cycles.
                if (@typeInfo(p.child) == .@"fn") h = hashType(h, p.child, depth - 1);
            },
            .@"fn" => |fninfo| {
                h = mixU64(h, @intFromEnum(std.meta.activeTag(fninfo.calling_convention)));
                h = mixU64(h, fninfo.params.len);
                for (fninfo.params) |param| {
                    if (param.type) |pt| {
                        h = hashType(h, pt, depth - 1);
                    } else {
                        h = mixStr(h, "anytype");
                    }
                }
                if (fninfo.return_type) |rt| h = hashType(h, rt, depth - 1);
            },
            else => {},
        }
        return h;
    }
}

test "fingerprint is stable and order-sensitive" {
    const A = struct { x: u32, y: u64 };
    const B = struct { y: u64, x: u32 };
    const a = comptime hashAll(seed, .{A}, 4);
    const a2 = comptime hashAll(seed, .{A}, 4);
    const b = comptime hashAll(seed, .{B}, 4);
    try std.testing.expectEqual(a, a2);
    try std.testing.expect(a != b); // field reorder changes the fingerprint
    try std.testing.expect(a != seed);
}

test "fingerprint catches function-pointer signature changes" {
    const V1 = struct { call: *const fn (u32) void };
    const V2 = struct { call: *const fn (u64) void };
    const v1 = comptime hashAll(seed, .{V1}, 6);
    const v2 = comptime hashAll(seed, .{V2}, 6);
    try std.testing.expect(v1 != v2);
}
