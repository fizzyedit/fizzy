const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const build_opts = @import("build_opts");
const auto_update = @import("../../auto_update.zig");
const update_notify = @import("../../update_notify.zig");
const assets = @import("assets");

fn dialogButton(src: std.builtin.SourceLocation, label_text: []const u8, style: dvui.Theme.Style.Name, tab_idx: u16, id_extra: usize) bool {
    const opts: dvui.Options = .{
        .tab_index = tab_idx,
        .style = style,
        .id_extra = id_extra,
        .box_shadow = .{
            .color = .black,
            .alpha = 0.25,
            .offset = .{ .x = -4, .y = 4 },
            .fade = 8,
        },
    };
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, opts);
    defer button.deinit();
    button.processEvents();
    button.drawFocus();
    button.drawBackground();
    dvui.labelNoFmt(src, label_text, .{}, opts.strip().override(button.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));
    return button.clicked();
}

/// True if the about dialog is already showing.
pub fn active(win: *dvui.Window) bool {
    var it = win.dialogs.iterator(null);
    while (it.next()) |d| {
        const df = dvui.dataGet(null, d.id, "_displayFn", fizzy.dvui.DisplayFn) orelse continue;
        if (df == dialog) return true;
    }
    return false;
}

pub fn request() void {
    if (active(dvui.currentWindow())) return;
    status_line = " ";
    update_ready_after_check = false;
    var mutex = fizzy.dvui.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "About Fizzy",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .max_size = .{ .w = 440, .h = 400 },
        .header_kind = .info,
    });
    mutex.mutex.unlock(dvui.io);
}

var status_line_buf: [384]u8 = undefined;
var status_line: []const u8 = " ";
/// After “Check for updates” returns `.available`; cleared when opening/closing dialog or starting a new check.
var update_ready_after_check: bool = false;

fn setStatus(msg: []const u8) void {
    const n = @min(msg.len, status_line_buf.len);
    @memcpy(status_line_buf[0..n], msg[0..n]);
    status_line = status_line_buf[0..n];
}

pub fn dialog(_: dvui.Id) anyerror!bool {
    const alloc = fizzy.app.allocator;

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer outer.deinit();

    const body = dvui.Font.theme(.body);
    const body_small = body.larger(-1.0);
    const heading = dvui.Font.theme(.heading);

    // Fox at the top, centered. Use a fixed natural size (96×96) so it
    // doesn't blow out the dialog regardless of the source PNG's resolution.
    if (fizzy.image.fromImageFileBytes("fox.png", assets.files.@"fox.png", .ptr)) |fox_src| {
        _ = dvui.image(@src(), .{ .source = fox_src, .shrink = .ratio }, .{
            .gravity_x = 0.5,
            .min_size_content = .{ .w = 96, .h = 96 },
        });
    } else |_| {}

    // Website link.
    {
        var link_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5, .padding = .{ .y = 4, .h = 6 } });
        defer link_row.deinit();
        dvui.link(@src(), .{ .url = "https://fizzyed.it", .label = "fizzyed.it" }, .{
            .font = heading,
            .color_text = dvui.themeGet().color(.highlight, .fill),
        });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 8 } });

    // Version block.
    dvui.labelNoFmt(@src(), "Version", .{}, .{ .font = heading, .gravity_x = 0.5 });
    dvui.label(@src(), "{s}", .{build_opts.app_version}, .{ .font = body, .gravity_x = 0.5 });

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 8 } });

    if (comptime auto_update.impl) {
        if (!auto_update.installLayoutSupported(dvui.io) and builtin.os.tag == .macos) {
            dvui.labelNoFmt(
                @src(),
                "In-app updates need a packaged .app (Velopack). A zig-out binary is not an app bundle.",
                .{},
                .{ .font = body_small, .gravity_x = 0.5 },
            );
        }

        // GitHub link (clickable).
        if (build_opts.app_repo_url.len > 0) {
            var gh_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5 });
            defer gh_row.deinit();
            dvui.labelNoFmt(@src(), "GitHub:", .{}, .{ .font = body_small, .gravity_y = 0.5, .padding = .{ .w = 6 } });
            dvui.link(@src(), .{ .url = build_opts.app_repo_url, .label = build_opts.app_repo_url }, .{
                .font = body_small,
                .gravity_y = 0.5,
            });
        } else {
            dvui.labelNoFmt(@src(), "Updates: configure build with -Drepo-url", .{}, .{ .font = body_small, .gravity_x = 0.5 });
        }
    } else {
        dvui.labelNoFmt(@src(), "Automatic updates are not included in this build.", .{}, .{ .font = body_small, .gravity_x = 0.5 });
    }

    // `std.c.getenv` requires libc (not available on wasm32-freestanding).
    // Auto-update is disabled on web anyway (see `auto_update.impl`).
    if (comptime @import("builtin").target.cpu.arch != .wasm32) {
        if (std.c.getenv("FIZZY_AUTOUPDATE_URL")) |_| {
            dvui.labelNoFmt(@src(), "FIZZY_AUTOUPDATE_URL is set (local/HTTP feed).", .{}, .{ .font = body_small, .gravity_x = 0.5 });
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 10 } });

    dvui.labelNoFmt(@src(), status_line, .{}, .{ .font = body_small, .gravity_x = 0.5, .color_text = dvui.themeGet().color(.control, .text) });

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 12 } });

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5 });
    defer btn_row.deinit();

    if (comptime auto_update.impl) {
        if (dialogButton(@src(), "Check for updates", .highlight, 1, 0)) {
            setStatus("Checking…");
            update_ready_after_check = false;
            var ver_out: [128]u8 = undefined;
            if (auto_update.checkRemoteVersionSummary(dvui.io, alloc, &ver_out)) |summary| {
                switch (summary) {
                    .unavailable => setStatus("Updates are not available in this build."),
                    .no_feed => setStatus("No update feed configured."),
                    .install_layout_unsupported => setStatus("On macOS, use the packaged .app from a release (zig-out binary cannot use Velopack updates)."),
                    .failed => {
                        var eb: [320]u8 = undefined;
                        const es = auto_update.lastErrorSlice(&eb);
                        if (es.len > 0) {
                            if (std.fmt.bufPrint(&status_line_buf, "Check failed: {s}", .{es})) |s| {
                                status_line = s;
                            } else |_| {
                                setStatus("Check failed.");
                            }
                        } else {
                            setStatus("Check failed.");
                        }
                    },
                    .no_update => setStatus("You're up to date."),
                    .remote_empty => setStatus("Release feed is empty."),
                    .available => |remote| {
                        update_ready_after_check = true;
                        if (std.fmt.bufPrint(&status_line_buf, "Update available: {s}.", .{remote})) |s| {
                            status_line = s;
                        } else |_| {
                            setStatus("Update available.");
                        }
                    },
                }
            } else |e| {
                setStatus(@errorName(e));
            }
        }

        if (update_ready_after_check) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });

            if (dialogButton(@src(), "Download and restart", .control, 2, 1)) {
                // Kick the background install (publishes phase + 0–100 progress
                // through atomics) and close the dialog — the progress toast
                // anchored above the infobar shows the rest.
                update_ready_after_check = false;
                setStatus(" ");
                update_notify.kickInstall();
                fizzy.dvui.closeFloatingDialogAnchored();
            }
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });

    if (dialogButton(@src(), "Close", .control, 10, 2)) {
        fizzy.dvui.closeFloatingDialogAnchored();
    }

    return true;
}

pub fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) !void {
    setStatus(" ");
    update_ready_after_check = false;
}
