//! In-memory ring buffer capturing every `std.log`/`dvui.log` call in the process (wired up
//! via `App.zig`'s `logFn` wrapper), rendered by the "Output" bottom panel (`OutputPanel.zig`).
//! Plugins reach the same buffer through `Host.logLine` (see `appendLine`) — e.g. the `zig`
//! plugin's LSP client forwards zls's subprocess stderr there.
//!
//! Backed by `page_allocator` (no shared state to synchronize) rather than the app's GPA, so
//! logging works before the app/GPA exist and never entangles with their teardown order.

const std = @import("std");

pub const Line = struct {
    level: std.log.Level,
    /// Owned copy of the source scope/plugin id ("fizzy", "zig", "text", …) — kept separate
    /// from `text` (rather than parsed back out of it) so the Output panel can filter by
    /// plugin without re-parsing every line's formatted prefix each frame.
    scope: []const u8,
    /// Fully formatted, e.g. "warn(text): dylib load failed: ...".
    text: []const u8,
};

const max_lines = 2000;
const evict_batch = 200;
const allocator = std.heap.page_allocator;

// A plain spinlock rather than `std.Io.Mutex`: this can be called before `dvui.io` exists
// (the very first startup log line included), and contention here is negligible — occasional
// writes from a log call, one read per panel draw.
var spin: std.atomic.Mutex = .unlocked;
var lines: std.ArrayListUnmanaged(Line) = .empty;

/// Matches `std.Options.logFn`'s signature so it can be assigned directly as (or called
/// from) a `logFn` wrapper. Used for fizzy's own (comptime-scoped) `std.log` calls —
/// this covers every statically-linked scope (`.default`, dvui's own `.dvui`, the SDL
/// backend's `SDLBACKEND`/`SDL_SYSTEM`/`SDL_RENDER`, …), not just fizzy's literal code.
/// All of it is grouped under one `"fizzy"` tab rather than one tab per internal scope —
/// only genuine plugin dylibs (via `appendLine`/`Host.logLine`) get their own tab, since
/// those are the only scopes a user would actually want to filter on independently.
pub fn append(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const prefix = comptime if (scope == .default)
        level.asText() ++ ": "
    else
        level.asText() ++ "(" ++ @tagName(scope) ++ "): ";
    const text = std.fmt.allocPrint(allocator, prefix ++ format, args) catch return;
    store(level, @import("app").AppInfo.current.name, text);
}

/// Runtime counterpart of `append`, for callers that only have runtime strings — namely
/// `Host.logLine`, which plugins call across the SDK's plain (non-`comptime`) vtable. `scope`
/// here is always a real plugin id ("zig", "pixi", "ghostty", …), so — unlike `append` above —
/// it's used as-is for the Output panel's per-plugin tab, not collapsed into `"fizzy"`.
pub fn appendLine(level: std.log.Level, scope: []const u8, message: []const u8) void {
    // Not `level.asText()`: that requires a comptime `self` (fine for `append` above, where
    // `level` is comptime), but `level` here is a genuine runtime value.
    const level_text: []const u8 = switch (level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    const text = std.fmt.allocPrint(allocator, "{s}({s}): {s}", .{ level_text, scope, message }) catch return;
    store(level, scope, text);
}

/// Takes ownership of `text` (already fully formatted): stores it (alongside its own copy of
/// `scope`, which may be a borrowed slice from a plugin dylib that could later unload), evicting
/// the oldest batch first if the ring buffer is full.
fn store(level: std.log.Level, scope: []const u8, text: []const u8) void {
    lock();
    defer unlock();

    const scope_copy = allocator.dupe(u8, scope) catch {
        allocator.free(text);
        return;
    };

    if (lines.items.len >= max_lines) {
        for (lines.items[0..evict_batch]) |old| {
            allocator.free(old.text);
            allocator.free(old.scope);
        }
        std.mem.copyForwards(Line, lines.items[0 .. lines.items.len - evict_batch], lines.items[evict_batch..]);
        lines.shrinkRetainingCapacity(lines.items.len - evict_batch);
    }
    lines.append(allocator, .{ .level = level, .scope = scope_copy, .text = text }) catch {
        allocator.free(text);
        allocator.free(scope_copy);
    };
}

/// Locks the log for reading; pair with `unlock` around a call to `items`.
pub fn lock() void {
    while (!spin.tryLock()) {}
}

pub fn unlock() void {
    spin.unlock();
}

/// Only valid while holding the lock (see `lock`/`unlock`).
pub fn items() []const Line {
    return lines.items;
}

pub fn clear() void {
    lock();
    defer unlock();
    for (lines.items) |line| {
        allocator.free(line.text);
        allocator.free(line.scope);
    }
    lines.clearRetainingCapacity();
}
