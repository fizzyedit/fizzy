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

/// Fold a raw string into an accumulator — for mixing in non-type discriminants alongside a
/// type hash (e.g. the optimize-mode safety class in `dylib.abi_fingerprint`). Same FNV-1a step
/// the type walks use, so it composes with `hashAll`/`hashAllShape` results.
pub fn foldString(h: u64, s: []const u8) u64 {
    return mixStr(h, s);
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

/// Fold every type in `types` into `h_in`, hashing only target- and optimize-mode-*invariant*
/// declaration shape: field names, field position (not byte offset), integer bit-width and
/// signedness (except pointer-sized `usize`/`isize`, which are canonicalized to width-free tokens
/// so a 64-bit host and a 32-bit wasm32 build agree), enum tag names, pointer kind/constness, and
/// function calling-convention + parameter/return shapes. Deliberately never touches
/// `@sizeOf`/`@alignOf`/`@offsetOf` — those
/// vary with arch/os (pointer width, struct padding) and even with optimize mode alone (e.g.
/// `std.HashMapUnmanaged` carries a `pointer_stability: std.debug.SafetyLock` field that is
/// zero-sized under `ReleaseFast`/`ReleaseSmall` but not under `Debug`/`ReleaseSafe`, which
/// shifts sibling field offsets with no boundary change involved). A single value from this
/// function is therefore valid to record and check regardless of which target or optimize mode
/// compiles it — unlike `hashAll`, whose result is real memory-layout information and must be
/// (and is, via `dylib.abi_fingerprint`) recomputed live on both sides of the plugin boundary at
/// load time rather than checked against a recorded literal.
pub fn hashAllShape(h_in: u64, comptime types: anytype, comptime depth: comptime_int) u64 {
    comptime {
        var h = h_in;
        for (types) |T| h = hashTypeShape(h, T, depth);
        return h;
    }
}

/// `callconv(.c)` is sugar for `std.builtin.CallingConvention.c`, which is itself
/// `builtin.target.cCallingConvention().?` — a *concrete*, target-specific tag (e.g.
/// `.x86_64_sysv` on Linux/macOS x86_64, `.x86_64_win` on Windows, `.aarch64_aapcs_darwin` on
/// Apple aarch64). So two hook signatures declared identically as `callconv(.c)` report
/// different `@typeInfo` tags depending only on which target compiled them — exactly the kind of
/// target-specificity `hashTypeShape` exists to ignore. Canonicalize that one case back to a
/// single key; every other calling convention (`.auto`, `.naked`, `.@"inline"`, ...) is already
/// target-invariant and is hashed as-is.
fn callingConventionShapeKey(cc: std.builtin.CallingConvention) u64 {
    if (std.meta.eql(cc, std.builtin.CallingConvention.c)) return 0;
    return 1 + @intFromEnum(std.meta.activeTag(cc));
}

/// `std.debug.SafetyLock.state`'s enum has a *different tag set* in safety builds
/// (`.unlocked`/`.locked`) than in non-safety builds (`.unknown`) — see `lib/std/debug.zig`. It
/// is a debug-only assertion helper embedded inside `std.HashMapUnmanaged` /
/// `std.ArrayHashMapUnmanaged` (as `pointer_stability`), which several boundary types (`Host`,
/// `dvui.Window`) hold by value. A plugin never reads it — it exists purely to assert against
/// concurrent mutation during iteration — so exclude its internals from this target/mode-
/// invariant hash; otherwise every Fizzy struct embedding a hash map by value would spuriously
/// flag a "boundary change" on every Debug/ReleaseSafe vs ReleaseFast/ReleaseSmall build.
fn hashFieldTypeShape(h_in: u64, comptime FieldType: type, comptime depth: comptime_int) u64 {
    if (FieldType == std.debug.SafetyLock) return mixStr(h_in, "std.debug.SafetyLock");
    return hashTypeShape(h_in, FieldType, depth);
}

fn hashTypeShape(h_in: u64, comptime T: type, comptime depth: comptime_int) u64 {
    comptime {
        const info = @typeInfo(T);
        var h = mixU64(h_in, @intFromEnum(std.meta.activeTag(info)));
        switch (info) {
            .int => {
                // `usize`/`isize` are pointer-width: 64-bit on native, 32-bit on wasm32. Hashing
                // their concrete `.bits` would make this "target-invariant" fingerprint diverge
                // per target — and they are reached constantly (every `std` container holds
                // `usize` len/capacity fields), which is exactly why the recorded native literal
                // never matched a wasm32 build. Canonicalize them to a stable, width-free token.
                // They are distinct Zig types from `u32`/`u64` (`usize == u64` is `false`), so a
                // boundary field that genuinely wants a fixed width still uses `u32`/`u64` and is
                // hashed by bit-width as before, staying distinguishable from `usize`/`isize`.
                if (T == usize) {
                    h = mixStr(h, "usize");
                } else if (T == isize) {
                    h = mixStr(h, "isize");
                } else {
                    const i = info.int;
                    h = mixU64(h, @intFromEnum(i.signedness));
                    h = mixU64(h, i.bits);
                }
            },
            .float => |f| h = mixU64(h, f.bits),
            else => {},
        }
        if (depth <= 0) return h;

        switch (info) {
            .@"struct" => |s| {
                h = mixU64(h, s.fields.len);
                for (s.fields, 0..) |f, i| {
                    h = mixStr(h, f.name);
                    h = mixU64(h, i); // declaration position, never a byte offset
                    h = hashFieldTypeShape(h, f.type, depth - 1);
                }
            },
            .@"union" => |u| {
                h = mixU64(h, u.fields.len);
                for (u.fields, 0..) |f, i| {
                    h = mixStr(h, f.name);
                    h = mixU64(h, i);
                    h = hashFieldTypeShape(h, f.type, depth - 1);
                }
            },
            .@"enum" => |e| {
                h = mixU64(h, e.fields.len);
                for (e.fields, 0..) |f, i| {
                    h = mixStr(h, f.name);
                    h = mixU64(h, i);
                }
            },
            .optional => |o| h = hashTypeShape(h, o.child, depth - 1),
            .array => |a| {
                h = mixU64(h, a.len);
                h = hashTypeShape(h, a.child, depth - 1);
            },
            .pointer => |p| {
                h = mixU64(h, @intFromEnum(p.size));
                h = mixU64(h, @intFromBool(p.is_const));
                if (@typeInfo(p.child) == .@"fn") h = hashTypeShape(h, p.child, depth - 1);
            },
            .@"fn" => |fninfo| {
                h = mixU64(h, callingConventionShapeKey(fninfo.calling_convention));
                h = mixU64(h, fninfo.params.len);
                for (fninfo.params) |param| {
                    if (param.type) |pt| {
                        h = hashTypeShape(h, pt, depth - 1);
                    } else {
                        h = mixStr(h, "anytype");
                    }
                }
                if (fninfo.return_type) |rt| h = hashTypeShape(h, rt, depth - 1);
            },
            else => {},
        }
        return h;
    }
}

test "shape fingerprint is stable and order-sensitive" {
    const A = struct { x: u32, y: u64 };
    const B = struct { y: u64, x: u32 };
    const a = comptime hashAllShape(seed, .{A}, 4);
    const a2 = comptime hashAllShape(seed, .{A}, 4);
    const b = comptime hashAllShape(seed, .{B}, 4);
    try std.testing.expectEqual(a, a2);
    try std.testing.expect(a != b); // field reorder changes the shape fingerprint
    try std.testing.expect(a != seed);
}

test "shape fingerprint catches bit-width changes despite ignoring @sizeOf" {
    const V1 = struct { x: u32 };
    const V2 = struct { x: u64 };
    const v1 = comptime hashAllShape(seed, .{V1}, 4);
    const v2 = comptime hashAllShape(seed, .{V2}, 4);
    try std.testing.expect(v1 != v2);
}

test "shape fingerprint catches function-pointer signature changes" {
    const V1 = struct { call: *const fn (u32) void };
    const V2 = struct { call: *const fn (u64) void };
    const v1 = comptime hashAllShape(seed, .{V1}, 6);
    const v2 = comptime hashAllShape(seed, .{V2}, 6);
    try std.testing.expect(v1 != v2);
}

test "shape fingerprint treats usize/isize as target-width-invariant tokens" {
    // The point of the pointer-width canonicalization: `usize` must not hash like whatever
    // fixed-width int it happens to alias on the current target, or the recorded literal would
    // drift between a 64-bit host and a 32-bit (wasm32) build.
    const WithUsize = struct { n: usize };
    const WithU64 = struct { n: u64 };
    const WithU32 = struct { n: u32 };
    const usize_fp = comptime hashAllShape(seed, .{WithUsize}, 4);
    // Distinct from every fixed width — a boundary can still choose an explicit width and be told
    // apart from a `usize` field.
    try std.testing.expect(usize_fp != comptime hashAllShape(seed, .{WithU64}, 4));
    try std.testing.expect(usize_fp != comptime hashAllShape(seed, .{WithU32}, 4));

    const WithIsize = struct { n: isize };
    const WithI64 = struct { n: i64 };
    const isize_fp = comptime hashAllShape(seed, .{WithIsize}, 4);
    try std.testing.expect(isize_fp != usize_fp);
    try std.testing.expect(isize_fp != comptime hashAllShape(seed, .{WithI64}, 4));
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
