const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const build_opts = @import("build_opts");
const auto_update = @import("../../backend/auto_update.zig");
const update_notify = @import("../../backend/update_notify.zig");
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

// ----------------------------------------------------------------------------
// Background "Check for updates" worker. The Velopack feed check is a blocking
// network call — if we ran it on the GUI thread the frame wouldn't return
// until the check completed, and the spinner the user expects to see would
// never animate. Instead, the click spawns a detached thread; each frame the
// GUI side polls `check_in_flight` to render a spinner, and `check_done` to
// consume the result exactly once.
// ----------------------------------------------------------------------------

const CheckOutcome = enum(u8) {
    none = 0,
    unavailable,
    no_feed,
    install_layout_unsupported,
    failed,
    no_update,
    remote_empty,
    available,
    oom,
    spawn_failed,
};

var check_in_flight: std.atomic.Value(bool) = .init(false);
var check_done: std.atomic.Value(bool) = .init(false);
/// Read only after `check_done` is observed `true` with `.acquire`.
var check_outcome: CheckOutcome = .none;
/// Holds either the available version string or the Velopack error message.
var check_msg_buf: [320]u8 = undefined;
var check_msg_len: usize = 0;
/// Captured at button-click time so the worker can wake the GUI loop.
var check_window: ?*dvui.Window = null;
/// Wall-clock timestamp the check finished successfully. While `now - start`
/// is within `check_done_flash_duration_ns` the dialog shows the bubbleSpinner's
/// sync → pop → check finish animation in place of the status line, matching
/// the file-save completion feedback.
var check_complete_at_ns: ?i128 = null;
const check_done_flash_duration_ns: i128 = 2 * std.time.ns_per_s;

fn checkWorker(io: std.Io) void {
    defer {
        check_done.store(true, .release);
        if (check_window) |w| dvui.refresh(w, @src(), null);
    }

    var ver_out: [128]u8 = undefined;
    if (auto_update.checkRemoteVersionSummary(io, std.heap.page_allocator, &ver_out)) |summary| {
        switch (summary) {
            .unavailable => {
                check_msg_len = 0;
                check_outcome = .unavailable;
            },
            .no_feed => {
                check_msg_len = 0;
                check_outcome = .no_feed;
            },
            .install_layout_unsupported => {
                check_msg_len = 0;
                check_outcome = .install_layout_unsupported;
            },
            .failed => {
                const es = auto_update.lastErrorSlice(&check_msg_buf);
                check_msg_len = es.len;
                check_outcome = .failed;
            },
            .no_update => {
                check_msg_len = 0;
                check_outcome = .no_update;
            },
            .remote_empty => {
                check_msg_len = 0;
                check_outcome = .remote_empty;
            },
            .available => |remote| {
                const n = @min(remote.len, check_msg_buf.len);
                @memcpy(check_msg_buf[0..n], remote[0..n]);
                check_msg_len = n;
                check_outcome = .available;
            },
        }
    } else |_| {
        check_msg_len = 0;
        check_outcome = .oom;
    }
}

/// Consume the worker's published result on the GUI thread. Translates the
/// outcome into `status_line` + `update_ready_after_check`. No-op if the
/// worker hasn't published yet.
fn consumeCheckResult() void {
    if (!check_done.swap(false, .acquire)) return;
    check_in_flight.store(false, .release);

    // Arm the finish animation for outcomes where the check itself succeeded
    // (even "no update" is a successful check). For hard failures we skip
    // straight to the error text — showing a green checkmark next to a
    // "Check failed" message would be misleading.
    const success = switch (check_outcome) {
        .available, .no_update, .remote_empty, .unavailable, .install_layout_unsupported, .no_feed => true,
        .failed, .oom, .spawn_failed, .none => false,
    };
    if (success) {
        check_complete_at_ns = fizzy.perf.nanoTimestamp();
    } else {
        check_complete_at_ns = null;
    }

    switch (check_outcome) {
        .unavailable => setStatus("Updates are not available in this build."),
        .no_feed => setStatus("No update feed configured."),
        .install_layout_unsupported => setStatus("On macOS, use the packaged .app from a release (zig-out binary cannot use Velopack updates)."),
        .failed => {
            if (check_msg_len > 0) {
                if (std.fmt.bufPrint(&status_line_buf, "Check failed: {s}", .{check_msg_buf[0..check_msg_len]})) |s| {
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
        .available => {
            update_ready_after_check = true;
            if (std.fmt.bufPrint(&status_line_buf, "Update available: {s}.", .{check_msg_buf[0..check_msg_len]})) |s| {
                status_line = s;
            } else |_| {
                setStatus("Update available.");
            }
        },
        .oom => setStatus("Out of memory."),
        .spawn_failed => setStatus("Could not start update check."),
        .none => {},
    }
    check_outcome = .none;
}

pub fn dialog(_: dvui.Id) anyerror!bool {
    // Drain a finished background check (if any) into `status_line` /
    // `update_ready_after_check` before laying out the dialog body, so the
    // result is visible this frame instead of next.
    if (comptime auto_update.impl) consumeCheckResult();

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

    // Three states for the status slot:
    //  1. `checking`        — looping spinner (worker thread is in flight).
    //  2. `finish_elapsed`  — pop → check finish animation right after the
    //                          worker publishes a successful outcome, same
    //                          feedback as a completed file save.
    //  3. otherwise          — static status text.
    const checking: bool = if (comptime auto_update.impl) check_in_flight.load(.acquire) else false;
    const finish_elapsed: ?i128 = blk: {
        if (comptime !auto_update.impl) break :blk null;
        const start = check_complete_at_ns orelse break :blk null;
        const elapsed = fizzy.perf.nanoTimestamp() - start;
        if (elapsed >= check_done_flash_duration_ns) {
            check_complete_at_ns = null;
            break :blk null;
        }
        break :blk elapsed;
    };

    {
        var spinner_slot = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .min_size_content = .{ .w = 24, .h = 24 },
            .gravity_x = 0.5,
        });
        defer spinner_slot.deinit();

        if (checking or finish_elapsed != null) {
            fizzy.dvui.bubbleSpinner(@src(), .{
                .expand = .none,
                .min_size_content = .{ .w = 24, .h = 24 },
                .gravity_x = 0.5,
                .color_text = dvui.themeGet().color(.control, .text),
            }, .{ .complete_elapsed_ns = finish_elapsed });
            dvui.refresh(null, @src(), null);
        }
    }

    if (!checking) {
        dvui.labelNoFmt(@src(), status_line, .{}, .{ .font = body_small, .gravity_x = 0.5, .color_text = dvui.themeGet().color(.control, .text) });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 12 } });

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5 });
    defer btn_row.deinit();

    if (comptime auto_update.impl) {
        // Suppress the buttons while the worker is running — re-clicking would
        // either no-op (already in flight) or queue duplicate worker threads.
        if (!checking and dialogButton(@src(), "Check for updates", .highlight, 1, 0)) {
            setStatus("Checking…");
            update_ready_after_check = false;
            check_window = dvui.currentWindow();
            check_in_flight.store(true, .release);
            check_done.store(false, .release);
            if (std.Thread.spawn(.{}, checkWorker, .{dvui.io})) |thread| {
                thread.detach();
            } else |_| {
                check_in_flight.store(false, .release);
                setStatus("Could not start update check.");
            }
        }

        if (!checking and update_ready_after_check) {
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
