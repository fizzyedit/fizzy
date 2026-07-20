//! Comptime settings API for plugins — Zig build-options-style declaration.
//!
//!   const MySettings = sdk.settings.Schema(struct {
//!       insert_spaces_on_tab: bool = true,
//!       tab_size: u8 = 4,
//!       format_on_save: bool = false,
//!   });
//!   MySettings.load(host, plugin.id, &values);
//!   try MySettings.register(host, &plugin, .{ .title = "Text Editor", .value = &values });
//!
//! Plugins register a typed value + field metadata only. The **shell** draws a shared
//! settings UI from `SettingsSchema.fields` (see `PluginSettingsPane`) — plugins do not
//! supply a `draw` callback.
//!
//! Loaded-only: a `SettingsSchema` exists in the Host registry only while the plugin is
//! registered.
const std = @import("std");
const dvui = @import("dvui");
const Plugin = @import("Plugin.zig");
const runtime = @import("runtime.zig");

pub const TypeTag = enum { bool, int, float, string, enumeration, color };

pub const IntKind = struct {
    min: i64,
    max: i64,
    /// A small discrete set (e.g. tab widths 2/4/8); empty = free slider/entry.
    choices: []const i64 = &.{},
};

pub const FloatKind = struct {
    min: f64 = 0,
    max: f64 = 1,
    step: f64 = 0.01,
};

pub const EnumKind = struct {
    /// Tag names in declaration order.
    choices: []const []const u8,
};

/// Per-type metadata for a `Setting` — only the variant matching `Setting.kind`'s active tag
/// is populated, so (say) a `bool` setting no longer carries meaningless `int`/`float` bounds.
pub const Kind = union(TypeTag) {
    bool: void,
    int: IntKind,
    float: FloatKind,
    string: void,
    enumeration: EnumKind,
    color: void,
};

pub const Setting = struct {
    key: []const u8,
    label: []const u8,
    kind: Kind,
};

/// Type-erased read/write of a `Schema(T).Value` for the shell's generic settings UI.
pub const Access = struct {
    getBool: *const fn (value: *anyopaque, field_index: usize) bool,
    setBool: *const fn (value: *anyopaque, field_index: usize, v: bool) void,
    getInt: *const fn (value: *anyopaque, field_index: usize) i64,
    setInt: *const fn (value: *anyopaque, field_index: usize, v: i64) void,
    getFloat: *const fn (value: *anyopaque, field_index: usize) f64,
    setFloat: *const fn (value: *anyopaque, field_index: usize, v: f64) void,
    getEnumIndex: *const fn (value: *anyopaque, field_index: usize) usize,
    setEnumIndex: *const fn (value: *anyopaque, field_index: usize, choice_index: usize) void,
    getString: *const fn (value: *anyopaque, field_index: usize) []const u8,
    setString: *const fn (value: *anyopaque, field_index: usize, v: []const u8) void,
    /// Persist `value` via `host.storePluginSettings(owner.id, zon)` and notify `owner`.
    persist: *const fn (value: *anyopaque, owner: *Plugin) void,
};

pub const SettingsSchema = struct {
    owner: *Plugin,
    title: []const u8,
    fields: []const Setting,
    /// Pointer to the plugin's `Schema(T).Value` (stable for the loaded lifetime).
    value: *anyopaque,
    access: *const Access,
};

fn typeTagFor(comptime T: type) TypeTag {
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int => .int,
        .float => .float,
        .@"enum" => .enumeration,
        .pointer => |p| if (p.size == .slice and p.child == u8)
            .string
        else
            @compileError("sdk.settings.Schema: unsupported field type " ++ @typeName(T)),
        else => @compileError("sdk.settings.Schema: unsupported field type " ++ @typeName(T)),
    };
}

fn intBounds(comptime IntT: type) struct { min: i64, max: i64 } {
    const info = @typeInfo(IntT).int;
    if (info.signedness == .signed) {
        return .{ .min = std.math.minInt(IntT), .max = std.math.maxInt(IntT) };
    }
    const max_u64: u64 = std.math.maxInt(IntT);
    const max: i64 = if (max_u64 > @as(u64, std.math.maxInt(i64))) std.math.maxInt(i64) else @intCast(max_u64);
    return .{ .min = 0, .max = max };
}

fn enumChoices(comptime EnumT: type) []const []const u8 {
    const enum_fields = std.meta.fields(EnumT);
    comptime var names: [enum_fields.len][]const u8 = undefined;
    inline for (enum_fields, 0..) |f, i| names[i] = f.name;
    const frozen = names;
    return &frozen;
}

/// Derive a field's `Kind` from its Zig type. `int`/`enumeration` get bounds/choices for free
/// from the type itself (bit-width, tag names); `float` has no such source (a bare `f32` carries
/// no notion of range), so it falls back to `FloatKind`'s defaults (0..1, step 0.01).
fn kindFor(comptime T: type) Kind {
    return switch (typeTagFor(T)) {
        .bool => .{ .bool = {} },
        .int => .{ .int = .{ .min = intBounds(T).min, .max = intBounds(T).max } },
        .float => .{ .float = .{} },
        .string => .{ .string = {} },
        .enumeration => .{ .enumeration = .{ .choices = enumChoices(T) } },
        .color => .{ .color = {} },
    };
}

fn buildSettings(comptime T: type) [std.meta.fields(T).len]Setting {
    const struct_fields = std.meta.fields(T);
    var out: [struct_fields.len]Setting = undefined;
    inline for (struct_fields, 0..) |f, i| {
        out[i] = .{
            .key = f.name,
            .label = f.name,
            .kind = kindFor(f.type),
        };
    }
    return out;
}

/// Build a settings namespace for plain struct `T`.
pub fn Schema(comptime T: type) type {
    const struct_fields = std.meta.fields(T);
    const built_settings = buildSettings(T);

    return struct {
        pub const Value = T;
        pub const settings: []const Setting = &built_settings;

        pub fn load(host: anytype, id: []const u8, out: *T) void {
            const blob = host.loadPluginSettings(id) orelse return;
            defer host.allocator.free(blob);
            applyZon(out, blob);
        }

        pub fn store(host: anytype, id: []const u8, value: T) void {
            const gpa = host.allocator;
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            std.zon.stringify.serialize(value, .{}, &aw.writer) catch |err| {
                dvui.log.warn("sdk.settings: failed to serialize '{s}': {s}", .{ id, @errorName(err) });
                return;
            };
            host.storePluginSettings(id, aw.written()) catch |err| {
                dvui.log.warn("sdk.settings: failed to store '{s}': {s}", .{ id, @errorName(err) });
            };
        }

        pub fn applyZon(out: *T, blob: []const u8) void {
            const gpa = runtime.allocator();
            const blob_z = gpa.dupeZ(u8, blob) catch |err| {
                dvui.log.warn("sdk.settings: out of memory parsing settings: {s}", .{@errorName(err)});
                return;
            };
            defer gpa.free(blob_z);

            const parsed = std.zon.parse.fromSliceAlloc(T, gpa, blob_z, null, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                dvui.log.warn("sdk.settings: failed to parse settings: {s}", .{@errorName(err)});
                return;
            };
            std.zon.parse.free(gpa, out.*);
            out.* = parsed;
        }

        fn asValue(ptr: *anyopaque) *T {
            return @ptrCast(@alignCast(ptr));
        }

        fn getBool(ptr: *anyopaque, field_index: usize) bool {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) != .bool) return false;
                    return @field(v.*, f.name);
                }
            }
            return false;
        }

        fn setBool(ptr: *anyopaque, field_index: usize, b: bool) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) == .bool) @field(v.*, f.name) = b;
                    return;
                }
            }
        }

        fn getInt(ptr: *anyopaque, field_index: usize) i64 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) != .int) return 0;
                    return @intCast(@field(v.*, f.name));
                }
            }
            return 0;
        }

        fn setInt(ptr: *anyopaque, field_index: usize, n: i64) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) == .int) {
                        @field(v.*, f.name) = std.math.cast(f.type, n) orelse @field(v.*, f.name);
                    }
                    return;
                }
            }
        }

        fn getFloat(ptr: *anyopaque, field_index: usize) f64 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) != .float) return 0;
                    return @floatCast(@field(v.*, f.name));
                }
            }
            return 0;
        }

        fn setFloat(ptr: *anyopaque, field_index: usize, n: f64) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) == .float) @field(v.*, f.name) = @floatCast(n);
                    return;
                }
            }
        }

        fn getEnumIndex(ptr: *anyopaque, field_index: usize) usize {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) != .@"enum") return 0;
                    // Declaration-order position, matching `enumChoices`' `choices` list and
                    // `setEnumIndex`'s `std.meta.tags(f.type)[choice_index]` — not the enum's
                    // raw backing integer, which for an explicit-value enum like `TabSize`
                    // (`@"2" = 2, @"4" = 4, @"8" = 8`) is out of range for `choices.len`.
                    const current = @field(v.*, f.name);
                    const tags = std.meta.tags(f.type);
                    inline for (tags, 0..) |t, ti| {
                        if (t == current) return ti;
                    }
                    return 0;
                }
            }
            return 0;
        }

        fn setEnumIndex(ptr: *anyopaque, field_index: usize, choice_index: usize) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type) == .@"enum") {
                        const tags = std.meta.tags(f.type);
                        if (choice_index < tags.len) @field(v.*, f.name) = tags[choice_index];
                    }
                    return;
                }
            }
        }

        fn getString(ptr: *anyopaque, field_index: usize) []const u8 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (comptime typeTagFor(f.type) == .string) return @field(v.*, f.name);
                    return "";
                }
            }
            return "";
        }

        fn setString(ptr: *anyopaque, field_index: usize, s: []const u8) void {
            _ = ptr;
            _ = field_index;
            _ = s;
            // String fields that own memory need a plugin-specific allocator policy;
            // not used by built-ins yet. Shell UI skips editable strings until then.
        }

        const access_vtable: Access = .{
            .getBool = getBool,
            .setBool = setBool,
            .getInt = getInt,
            .setInt = setInt,
            .getFloat = getFloat,
            .setFloat = setFloat,
            .getEnumIndex = getEnumIndex,
            .setEnumIndex = setEnumIndex,
            .getString = getString,
            .setString = setString,
            .persist = persistValue,
        };

        fn persistValue(ptr: *anyopaque, owner: *Plugin) void {
            const host = runtime.host();
            const gpa = host.allocator;
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            std.zon.stringify.serialize(asValue(ptr).*, .{}, &aw.writer) catch |err| {
                dvui.log.warn("sdk.settings: failed to serialize '{s}': {s}", .{ owner.id, @errorName(err) });
                return;
            };
            const blob = aw.written();
            host.storePluginSettings(owner.id, blob) catch |err| {
                dvui.log.warn("sdk.settings: failed to store '{s}': {s}", .{ owner.id, @errorName(err) });
                return;
            };
            owner.settingsChanged(blob);
        }

        /// Register schema + value pointer. The shell draws controls from `fields` via `access`.
        pub fn register(host: anytype, plugin: *Plugin, opts: struct {
            title: []const u8,
            value: *T,
        }) !void {
            try host.registerSettingsSchema(.{
                .owner = plugin,
                .title = opts.title,
                .fields = settings,
                .value = opts.value,
                .access = &access_vtable,
            });
        }
    };
}

const testing = std.testing;

test "Schema() derives field metadata from a plain struct" {
    const S = Schema(struct {
        insert_spaces_on_tab: bool = true,
        tab_size: u8 = 4,
        ratio: f32 = 1.0,
        mode: enum { fast, slow } = .fast,
    });

    try testing.expectEqual(@as(usize, 4), S.settings.len);
    try testing.expectEqual(TypeTag.bool, std.meta.activeTag(S.settings[0].kind));
    try testing.expectEqual(TypeTag.int, std.meta.activeTag(S.settings[1].kind));
    try testing.expectEqual(@as(i64, 0), S.settings[1].kind.int.min);
    try testing.expectEqual(@as(i64, 255), S.settings[1].kind.int.max);
    try testing.expectEqual(TypeTag.float, std.meta.activeTag(S.settings[2].kind));
    try testing.expectEqual(TypeTag.enumeration, std.meta.activeTag(S.settings[3].kind));
    try testing.expectEqualStrings("fast", S.settings[3].kind.enumeration.choices[0]);
}

test "getEnumIndex/setEnumIndex use declaration-order position, not the enum's backing value" {
    // Regression: an explicit-value enum (like text's `TabSize`) has backing values that don't
    // match declaration-order position. `getEnumIndex` previously returned `@intFromEnum`
    // directly, which was out of range for `choices.len` whenever the backing values weren't
    // 0/1/2/... — the settings pane's dropdown preview showed "?" for every value.
    const TabSize = enum(u8) { @"2" = 2, @"4" = 4, @"8" = 8 };
    const S = Schema(struct {
        tab_size: TabSize = .@"4",
    });
    var value: S.Value = .{ .tab_size = .@"4" };

    // Declaration-order position (1), not the backing value (4).
    try testing.expectEqual(@as(usize, 1), S.access_vtable.getEnumIndex(&value, 0));

    S.access_vtable.setEnumIndex(&value, 0, 2);
    try testing.expectEqual(TabSize.@"8", value.tab_size);
    try testing.expectEqual(@as(usize, 2), S.access_vtable.getEnumIndex(&value, 0));
}

test "applyZon parses a zon blob into the value type" {
    runtime.installRuntime(&testing.allocator, null, null);

    const S = Schema(struct {
        tab_size: u8 = 4,
        format_on_save: bool = false,
    });

    var value: S.Value = .{};
    S.applyZon(&value, ".{ .tab_size = 8, .format_on_save = true }");

    try testing.expectEqual(@as(u8, 8), value.tab_size);
    try testing.expectEqual(true, value.format_on_save);
}
