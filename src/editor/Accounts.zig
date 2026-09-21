//! The account glyph at the bottom of the rail and the flyout it opens: every signed-in
//! identity from every registered `sdk.accounts.Provider` ("me@x (Google Drive)", "me
//! (GitHub)"), each with its picture in a disc and the provider's own submenu (open, sign
//! out …), then a sign-in row for each provider with nobody signed in. Nothing here knows a
//! service; the providers do.
//!
//! Two levels, one `core.widgets.Popover` each: the list beside the rail, and the submenu
//! beside the hovered account row. A press anywhere else closes both.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const sdk = @import("fizzy_sdk");

const Editor = fizzy.Editor;
const Popover = fizzy.core.widgets.Popover;

/// Whether the flyout is showing. One flyout per app, so one flag.
var open: bool = false;
/// The list's and the submenu's rects: persistent because the popovers animate their size
/// through them; zeroed when the flyout (re)opens so each grows from its anchor.
var list_rect: dvui.Rect = .{};
var sub_rect: dvui.Rect = .{};
/// The account row whose submenu is open: `provider_index * 64 + account_index`.
var sub_for: ?usize = null;
/// The submenu's physical rect last frame, so hovering into it keeps it open.
var sub_phys: dvui.Rect.Physical = .{};
/// True while the flyout's rows are being drawn, so `Host.drawMenuItem` (a provider's submenu
/// rows) draws a popover row rather than a menubar row.
pub var drawing_rows: bool = false;

/// Draw the glyph as one rail cell. Drawn only when a provider exists (`Sidebar`).
pub fn drawRailDisc(editor: *Editor, size: f32) !void {
    const host = &editor.app.host;
    const arena = host.arena();
    const theme = dvui.themeGet();

    // The same cell as every other rail icon (`Sidebar.drawOption`): a button the icon's
    // height, the glyph in it, nothing else. Click toggles the flyout.
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{ .min_size_content = .{ .h = size } });
    defer bw.deinit();
    bw.processEvents();
    const color = if (bw.hovered() or open) theme.color(.window, .text) else theme.color(.window, .fill);
    fizzy.core.icon.icon(@src(), "accounts", dvui.entypo.user, .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } }, .{
        .min_size_content = .{ .h = size },
    });
    if (bw.clicked()) {
        open = !open;
        if (open) {
            list_rect = .{};
            sub_rect = .{};
            sub_for = null;
            sub_phys = .{};
        }
    }
    if (!open) return;
    const button_r = bw.data().borderRectScale().r;
    if (Popover.outside(&.{ button_r, list_rect.scale(dvui.windowNaturalScale(), dvui.Rect.Physical), sub_phys })) {
        open = false;
        return;
    }

    // Beside the icon, not below: the rail is at the screen's left edge.
    const from = button_r.toNatural();
    var list = Popover.init(@src(), .{ .rect = &list_rect, .anchor = .{ .x = from.x + from.w + 4, .y = from.y - 4 } });
    defer list.deinit();
    drawing_rows = true;
    defer drawing_rows = false;

    var rows: usize = 0;
    var hovered_any: ?usize = null;
    var sub_anchor: ?dvui.Rect.Physical = null;
    for (host.account_providers.items, 0..) |p, pi| {
        if (p.hidden) continue;
        for (p.accounts(arena), 0..) |a, ai| {
            const extra = pi * 64 + ai;
            const label = std.fmt.allocPrint(arena, "{s} ({s})", .{ a.label, p.name }) catch a.label;
            var r = Popover.row(@src(), .{ .id_extra = extra, .active = sub_for == extra });
            accountRowContent(label, a.avatar);
            if (r.hovered or r.clicked) hovered_any = extra;
            if (sub_for == extra) sub_anchor = r.rect();
            r.deinit();
            rows += 1;
        }
    }
    var offered: usize = 0;
    for (host.account_providers.items, 0..) |p, pi| {
        if (p.hidden or !p.canSignIn() or p.accounts(arena).len != 0) continue;
        if (offered == 0 and rows > 0) _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .x = 8, .y = 4, .w = 8, .h = 4 } });
        offered += 1;
        const label = std.fmt.allocPrint(arena, "Sign in to {s}…", .{p.name}) catch p.name;
        var r = Popover.row(@src(), .{ .id_extra = pi });
        dvui.labelNoFmt(@src(), label, .{}, .{ .gravity_y = 0.5, .margin = .all(0), .padding = .all(0) });
        r.deinit();
        if (r.clicked) {
            open = false;
            p.signIn();
        }
    }
    if (rows == 0 and offered == 0) {
        dvui.labelNoFmt(@src(), "No accounts", .{}, .{ .padding = .all(6) });
    }

    // Hovering an account row opens its submenu (and moves it from another row); the
    // submenu stays while the mouse is over it.
    if (hovered_any) |h| {
        if (sub_for != h) {
            sub_for = h;
            sub_rect = .{};
            sub_phys = .{};
        }
    } else if (sub_for != null and !sub_phys.contains(dvui.currentWindow().mouse_pt)) {
        sub_for = null;
        sub_phys = .{};
    }
    const anchor = sub_anchor orelse return;
    const which = sub_for orelse return;
    const p = host.account_providers.items[which / 64];
    const accounts = p.accounts(arena);
    if (which % 64 >= accounts.len) return;
    const a = accounts[which % 64];
    const at = anchor.toNatural();
    const list_top = list.rect.toNatural();
    // Overlapping the list by a sliver, so the pointer crosses from the row into the submenu
    // without passing over a gap that would read as "outside" and close it; top edges level.
    var sub = Popover.init(@src(), .{ .rect = &sub_rect, .anchor = .{ .x = at.x + at.w - 10, .y = list_top.y }, .id_extra = 1 });
    defer sub.deinit();
    sub_phys = sub.rect;
    if (p.menu(a.id)) open = false;
}

/// A provider's submenu row, for `Host.drawMenuItem` while `drawing_rows`: the popover shell
/// around an icon, the title and its chord — laid out on the same columns as an account row
/// (`accountRowContent`), so the two levels line up. Returns whether it was clicked.
pub fn drawMenuRow(title: []const u8, icon: ?[]const u8, kb: dvui.enums.Keybind, enabled: bool) bool {
    const theme = dvui.themeGet();
    const id_extra: usize = @truncate(std.hash.Wyhash.hash(0, title));
    var r = Popover.row(@src(), .{ .enabled = enabled, .id_extra = id_extra });
    defer r.deinit();
    const text_color = if (enabled) theme.color(.control, .text) else theme.color(.control, .text).opacity(0.5);
    {
        // The same cell an account's disc takes; the command's icon sits in it, centred.
        var cell = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id_extra, .min_size_content = .{ .w = row_disc, .h = row_disc }, .max_size_content = .size(.{ .w = row_disc, .h = row_disc }), .gravity_y = 0.5, .margin = .{ .w = row_disc_gap }, .background = false, .padding = .all(0) });
        defer cell.deinit();
        if (icon) |b| {
            fizzy.core.icon.icon(@src(), "menu_icon", b, .{ .stroke_color = .{ .color = text_color }, .fill_color = .{ .color = text_color } }, .{
                .id_extra = id_extra,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .min_size_content = .{ .h = row_disc - 4 },
                .margin = .all(0),
                .padding = .all(0),
            });
        }
    }
    dvui.labelNoFmt(@src(), title, .{}, .{ .id_extra = id_extra, .gravity_y = 0.5, .margin = .all(0), .padding = .all(0), .color_text = .{ .color = text_color } });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 16, .h = 1 }, .expand = .horizontal, .id_extra = id_extra });
    fizzy.core.draw.keybindLabels(&kb, enabled, .{ .id_extra = id_extra, .gravity_y = 0.5, .gravity_x = 1.0 });
    return r.clicked;
}

/// The picture/icon cell every popover row starts with, and the gap after it.
const row_disc: f32 = 18;
const row_disc_gap: f32 = 8;

/// An account row's content: its picture in a small disc (or a user glyph), the label, a
/// chevron for the submenu.
fn accountRowContent(label: []const u8, avatar: ?dvui.ImageSource) void {
    const theme = dvui.themeGet();
    const disc: f32 = row_disc;
    {
        // The disc: a spacer reserves the cell; the picture (or glyph) is drawn into it.
        const cell = dvui.spacer(@src(), .{ .min_size_content = .{ .w = disc, .h = disc }, .gravity_y = 0.5, .margin = .{ .w = row_disc_gap } });
        const rs = cell.rectScale();
        const side = disc * rs.s;
        const cx = rs.r.x + rs.r.w / 2;
        const cy = rs.r.y + rs.r.h / 2;
        const square: dvui.RectScale = .{ .r = .{ .x = cx - side / 2, .y = cy - side / 2, .w = side, .h = side }, .s = rs.s };
        const drew = blk: {
            const src = avatar orelse break :blk false;
            const tex = src.getTexture() catch break :blk false;
            dvui.renderTexture(tex, square, .{ .corners = .all(disc / 2) }) catch break :blk false;
            break :blk true;
        };
        if (!drew) {
            var path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
            path.addArc(.{ .x = cx, .y = cy }, side / 2, 0, std.math.tau, false);
            const circle = path.build();
            const c = theme.color(.control, .text);
            circle.fillConvex(.{ .color = .{ .color = c.opacity(0.15) }, .fade = 1.0 });
            circle.stroke(.{ .thickness = 1.0 * rs.s, .color = .{ .color = c.opacity(0.6) }, .closed = true });
        }
    }
    dvui.labelNoFmt(@src(), label, .{}, .{ .gravity_y = 0.5, .margin = .all(0), .padding = .all(0) });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 16, .h = 1 }, .expand = .horizontal });
    fizzy.core.icon.icon(@src(), "chevron_right", dvui.entypo.chevron_small_right, .{
        .stroke_color = .{ .color = theme.color(.control, .text).opacity(0.5) },
        .fill_color = .{ .color = theme.color(.control, .text).opacity(0.5) },
    }, .{ .gravity_x = 1.0, .gravity_y = 0.5, .margin = .all(0), .padding = .all(0) });
}
