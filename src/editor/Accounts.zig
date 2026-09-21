//! The account glyph at the bottom of the rail and the list it opens: every signed-in identity
//! from every registered `sdk.accounts.Provider` ("me@x (Google Drive)", "me (GitHub)"), each
//! with its picture in a disc and the provider's own submenu (open, sign out …), then a
//! sign-in row for each provider with room for one. Nothing here knows a service; the
//! providers do.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const sdk = @import("fizzy_sdk");
const Menu = @import("Menu.zig");

const Editor = fizzy.Editor;

/// Whether the list is showing. One list per app, so one flag.
var open: bool = false;

/// dvui closes the menu chain itself — a click elsewhere, focus lost, an item chosen — and
/// tells the chain's root through this; doing our own outside-click test instead closed the
/// list on the press that opened a submenu row, before its release could choose anything.
fn menuRootClose(_: *anyopaque, _: dvui.MenuWidget.CloseReason) void {
    open = false;
    dvui.refresh(null, @src(), null);
}

/// Draw the disc as one rail cell. Drawn only when a provider exists (`Sidebar`).
pub fn drawRailDisc(editor: *Editor, size: f32) !void {
    const host = &editor.app.host;
    const arena = host.arena();
    const theme = dvui.themeGet();

    var any_signed_in = false;
    for (host.account_providers.items) |p| {
        if (p.hidden) continue;
        if (p.accounts(arena).len != 0) any_signed_in = true;
    }

    // The same cell as every other rail icon (`Sidebar.drawOption`): a button the icon's
    // height, the glyph in it, nothing else. Click toggles the list.
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{ .min_size_content = .{ .h = size } });
    defer bw.deinit();
    bw.processEvents();
    const color = if (any_signed_in) theme.color(.highlight, .fill) else if (bw.hovered() or open) theme.color(.window, .text) else theme.color(.window, .fill);
    fizzy.core.icon.icon(@src(), "accounts", dvui.entypo.user, .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } }, .{
        .min_size_content = .{ .h = size },
    });
    if (bw.clicked()) open = !open;
    if (!open) return;
    const from = bw.data().borderRectScale().r.toNatural();
    const prev_root = dvui.MenuWidget.Root.set(.{ .ptr = &open, .close = menuRootClose });
    defer _ = dvui.MenuWidget.Root.set(prev_root);
    // Open to the right of the icon, not below: the rail is at the screen's left edge.
    var fw = dvui.floatingMenu(@src(), .{ .from = .{ .x = from.x + from.w, .y = from.y, .w = 0, .h = from.h }, .avoid = .horizontal }, .{});
    defer fw.deinit();

    var rows: usize = 0;
    for (host.account_providers.items, 0..) |p, pi| {
        if (p.hidden) continue;
        for (p.accounts(arena), 0..) |a, ai| {
            const label = std.fmt.allocPrint(arena, "{s} ({s})", .{ a.label, p.name }) catch a.label;
            const extra = pi * 64 + ai;
            if (accountRow(label, a.avatar, extra)) |r| {
                var sub = dvui.floatingMenu(@src(), .{ .from = r }, .{ .id_extra = extra });
                defer sub.deinit();
                if (p.menu(a.id)) {
                    open = false;
                    fw.close();
                }
            }
            rows += 1;
        }
    }
    // A sign-in row only for a provider with nobody signed in: one identity per provider.
    var offered: usize = 0;
    for (host.account_providers.items, 0..) |p, pi| {
        if (p.hidden or !p.canSignIn() or p.accounts(arena).len != 0) continue;
        if (offered == 0 and rows > 0) _ = dvui.separator(@src(), .{ .expand = .horizontal });
        offered += 1;
        const label = std.fmt.allocPrint(arena, "Sign in to {s}…", .{p.name}) catch p.name;
        if (dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal, .id_extra = pi, .color_text = .{ .color = theme.color(.control, .text) } }) != null) {
            open = false;
            fw.close();
            p.signIn();
        }
    }
    if (rows == 0 and offered == 0) {
        dvui.labelNoFmt(@src(), "No accounts", .{}, .{ .color_text = .{ .color = theme.color(.control, .text) } });
    }
}

/// One account's row: its picture in a small disc (or a user glyph), the label, a chevron
/// for the submenu. Returns the row's rect while its submenu should be open.
fn accountRow(label: []const u8, avatar: ?dvui.ImageSource, extra: usize) ?dvui.Rect.Natural {
    const theme = dvui.themeGet();
    var mi = dvui.menuItem(@src(), .{ .submenu = true }, .{ .expand = .horizontal, .id_extra = extra });
    const ret = mi.activeRect();

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = false, .padding = dvui.Rect.all(0), .margin = dvui.Rect.all(0) });
    const disc: f32 = 18;
    {
        // The disc: a spacer reserves the cell; the picture (or glyph) is drawn into it.
        const cell = dvui.spacer(@src(), .{ .min_size_content = .{ .w = disc, .h = disc }, .gravity_y = 0.5, .margin = .{ .w = 8 } });
        const rs = cell.rectScale();
        const side = disc * rs.s;
        const cx = rs.r.x + rs.r.w / 2;
        const cy = rs.r.y + rs.r.h / 2;
        const square: dvui.RectScale = .{ .r = .{ .x = cx - side / 2, .y = cy - side / 2, .w = side, .h = side }, .s = rs.s };
        const drew = blk: {
            const src = avatar orelse break :blk false;
            const tex = src.getTexture() catch break :blk false;
            dvui.renderTexture(tex, square, .{ .corners = .all(side / 2) }) catch break :blk false;
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
    var label_opts: dvui.Options = .{ .gravity_y = 0.5, .margin = dvui.Rect.all(0), .padding = dvui.Rect.all(0), .color_text = .{ .color = theme.color(.control, .text) } };
    if (fizzy.core.widgets.hovered(mi.data())) label_opts.color_text = .{ .color = theme.color(.window, .text) };
    dvui.labelNoFmt(@src(), label, .{}, label_opts);
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 12, .h = 1 }, .expand = .horizontal });
    fizzy.core.icon.icon(@src(), "chevron_right", dvui.entypo.chevron_small_right, .{
        .stroke_color = .{ .color = theme.color(.control, .text).opacity(0.5) },
        .fill_color = .{ .color = theme.color(.control, .text).opacity(0.5) },
    }, .{ .gravity_x = 1.0, .gravity_y = 0.5, .margin = dvui.Rect.all(0), .padding = dvui.Rect.all(0) });
    row.deinit();
    mi.deinit();
    return ret;
}
