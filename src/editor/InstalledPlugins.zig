//! Settings → Plugins: local plugin inventory (no network store yet).
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("sdk");
const fizzy = @import("../fizzy.zig");

const version = sdk.version;
const dylib = sdk.dylib;

pub fn register(host: *sdk.Host) !void {
    try host.registerSettingsSection(.{
        .id = "shell.settings.plugins",
        .title = "Plugins",
        .draw = drawPlugins,
    });
}

fn isBundled(id: []const u8) bool {
    return std.mem.eql(u8, id, "pixi") or
        std.mem.eql(u8, id, "workbench") or
        std.mem.eql(u8, id, "code");
}

fn drawPlugins(_: ?*anyopaque) anyerror!void {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer vbox.deinit();

    var host_sdk_buf: [96]u8 = undefined;
    const host_sdk = std.fmt.bufPrint(&host_sdk_buf, "Host SDK {d}.{d}.{d} · ABI 0x{x}", .{
        version.sdk_version.major,
        version.sdk_version.minor,
        version.sdk_version.patch,
        dylib.abi_fingerprint,
    }) catch "Host SDK ?";
    dvui.labelNoFmt(@src(), host_sdk, .{}, .{ .margin = .{ .h = 4 } });

    dvui.labelNoFmt(@src(), "Registered plugins", .{}, .{
        .font = dvui.Font.theme(.heading),
        .margin = .{ .y = 8 },
    });

    for (fizzy.editor.host.plugins.items, 0..) |plugin, i| {
        const tag: []const u8 = if (isBundled(plugin.id)) " (bundled)" else "";
        dvui.label(@src(), "• {s} — {s}{s}", .{ plugin.display_name, plugin.id, tag }, .{ .id_extra = i });
    }

    if (fizzy.editor.loaded_plugin_libs.items.len > 0) {
        dvui.labelNoFmt(@src(), "User dylibs", .{}, .{
            .font = dvui.Font.theme(.heading),
            .margin = .{ .y = 8 },
        });
        for (fizzy.editor.loaded_plugin_libs.items, 0..) |loaded, i| {
            const vi = loaded.version_info;
            var ver_buf: [32]u8 = undefined;
            const ver = std.fmt.bufPrint(&ver_buf, "{d}.{d}.{d}", .{
                vi.plugin_version.major,
                vi.plugin_version.minor,
                vi.plugin_version.patch,
            }) catch "?";
            dvui.label(
                @src(),
                "• {s} — v{s} (SDK {d}.{d}.{d})",
                .{
                    loaded.plugin_id,
                    ver,
                    vi.built_with_sdk_version.major,
                    vi.built_with_sdk_version.minor,
                    vi.built_with_sdk_version.patch,
                },
                .{ .id_extra = i },
            );
        }
    }

    if (fizzy.editor.failed_user_plugins.items.len > 0) {
        dvui.labelNoFmt(@src(), "Load failures", .{}, .{
            .font = dvui.Font.theme(.heading),
            .margin = .{ .y = 8 },
            .color_text = dvui.themeGet().color(.err, .text),
        });
        for (fizzy.editor.failed_user_plugins.items, 0..) |f, i| {
            if (f.detail) |detail| {
                dvui.label(@src(), "• {s} — {s} ({s})", .{ f.id, f.reason, detail }, .{ .id_extra = i });
            } else {
                dvui.label(@src(), "• {s} — {s}", .{ f.id, f.reason }, .{ .id_extra = i });
            }
        }
    }
}
