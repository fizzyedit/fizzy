//! Place settings: what one region shows, and how it shows it.
//!
//! Opened by name from anywhere — the settings table, a region's own corner button — through
//! `State.openPicker`, and drawn once per frame by the application through `draw` so it floats
//! above whatever opened it. One at a time.
//!
//! **Single** is one surface, no chooser. **Multiple** is several, and the
//! place grows a tab strip. The shape's default (Sidebar/Panel many, Main one)
//! is the starting point; the user's choice is remembered with the layout.
//!
//! Cards assign a surface here. That is how a sidebar view stays in the
//! sidebar, and how a plugin readme lands in the center — keywords are the
//! default guess, an assignment is the answer. "Back to defaults" undoes it.
//!
//! A card is also a handle. Dragged out of the popup it becomes the same
//! floating view the corner button lifts out of a place (`ViewDrag`), and
//! lands the same way — swapped onto a place, or split off one of its edges —
//! with the popup gone and the drag previewing on the places themselves. The
//! picker keeps driving that drag until the button comes up, because the
//! card that started it went away with the popup.
//!
//! Each card carries a **snapshot** of the surface, not the live surface.
//! A **pinned** place (Sidebar, Main, Panel, Center) can be emptied (**Clear**)
//! or returned to keywords; it cannot be deleted. A **created** place
//! (`Main/r1`) is **Remove**. Split offers Vertical or Horizontal, and keeps
//! this place's view beside the new empty one — see `SPLITS.md`.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Split = core.widgets.Split;
const Layout = @import("Layout.zig");
const State = @import("State.zig");
const ViewDrag = @import("ViewDrag.zig");

const Picker = @This();

/// Whether the popup is showing. dvui clears it on escape or a click outside.
is_open: bool = false,
/// The region being edited, gpa-owned; valid while `is_open`.
region: []const u8 = "",
/// Where to put the popup; centred on the window when null.
anchor: ?dvui.Point.Natural = null,
/// A card was dragged out of the popup and is riding the pointer as a loose
/// `ViewDrag`. The popup is closed; `draw` drives the drag instead until the
/// button comes up.
lifted: bool = false,

/// Card geometry, in points. The preview keeps the snapshot's aspect inside this box.
const preview: dvui.Size = .{ .w = 150, .h = 100 };
const columns: usize = 2;
const list_height: f32 = 420;

pub fn open(self: *Picker, gpa: std.mem.Allocator, region: []const u8, anchor: ?dvui.Point.Natural) void {
    self.close(gpa);
    self.region = gpa.dupe(u8, region) catch return;
    self.anchor = anchor;
    self.is_open = true;
}

pub fn close(self: *Picker, gpa: std.mem.Allocator) void {
    if (self.region.len > 0) gpa.free(self.region);
    self.region = "";
    self.is_open = false;
}

/// Draw the popup if it is open. Call once per frame after the shape has run. Closing —
/// by the user or because the region vanished — also discards the snapshots.
pub fn draw(self: *Picker, f: *Layout) void {
    if (self.lifted) return self.drawLifted(f);
    if (!self.is_open) return;
    const state = f.state;
    const gpa = f.gpa;

    const region = blk: {
        for (state.regions.items) |r| if (std.mem.eql(u8, r.name, self.region)) break :blk r;
        // The shape stopped declaring it (window narrowed, layout swapped): nothing to edit.
        self.close(gpa);
        state.discardSnapshots(gpa);
        return;
    };
    flushPendingStore(f, &region);

    const contents = f.matchingIn(&region);
    const theme = dvui.themeGet();

    // Same card as the command palette's panel: translucent content fill, rounded, no border,
    // soft drop shadow. A floating chooser and a floating palette are the same kind of thing, so
    // they read as one surface style rather than two.
    var popup = dvui.popup(@src(), .{ .open_flag = &self.is_open, .from = self.anchor }, .{
        .padding = dvui.Rect.all(8),
        .color_fill = .{ .color = theme.color(.content, .fill).opacity(0.95) },
        .corners = dvui.CornerRect.all(8),
        .border = .all(0),
        .box_shadow = .{
            .fade = 8,
            .corners = .all(8),
            .alpha = 0.25,
        },
    }) orelse {
        // Just closed.
        self.close(gpa);
        state.discardSnapshots(gpa);
        return;
    };
    defer popup.deinit();

    {
        var chrome = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .padding = .{ .h = 6 },
        });
        defer chrome.deinit();

        {
            var title = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer title.deinit();
            dvui.labelNoFmt(@src(), region.name, .{}, .{
                .font = dvui.Font.theme(.heading),
                .gravity_y = 0.5,
            });
        }

        {
            var mode = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .y = 4 },
            });
            defer mode.deinit();
            dvui.labelNoFmt(@src(), "Surfaces", .{}, .{
                .font = actionFont(),
                .gravity_y = 0.5,
                .color_text = .{ .color = theme.color(.window, .text).opacity(0.6) },
            });
            if (modeButton(@src(), "Single", region.shows == .one, 1)) {
                setShows(f, &region, .one);
            }
            if (modeButton(@src(), "Multiple", region.shows == .many, 2)) {
                setShows(f, &region, .many);
            }
        }

        {
            var splits = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .y = 4 },
            });
            defer splits.deinit();
            // Vertical / Horizontal name the divider: a vertical bar is side by
            // side (the layout axis is horizontal). The old "split horizontally"
            // label was that axis and read as the opposite split.
            var split: dvui.DropdownWidget = undefined;
            split.init(@src(), .{}, .{
                .font = actionFont(),
                .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                .margin = .{ .w = 4 },
                .gravity_y = 0.5,
            });
            defer split.deinit();
            {
                var label = dvui.box(@src(), .{ .dir = .horizontal }, .{});
                defer label.deinit();
                dvui.labelNoFmt(@src(), "Split", .{}, .{
                    .font = actionFont(),
                    .padding = .{},
                    .margin = .{},
                    .gravity_y = 0.5,
                });
                core.icon.icon(@src(), "split_choice", dvui.entypo.triangle_down, .{}, .{
                    .padding = .{ .x = 4 },
                    .gravity_y = 0.5,
                });
            }
            if (split.dropped()) {
                if (split.addChoiceLabel("Vertical")) {
                    f.splitNamed(region.name, .horizontal);
                    self.close(gpa);
                    state.discardSnapshots(gpa);
                    return;
                }
                if (split.addChoiceLabel("Horizontal")) {
                    f.splitNamed(region.name, .vertical);
                    self.close(gpa);
                    state.discardSnapshots(gpa);
                    return;
                }
            }
        }

        const created = isCreated(state, region.name);
        // On the tree, any leaf with a sibling can go — a declared place's pin moves to the
        // sibling. Off it, only a minted leaf can.
        const removable = created or state.canRemove(region.name);
        const assigned = state.assignment(region.name);
        const showing = if (assigned) |ids| ids.len > 0 else f.selectedIn(&region) != null;
        if (removable or showing or assigned != null) {
            var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer actions.deinit();
            if (removable) {
                if (actionButton(@src(), "Remove", 3)) {
                    removeRegion(f, &region);
                    self.close(gpa);
                    state.discardSnapshots(gpa);
                    return;
                }
            }
            if (!created and showing) {
                if (actionButton(@src(), "Clear", 2)) {
                    clearRegion(f, region.name);
                }
            }
            if (!created and assigned != null) {
                if (actionButtonRight(@src(), "Back to defaults")) {
                    state.unassign(gpa, region.name);
                    state.markDirty();
                    dvui.refresh(null, @src(), null);
                }
            }
        }
    }

    const width = @as(f32, @floatFromInt(columns)) * (preview.w + 16) + 16;
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .min_size_content = .{ .w = width, .h = list_height },
        .max_size_content = .size(.{ .w = width, .h = list_height }),
        .background = false,
    });
    defer scroll.deinit();

    var grid = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer grid.deinit();

    var row: ?*dvui.BoxWidget = null;
    defer if (row) |r| r.deinit();
    var col: usize = 0;
    for (f.host.surfaces.items, 0..) |*s, i| {
        if (s.hidden) continue;
        if (col == 0) {
            if (row) |r| r.deinit();
            row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
        }
        col = (col + 1) % columns;

        // Highlighted means "this is what you can see here", which over a `.one` region is the
        // selected surface rather than every surface its keywords attract — several cards lit up
        // in a region that draws one would be reporting a set that does not exist.
        const on = switch (region.shows) {
            .one => if (f.selectedIn(&region)) |sel| std.mem.eql(u8, sel.id, s.id) else false,
            .many => contains(contents, s.id),
        };
        switch (card(f, s, on, i)) {
            .none => continue,
            .lifted => |hit| {
                self.lift(f, s, hit);
                // The button may already be up in this frame's events (a
                // flick): drive the drag now rather than losing the release.
                if (self.lifted) self.drawLifted(f);
                return;
            },
            .clicked => {},
        }
        switch (region.shows) {
            // A swap. The region draws one surface, so a set would be a lie: the second and
            // third members would exist in the file and never appear on screen. Selecting as
            // well as assigning is what makes the click land on this frame — the region reads
            // its selection to decide what to draw, and a one-surface assignment it has never
            // selected would otherwise wait for the fallback.
            .one => {
                state.assign(gpa, region.name, &.{s.id}) catch |err| {
                    dvui.log.err("failed to assign '{s}': {t}", .{ region.name, err });
                };
                f.host.setSelectionForKey(region.selectionKey(), s.id);
                // One surface is the whole choice. Leave the popup so the
                // corner control can hide on a filled place.
                self.close(gpa);
                state.discardSnapshots(gpa);
                state.markDirty();
                dvui.refresh(null, @src(), null);
                return;
            },
            // A toggle: the region's contents, plus or minus this one, in the order they were
            // already in.
            .many => {
                var ids = std.ArrayListUnmanaged([]const u8).initCapacity(f.arena, contents.len + 1) catch return;
                for (contents) |c| if (!std.mem.eql(u8, c.id, s.id)) ids.appendAssumeCapacity(c.id);
                if (!on) ids.appendAssumeCapacity(s.id);
                state.assign(gpa, region.name, ids.items) catch |err| {
                    dvui.log.err("failed to assign '{s}': {t}", .{ region.name, err });
                };
            },
        }
        state.markDirty();
        dvui.refresh(null, @src(), null);
    }

    if (state.store_catalog) |store| drawStoreSection(f, &region, store, &row, &col);
}

/// What a card did this frame.
const Hit = union(enum) {
    none,
    clicked,
    /// Dragged past dvui's threshold: where the preview tile was, and the
    /// event that crossed it, so the drag can take the capture over.
    lifted: struct { tile: dvui.Rect.Physical, event_num: u16 },
};

/// One surface: its snapshot scaled to fit, its title, its owner, and a highlight when it is in
/// the region. A press that moves far enough lifts the card into a drag instead of clicking.
fn card(f: *Layout, s: *const sdk.Surface, on: bool, id_extra: usize) Hit {
    const theme = dvui.themeGet();
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = id_extra,
        .margin = dvui.Rect.all(4),
        .padding = dvui.Rect.all(6),
        .corners = dvui.CornerRect.all(6),
        .background = true,
        .color_fill = .{ .color = if (on) theme.color(.highlight, .fill).opacity(0.25) else theme.color(.control, .fill) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = if (on) theme.color(.highlight, .fill) else theme.color(.control, .border) },
    });
    defer bw.deinit();
    bw.processEvents();

    // The tile's rect is remembered from last frame: the press that starts a
    // drag is read here, before the tile is laid out.
    const tile_rect = dvui.dataGet(null, bw.data().id, "_tile", dvui.Rect.Physical) orelse bw.data().borderRectScale().r;
    var lifted: ?Hit = null;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        // The button took the press and the capture; from here the pointer is ours.
        if (!dvui.captured(bw.data().id)) continue;
        if (me.action == .press and me.button.pointer()) {
            dvui.dragPreStart(me.button, me.p, .{
                .offset = tile_rect.topLeft().diff(me.p),
                .size = tile_rect.size(),
                .name = "fizzy_view",
            });
        }
        if (me.action == .motion and dvui.dragging(me.p, "fizzy_view") != null) {
            e.handle(@src(), bw.data());
            lifted = .{ .lifted = .{ .tile = tile_rect, .event_num = e.num } };
            break;
        }
    }
    bw.drawBackground();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{});
    defer col.deinit();

    // The preview tile: the snapshot letterboxed into a fixed box so cards line up.
    {
        var tile = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = preview,
            .max_size_content = .size(preview),
            .background = true,
            .corners = dvui.CornerRect.all(3),
            .color_fill = .{ .color = theme.color(.content, .fill) },
        });
        defer tile.deinit();
        dvui.dataSet(null, bw.data().id, "_tile", tile.data().borderRectScale().r);
        if (f.state.snapshot(s.id)) |snap| {
            const rs = tile.data().contentRectScale();
            const scale = @min(rs.r.w / (snap.natural.w * rs.s), rs.r.h / (snap.natural.h * rs.s));
            const w = snap.natural.w * rs.s * scale;
            const h = snap.natural.h * rs.s * scale;
            const dst: dvui.Rect.Physical = .{
                .x = rs.r.x + (rs.r.w - w) / 2,
                .y = rs.r.y + (rs.r.h - h) / 2,
                .w = w,
                .h = h,
            };
            dvui.renderTexture(snap.texture, .{ .r = dst, .s = rs.s }, .{}) catch {};
        }
    }

    dvui.labelNoFmt(@src(), s.title, .{}, .{
        .padding = .{ .y = 4 },
        .max_size_content = .width(preview.w),
        .color_text = .{ .color = if (on) theme.color(.highlight, .fill) else theme.color(.window, .text) },
    });
    const owner = if (s.owner) |p| p.display_name else "";
    if (owner.len > 0) {
        dvui.labelNoFmt(@src(), owner, .{}, .{
            .padding = .{},
            .font = dvui.Font.theme(.heading),
            .color_text = .{ .color = theme.color(.control, .text) },
        });
    }
    if (lifted) |hit| return hit;
    return if (bw.clicked()) .clicked else .none;
}

/// The capture a loose drag holds while no widget of the picker exists to
/// hold it: the card is gone with the popup, so the drag is its own widget as
/// far as dvui's mouse routing is concerned. One id for every such drag, in
/// the base window, over the whole of it.
fn looseCapture() dvui.CaptureMouse {
    return .{
        .id = dvui.Id.extendId(null, @src(), 0),
        .rect = dvui.windowRectPixels(),
        .subwindow_id = dvui.currentWindow().data().id,
    };
}

/// A card crossed the drag threshold: hand its picture and the pointer to a
/// loose `ViewDrag` and shut the popup. The drag is driven by `drawLifted`
/// from the next frame on.
fn lift(self: *Picker, f: *Layout, s: *const sdk.Surface, hit: @FieldType(Hit, "lifted")) void {
    const gpa = f.gpa;
    const snap = f.state.stealSnapshot(gpa, s.id);
    ViewDrag.beginLoose(f, s.id, hit.tile, if (snap) |sn| sn.texture else null);
    if (!f.state.view_drag.active()) {
        if (snap) |sn| dvui.textureDestroyLater(sn.texture);
        return;
    }
    dvui.captureMouseCustom(looseCapture(), hit.event_num);
    self.lifted = true;
    self.close(gpa);
    f.state.discardSnapshots(gpa);
    dvui.refresh(null, @src(), null);
}

/// Drive a loose drag: keep the capture, land or cancel on release, and draw
/// the float. The places draw their own previews and hints from the drag
/// state, exactly as they do for a corner-button drag.
fn drawLifted(self: *Picker, f: *Layout) void {
    const d = &f.state.view_drag;
    if (!d.active() or !d.loose()) {
        // Discarded from outside (a plugin unloaded, the layout was swapped).
        self.lifted = false;
        if (dvui.captured(looseCapture().id)) {
            dvui.captureMouse(null, 0);
            dvui.dragEnd();
        }
        return;
    }
    const cm = looseCapture();
    // Not `captureMouseMaintain`: that walks the subwindow stack and drops
    // the capture on meeting a modal subwindow above the current one, and
    // the popup this drag came out of — modal — stays on the stack for one
    // frame after it stops being drawn. Re-asserting the capture from the
    // last event on keeps it without retargeting anything already routed.
    dvui.captureMouseCustom(cm, dvui.currentWindow().event_num);
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        if (e.target_widgetId != cm.id) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .motion => e.handled = true,
            .release => if (me.button.pointer()) {
                e.handled = true;
                ViewDrag.apply(f, ViewDrag.loose_source, me.p);
                d.discard();
                self.lifted = false;
                dvui.captureMouse(null, e.num);
                dvui.dragEnd();
                dvui.refresh(null, @src(), null);
                return;
            },
            else => {},
        }
    }
    ViewDrag.drawFloat(f);
}

fn setShows(f: *Layout, region: *const Layout.Region, shows: Layout.Region.Shows) void {
    f.state.setShows(f.gpa, region.name, shows);
    if (shows == .one) {
        const contents = f.matchingIn(region);
        if (contents.len > 1) {
            const keep = if (f.selectedIn(region)) |s| s.id else contents[0].id;
            f.state.assign(f.gpa, region.name, &.{keep}) catch {};
            f.host.setSelectionForKey(region.selectionKey(), keep);
        }
    }
    f.state.markDirty();
    dvui.refresh(null, @src(), null);
}

fn modeButton(src: std.builtin.SourceLocation, label: []const u8, on: bool, id_extra: usize) bool {
    const theme = dvui.themeGet();
    return dvui.button(src, label, .{}, .{
        .font = actionFont(),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        .margin = .{ .x = 4 },
        .gravity_y = 0.5,
        .id_extra = id_extra,
        .color_fill = if (on) .{ .color = theme.color(.highlight, .fill).opacity(0.25) } else null,
        .color_border = if (on) .{ .color = theme.color(.highlight, .fill) } else null,
    });
}

fn actionFont() dvui.Font {
    return dvui.Font.theme(.body).larger(-1);
}

fn actionButton(src: std.builtin.SourceLocation, label: []const u8, id_extra: usize) bool {
    return dvui.button(src, label, .{}, .{
        .font = actionFont(),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        .margin = .{ .w = 4 },
        .gravity_y = 0.5,
        .id_extra = id_extra,
    });
}

fn actionButtonRight(src: std.builtin.SourceLocation, label: []const u8) bool {
    return dvui.button(src, label, .{}, .{
        .font = actionFont(),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
        .gravity_x = 1.0,
        .gravity_y = 0.5,
    });
}

fn contains(list: []const *sdk.Surface, id: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s.id, id)) return true;
    return false;
}

/// A minted split leaf, not a name the shape declared.
fn isCreated(state: *State, name: []const u8) bool {
    return state.isMinted(name);
}

/// Empty the place: nothing draws, and keywords no longer attract a replacement.
fn clearRegion(f: *Layout, name: []const u8) void {
    f.state.assign(f.gpa, name, &.{}) catch |err| {
        dvui.log.err("failed to clear '{s}': {t}", .{ name, err });
        return;
    };
    f.state.markDirty();
    dvui.refresh(null, @src(), null);
}

/// Clear, then slide the sash shut. A minted split leaf collapses once the close lands.
/// The leftover (Center) can be emptied; it is not collapsed. A pinned seed leaf cannot
/// be removed.
fn removeRegion(f: *Layout, region: *const Layout.Region) void {
    const gpa = f.gpa;
    f.state.assign(gpa, region.name, &.{}) catch |err| {
        dvui.log.err("failed to clear '{s}': {t}", .{ region.name, err });
    };
    if (f.state.dock) |*dock| {
        const idx = dock.findPanel(region.name) orelse {
            f.state.markDirty();
            dvui.refresh(null, @src(), null);
            return;
        };
        dock.closeLeaf(idx);
        f.state.markDirty();
        dvui.refresh(null, @src(), null);
        return;
    }
    const forget = region.forget_when_empty or f.state.splits.canForget(region.name);
    if (forget) {
        if (region.id != .zero and (dvui.dataGet(null, region.id, "_size", f32) orelse 0) > 0) {
            Split.close(region.id);
            f.extents_changed = true;
        } else if (f.state.splits.collapse(gpa, region.name)) {
            if (f.state.clearExtent(gpa, region.name)) f.extents_changed = true;
            f.state.unassign(gpa, region.name);
        }
    }
    f.state.markDirty();
    dvui.refresh(null, @src(), null);
}

/// If a store install the user started from this picker has loaded, assign its surfaces.
fn flushPendingStore(f: *Layout, region: *const Layout.Region) void {
    const state = f.state;
    if (state.pending_store_plugin.len == 0) return;
    if (!std.mem.eql(u8, state.pending_store_region, region.name)) return;

    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    for (f.host.surfaces.items) |*s| {
        const owner = s.owner orelse continue;
        if (s.hidden) continue;
        if (std.mem.eql(u8, owner.id, state.pending_store_plugin)) {
            ids.append(f.arena, s.id) catch return;
        }
    }
    if (ids.items.len == 0) return;

    state.assign(f.gpa, region.name, ids.items) catch |err| {
        dvui.log.err("failed to assign store plugin to '{s}': {t}", .{ region.name, err });
        return;
    };
    if (region.shows == .one) f.host.setSelectionForKey(region.selectionKey(), ids.items[0]);
    state.clearPendingStore(f.gpa);
    state.markDirty();
    dvui.refresh(null, @src(), null);
}

fn drawStoreSection(
    f: *Layout,
    region: *const Layout.Region,
    store: State.StoreCatalog,
    row: *?*dvui.BoxWidget,
    col: *usize,
) void {
    const offers = store.uninstalled(f.arena);
    if (offers.len == 0) return;

    if (row.*) |r| {
        r.deinit();
        row.* = null;
    }
    col.* = 0;

    dvui.labelNoFmt(@src(), "Store", .{}, .{
        .font = dvui.Font.theme(.heading),
        .padding = .{ .y = 10, .x = 4 },
        .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.6) },
    });

    for (offers, 0..) |offer, i| {
        if (col.* == 0) {
            if (row.*) |r| r.deinit();
            row.* = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i + 10_000, .expand = .horizontal });
        }
        col.* = (col.* + 1) % columns;
        if (storeCard(offer, store.installing(offer.id), i)) {
            store.install(offer.id);
            f.state.requestStoreInstall(f.gpa, region.name, offer.id);
            dvui.refresh(null, @src(), null);
        }
    }
}

fn storeCard(offer: State.StoreOffer, installing: bool, id_extra: usize) bool {
    const theme = dvui.themeGet();
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = id_extra,
        .margin = dvui.Rect.all(4),
        .padding = dvui.Rect.all(6),
        .corners = dvui.CornerRect.all(6),
        .background = true,
        .color_fill = .{ .color = theme.color(.control, .fill) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = theme.color(.control, .border) },
    });
    defer bw.deinit();
    bw.processEvents();
    bw.drawBackground();

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{});
    defer col.deinit();

    {
        var tile = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = preview,
            .max_size_content = .size(preview),
            .background = true,
            .corners = dvui.CornerRect.all(3),
            .color_fill = .{ .color = theme.color(.content, .fill) },
        });
        defer tile.deinit();
        dvui.labelNoFmt(@src(), if (installing) "Installing…" else "Install", .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = theme.color(.control, .text) },
        });
    }

    dvui.labelNoFmt(@src(), offer.title, .{}, .{
        .padding = .{ .y = 4 },
        .max_size_content = .width(preview.w),
    });
    dvui.labelNoFmt(@src(), "Store", .{}, .{
        .padding = .{},
        .font = dvui.Font.theme(.heading),
        .color_text = .{ .color = theme.color(.control, .text) },
    });
    return bw.clicked() and !installing;
}
