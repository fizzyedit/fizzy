//! The macOS menu bar, built from the app's own description of it. An app hands over its menus
//! as data (`install`): commands, separators, and list submenus it fills later (`setList` — recent
//! folders, say); items it adds and takes away at run time go in with `setExtras`, into its menus
//! or as new menus before Help. Each item carries a `Ref` — which part of the bar it is in and the
//! app's own tag for it — and that is all that crosses back: a choice is queued
//! (`pollActivation`) for the app to act on in its frame, and just before a menu shows AppKit asks
//! the app (`Hooks`) whether each item is enabled and what it is called now.
//!
//! Everything here is a no-op off macOS; elsewhere an app draws its menus itself.
const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const dialogs = @import("dialogs.zig");

const log = std.log.scoped(.menu);

/// Which part of the bar an item is in: the app's fixed menus (`install`), what it added at run
/// time (`setExtras`), or a list submenu (`setList`).
pub const Section = enum(u8) { bar = 0, extra = 1, list = 2 };

/// An item, as the app knows it: its part of the bar and the app's tag for it.
pub const Ref = struct { section: Section, tag: u32 };

/// One entry of a fixed menu.
pub const Entry = union(enum) {
    command: struct {
        title: [:0]const u8,
        tag: u32,
        /// An SF Symbol to show beside it.
        symbol: ?[:0]const u8 = null,
    },
    separator,
    /// A submenu the app fills later (`setList`, by the order these appear across the bar).
    list: struct { title: [:0]const u8 },
};

pub const Menu = struct {
    /// What `ExtraItem.menu_id` names it by — or any of `aliases`.
    id: []const u8,
    aliases: []const []const u8 = &.{},
    title: [:0]const u8,
    entries: []const Entry,
    /// The Help menu: last on the bar, where AppKit puts its search field.
    help: bool = false,
};

/// What the app decides as a menu is about to show.
pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// Whether the item can be chosen now.
    enabled: *const fn (ctx: ?*anyopaque, ref: Ref) bool,
    /// The item's title now, for one that changes with the app ("Show Explorer" / "Hide
    /// Explorer"); null to leave it.
    title: *const fn (ctx: ?*anyopaque, ref: Ref) ?[*:0]const u8,
    /// True while the app must not act on keys at all (capturing a shortcut): every item reports
    /// disabled, the only way to stop AppKit performing a key equivalent before the app sees it.
    input_blocked: *const fn (ctx: ?*anyopaque) bool,
};

/// A menu item chosen. `from_key`: by its key equivalent, not a click — AppKit then also hands
/// the keystroke on to the window, so the app must not synthesize a second one.
pub const Activation = struct { ref: Ref, from_key: bool };

pub const modifier_command: c_ulong = 1 << 20;
pub const modifier_shift: c_ulong = 1 << 17;
pub const modifier_option: c_ulong = 1 << 18;
pub const modifier_control: c_ulong = 1 << 19;

// ── State ──────────────────────────────────────────────────────────────────────────────────────

var hooks: ?Hooks = null;
var installed = false;
var main_menu: ?objc.Object = null;
var target: ?objc.Object = null;
var help_item: ?objc.Object = null;

const max_menus = 16;
const max_lists = 4;
var fixed_menus: [max_menus]?objc.Object = @splat(null);
var fixed_specs: [max_menus]Menu = undefined;
var fixed_count: usize = 0;
var list_menus: [max_lists]?objc.Object = @splat(null);
var list_items: [max_lists]?objc.Object = @splat(null);
var list_count: usize = 0;

/// The fixed items by tag, for `setKeyEquivalent`.
var bar_items: std.AutoHashMapUnmanaged(u32, objc.Object) = .empty;

const ExtraMenuItem = struct { item: objc.Object, menu: objc.Object };
const ExtraLeaf = struct { parent: objc.Object, item: objc.Object, tag: u32 };
var extra_menus: std.ArrayListUnmanaged(ExtraMenuItem) = .empty;
var extra_leaves: std.ArrayListUnmanaged(ExtraLeaf) = .empty;

// Choices, written from AppKit's action (main thread) and drained in the frame: one pending per
// part of the bar, as a menu choice is one at a time.
var pending_tag: [3]std.atomic.Value(i64) = .{ .init(-1), .init(-1), .init(-1) };
var pending_from_key: std.atomic.Value(bool) = .init(false);
var pending_about: std.atomic.Value(bool) = .init(false);

// ── The Objective-C side (`macos/menu_target.m`) ───────────────────────────────────────────────

extern fn FizzyGetSelector(name: [*:0]const u8) ?*anyopaque;

fn selector(name: [*:0]const u8) ?*anyopaque {
    return FizzyGetSelector(name);
}

export fn FizzyMenuActivated(section: c_int, tag: c_int, from_key: bool) void {
    if (section < 0 or section > 2 or tag < 0) return;
    if (section == 0) pending_from_key.store(from_key, .release);
    pending_tag[@intCast(section)].store(tag, .release);
}

export fn FizzyMenuEnabled(section: c_int, tag: c_int) callconv(.c) bool {
    const h = hooks orelse return true;
    if (h.input_blocked(h.ctx)) return false;
    if (section < 0 or section > 2 or tag < 0) return true;
    return h.enabled(h.ctx, .{ .section = @enumFromInt(section), .tag = @intCast(tag) });
}

export fn FizzyMenuTitle(section: c_int, tag: c_int) callconv(.c) ?[*:0]const u8 {
    const h = hooks orelse return null;
    if (section < 0 or section > 2 or tag < 0) return null;
    return h.title(h.ctx, .{ .section = @enumFromInt(section), .tag = @intCast(tag) });
}

export fn FizzyMenuInputBlocked() callconv(.c) bool {
    const h = hooks orelse return false;
    return h.input_blocked(h.ctx);
}

export fn FizzyMenuAbout() callconv(.c) void {
    pending_about.store(true, .release);
}

// ── Building ───────────────────────────────────────────────────────────────────────────────────

fn nsString(text: [*:0]const u8) objc.Object {
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{text});
}

/// A sentinel copy of `text` for AppKit, from the platform allocator; free with `freeZ`.
fn dupeZ(text: []const u8) ?[:0]u8 {
    return dialogs.allocator().dupeZ(u8, text) catch null;
}

fn setImage(item: objc.Object, symbol: [*:0]const u8, description: [*:0]const u8) void {
    const NSImage = objc.getClass("NSImage") orelse return;
    const img = NSImage.msgSend(objc.Object, "imageWithSystemSymbolName:accessibilityDescription:", .{ nsString(symbol).value, nsString(description).value });
    if (img.value == 0) return;
    img.msgSend(void, "setTemplate:", .{true});
    item.msgSend(void, "setImage:", .{img.value});
}

/// Build the bar: `menus` in order after the app menu, Help last, the app menu's About retitled
/// `about_title` and routed to `pollAbout`. Once; `hooks` answer for every item from then on.
pub fn install(menus: []const Menu, h: Hooks, about_title: ?[:0]const u8) void {
    if (comptime builtin.os.tag != .macos) return;
    if (installed) return;
    hooks = h;
    const NSApplication = objc.getClass("NSApplication") orelse return;
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const TargetClass = objc.getClass("FizzyMenuTarget") orelse return;
    const app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});
    if (app.value == 0) return;
    const bar = app.msgSend(objc.Object, "mainMenu", .{});
    if (bar.value == 0) return;
    main_menu = bar;
    const t = TargetClass.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    if (t.value == 0) return;
    target = t;
    const empty = nsString("");
    const action = selector("barAction:") orelse return;

    for (menus, 0..) |spec, menu_index| {
        if (menu_index >= max_menus) break;
        const title = nsString(spec.title.ptr);
        const menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{title.value});
        if (menu.value == 0) continue;
        fixed_menus[menu_index] = menu;
        fixed_specs[menu_index] = spec;
        fixed_count = menu_index + 1;
        for (spec.entries) |entry| switch (entry) {
            .separator => menu.msgSend(void, "addItem:", .{NSMenuItem.msgSend(objc.Object, "separatorItem", .{}).value}),
            .command => |cmd| {
                const mi = menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{ nsString(cmd.title.ptr).value, @intFromPtr(action), empty.value });
                if (mi.value == 0) continue;
                mi.msgSend(void, "setTarget:", .{t.value});
                mi.msgSend(void, "setTag:", .{@as(c_long, cmd.tag)});
                if (cmd.symbol) |sym| setImage(mi, sym.ptr, cmd.title.ptr);
                bar_items.put(dialogs.allocator(), cmd.tag, mi) catch {};
            },
            .list => |l| {
                if (list_count >= max_lists) continue;
                const lt = nsString(l.title.ptr);
                const li = menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{ lt.value, @as(usize, 0), empty.value });
                if (li.value == 0) continue;
                const lm = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{lt.value});
                if (lm.value == 0) continue;
                li.msgSend(void, "setSubmenu:", .{lm.value});
                li.msgSend(void, "setHidden:", .{true});
                list_menus[list_count] = lm;
                list_items[list_count] = li;
                list_count += 1;
            },
        };

        const bar_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{ title.value, @as(usize, 0), empty.value });
        if (bar_item.value == 0) continue;
        bar_item.msgSend(void, "setSubmenu:", .{menu.value});
        if (spec.help) {
            bar.msgSend(void, "addItem:", .{bar_item.value});
            app.msgSend(void, "setHelpMenu:", .{menu.value});
            help_item = bar_item;
        } else {
            // After the app menu, in order (AppKit's Window menu stays where SDL put it).
            bar.msgSend(void, "insertItem:atIndex:", .{ bar_item.value, @as(c_ulong, menu_index + 1) });
        }
    }

    // The app menu's About is AppKit's, not the app's: retitle it and route it here.
    const app_menu = bar.msgSend(objc.Object, "itemAtIndex:", .{@as(c_ulong, 0)}).msgSend(objc.Object, "submenu", .{});
    if (app_menu.value != 0) if (selector("about:")) |about| {
        const about_item = app_menu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_ulong, 0)});
        if (about_item.value != 0) {
            if (about_title) |at| about_item.msgSend(void, "setTitle:", .{nsString(at.ptr).value});
            about_item.msgSend(void, "setAction:", .{about});
            about_item.msgSend(void, "setTarget:", .{t.value});
        }
    };
    // SDL's Window menu closes the window on ⌘W, the chord an editor gives to closing the
    // document (`fizzy.close`, File ▸ Close). Two items on one key equivalent leave AppKit to pick,
    // and it picked the window. The window takes ⇧⌘W instead, as VS Code's does.
    if (selector("performClose:")) |close| {
        const window_menu = app.msgSend(objc.Object, "windowsMenu", .{});
        if (window_menu.value != 0) {
            const index = window_menu.msgSend(c_long, "indexOfItemWithTarget:andAction:", .{ @as(usize, 0), close });
            if (index >= 0) {
                const item = window_menu.msgSend(objc.Object, "itemAtIndex:", .{index});
                item.msgSend(void, "setKeyEquivalent:", .{nsString("w").value});
                item.msgSend(void, "setKeyEquivalentModifierMask:", .{@as(c_ulong, modifier_command | modifier_shift)});
            }
        }
    }
    installed = true;
    log.debug("menu bar: {d} menus, {d} items, {d} lists", .{ fixed_count, bar_items.count(), list_count });
}

/// A menu the app adds at run time, inserted before Help.
pub const ExtraMenu = struct { id: []const u8, title: []const u8 };

/// An item the app adds at run time, into a fixed menu (by its id or an alias) or an `ExtraMenu`.
pub const ExtraItem = struct {
    menu_id: []const u8,
    title: []const u8,
    symbol: ?[]const u8 = null,
    tag: u32,
};

fn fixedMenuFor(id: []const u8) ?objc.Object {
    for (fixed_specs[0..fixed_count], 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, id)) return fixed_menus[i];
        for (spec.aliases) |a| if (std.mem.eql(u8, a, id)) return fixed_menus[i];
    }
    return null;
}

/// Whether `id` names one of the fixed menus.
pub fn isFixedMenu(id: []const u8) bool {
    return fixedMenuFor(id) != null;
}

/// Replace everything added at run time with `menus` and `items`: the last set is taken out
/// first, so this is safe — and cheap enough — to call on every change. An `ExtraMenu` with no
/// item in it is left out.
pub fn setExtras(menus: []const ExtraMenu, items: []const ExtraItem) void {
    if (comptime builtin.os.tag != .macos) return;
    if (!installed) return;
    const bar = main_menu orelse return;
    const t = target orelse return;
    const gpa = dialogs.allocator();
    for (extra_leaves.items) |e| e.parent.msgSend(void, "removeItem:", .{e.item.value});
    extra_leaves.clearRetainingCapacity();
    for (extra_menus.items) |e| bar.msgSend(void, "removeItem:", .{e.item.value});
    extra_menus.clearRetainingCapacity();

    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const empty = nsString("");
    const action = selector("extraAction:") orelse return;

    var created: std.StringHashMapUnmanaged(objc.Object) = .empty;
    defer created.deinit(gpa);
    for (menus) |m| {
        if (m.title.len == 0 or isFixedMenu(m.id)) continue;
        const used = for (items) |it| {
            if (std.mem.eql(u8, it.menu_id, m.id)) break true;
        } else false;
        if (!used) continue;
        const title_z = dupeZ(m.title) orelse continue;
        defer gpa.free(title_z);
        const title = nsString(title_z.ptr);
        const menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:", .{title.value});
        if (menu.value == 0) continue;
        const item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{ title.value, @as(usize, 0), empty.value });
        if (item.value == 0) continue;
        item.msgSend(void, "setSubmenu:", .{menu.value});
        const at: c_long = if (help_item) |h| bar.msgSend(c_long, "indexOfItem:", .{h.value}) else -1;
        if (at >= 0) bar.msgSend(void, "insertItem:atIndex:", .{ item.value, @as(c_ulong, @intCast(at)) }) else bar.msgSend(void, "addItem:", .{item.value});
        extra_menus.append(gpa, .{ .item = item, .menu = menu }) catch {};
        created.put(gpa, m.id, menu) catch {};
    }

    for (items) |it| {
        const parent = fixedMenuFor(it.menu_id) orelse (created.get(it.menu_id) orelse continue);
        const title_z = dupeZ(it.title) orelse continue;
        defer gpa.free(title_z);
        const item = parent.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{ nsString(title_z.ptr).value, @intFromPtr(action), empty.value });
        if (item.value == 0) continue;
        item.msgSend(void, "setTarget:", .{t.value});
        item.msgSend(void, "setTag:", .{@as(c_long, it.tag)});
        if (it.symbol) |sym| if (dupeZ(sym)) |sym_z| {
            defer gpa.free(sym_z);
            setImage(item, sym_z.ptr, title_z.ptr);
        };
        extra_leaves.append(gpa, .{ .parent = parent, .item = item, .tag = it.tag }) catch {};
    }
    log.debug("menu bar extras: {d} menus, {d} items", .{ extra_menus.items.len, extra_leaves.items.len });
}

/// Fill list submenu `index` (the `index`th `.list` entry across the bar) with `titles`, in
/// order; an item chosen reports its position in `titles`. Hidden while empty.
pub fn setList(index: usize, titles: []const []const u8) void {
    if (comptime builtin.os.tag != .macos) return;
    if (index >= list_count) return;
    const menu = list_menus[index] orelse return;
    const t = target orelse return;
    const action = selector("listAction:") orelse return;
    menu.msgSend(void, "removeAllItems", .{});
    const empty = nsString("");
    for (titles, 0..) |title, i| {
        const z = dupeZ(title) orelse continue;
        defer dialogs.allocator().free(z);
        const item = menu.msgSend(objc.Object, "addItemWithTitle:action:keyEquivalent:", .{ nsString(z.ptr).value, @intFromPtr(action), empty.value });
        if (item.value == 0) continue;
        item.msgSend(void, "setTarget:", .{t.value});
        item.msgSend(void, "setTag:", .{@as(c_long, @intCast(i))});
    }
    if (list_items[index]) |li| li.msgSend(void, "setHidden:", .{titles.len == 0});
}

/// Give item `ref` the key equivalent `key` (lowercase, as AppKit wants it — shift goes in
/// `modifiers`) with `modifiers` (`modifier_command` and the rest); null clears it. An item not
/// on the bar now is left alone.
pub fn setKeyEquivalent(ref: Ref, key: ?[]const u8, modifiers: c_ulong) void {
    if (comptime builtin.os.tag != .macos) return;
    switch (ref.section) {
        .bar => if (bar_items.get(ref.tag)) |item| applyKey(item, key, modifiers),
        .extra => for (extra_leaves.items) |e| if (e.tag == ref.tag) applyKey(e.item, key, modifiers),
        .list => {},
    }
}

fn applyKey(item: objc.Object, key: ?[]const u8, modifiers: c_ulong) void {
    var buf: [8]u8 = undefined;
    const text: [:0]const u8 = blk: {
        const k = key orelse break :blk "";
        if (k.len >= buf.len) break :blk "";
        @memcpy(buf[0..k.len], k);
        buf[k.len] = 0;
        break :blk buf[0..k.len :0];
    };
    item.msgSend(void, "setKeyEquivalent:", .{nsString(text.ptr).value});
    item.msgSend(void, "setKeyEquivalentModifierMask:", .{if (key == null) @as(c_ulong, 0) else modifiers});
}

// ── Draining ───────────────────────────────────────────────────────────────────────────────────

/// The item chosen in `section` since the last call, if one was. Call once a frame, inside it.
pub fn pollActivation(section: Section) ?Activation {
    const tag = pending_tag[@intFromEnum(section)].swap(-1, .acq_rel);
    if (tag < 0) return null;
    return .{
        .ref = .{ .section = section, .tag = @intCast(tag) },
        .from_key = section == .bar and pending_from_key.load(.acquire),
    };
}

/// Whether the app menu's About was chosen since the last call.
pub fn pollAbout() bool {
    return pending_about.swap(false, .acq_rel);
}
