//! One-shot migration of the legacy `settings.json` into `settings.zon` (see
//! docs/PLUGIN_MANIFEST_PLAN.md R3). All `std.json` usage on the shell settings path is
//! isolated to this file so it can be deleted once every install has migrated.
const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const Settings = @import("Settings.zig");

/// If `zon_path` doesn't exist yet but its sibling `<name>.json` does, parse the legacy
/// JSON, write an equivalent `zon_path`, split any legacy `"plugins"` blobs out to their own
/// `<plugins_dir>/<id>.settings.zon` files, and delete the JSON file. No-op (including on any
/// failure along the way — the caller falls back to defaults as usual) otherwise. `plugins_dir`
/// is null on wasm/headless, in which case plugin blobs are silently dropped (no filesystem).
pub fn migrateIfNeeded(allocator: std.mem.Allocator, zon_path: []const u8, plugins_dir: ?[]const u8) void {
    if (fizzy.fs.read(allocator, dvui.io, zon_path) catch null) |existing| {
        allocator.free(existing);
        return;
    }

    const json_path = siblingJsonPath(allocator, zon_path) catch return;
    defer allocator.free(json_path);

    const data = fizzy.fs.read(allocator, dvui.io, json_path) catch return;
    defer allocator.free(data);

    migrate(allocator, zon_path, json_path, data, plugins_dir) catch |err| {
        dvui.log.warn("settings: failed to migrate {s} to zon: {s}", .{ json_path, @errorName(err) });
    };
}

fn siblingJsonPath(allocator: std.mem.Allocator, zon_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, zon_path, ".zon")) {
        return std.fmt.allocPrint(allocator, "{s}json", .{zon_path[0 .. zon_path.len - 3]});
    }
    return std.fmt.allocPrint(allocator, "{s}.json", .{zon_path});
}

fn migrate(allocator: std.mem.Allocator, zon_path: []const u8, json_path: []const u8, data: []const u8, plugins_dir: ?[]const u8) !void {
    const options = std.json.ParseOptions{ .duplicate_field_behavior = .use_first, .ignore_unknown_fields = true };
    var parsed = try std.json.parseFromSlice(Settings, allocator, data, options);
    defer parsed.deinit();

    const zon_text = try Settings.serialize(&parsed.value, allocator);
    defer allocator.free(zon_text);

    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = zon_path, .data = zon_text });
    writePluginBlobs(allocator, data, plugins_dir);
    std.Io.Dir.deleteFileAbsolute(dvui.io, json_path) catch |err| {
        dvui.log.warn("settings: migrated to zon but failed to delete legacy {s}: {s}", .{ json_path, @errorName(err) });
    };
}

/// Splits the legacy `"plugins"` object in `data` out into `<plugins_dir>/<id>.settings.zon`
/// files, converting each JSON blob to zon text. Mirrors the pre-R3 `Settings.loadPluginStore`'s
/// JSON handling, including the legacy-flat-file fallback that seeds the pixel-art blob from
/// the whole root. Best-effort throughout: a single bad entry, or no `plugins_dir` (wasm/
/// headless), just means that plugin starts over with defaults.
fn writePluginBlobs(allocator: std.mem.Allocator, data: []const u8, plugins_dir: ?[]const u8) void {
    const dir = plugins_dir orelse return;

    var parsed_v = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed_v.deinit();

    const root = switch (parsed_v.value) {
        .object => |o| o,
        else => return,
    };

    if (root.get("plugins")) |plugins_val| {
        switch (plugins_val) {
            .object => |plugins| {
                var it = plugins.iterator();
                while (it.next()) |e| writePluginBlob(allocator, dir, e.key_ptr.*, e.value_ptr.*);
                return;
            },
            else => {},
        }
    }

    // Legacy flat settings.json (no "plugins" object): seed the pixel-art blob from the
    // whole root so its moved fields survive the format change.
    writePluginBlob(allocator, dir, "pixi", parsed_v.value);
}

fn writePluginBlob(allocator: std.mem.Allocator, dir: []const u8, id: []const u8, value: std.json.Value) void {
    const blob = jsonValueToZonAlloc(allocator, value) catch return;
    defer allocator.free(blob);

    const path = std.fmt.allocPrint(allocator, "{s}/{s}.settings.zon", .{ dir, id }) catch return;
    defer allocator.free(path);

    std.Io.Dir.createDirAbsolute(dvui.io, dir, .default_dir) catch {}; // best-effort; exists is fine
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = blob }) catch |err| {
        dvui.log.warn("settings: failed to migrate '{s}' plugin settings: {s}", .{ id, @errorName(err) });
    };
}

/// One-shot (per plugin id) split of a pre-R7 `settings.zon`'s embedded `plugins` list (each
/// entry an escaped-zon-text blob under a shared `plugins = .{ .{ .id = ..., .data = ... }, ... }`
/// key) out to its own `<plugins_dir>/<id>.settings.zon` file — see docs/PLUGIN_MANIFEST_PLAN.md.
/// Runs on every load but is a no-op per id once that id's file already exists, so a live edit
/// made through the new per-file system is never clobbered by a stale embedded blob that just
/// hasn't been overwritten by a save yet (`Settings.serialize` no longer emits `plugins` at all).
/// `zon_data` is `settings.zon`'s raw (already-read) bytes; a null `plugins_dir` (wasm/headless)
/// makes this a no-op.
pub fn splitEmbeddedPluginsIfNeeded(allocator: std.mem.Allocator, zon_data: [:0]const u8, plugins_dir: ?[]const u8) void {
    const dir = plugins_dir orelse return;

    const Embedded = struct {
        plugins: []const struct { id: []const u8, data: []const u8 } = &.{},
    };
    const parsed = std.zon.parse.fromSliceAlloc(Embedded, allocator, zon_data, null, .{ .ignore_unknown_fields = true }) catch return;
    defer std.zon.parse.free(allocator, parsed);
    if (parsed.plugins.len == 0) return;

    for (parsed.plugins) |entry| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}.settings.zon", .{ dir, entry.id }) catch continue;
        defer allocator.free(path);

        // Don't clobber a file already written through the new per-plugin system.
        if (fizzy.fs.read(allocator, dvui.io, path) catch null) |existing| {
            allocator.free(existing);
            continue;
        }

        std.Io.Dir.createDirAbsolute(dvui.io, dir, .default_dir) catch {}; // best-effort; exists is fine
        std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = entry.data }) catch |err| {
            dvui.log.warn("settings: failed to split embedded '{s}' plugin settings: {s}", .{ entry.id, @errorName(err) });
        };
    }
}

/// Recursively renders a `std.json.Value` as zon source text (a plugin's `<id>.settings.zon`
/// file's actual contents — see docs/PLUGIN_MANIFEST_PLAN.md). Covers every `Value` variant
/// that can appear in a plugin's own settings blob.
fn jsonValueToZonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeJsonValueAsZon(&aw.writer, value);
    return aw.toOwnedSlice();
}

fn writeJsonValueAsZon(w: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try w.print("\"{f}\"", .{std.zig.fmtString(s)}),
        .array => |arr| {
            try w.writeAll(".{");
            for (arr.items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try writeJsonValueAsZon(w, item);
            }
            try w.writeAll("}");
        },
        .object => |obj| {
            try w.writeAll(".{ ");
            var it = obj.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeAll(", ");
                first = false;
                try w.print(".{f} = ", .{std.zig.fmtId(e.key_ptr.*)});
                try writeJsonValueAsZon(w, e.value_ptr.*);
            }
            try w.writeAll(" }");
        },
    }
}
