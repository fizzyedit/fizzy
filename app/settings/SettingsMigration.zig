//! One-shot migrations for `settings.zon` layout changes — see docs/PLUGIN_MANIFEST_PLAN.md.
//!
//! 1. `mergeLegacyPerPluginFiles` — pre-R10 one-file-per-plugin (`<plugins_dir>/<id>.settings.zon`)
//!    into the merged `.plugins.<id>` field (R10).
//! 2. `migrateToPerPluginEnabled` — pre-R12 flat `.plugins.<id> = .{ <author fields> }` + top-level
//!    `disabled_plugins` into nested `.{ .enabled = …, .settings = .{ … } }` (R12).
const std = @import("std");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const Settings = @import("Settings.zig");
const SettingsPluginsZon = @import("SettingsPluginsZon.zig");

const legacy_suffix = ".settings.zon";

/// Scans `<plugins_dir>/*.settings.zon` (the pre-R10 per-plugin layout) and, for each one, upserts
/// its content into `settings_zon_path`'s `.plugins.<id>` field (via `SettingsPluginsZon.upsertOne`,
/// which never clobbers an id already present there) and deletes the old file on success. No-op
/// if `plugins_dir` is null (wasm/headless) or the directory doesn't exist yet. Best-effort: a
/// single bad entry is logged and skipped rather than aborting the rest.
pub fn mergeLegacyPerPluginFiles(allocator: std.mem.Allocator, settings_zon_path: []const u8, plugins_dir: ?[]const u8) void {
    const dir_path = plugins_dir orelse return;
    var dir = std.Io.Dir.cwd().openDir(dvui.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(dvui.io);

    var iter = dir.iterate();
    while (iter.next(dvui.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, legacy_suffix)) continue;
        const id = entry.name[0 .. entry.name.len - legacy_suffix.len];
        if (id.len == 0) continue;

        mergeOne(allocator, settings_zon_path, dir_path, id) catch |err| {
            dvui.log.warn("settings: failed to migrate legacy '{s}' settings: {s}", .{ id, @errorName(err) });
        };
    }
}

fn mergeOne(allocator: std.mem.Allocator, settings_zon_path: []const u8, plugins_dir: []const u8, id: []const u8) !void {
    const legacy_path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ plugins_dir, id, legacy_suffix });
    defer allocator.free(legacy_path);

    const legacy_text = try core.fs.read(allocator, dvui.io, legacy_path);
    defer allocator.free(legacy_text);

    const existing = core.fs.readZ(allocator, dvui.io, settings_zon_path) catch null;
    defer if (existing) |e| allocator.free(e);

    const composed = try SettingsPluginsZon.upsertOne(allocator, existing, .{ .id = id, .text = legacy_text });
    defer allocator.free(composed);

    try core.fs.write(dvui.io, settings_zon_path, composed);
    std.Io.Dir.deleteFileAbsolute(dvui.io, legacy_path) catch |err| {
        dvui.log.warn("settings: migrated legacy '{s}' settings but failed to delete old file: {s}", .{ id, @errorName(err) });
    };
}

/// Pre-R12 on-disk shape still parseable for this one-shot: a top-level `disabled_plugins` list
/// plus flat `.plugins.<id> = .{ <author fields> }` blocks (no nested `.settings` / `.enabled`).
const LegacyDisk = struct {
    disabled_plugins: []const []const u8 = &.{},
};

/// Rewrites pre-R12 flat `.plugins.<id>` blocks + top-level `disabled_plugins` into the nested
/// `.{ .enabled = …, .settings = .{ … } }` shape (and drops `disabled_plugins` from the file).
/// Also writes `.enabled = true` for any on-disk plugin directory that was previously enabled by
/// default (absent from `disabled_plugins`) but had no settings block — under R12, absence means
/// disabled. Idempotent: already-nested blocks are left alone; a file with no legacy list and no
/// flat blocks is a no-op. Best-effort throughout.
pub fn migrateToPerPluginEnabled(allocator: std.mem.Allocator, settings_zon_path: []const u8, plugins_dir: ?[]const u8) void {
    const data = core.fs.readZ(allocator, dvui.io, settings_zon_path) catch return;
    defer allocator.free(data);

    @setEvalBranchQuota(10_000);
    const legacy = std.zon.parse.fromSliceAlloc(LegacyDisk, allocator, data, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        dvui.log.warn("settings: could not parse settings.zon for R12 enabled migration ({s}); skipping", .{@errorName(err)});
        return;
    };
    defer std.zon.parse.free(allocator, legacy);

    const blocks = SettingsPluginsZon.listPluginBlocks(allocator, data) catch return;
    defer SettingsPluginsZon.freeEntries(allocator, blocks);

    var overlay: std.ArrayListUnmanaged(SettingsPluginsZon.Entry) = .empty;
    defer {
        for (overlay.items) |e| {
            // overlay ids are borrowed (from blocks / dupe below); texts we allocate are freed here.
            if (e.text) |t| allocator.free(t);
        }
        // Free any id we duped for on-disk plugins that had no prior block.
        for (overlay.items) |e| {
            var borrowed = false;
            for (blocks) |b| {
                if (e.id.ptr == b.id.ptr) {
                    borrowed = true;
                    break;
                }
            }
            if (!borrowed) allocator.free(e.id);
        }
        overlay.deinit(allocator);
    }

    var needs_write = legacy.disabled_plugins.len > 0;

    for (blocks) |e| {
        const text = e.text orelse continue;
        if (isAlreadyNested(allocator, text)) continue;
        needs_write = true;
        const enabled = !containsId(legacy.disabled_plugins, e.id);
        const settings_text: ?[]const u8 = if (isEmptyStructLiteral(text)) null else text;
        const new_block = SettingsPluginsZon.composePluginIdBlock(allocator, .{ .enabled = enabled }, settings_text) catch |err| {
            dvui.log.warn("settings: failed to compose R12 block for '{s}': {s}", .{ e.id, @errorName(err) });
            continue;
        };
        overlay.append(allocator, .{ .id = e.id, .text = new_block }) catch {
            allocator.free(new_block);
        };
    }

    // Old default was "enabled unless listed in disabled_plugins." New default is disabled
    // (no entry). Any on-disk plugin that was previously auto-loaded needs an explicit
    // `.enabled = true` written now, even if it had no settings block.
    if (plugins_dir) |dir_path| {
        var dir = std.Io.Dir.cwd().openDir(dvui.io, dir_path, .{ .iterate = true }) catch null;
        if (dir) |*d| {
            defer d.close(dvui.io);
            var iter = d.iterate();
            while (iter.next(dvui.io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                const id = entry.name;
                if (id.len == 0 or id[0] == '.') continue;
                if (containsId(legacy.disabled_plugins, id)) continue;
                if (hasBlock(blocks, id)) continue;
                // Already covered by an overlay entry? (shouldn't be — no prior block)
                if (overlayHas(overlay.items, id)) continue;
                needs_write = true;
                const new_block = SettingsPluginsZon.composePluginIdBlock(allocator, .{ .enabled = true }, null) catch continue;
                const id_dup = allocator.dupe(u8, id) catch {
                    allocator.free(new_block);
                    continue;
                };
                overlay.append(allocator, .{ .id = id_dup, .text = new_block }) catch {
                    allocator.free(id_dup);
                    allocator.free(new_block);
                };
            }
        }
    }

    if (!needs_write) return;

    // Regenerate fizzy's own fields from a Settings parse (unknown fields — including the legacy
    // `disabled_plugins` list — are ignored), so the rewritten file drops that list for free.
    const parsed = Settings.parseOnly(allocator, data) catch |err| {
        dvui.log.warn("settings: could not re-serialize fizzy's own fields for R12 migration ({s}); skipping", .{@errorName(err)});
        return;
    };
    defer Settings.freeParsed(allocator, parsed);

    const fizzy_text = Settings.serialize(&parsed, allocator) catch |err| {
        dvui.log.warn("settings: could not serialize fizzy's own fields for R12 migration ({s}); skipping", .{@errorName(err)});
        return;
    };
    defer allocator.free(fizzy_text);

    const composed = SettingsPluginsZon.composeMergedText(allocator, fizzy_text, data, overlay.items) catch |err| {
        dvui.log.warn("settings: failed to compose R12-migrated settings.zon ({s}); skipping", .{@errorName(err)});
        return;
    };
    defer allocator.free(composed);

    core.fs.write(dvui.io, settings_zon_path, composed) catch |err| {
        dvui.log.warn("settings: failed to write R12-migrated settings.zon ({s})", .{@errorName(err)});
        return;
    };
    dvui.log.info("settings: migrated plugin blocks to per-plugin .enabled/.settings (R12)", .{});
}

/// Whether `text` is already an R12-shaped block rather than a pre-R12 flat one.
///
/// A block counts as modern the moment it carries **any** fizzy-reserved field, or a nested
/// `.settings`. Getting this wrong is destructive in a way that is easy to miss: a block judged
/// "flat" has its entire contents wrapped into `.settings` and stamped `.enabled = true`, which
/// would silently reinterpret fizzy-reserved data as plugin-author settings — an `.extensions`
/// assignment would stop routing files and reappear as an unknown author field.
///
/// The reserved names come from `SettingsPluginsZon.Reserved` itself rather than a hand-kept
/// list, so adding a field there can never leave this check behind. (It already had: only
/// `enabled` was listed, so an `.auto_update = false`-only block — which the app itself can
/// write for a disabled plugin — was being swallowed too.)
fn isAlreadyNested(gpa: std.mem.Allocator, text: []const u8) bool {
    const z = gpa.dupeZ(u8, text) catch return false;
    defer gpa.free(z);

    if (SettingsPluginsZon.extractField(gpa, z, "settings")) |s| {
        gpa.free(s);
        return true;
    }
    inline for (@typeInfo(SettingsPluginsZon.Reserved).@"struct".fields) |field| {
        if (SettingsPluginsZon.extractField(gpa, z, field.name)) |s| {
            gpa.free(s);
            return true;
        }
    }
    return false;
}

fn isEmptyStructLiteral(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.mem.eql(u8, trimmed, ".{}") or std.mem.eql(u8, trimmed, ".{ }");
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| {
        if (std.mem.eql(u8, x, id)) return true;
    }
    return false;
}

fn hasBlock(blocks: []const SettingsPluginsZon.Entry, id: []const u8) bool {
    for (blocks) |e| {
        if (std.mem.eql(u8, e.id, id)) return true;
    }
    return false;
}

fn overlayHas(overlay: []const SettingsPluginsZon.Entry, id: []const u8) bool {
    for (overlay) |e| {
        if (std.mem.eql(u8, e.id, id)) return true;
    }
    return false;
}
