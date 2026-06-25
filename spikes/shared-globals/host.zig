//! The near-empty host exe. It owns the dvui state (Window + per-frame arena +
//! FreeType handle), then dlopens the plugin and lets it draw into that state —
//! modelling fizzy's shell driving a plugin's render across the dylib boundary.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

pub fn main() !void {
    // The host owns the per-frame arena (as dvui's Window owns its arena).
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();

    var ft = core.FreeType{}; // host owns the FreeType handle
    var win = core.Window{ .arena = arena_inst.allocator() };
    core.setCurrentWindow(&win);
    core.setFreeType(&ft);
    _ = try core.label("host-drawn"); // host renders 1 widget itself
    std.debug.print("[host] after host label(): widget_count={d} shape_calls={d}\n", .{ win.widget_count, ft.shape_calls });

    const ext = switch (builtin.os.tag) {
        .macos => "dylib",
        .windows => "dll",
        else => "so",
    };
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "zig-out/lib/libplugin.{s}", .{ext});

    var lib = try std.DynLib.open(path);
    defer lib.close();

    const set_ctx = lib.lookup(*const fn (?*core.Window, ?*core.FreeType) callconv(.c) void, "plugin_set_context") orelse return error.SymMissing;
    const draw = lib.lookup(*const fn () callconv(.c) usize, "plugin_draw") orelse return error.SymMissing;
    const plugin_global_addr = lib.lookup(*const fn () callconv(.c) usize, "plugin_current_window_addr") orelse return error.SymMissing;

    std.debug.print("[host] host current_window @ {x}, plugin current_window @ {x} ({s})\n", .{
        core.currentWindowAddr(),
        plugin_global_addr(),
        if (core.currentWindowAddr() == plugin_global_addr()) "SHARED" else "SEPARATE → inject",
    });

    // Mechanism B: inject the host's dvui state into the plugin.
    set_ctx(&win, &ft);
    const last_len = draw(); // plugin renders 3 labels via host arena + host FreeType

    std.debug.print("[host] plugin allocated last string len={d} (expect 9 for \"readme.md\")\n", .{last_len});
    std.debug.print("[host] after plugin draw: widget_count={d} (expect 4) shape_calls={d} (expect 4)\n", .{ win.widget_count, ft.shape_calls });

    const ok = win.widget_count == 4 and ft.shape_calls == 4 and last_len == 9 and win.magic == 0xDEADBEEF;
    if (ok) {
        std.debug.print("\n[host] ✅ SUCCESS: plugin drove the host's Window, allocated in the host's arena, and used the host's FreeType handle — across the dylib boundary.\n", .{});
    } else {
        std.debug.print("\n[host] ❌ FAIL: count={d} shape={d} len={d} magic={x}\n", .{ win.widget_count, ft.shape_calls, last_len, win.magic });
        return error.SpikeFailed;
    }
}
