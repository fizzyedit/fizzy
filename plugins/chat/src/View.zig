//! The chat surface: the provider's messages above, the composer below. Drawn from the theme and
//! the app's glass only, so another app's look is the chat's look.
//!
//! The composer is a rounded pane of glass with a plus (attach) on its left and a send button on
//! its right. Its text grows with what is typed up to `composer.max_lines`, then scrolls. Enter
//! sends on a desktop and is a new line on a phone (`composer.enter`).
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const composer = @import("composer.zig");

const Api = sdk.services.chat.Api;

const View = @This();

/// The composer's text, kept across frames.
text: std.ArrayList(u8) = .empty,
/// Messages seen last frame: the list scrolls to the end when this grows.
seen: usize = 0,
/// The composer's text entry as last drawn, for a test to read: its widget id, its rect and its
/// scroll state.
entry_id: dvui.Id = .zero,
entry_rect: dvui.Rect = .{},
entry_scroll: dvui.ScrollInfo = .{},

pub fn deinit(self: *View, gpa: std.mem.Allocator) void {
    self.text.deinit(gpa);
}

pub fn draw(self: *View, gpa: std.mem.Allocator, provider: ?*Api) void {
    var column = dvui.box(@src(), .{}, .{ .expand = .both, .background = false });
    defer column.deinit();

    const api = provider orelse return note("Nothing is offering a conversation (chat.provider).");
    self.messages(api.*);
    self.compose(gpa, api.*, column.data());
}

fn messages(self: *View, api: Api) void {
    var scroll = core.widgets.ScrollArea.init(@src(), .{ .horizontal = .none, .vertical_bar = .auto_overlay }, .{ .expand = .both, .background = false });
    defer scroll.deinit();

    const log = api.messages();
    for (log, 0..) |m, i| message(m, i);

    if (log.len != self.seen) {
        self.seen = log.len;
        scroll.si.scrollToOffset(.vertical, std.math.floatMax(f32));
        dvui.refresh(null, @src(), null);
    }
}

fn message(m: Api.Message, i: usize) void {
    const theme = dvui.themeGet();
    var box = dvui.box(@src(), .{}, .{ .expand = .horizontal, .id_extra = i, .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 }, .background = false });
    defer box.deinit();

    const who = switch (m.role) {
        .user => "You",
        .assistant => "Reply",
        .system => "",
    };
    if (who.len > 0) dvui.labelNoFmt(@src(), who, .{}, .{ .color_text = .{ .color = theme.color(.control, .text).opacity(0.6) }, .font = theme.font_body.larger(-2) });

    var segments: composer.Segments = .{ .text = m.text };
    var n: usize = 0;
    while (segments.next()) |s| : (n += 1) {
        if (s.body.len == 0 and s.kind == .text) continue;
        switch (s.kind) {
            .text => {
                var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .id_extra = n, .background = false });
                defer tl.deinit();
                tl.addText(s.body, .{});
            },
            .code => {
                var block = dvui.box(@src(), .{}, .{
                    .expand = .horizontal,
                    .id_extra = n,
                    .background = true,
                    .color_fill = .{ .color = theme.color(.control, .fill) },
                    .corners = core.corners.all(core.corners.small),
                    .padding = .all(6),
                    .margin = .{ .y = 2, .h = 2 },
                });
                defer block.deinit();
                var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .font = theme.font_mono });
                defer tl.deinit();
                tl.addText(s.body, .{});
            },
        }
    }
}

fn compose(self: *View, gpa: std.mem.Allocator, api: Api, parent: *const dvui.WidgetData) void {
    const theme = dvui.themeGet();
    const radius = core.corners.card + 4;
    var pane = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .corners = core.corners.all(radius),
        .margin = .all(8),
        .padding = .all(6),
    });
    defer pane.deinit();
    const r = pane.data().borderRectScale().r;
    const corners = core.corners.all(radius);
    if (!core.dialogs.frostPane(pane.data().id, r, corners, pane.data().rectScale().s)) {
        r.fill(corners.scale(pane.data().rectScale().s, dvui.CornerRect.Physical), .{ .color = .{ .color = core.dialogs.dialogFill() }, .fade = 1 });
    }

    if (iconButton(@src(), dvui.entypo.plus, "Attach", true)) api.attach();

    const line_h = theme.font_body.lineHeight();
    const entry_src = @src();
    const entry_id = pane.data().id.extendId(entry_src, 0);
    const mobile = core.platform.formFactor() == .mobile;
    var send = false;
    for (dvui.events()) |*e| {
        if (e.handled or e.target_widgetId != entry_id) continue;
        const ke = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        if (ke.code != .enter or ke.action == .up) continue;
        const shift = ke.mod.has(.lshift) or ke.mod.has(.rshift);
        if (composer.enter(shift, mobile) == .send) {
            e.handle(@src(), parent);
            send = ke.action == .down;
        }
    }

    var entry = dvui.textEntry(entry_src, .{
        .multiline = true,
        .break_lines = true,
        .placeholder = "Message",
        .text = .{ .array_list = .{ .backing = &self.text, .allocator = gpa } },
    }, .{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .background = false,
        .min_size_content = .{ .w = 1, .h = line_h },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = line_h * composer.max_lines },
    });
    defer entry.deinit();
    self.entry_id = entry.data().id;
    self.entry_rect = entry.data().rect;
    self.entry_scroll = entry.scroll.si.*;

    const text = composer.sendable(self.text.items);
    if (iconButton(@src(), dvui.entypo.paper_plane, "Send", text != null and api.status() != .offline)) send = true;
    if (send) {
        if (text) |t| if (api.send(t)) {
            self.text.clearRetainingCapacity();
            entry.textSet("", false);
        };
    }
}

fn iconButton(src: std.lang.SourceLocation, glyph: []const u8, label: []const u8, enabled: bool) bool {
    const theme = dvui.themeGet();
    var btn: dvui.ButtonWidget = undefined;
    btn.init(src, .{}, .{
        .gravity_y = 1.0,
        .min_size_content = .{ .w = 18, .h = 18 },
        .corners = core.corners.all(core.corners.control),
        .background = false,
        .label = .{ .text = label },
    });
    defer btn.deinit();
    if (enabled) btn.processEvents();
    btn.drawBackground();
    if (enabled) btn.drawFocus();
    const color = theme.color(.control, .text).opacity(if (enabled) 1 else 0.4);
    core.icon.icon(@src(), label, glyph, .{ .stroke_color = .white, .fill_color = .white }, .{ .color_text = .{ .color = color }, .expand = .ratio, .gravity_x = 0.5, .gravity_y = 0.5 });
    return enabled and btn.clicked();
}

fn note(text: []const u8) void {
    dvui.labelNoFmt(@src(), text, .{}, .{ .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.6) }, .padding = .all(6) });
}
