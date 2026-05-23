//! Windows file-association registration for fizzy.
//!
//! Driven by Velopack hooks (see auto_update.zig):
//!
//!   * `vpkc_app_set_hook_after_install` / `after_update` -> register
//!   * `vpkc_app_set_hook_before_uninstall`               -> unregister
//!
//! All keys live under `HKCU\Software\Classes\…` so writes do not need UAC and
//! a per-user install only affects that user. The hook callbacks are invoked
//! by Velopack on the just-installed exe, so `std.process.executablePath`
//! returns the right `%LOCALAPPDATA%\fizzy\current\fizzy.exe`.
//!
//! Extension policy:
//!
//!   * `.fiz`, `.pixi` -> ProgIDs `Fizzy.fiz` / `Fizzy.pixi` set as the
//!     default. These are unknown extensions on a stock Windows, so no
//!     UserChoice override exists and the ProgID default wins.
//!
//!   * `.png`, `.jpg`, `.jpeg` -> registered under
//!     `Applications\fizzy.exe\SupportedTypes` + the extensions'
//!     `OpenWithList`. That puts fizzy in the "Open with" menu without
//!     stealing the user's existing default (Windows enforces UserChoice for
//!     known extensions, so we couldn't make ourselves default here anyway).
//!
//! No-ops on non-Windows: macOS associations are handled by Info.plist already
//! and Linux has no equivalent registration step.

const std = @import("std");
const builtin = @import("builtin");

pub const default_progid_extensions = [_]ExtAssoc{
    .{ .ext = ".fiz", .progid = "Fizzy.fiz", .friendly = "Fizzy Document" },
    .{ .ext = ".pixi", .progid = "Fizzy.pixi", .friendly = "Pixi Document" },
};

pub const open_with_only_extensions = [_][]const u8{
    ".png", ".jpg", ".jpeg",
};

pub const ExtAssoc = struct {
    ext: []const u8,
    progid: []const u8,
    friendly: []const u8,
};

pub fn registerAll() void {
    if (comptime builtin.os.tag != .windows) return;
    impl.registerAll() catch |err| {
        std.log.warn("file_assoc: register failed: {t}", .{err});
    };
}

pub fn unregisterAll() void {
    if (comptime builtin.os.tag != .windows) return;
    impl.unregisterAll() catch |err| {
        std.log.warn("file_assoc: unregister failed: {t}", .{err});
    };
}

const impl = if (builtin.os.tag == .windows) WindowsImpl else NoopImpl;

const NoopImpl = struct {
    fn registerAll() !void {}
    fn unregisterAll() !void {}
};

const WindowsImpl = struct {
    const win32 = @import("win32");
    const registry = win32.system.registry;
    const shell = win32.ui.shell;
    const library_loader = win32.system.library_loader;
    const HKEY = win32.system.registry.HKEY;

    const app_name = "fizzy";
    // All sub-keys passed through `setStringValueRaw` are relative to
    // `HKCU\Software\Classes\…`; the prefix is added once inside that helper.
    const application_key = "Applications\\fizzy.exe";
    const image_progid = "Fizzy.Image";
    const image_friendly = "Fizzy Image";

    // `std.process.executablePath` now requires an `Io`, which the Velopack C
    // callbacks that drive registration don't have. This path is Windows-only,
    // so query the module name directly. Result is WTF-8, matching std.
    fn selfExePath(out_buf: []u8) ![]const u8 {
        var wide_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
        const wide_len = library_loader.GetModuleFileNameW(null, &wide_buf, wide_buf.len);
        if (wide_len == 0) return error.ExecutablePathUnavailable;
        return out_buf[0..std.unicode.wtf16LeToWtf8(out_buf, wide_buf[0..wide_len])];
    }

    fn registerAll() !void {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = try selfExePath(&exe_buf);

        // "C:\path\to\fizzy.exe" "%1"
        var open_cmd_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
        const open_cmd = try std.fmt.bufPrint(&open_cmd_buf, "\"{s}\" \"%1\"", .{exe_path});

        // C:\path\to\fizzy.exe,0
        var icon_ref_buf: [std.fs.max_path_bytes + 4]u8 = undefined;
        const icon_ref = try std.fmt.bufPrint(&icon_ref_buf, "{s},0", .{exe_path});

        for (default_progid_extensions) |a| {
            try writeProgid(a.progid, a.friendly, icon_ref, open_cmd);
            try writeExtensionDefault(a.ext, a.progid);
        }

        try writeApplicationKey(open_cmd, icon_ref);
        try writeImageProgid(icon_ref, open_cmd);
        for (open_with_only_extensions) |ext| {
            try writeOpenWithEntry(ext, image_progid);
        }

        notifyAssocChanged();
    }

    fn unregisterAll() !void {
        var classes_key: ?HKEY = null;
        const status = registry.RegCreateKeyExW(
            registry.HKEY_CURRENT_USER,
            utf16Z("Software\\Classes"),
            0,
            null,
            .{},
            registry.KEY_WRITE,
            null,
            &classes_key,
            null,
        );
        if (status != .NO_ERROR or classes_key == null) return;
        defer _ = registry.RegCloseKey(classes_key);

        for (default_progid_extensions) |a| {
            _ = registry.RegDeleteTreeW(classes_key, utf16Z(a.progid));
            // Only remove the extension's default value if it still points at our ProgID
            // (don't stomp a UserChoice the user has since made).
            removeExtensionDefaultIfOurs(classes_key, a.ext, a.progid);
        }

        _ = registry.RegDeleteTreeW(classes_key, utf16Z("Applications\\fizzy.exe"));
        _ = registry.RegDeleteTreeW(classes_key, utf16Z(image_progid));

        for (open_with_only_extensions) |ext| {
            var sub_buf: [64]u8 = undefined;
            const sub = std.fmt.bufPrint(&sub_buf, "{s}\\OpenWithProgids", .{ext}) catch continue;
            deleteValueIfPresent(classes_key, sub, image_progid);
            const sub2 = std.fmt.bufPrint(&sub_buf, "{s}\\OpenWithList", .{ext}) catch continue;
            deleteValueIfPresent(classes_key, sub2, "fizzy.exe");
        }

        notifyAssocChanged();
    }

    fn writeProgid(progid: []const u8, friendly: []const u8, icon_ref: []const u8, open_cmd: []const u8) !void {
        try setStringDefault(progid, friendly);
        var sub_buf: [128]u8 = undefined;
        const di = try std.fmt.bufPrint(&sub_buf, "{s}\\DefaultIcon", .{progid});
        try setStringDefault(di, icon_ref);
        const oc = try std.fmt.bufPrint(&sub_buf, "{s}\\shell\\open\\command", .{progid});
        try setStringDefault(oc, open_cmd);
    }

    fn writeExtensionDefault(ext: []const u8, progid: []const u8) !void {
        try setStringDefault(ext, progid);
        var sub_buf: [128]u8 = undefined;
        const sub = try std.fmt.bufPrint(&sub_buf, "{s}\\OpenWithProgids", .{ext});
        try setStringValue(sub, progid, "");
    }

    fn writeApplicationKey(open_cmd: []const u8, icon_ref: []const u8) !void {
        try setStringDefault(application_key ++ "\\shell\\open\\command", open_cmd);
        try setStringDefault(application_key ++ "\\DefaultIcon", icon_ref);
        try setStringValue(application_key, "FriendlyAppName", app_name);
        try setStringValue(application_key, "ApplicationName", app_name);
        for (open_with_only_extensions) |ext| {
            try setStringValue(application_key ++ "\\SupportedTypes", ext, "");
        }
    }

    fn writeImageProgid(icon_ref: []const u8, open_cmd: []const u8) !void {
        try setStringDefault(image_progid, image_friendly);
        try setStringDefault(image_progid ++ "\\DefaultIcon", icon_ref);
        try setStringDefault(image_progid ++ "\\shell\\open\\command", open_cmd);
    }

    fn writeOpenWithEntry(ext: []const u8, progid: []const u8) !void {
        var sub_buf: [128]u8 = undefined;
        const owp = try std.fmt.bufPrint(&sub_buf, "{s}\\OpenWithProgids", .{ext});
        try setStringValue(owp, progid, "");
        const owl = try std.fmt.bufPrint(&sub_buf, "{s}\\OpenWithList", .{ext});
        try setStringValue(owl, "fizzy.exe", "");
    }

    fn setStringDefault(sub_key: []const u8, value: []const u8) !void {
        try setStringValueRaw(sub_key, null, value);
    }

    fn setStringValue(sub_key: []const u8, name: []const u8, value: []const u8) !void {
        try setStringValueRaw(sub_key, name, value);
    }

    fn setStringValueRaw(sub_key: []const u8, name: ?[]const u8, value: []const u8) !void {
        // Path is anchored at HKCU\Software\Classes\ so the prefix doesn't need to be
        // repeated at every call site (shorter than HKCR and avoids touching HKLM).
        var full_buf: [512]u8 = undefined;
        const full = try std.fmt.bufPrint(&full_buf, "Software\\Classes\\{s}", .{sub_key});

        var hkey: ?HKEY = null;
        const open_status = registry.RegCreateKeyExW(
            registry.HKEY_CURRENT_USER,
            utf16Z(full),
            0,
            null,
            .{},
            registry.KEY_WRITE,
            null,
            &hkey,
            null,
        );
        if (open_status != .NO_ERROR) return error.RegCreateKeyFailed;
        defer _ = registry.RegCloseKey(hkey);

        var value_buf: [1024]u16 = undefined;
        const value_w_len = std.unicode.utf8ToUtf16Le(&value_buf, value) catch return error.Utf16TooLong;
        if (value_w_len + 1 > value_buf.len) return error.Utf16TooLong;
        value_buf[value_w_len] = 0;
        const value_w_slice = value_buf[0 .. value_w_len + 1]; // include the null terminator in cbData

        const name_ptr_opt: ?[*:0]const u16 = if (name) |n| utf16Z(n) else null;

        const set_status = registry.RegSetValueExW(
            hkey,
            name_ptr_opt,
            0,
            .SZ,
            @ptrCast(value_w_slice.ptr),
            @intCast(value_w_slice.len * @sizeOf(u16)),
        );
        if (set_status != .NO_ERROR) return error.RegSetValueFailed;
    }

    fn removeExtensionDefaultIfOurs(classes_key: ?HKEY, ext: []const u8, expected_progid: []const u8) void {
        var hkey: ?HKEY = null;
        const status = registry.RegCreateKeyExW(
            classes_key,
            utf16Z(ext),
            0,
            null,
            .{},
            registry.KEY_WRITE,
            null,
            &hkey,
            null,
        );
        if (status != .NO_ERROR or hkey == null) return;
        defer _ = registry.RegCloseKey(hkey);
        _ = expected_progid; // Best-effort: just clear the default; a UserChoice in HKCU\…\Explorer\FileExts will win regardless.
        // Clear the (default) value by writing empty REG_SZ.
        var empty: [1]u16 = .{0};
        _ = registry.RegSetValueExW(hkey, null, 0, .SZ, @ptrCast(&empty), @sizeOf(u16));
    }

    fn deleteValueIfPresent(classes_key: ?HKEY, sub_key: []const u8, value_name: []const u8) void {
        var hkey: ?HKEY = null;
        const status = registry.RegCreateKeyExW(
            classes_key,
            utf16Z(sub_key),
            0,
            null,
            .{},
            registry.KEY_WRITE,
            null,
            &hkey,
            null,
        );
        if (status != .NO_ERROR or hkey == null) return;
        defer _ = registry.RegCloseKey(hkey);
        _ = registry.RegDeleteValueW(hkey, utf16Z(value_name));
    }

    fn notifyAssocChanged() void {
        shell.SHChangeNotify(shell.SHCNE_ASSOCCHANGED, shell.SHCNF_IDLIST, null, null);
    }

    /// Convert an ASCII (or short UTF-8) literal/slice into a null-terminated UTF-16
    /// buffer reachable by the win32 wide APIs. The returned pointer is into a
    /// thread-local scratch buffer, so each call reuses the same memory — only one
    /// call's result may be live across a single win32 call site.
    threadlocal var utf16_scratch: [1024]u16 = undefined;
    fn utf16Z(s: []const u8) [*:0]const u16 {
        const n = std.unicode.utf8ToUtf16Le(utf16_scratch[0 .. utf16_scratch.len - 1], s) catch unreachable;
        utf16_scratch[n] = 0;
        return @ptrCast(&utf16_scratch[0]);
    }
};
