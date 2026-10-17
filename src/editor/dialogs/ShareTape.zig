//! What a share of a document's track holds, before anything is written (`plans/RECORDING_PLAN.md`,
//! "Privacy": export shows what is in it first): which document, how many steps over how long,
//! whose they are, and how long the tape plays. The person picks the range of the track to share
//! and whether pauses keep their length; Share hands it to `Editor.shareDocument` at the next
//! frame's top (`Editor.share_pending`). Opened by the transport's share.
const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const sdk = fizzy.sdk;
const Tracks = @import("app").Tracks;

pub fn request(doc_id: u64) void {
    var mutex = fizzy.core.dialogs.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "Share how it was made",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .max_size = .width(520),
    });
    dvui.dataSet(null, mutex.id, "_doc", doc_id);
    dvui.dataSet(null, mutex.id, "_from", @as(f32, 0));
    dvui.dataSet(null, mutex.id, "_to", @as(f32, 1));
    dvui.dataSet(null, mutex.id, "_real", false);
    mutex.mutex.unlock(dvui.io);
}

/// "48 s", "3 min 20 s", "1 h 5 min".
fn duration(arena: std.mem.Allocator, ms: u64) []const u8 {
    const s = (ms + 500) / 1000;
    return (if (s < 60)
        std.fmt.allocPrint(arena, "{d} s", .{s})
    else if (s < 3600)
        std.fmt.allocPrint(arena, "{d} min {d} s", .{ s / 60, s % 60 })
    else
        std.fmt.allocPrint(arena, "{d} h {d} min", .{ s / 3600, s % 3600 / 60 })) catch "";
}

/// "you", "you and Claude", "you, Claude and the tour".
fn whose(arena: std.mem.Allocator, authors: []const sdk.Author) []const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (authors, 0..) |a, i| {
        if (i > 0) out.writer.writeAll(if (i == authors.len - 1) " and " else ", ") catch {};
        out.writer.writeAll(switch (a.kind) {
            .person => "you",
            .unattributed => "someone unknown",
            else => if (a.label.len > 0) a.label else "an agent",
        }) catch {};
    }
    return out.written();
}

fn refusal(err: Tracks.ExportError) []const u8 {
    return switch (err) {
        error.StartNotInHistory => "The document can't be put back where this range begins: that point was undone and edited over. Start the range later.",
        error.NoHistory => "This document keeps no history to share from.",
        error.EmptyRange => "The range holds no steps.",
        else => "This document's track can't be shared yet.",
    };
}

pub fn dialog(id: dvui.Id) anyerror!bool {
    const editor = fizzy.editor();
    const doc_id = dvui.dataGet(null, id, "_doc", u64) orelse return false;
    const doc = editor.app.docById(doc_id) orelse return false;
    const tracks = &(editor.app.tracks orelse return false);
    const track = tracks.trackOf(doc_id) orelse return false;
    const from_f = dvui.dataGetPtr(null, id, "_from", f32) orelse return false;
    const to_f = dvui.dataGetPtr(null, id, "_to", f32) orelse return false;
    const real = dvui.dataGetPtr(null, id, "_real", bool) orelse return false;
    const arena = dvui.currentWindow().arena();
    const n = track.steps.items.len;
    if (n == 0) return false;

    const from, const to = @import("app").history_transport.shareRange(n, from_f.*, to_f.*);
    const opts: Tracks.ExportOptions = .{ .from = from, .to = to, .real_time = real.* };
    const sum = tracks.summarize(&editor.app.host, doc, arena, opts) catch return false;
    const name = std.fs.path.basename(doc.owner.documentPath(doc));

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer outer.deinit();

    const message = std.fmt.allocPrint(arena, "{s}: {d} step{s} over {s}, by {s}. The tape plays in {s}.", .{
        name,
        sum.steps,
        if (sum.steps == 1) "" else "s",
        duration(arena, sum.recorded_ms),
        whose(arena, sum.authors),
        duration(arena, sum.played_ms),
    }) catch name;
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
    tl.addText(message, .{ .font = dvui.Font.theme(.body) });
    tl.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 12 } });

    // The range, as two ends over the track: each says when its step came.
    const base_at = if (track.base) |b| b.at else 0;
    inline for (.{ .{ "From", from_f, from }, .{ "To", to_f, to } }, 0..) |end, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
        defer row.deinit();
        dvui.labelNoFmt(@src(), end[0], .{}, .{ .min_size_content = .{ .w = 48 }, .gravity_y = 0.5 });
        _ = dvui.slider(@src(), .{ .fraction = end[1] }, .{ .expand = .horizontal, .gravity_y = 0.5 });
        if (end[2] == 0) {
            dvui.labelNoFmt(@src(), "where it began", .{}, .{ .min_size_content = .{ .w = 170 }, .gravity_y = 0.5 });
        } else {
            const when = duration(arena, track.steps.items[@min(end[2], n) - 1].at -| base_at);
            dvui.label(@src(), "after step {d}, {s} in", .{ end[2], when }, .{ .min_size_content = .{ .w = 170 }, .gravity_y = 0.5 });
        }
    }

    _ = dvui.checkbox(@src(), real, "Keep every pause as long as it was", .{});

    if (sum.refused) |err| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 8 } });
        var why = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
        why.addText(refusal(err), .{ .font = dvui.Font.theme(.body), .color_text = .{ .color = dvui.themeGet().color(.err, .text) } });
        why.deinit();
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 16 } });
    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5 });
    defer btn_row.deinit();
    if (sum.refused == null and fizzy.core.dialogs.bodyButton(@src(), id, "Share", .highlight, 1, 0)) {
        editor.share_pending = .{ .doc_id = doc_id, .opts = opts };
        dvui.refresh(null, @src(), null);
        fizzy.core.dialogs.closeFloatingDialogAnchored();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (fizzy.core.dialogs.bodyButton(@src(), id, "Cancel", .control, 2, 1)) {
        fizzy.core.dialogs.closeFloatingDialogAnchored();
    }
    return true;
}

pub fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) !void {}
