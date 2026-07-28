//! Comptime settings API for plugins — Zig build-options-style declaration.
//!
//!   const MySettings = sdk.settings.Schema(struct {
//!       insert_spaces_on_tab: sdk.settings.Value(bool, .{
//!           .description = "Insert spaces instead of a tab character when pressing Tab.",
//!       }) = .init(true),
//!       tab_size: sdk.settings.Value(TabSize, .{
//!           .description = "Number of spaces a tab occupies.",
//!       }) = .init(.@"4"),
//!   });
//!   MySettings.load(host, plugin.id, &values);
//!   try MySettings.register(host, &plugin, .{ .title = "Text", .value = &values });
//!
//! **Every setting describes itself.** A field's *type* is a `Value(T, opts)` cell carrying the
//! payload type plus its metadata — a **required** description, and optional display name and
//! numeric bounds. All of that is comptime (`opts` is a type parameter), so a cell costs exactly
//! `@sizeOf(T)` at runtime; only the payload is ever stored. Reads/writes go through
//! `.get()`/`.set()`.
//!
//! Plugins register a typed value + field metadata only. The **shell** draws a shared settings UI
//! from `SettingsSchema.fields` (see `PluginSettingsPane`/`SettingRow`) — plugins do not supply a
//! `draw` callback.
//!
//! **The on-disk shape is the payloads, not the cells.** Everything persistence touches goes
//! through `Plain(T)` — a comptime mirror of `T` with the same field names but bare payload types
//! — so `settings.zon` holds `.{ .tab_size = .@"8" }` exactly as it did before cells existed. No
//! migration, and R11 reconciliation / R12 diff-only persistence are unaffected.
//!
//! Loaded-only: a `SettingsSchema` exists in the Host registry only while the plugin is
//! registered.
const std = @import("std");
const dvui = @import("dvui");
const Plugin = @import("Plugin.zig");
const runtime = @import("runtime.zig");

/// `other` is the escape hatch: any type `std.zon` can round-trip is a legal setting, and the
/// shell draws whatever it has no dedicated control for as editable zon text.
pub const TypeTag = enum { bool, int, float, string, enumeration, color, other };

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
    other: void,
};

pub const Setting = struct {
    /// The field name, which is also the key in `settings.zon` — shown under the label and
    /// matched by the settings search, so a user who knows the zon key can find its row.
    key: []const u8,
    /// Human-readable name derived from `key` (`insert_spaces_on_tab` → `Insert spaces on tab`)
    /// unless the cell overrode it with `Options.name`.
    label: []const u8,
    /// What the setting does, in a sentence or two. Required at declaration — see `Options`.
    description: []const u8,
    kind: Kind,
};

/// Per-setting metadata, supplied as the second (comptime) parameter of `Value`.
///
/// `description` has no default, so leaving it out is a compile error at the declaration site.
/// That's the whole point: the settings UI has a permanent place for it, and no shell-side table
/// can drift from the plugin that owns the setting.
pub const Options = struct {
    description: []const u8,
    /// Overrides the name derived from the field name.
    name: ?[]const u8 = null,
    /// Numeric bounds. Ints/enums derive theirs from the type itself (bit width, tag list), so
    /// these matter mostly for floats, where a bare `f32` carries no notion of range.
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
};

/// One self-describing setting. Use it as a field type in the struct handed to `Schema`, with the
/// default value supplied by the field default:
///
///     window_opacity: Value(f32, .{ .description = "…", .min = 0, .max = 1 }) = .init(0.9),
///
/// The metadata lives in the type, so `@sizeOf(Value(T, …)) == @sizeOf(T)`.
pub fn Value(comptime T: type, comptime opts: Options) type {
    return struct {
        const Self = @This();

        v: T,

        pub const Payload = T;
        pub const setting_options = opts;
        /// Marker `Schema` uses to tell a cell from a bare field (see `isCell`).
        pub const is_setting_cell = true;

        pub fn init(default_payload: T) Self {
            return .{ .v = default_payload };
        }

        pub fn get(self: Self) T {
            return self.v;
        }

        pub fn set(self: *Self, payload: T) void {
            self.v = payload;
        }
    };
}

fn isCell(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "is_setting_cell"),
        else => false,
    };
}

/// Compile error for a settings struct field that isn't a `Value(...)` cell. Bare fields used to
/// be the whole API, so this names the fix rather than just the rule.
fn requireCell(comptime T: type, comptime field_name: []const u8, comptime owner: type) void {
    if (!isCell(T)) @compileError(
        "sdk.settings.Schema: field '" ++ field_name ++ "' of " ++ @typeName(owner) ++
            " must be a settings cell — `" ++ field_name ++
            ": sdk.settings.Value(" ++ @typeName(T) ++
            ", .{ .description = \"…\" }) = .init(<default>)`. Every setting needs a description.",
    );
}

/// `insert_spaces_on_tab` → `Insert spaces on tab`: underscores become spaces and the first letter
/// is capitalized. Sentence case, not title case — a description follows it, and title-casing
/// every word reads like a menu item rather than a setting name.
fn deriveLabel(comptime key: []const u8) []const u8 {
    comptime {
        var buf: [key.len]u8 = undefined;
        for (key, 0..) |c, i| buf[i] = if (c == '_') ' ' else c;
        if (buf.len > 0) buf[0] = std.ascii.toUpper(buf[0]);
        const frozen = buf;
        return &frozen;
    }
}

fn typeTagFor(comptime T: type) TypeTag {
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int => .int,
        .float => .float,
        .@"enum" => .enumeration,
        .pointer => |p| if (p.size == .slice and p.child == u8) .string else .other,
        else => .other,
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

/// Derive a field's `Kind` from its payload type, refined by whatever bounds the cell declared.
/// `int`/`enumeration` get bounds/choices for free from the type itself (bit-width, tag names);
/// `float` has no such source (a bare `f32` carries no notion of range), so it falls back to
/// `FloatKind`'s defaults (0..1, step 0.01) unless `Options` narrowed them.
fn kindFor(comptime T: type, comptime opts: Options) Kind {
    return switch (typeTagFor(T)) {
        .bool => .{ .bool = {} },
        .int => blk: {
            const bounds = intBounds(T);
            break :blk .{ .int = .{
                .min = if (opts.min) |m| @intFromFloat(m) else bounds.min,
                .max = if (opts.max) |m| @intFromFloat(m) else bounds.max,
            } };
        },
        .float => .{ .float = .{
            .min = opts.min orelse 0,
            .max = opts.max orelse 1,
            .step = opts.step orelse 0.01,
        } },
        .string => .{ .string = {} },
        .enumeration => .{ .enumeration = .{ .choices = enumChoices(T) } },
        .color => .{ .color = {} },
        .other => .{ .other = {} },
    };
}

fn buildSettings(comptime T: type) [std.meta.fields(T).len]Setting {
    const struct_fields = std.meta.fields(T);
    var out: [struct_fields.len]Setting = undefined;
    inline for (struct_fields, 0..) |f, i| {
        requireCell(f.type, f.name, T);
        const opts = f.type.setting_options;
        out[i] = .{
            .key = f.name,
            .label = opts.name orelse deriveLabel(f.name),
            .description = opts.description,
            .kind = kindFor(f.type.Payload, opts),
        };
    }
    return out;
}

/// Comptime mirror of a cell struct with the same field names but bare payload types, carrying
/// each cell's declared default. Everything that touches disk — `std.zon` parse/stringify, the
/// diff against defaults — works on this, which is why the on-disk format never learned that
/// cells exist.
fn Plain(comptime T: type) type {
    const cell_fields = std.meta.fields(T);
    var names: [cell_fields.len][:0]const u8 = undefined;
    var types: [cell_fields.len]type = undefined;
    var attrs: [cell_fields.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (cell_fields, 0..) |f, i| {
        requireCell(f.type, f.name, T);
        const P = f.type.Payload;
        const cell_default = f.defaultValue() orelse @compileError(
            "sdk.settings.Schema: field '" ++ f.name ++ "' of " ++ @typeName(T) ++
                " needs a default value (`= .init(<default>)`) — required so settings.zon only " ++
                "has to record what differs from it",
        );
        const payload_default: P = cell_default.v;
        names[i] = f.name;
        types[i] = P;
        attrs[i] = .{ .default_value_ptr = @ptrCast(&payload_default) };
    }
    const frozen_names = names;
    const frozen_types = types;
    const frozen_attrs = attrs;
    return @Struct(.auto, null, &frozen_names, &frozen_types, &frozen_attrs);
}

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
    /// Zon text of one field's payload, allocated in `arena` — how the shell shows (and edits) a
    /// `.other` setting it has no dedicated control for. Returns "" if serialization fails.
    getZonText: *const fn (value: *anyopaque, field_index: usize, arena: std.mem.Allocator) []const u8,
    /// Parse `text` as zon into one field. Returns false (leaving the field untouched) when the
    /// text doesn't parse as that field's type — the pane keeps showing the old value.
    setZonText: *const fn (value: *anyopaque, field_index: usize, text: []const u8) bool,
    /// Persist `value` via `host.storePluginSettings(owner.id, zon)` and notify `owner`.
    persist: *const fn (value: *anyopaque, owner: *Plugin) void,
    /// Parse `blob` into `value` and notify `owner.settingsChanged(blob)` — the reconciliation-
    /// path counterpart to `persist` (which goes the other direction: live value → disk). Used
    /// only by external-change reconciliation (see R11 in docs/PLUGIN_MANIFEST_PLAN.md), never
    /// by an in-app edit through the settings pane.
    applyBlob: *const fn (value: *anyopaque, owner: *Plugin, blob: []const u8) void,
};

pub const SettingsSchema = struct {
    owner: *Plugin,
    title: []const u8,
    fields: []const Setting,
    /// Pointer to the plugin's `Schema(T).Value` (stable for the loaded lifetime).
    value: *anyopaque,
    access: *const Access,
    /// Hash of the last `.settings` blob text actually applied to `value` (seeded at `register()`
    /// time from whatever `loadPluginSettings` returned, if anything). Lets external-change
    /// reconciliation skip re-parsing/re-notifying a plugin whose own `.plugins.<id>.settings`
    /// hasn't changed, even when *some other* part of settings.zon has (see R11) — without this,
    /// any change anywhere in the file would spuriously renotify every loaded plugin, not just
    /// the one that changed.
    last_applied_hash: u64 = 0,
};

/// Build a settings namespace for `T`, a struct whose every field is a `Value(...)` cell with a
/// default (`= .init(…)`). The default is required to compute `default_value` below, which the
/// non-default-only persistence (see `diffSerialize`, R12 in docs/PLUGIN_MANIFEST_PLAN.md) diffs
/// every value against.
pub fn Schema(comptime T: type) type {
    const struct_fields = std.meta.fields(T);
    const built_settings = buildSettings(T);

    return struct {
        /// The plugin's own settings struct (the one made of cells). Named `Cells` rather than
        /// `Value` so it doesn't shadow the module-level `Value` cell constructor.
        pub const Cells = T;
        /// Bare-payload mirror — the shape that is parsed from and written to `settings.zon`.
        pub const Payloads = Plain(T);
        pub const settings: []const Setting = &built_settings;

        const default_payloads: Payloads = .{};

        /// Payload type of field `i`.
        fn PayloadOf(comptime i: usize) type {
            return struct_fields[i].type.Payload;
        }

        /// Live payload of a field, by name — cells are transparent to everything in here.
        fn payloadPtr(v: *T, comptime name: []const u8) *@FieldType(Payloads, name) {
            return &@field(v.*, name).v;
        }

        fn toPayloads(v: T) Payloads {
            var out: Payloads = undefined;
            inline for (struct_fields) |f| @field(out, f.name) = @field(v, f.name).v;
            return out;
        }

        fn fromPayloads(out: *T, p: Payloads) void {
            inline for (struct_fields) |f| @field(out.*, f.name).v = @field(p, f.name);
        }

        pub fn load(host: anytype, id: []const u8, out: *T) void {
            const blob = host.loadPluginSettings(id) orelse return;
            defer host.allocator.free(blob);
            applyZon(out, blob);
        }

        /// Serializes the *whole* current value — used only to notify `settingsChanged`, which
        /// documents `blob` as "the whole, freshly-serialized zon text." What's actually
        /// persisted to disk is `diffSerialize`'s smaller, non-default-only blob instead; the two
        /// don't need to match byte-for-byte, and a plugin's own `applyZon`-based re-parse can't
        /// tell the difference either way (missing fields fill from the declared defaults).
        fn fullSerialize(gpa: std.mem.Allocator, value: T) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try std.zon.stringify.serialize(toPayloads(value), .{}, &aw.writer);
            return aw.toOwnedSlice();
        }

        fn fieldEqual(comptime FT: type, a: FT, b: FT) bool {
            return switch (@typeInfo(FT)) {
                .bool, .int, .float, .@"enum" => a == b,
                .pointer => |p| if (p.size == .slice and p.child == u8) std.mem.eql(u8, a, b) else false,
                else => std.meta.eql(a, b),
            };
        }

        fn isAllDefault(value: T) bool {
            const p = toPayloads(value);
            inline for (struct_fields) |f| {
                const P = f.type.Payload;
                if (!fieldEqual(P, @field(p, f.name), @field(default_payloads, f.name))) return false;
            }
            return true;
        }

        /// Serializes only the fields of `value` that differ from their declared defaults —
        /// e.g. `.{ .tab_size = 8 }` instead of every field. Returns `null` when `value` is
        /// entirely default, signaling "nothing to persist" (the caller removes any existing
        /// on-disk entry for this id entirely, rather than writing an empty/default blob).
        fn diffSerialize(gpa: std.mem.Allocator, value: T) !?[]u8 {
            if (isAllDefault(value)) return null;
            const p = toPayloads(value);
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try aw.writer.writeAll(".{\n");
            inline for (struct_fields) |f| {
                const P = f.type.Payload;
                if (!fieldEqual(P, @field(p, f.name), @field(default_payloads, f.name))) {
                    try aw.writer.print("    .{f} = ", .{std.zig.fmtId(f.name)});
                    try std.zon.stringify.serialize(@field(p, f.name), .{}, &aw.writer);
                    try aw.writer.writeAll(",\n");
                }
            }
            try aw.writer.writeAll("}");
            return try aw.toOwnedSlice();
        }

        pub fn store(host: anytype, id: []const u8, value: T) void {
            const gpa = host.allocator;
            const blob = diffSerialize(gpa, value) catch |err| {
                dvui.log.warn("sdk.settings: failed to serialize '{s}': {s}", .{ id, @errorName(err) });
                return;
            };
            if (blob) |b| {
                defer gpa.free(b);
                host.storePluginSettings(id, b) catch |err| {
                    dvui.log.warn("sdk.settings: failed to store '{s}': {s}", .{ id, @errorName(err) });
                };
            } else {
                host.removePluginSettings(id) catch |err| {
                    dvui.log.warn("sdk.settings: failed to remove '{s}': {s}", .{ id, @errorName(err) });
                };
            }
        }

        /// True when `value`'s field `name` currently points at storage this schema allocated,
        /// rather than at the declared default. See `freeOwned` for the rule this encodes.
        fn fieldIsOwned(comptime name: []const u8, value: T) bool {
            return @field(value, name).v.ptr != @field(default_payloads, name).ptr;
        }

        /// Releases every string field of `value` that this schema allocated.
        ///
        /// **Ownership rule for `[]const u8` settings payloads:** a field's bytes belong to this
        /// schema (allocated with `runtime.allocator()` by `applyZon`/`setString`) *unless* the
        /// slice is exactly the declared default, which lives in the plugin image's constant data
        /// and must never reach an allocator. Pointer identity is the test — a parsed value that
        /// happens to *equal* the default string is still schema-owned and still freed.
        ///
        /// Whole-struct `std.zon.parse.free` can't be used here: a settings.zon that omits a
        /// field (the normal case, since only non-default fields are persisted — R12) makes
        /// `std.zon.parse` fill it from that same declared default, so freeing the parse result
        /// wholesale would hand a string literal to the allocator. Payloads that aren't strings
        /// or don't contain any need no release at all.
        fn freeOwned(gpa: std.mem.Allocator, value: T) void {
            inline for (struct_fields) |f| {
                if (comptime typeTagFor(f.type.Payload) == .string) {
                    if (fieldIsOwned(f.name, value)) gpa.free(@field(value, f.name).v);
                }
            }
        }

        /// Releases anything this schema allocated into `value` and resets it to the declared
        /// defaults. Plugins with a string setting should call this when they tear down the
        /// value they passed to `register` (a plugin whose settings are all scalars/enums may
        /// skip it — it's a no-op there). Safe to call more than once.
        pub fn deinit(value: *T) void {
            freeOwned(runtime.allocator(), value.*);
            fromPayloads(value, default_payloads);
        }

        pub fn applyZon(out: *T, blob: []const u8) void {
            const gpa = runtime.allocator();
            const blob_z = gpa.dupeZ(u8, blob) catch |err| {
                dvui.log.warn("sdk.settings: out of memory parsing settings: {s}", .{@errorName(err)});
                return;
            };
            defer gpa.free(blob_z);

            const parsed = std.zon.parse.fromSliceAlloc(Payloads, gpa, blob_z, null, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                dvui.log.warn("sdk.settings: failed to parse settings: {s}", .{@errorName(err)});
                return;
            };
            freeOwned(gpa, out.*);
            fromPayloads(out, parsed);
        }

        fn asValue(ptr: *anyopaque) *T {
            return @ptrCast(@alignCast(ptr));
        }

        fn getBool(ptr: *anyopaque, field_index: usize) bool {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type.Payload) != .bool) return false;
                    return payloadPtr(v, f.name).*;
                }
            }
            return false;
        }

        fn setBool(ptr: *anyopaque, field_index: usize, b: bool) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type.Payload) == .bool) payloadPtr(v, f.name).* = b;
                    return;
                }
            }
        }

        fn getInt(ptr: *anyopaque, field_index: usize) i64 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type.Payload) != .int) return 0;
                    return @intCast(payloadPtr(v, f.name).*);
                }
            }
            return 0;
        }

        fn setInt(ptr: *anyopaque, field_index: usize, n: i64) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type.Payload) == .int) {
                        const p = payloadPtr(v, f.name);
                        p.* = std.math.cast(f.type.Payload, n) orelse p.*;
                    }
                    return;
                }
            }
        }

        fn getFloat(ptr: *anyopaque, field_index: usize) f64 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type.Payload) != .float) return 0;
                    return @floatCast(payloadPtr(v, f.name).*);
                }
            }
            return 0;
        }

        fn setFloat(ptr: *anyopaque, field_index: usize, n: f64) void {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (@typeInfo(f.type.Payload) == .float) payloadPtr(v, f.name).* = @floatCast(n);
                    return;
                }
            }
        }

        fn getEnumIndex(ptr: *anyopaque, field_index: usize) usize {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    const P = f.type.Payload;
                    if (@typeInfo(P) != .@"enum") return 0;
                    // Declaration-order position, matching `enumChoices`' `choices` list and
                    // `setEnumIndex`'s `std.meta.tags(P)[choice_index]` — not the enum's raw
                    // backing integer, which for an explicit-value enum like `TabSize`
                    // (`@"2" = 2, @"4" = 4, @"8" = 8`) is out of range for `choices.len`.
                    const current = payloadPtr(v, f.name).*;
                    const tags = std.meta.tags(P);
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
                    const P = f.type.Payload;
                    if (@typeInfo(P) == .@"enum") {
                        const tags = std.meta.tags(P);
                        if (choice_index < tags.len) payloadPtr(v, f.name).* = tags[choice_index];
                    }
                    return;
                }
            }
        }

        fn getString(ptr: *anyopaque, field_index: usize) []const u8 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (comptime typeTagFor(f.type.Payload) == .string) return payloadPtr(v, f.name).*;
                    return "";
                }
            }
            return "";
        }

        /// Copies `s` into schema-owned storage and releases whatever the field held before,
        /// per `freeOwned`'s ownership rule. A failed dupe leaves the field untouched (logged) —
        /// the settings pane simply keeps showing the old value.
        fn setString(ptr: *anyopaque, field_index: usize, s: []const u8) void {
            const v = asValue(ptr);
            const gpa = runtime.allocator();
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    if (comptime typeTagFor(f.type.Payload) == .string) {
                        const copy = gpa.dupe(u8, s) catch |err| {
                            dvui.log.warn("sdk.settings: failed to set '{s}': {s}", .{ f.name, @errorName(err) });
                            return;
                        };
                        if (fieldIsOwned(f.name, v.*)) gpa.free(@field(v.*, f.name).v);
                        payloadPtr(v, f.name).* = copy;
                    }
                    return;
                }
            }
        }

        fn getZonText(ptr: *anyopaque, field_index: usize, arena: std.mem.Allocator) []const u8 {
            const v = asValue(ptr);
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    var aw: std.Io.Writer.Allocating = .init(arena);
                    std.zon.stringify.serialize(payloadPtr(v, f.name).*, .{}, &aw.writer) catch {
                        aw.deinit();
                        return "";
                    };
                    return aw.toOwnedSlice() catch "";
                }
            }
            return "";
        }

        /// Parses `text` as this field's payload type. Anything the parser rejects leaves the
        /// live value alone — the pane re-seeds itself from it, so a half-typed entry can't
        /// clobber a good setting.
        fn setZonText(ptr: *anyopaque, field_index: usize, text: []const u8) bool {
            const v = asValue(ptr);
            const gpa = runtime.allocator();
            inline for (struct_fields, 0..) |f, i| {
                if (i == field_index) {
                    const P = f.type.Payload;
                    const text_z = gpa.dupeZ(u8, text) catch return false;
                    defer gpa.free(text_z);
                    const parsed = std.zon.parse.fromSliceAlloc(P, gpa, text_z, null, .{}) catch return false;
                    // Strings follow the same ownership rule as `setString`; other payloads are
                    // plain values the parse allocated nothing for.
                    if (comptime typeTagFor(P) == .string) {
                        if (fieldIsOwned(f.name, v.*)) gpa.free(@field(v.*, f.name).v);
                    }
                    payloadPtr(v, f.name).* = parsed;
                    return true;
                }
            }
            return false;
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
            .getZonText = getZonText,
            .setZonText = setZonText,
            .persist = persistValue,
            .applyBlob = applyBlobValue,
        };

        /// Queues `value`'s **non-default fields only** for the next merged settings.zon write, or
        /// queues the whole entry's removal when nothing differs from the declared defaults.
        /// Returns false (already logged) if it couldn't queue anything.
        ///
        /// Shared by both writers — the in-app edit path (`persistValue`) and the external
        /// hand-edit reconciliation path (`applyBlobValue`) — so settings.zon lands in the same
        /// normalized, non-default-only shape (R12) no matter which one got there. Routing the
        /// external path through here too is what prunes a field the user hand-edited back to its
        /// default, including when *other* fields in the same block are still non-default.
        ///
        /// Cost of normalizing on the external path: this re-emits the plugin's `.settings` block
        /// canonically, so comments/formatting the user wrote *inside that block* don't survive
        /// (R10's verbatim-span preservation still protects every other part of the file, and any
        /// plugin block that wasn't touched this cycle).
        fn queueNormalizedPersist(owner_id: []const u8, value: T) bool {
            const host = runtime.host();
            const gpa = host.allocator;

            const diff_blob = diffSerialize(gpa, value) catch |err| {
                dvui.log.warn("sdk.settings: failed to serialize '{s}': {s}", .{ owner_id, @errorName(err) });
                return false;
            };
            if (diff_blob) |b| {
                defer gpa.free(b);
                host.storePluginSettings(owner_id, b) catch |err| {
                    dvui.log.warn("sdk.settings: failed to store '{s}': {s}", .{ owner_id, @errorName(err) });
                    return false;
                };
            } else {
                host.removePluginSettings(owner_id) catch |err| {
                    dvui.log.warn("sdk.settings: failed to remove '{s}': {s}", .{ owner_id, @errorName(err) });
                    return false;
                };
            }
            return true;
        }

        fn persistValue(ptr: *anyopaque, owner: *Plugin) void {
            const value = asValue(ptr).*;
            if (!queueNormalizedPersist(owner.id, value)) return;

            const gpa = runtime.host().allocator;
            const notify_blob = fullSerialize(gpa, value) catch |err| {
                dvui.log.warn("sdk.settings: failed to serialize '{s}' for notification: {s}", .{ owner.id, @errorName(err) });
                return;
            };
            defer gpa.free(notify_blob);
            owner.settingsChanged(notify_blob);
        }

        /// The reconciliation-path counterpart to `persistValue` — parses a freshly-read blob
        /// (from external-change reconciliation, see R11) into the live value, re-queues it in
        /// normalized form, and notifies the plugin, same as an in-app edit would. Caller
        /// (`Editor.reconcileExternalSettingsChange`) is responsible for only calling this when
        /// `blob`'s hash actually differs from `SettingsSchema.last_applied_hash` — this function
        /// itself doesn't check.
        ///
        /// The re-queue is what keeps a hand-edited file converging on R12's non-default-only
        /// shape: any field the user spelled back out at its default drops out on the next write,
        /// whether or not its siblings are still non-default. See `queueNormalizedPersist` for
        /// what that costs.
        fn applyBlobValue(ptr: *anyopaque, owner: *Plugin, blob: []const u8) void {
            const value = asValue(ptr);
            applyZon(value, blob);
            _ = queueNormalizedPersist(owner.id, value.*);
            owner.settingsChanged(blob);
        }

        /// Register schema + value pointer. The shell draws controls from `fields` via `access`.
        pub fn register(host: anytype, plugin: *Plugin, opts: struct {
            title: []const u8,
            value: *T,
        }) !void {
            // Seed `last_applied_hash` from whatever's on disk right now (the same blob `load()`
            // was just called with, immediately before this, per this module's documented
            // calling convention) so the *first* reconciliation after startup doesn't spuriously
            // renotify a plugin whose settings haven't actually changed since load.
            const seed_hash: u64 = blk: {
                const blob = host.loadPluginSettings(plugin.id) orelse break :blk 0;
                defer host.allocator.free(blob);
                break :blk std.hash.Wyhash.hash(0, blob);
            };
            try host.registerSettingsSchema(.{
                .owner = plugin,
                .title = opts.title,
                .fields = settings,
                .value = opts.value,
                .access = &access_vtable,
                .last_applied_hash = seed_hash,
            });
        }
    };
}

const testing = std.testing;

test "Schema() derives field metadata from a struct of cells" {
    const S = Schema(struct {
        insert_spaces_on_tab: Value(bool, .{ .description = "Spaces, not tabs." }) = .init(true),
        tab_size: Value(u8, .{ .description = "Tab width." }) = .init(4),
        ratio: Value(f32, .{ .description = "A ratio." }) = .init(1.0),
        mode: Value(enum { fast, slow }, .{ .description = "How fast." }) = .init(.fast),
    });

    try testing.expectEqual(@as(usize, 4), S.settings.len);
    try testing.expectEqual(TypeTag.bool, std.meta.activeTag(S.settings[0].kind));
    try testing.expectEqual(TypeTag.int, std.meta.activeTag(S.settings[1].kind));
    try testing.expectEqual(@as(i64, 0), S.settings[1].kind.int.min);
    try testing.expectEqual(@as(i64, 255), S.settings[1].kind.int.max);
    try testing.expectEqual(TypeTag.float, std.meta.activeTag(S.settings[2].kind));
    try testing.expectEqual(TypeTag.enumeration, std.meta.activeTag(S.settings[3].kind));
    try testing.expectEqualStrings("fast", S.settings[3].kind.enumeration.choices[0]);

    // Every field carries the description it declared, and no field can omit one (that's a
    // compile error at the declaration site, so it can't be asserted here).
    try testing.expectEqualStrings("Spaces, not tabs.", S.settings[0].description);
}

test "labels are derived in sentence case, and Options.name overrides" {
    const S = Schema(struct {
        insert_spaces_on_tab: Value(bool, .{ .description = "d" }) = .init(true),
        tab_size: Value(u8, .{ .description = "d", .name = "Tab Size (spaces)" }) = .init(4),
    });

    try testing.expectEqualStrings("insert_spaces_on_tab", S.settings[0].key);
    try testing.expectEqualStrings("Insert spaces on tab", S.settings[0].label);
    // Override wins, key is untouched.
    try testing.expectEqualStrings("tab_size", S.settings[1].key);
    try testing.expectEqualStrings("Tab Size (spaces)", S.settings[1].label);
}

test "Options bounds refine the derived float kind" {
    const S = Schema(struct {
        opacity: Value(f32, .{ .description = "d", .min = 0.2, .max = 4, .step = 0.5 }) = .init(1),
    });
    try testing.expectEqual(@as(f64, 0.2), S.settings[0].kind.float.min);
    try testing.expectEqual(@as(f64, 4), S.settings[0].kind.float.max);
    try testing.expectEqual(@as(f64, 0.5), S.settings[0].kind.float.step);
}

test "getEnumIndex/setEnumIndex use declaration-order position, not the enum's backing value" {
    // Regression: an explicit-value enum (like text's `TabSize`) has backing values that don't
    // match declaration-order position. `getEnumIndex` previously returned `@intFromEnum`
    // directly, which was out of range for `choices.len` whenever the backing values weren't
    // 0/1/2/... — the settings pane's dropdown preview showed "?" for every value.
    const TabSize = enum(u8) { @"2" = 2, @"4" = 4, @"8" = 8 };
    const S = Schema(struct {
        tab_size: Value(TabSize, .{ .description = "d" }) = .init(.@"4"),
    });
    var value: S.Cells = .{};

    // Declaration-order position (1), not the backing value (4).
    try testing.expectEqual(@as(usize, 1), S.access_vtable.getEnumIndex(&value, 0));

    S.access_vtable.setEnumIndex(&value, 0, 2);
    try testing.expectEqual(TabSize.@"8", value.tab_size.get());
    try testing.expectEqual(@as(usize, 2), S.access_vtable.getEnumIndex(&value, 0));
}

test "applyZon parses a bare-payload zon blob into the cells" {
    runtime.installRuntime(&testing.allocator, null, null);

    const S = Schema(struct {
        tab_size: Value(u8, .{ .description = "d" }) = .init(4),
        format_on_save: Value(bool, .{ .description = "d" }) = .init(false),
    });

    var value: S.Cells = .{};
    // Exactly the on-disk shape from before cells existed — payloads, not `.{ .v = … }`.
    S.applyZon(&value, ".{ .tab_size = 8, .format_on_save = true }");

    try testing.expectEqual(@as(u8, 8), value.tab_size.get());
    try testing.expectEqual(true, value.format_on_save.get());
}

test "applyZon replaces a string field without freeing its declared default" {
    // Regression: `applyZon` used to `std.zon.parse.free` the whole previous value. A string
    // field still holding the declared default points at constant data, so that freed a
    // non-allocation — and since R12 omits default fields from disk, a *parsed* value hits this
    // too (missing fields are filled from the same literals). `testing.allocator` panics on
    // both the invalid free and any leak, so this test covers both directions.
    runtime.installRuntime(&testing.allocator, null, null);

    const S = Schema(struct {
        greeting: Value([]const u8, .{ .description = "d" }) = .init("hello"),
        tab_size: Value(u8, .{ .description = "d" }) = .init(4),
    });

    var value: S.Cells = .{};
    S.applyZon(&value, ".{ .greeting = \"hi\" }");
    try testing.expectEqualStrings("hi", value.greeting.get());

    // Second apply must free the first parse's allocation, not the literal.
    S.applyZon(&value, ".{ .greeting = \"hey\", .tab_size = 8 }");
    try testing.expectEqualStrings("hey", value.greeting.get());
    try testing.expectEqual(@as(u8, 8), value.tab_size.get());

    // A blob that omits the field puts the declared default literal back...
    S.applyZon(&value, ".{ .tab_size = 2 }");
    try testing.expectEqualStrings("hello", value.greeting.get());
    // ...and releasing the value then has nothing to free for that field.
    S.deinit(&value);
    try testing.expectEqualStrings("hello", value.greeting.get());
}

test "setString copies into schema-owned storage and releases the previous value" {
    runtime.installRuntime(&testing.allocator, null, null);

    const S = Schema(struct {
        greeting: Value([]const u8, .{ .description = "d" }) = .init("hello"),
    });

    var value: S.Cells = .{};
    var scratch: [8]u8 = "howdy\x00\x00\x00".*;
    S.access_vtable.setString(&value, 0, scratch[0..5]);
    // Owned copy, not a borrow of the caller's buffer.
    @memset(scratch[0..5], 'x');
    try testing.expectEqualStrings("howdy", S.access_vtable.getString(&value, 0));

    S.access_vtable.setString(&value, 0, "later");
    try testing.expectEqualStrings("later", S.access_vtable.getString(&value, 0));
    S.deinit(&value);
}

test "diffSerialize compares string fields by content, not pointer" {
    runtime.installRuntime(&testing.allocator, null, null);

    const S = Schema(struct {
        greeting: Value([]const u8, .{ .description = "d" }) = .init("hello"),
    });

    // An allocated copy that *equals* the default is still default for persistence purposes.
    var value: S.Cells = .{};
    S.access_vtable.setString(&value, 0, "hello");
    try testing.expect(try S.diffSerialize(testing.allocator, value) == null);

    S.access_vtable.setString(&value, 0, "goodbye");
    const blob = (try S.diffSerialize(testing.allocator, value)).?;
    defer testing.allocator.free(blob);
    try testing.expect(std.mem.indexOf(u8, blob, "goodbye") != null);
    S.deinit(&value);
}

test "diffSerialize returns null when every field is default (R12 non-default-only persistence)" {
    const S = Schema(struct {
        insert_spaces_on_tab: Value(bool, .{ .description = "d" }) = .init(true),
        tab_size: Value(u8, .{ .description = "d" }) = .init(4),
        format_on_save: Value(bool, .{ .description = "d" }) = .init(false),
    });

    const all_default: S.Cells = .{};
    try testing.expect(try S.diffSerialize(testing.allocator, all_default) == null);
}

test "isAllDefault treats a field explicitly spelled out at its default as still default" {
    // Drives `queueNormalizedPersist`'s remove-the-whole-entry branch: the user writes
    // `.{ .insert_spaces_on_tab = true }` (the declared default) back into settings.zon by hand,
    // so the entry is redundant and should come back out of the file. (The partial case — some
    // fields default, some not — is `diffSerialize`'s job; see the test below.)
    const S = Schema(struct {
        insert_spaces_on_tab: Value(bool, .{ .description = "d" }) = .init(true),
        tab_size: Value(u8, .{ .description = "d" }) = .init(4),
    });

    try testing.expect(S.isAllDefault(.{}));
    try testing.expect(S.isAllDefault(.{ .insert_spaces_on_tab = .init(true), .tab_size = .init(4) }));
    try testing.expect(!S.isAllDefault(.{ .insert_spaces_on_tab = .init(false) }));
    try testing.expect(!S.isAllDefault(.{ .tab_size = .init(8) }));
}

test "diffSerialize emits only the fields that differ from the declared defaults" {
    const S = Schema(struct {
        insert_spaces_on_tab: Value(bool, .{ .description = "d" }) = .init(true),
        tab_size: Value(u8, .{ .description = "d" }) = .init(4),
        format_on_save: Value(bool, .{ .description = "d" }) = .init(false),
    });

    const changed: S.Cells = .{ .tab_size = .init(8) };
    const blob = (try S.diffSerialize(testing.allocator, changed)).?;
    defer testing.allocator.free(blob);

    // The on-disk shape is bare payloads: `.tab_size = 8`, not `.tab_size = .{ .v = 8 }`.
    try testing.expect(std.mem.indexOf(u8, blob, "tab_size = 8") != null);
    try testing.expect(std.mem.indexOf(u8, blob, ".v") == null);
    try testing.expect(std.mem.indexOf(u8, blob, "insert_spaces_on_tab") == null);
    try testing.expect(std.mem.indexOf(u8, blob, "format_on_save") == null);
}

test "a partial (diff-only) blob still fills the rest from the declared defaults" {
    runtime.installRuntime(&testing.allocator, null, null);

    const S = Schema(struct {
        insert_spaces_on_tab: Value(bool, .{ .description = "d" }) = .init(true),
        tab_size: Value(u8, .{ .description = "d" }) = .init(4),
        format_on_save: Value(bool, .{ .description = "d" }) = .init(false),
    });

    var value: S.Cells = .{};
    // Exactly the shape `diffSerialize` would have produced for `.{ .tab_size = 8 }`.
    S.applyZon(&value, ".{ .tab_size = 8 }");

    try testing.expectEqual(@as(u8, 8), value.tab_size.get());
    try testing.expectEqual(true, value.insert_spaces_on_tab.get());
    try testing.expectEqual(false, value.format_on_save.get());
}

test "a type with no dedicated control is still a legal setting, edited as zon text" {
    runtime.installRuntime(&testing.allocator, null, null);

    const Margins = struct { x: i32 = 0, y: i32 = 0 };
    const S = Schema(struct {
        margins: Value(Margins, .{ .description = "Edge padding." }) = .init(.{}),
    });

    try testing.expectEqual(TypeTag.other, std.meta.activeTag(S.settings[0].kind));

    var value: S.Cells = .{};
    try testing.expect(S.access_vtable.setZonText(&value, 0, ".{ .x = 3, .y = 7 }"));
    try testing.expectEqual(@as(i32, 3), value.margins.get().x);
    try testing.expectEqual(@as(i32, 7), value.margins.get().y);

    // A value that doesn't parse leaves the live setting alone.
    try testing.expect(!S.access_vtable.setZonText(&value, 0, "not zon at all ("));
    try testing.expectEqual(@as(i32, 3), value.margins.get().x);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = S.access_vtable.getZonText(&value, 0, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, text, "3") != null);

    // `.other` payloads take part in diff-vs-default like anything else.
    try testing.expect(try S.diffSerialize(testing.allocator, .{}) == null);
}
