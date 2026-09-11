//! The surface picker: a popup of cards, one per surface, that sets what one region shows.
//!
//! Opened by name from anywhere — the settings table, a region's own corner button — through
//! `State.openPicker`, and drawn once per frame by the application through `draw` so it floats
//! above whatever opened it. One picker at a time: the state holds a single one.
//!
//! Each card carries a **snapshot** of the surface, not the live surface. Drawing a surface
//! twice in a frame would run its widgets twice — events reaching both, plugins that assume
//! one draw per frame breaking — and a surface in no region has no live pixels to show at all.
//! `Layout` takes the snapshots (`State.snapshots_wanted`) and this only reads them; a card
//! without one yet shows its title on a blank tile until the capture lands a frame later.
//!
//! A click toggles the surface in the region. The write is the region's *full* list — what it
//! shows now, plus or minus one — so the first toggle on a never-assigned region turns the
//! keyword match it was showing into an explicit assignment. That is the honest reading of the
//! click: the user has now chosen this region's contents, and a plugin loaded later will not
//! walk in by keyword until they choose again. "Back to defaults" undoes exactly that.
//! "Clear" and "Remove" are for places the user made: a minted split leaf
//! (`Main/r1`, `Center/r1`) or a leftover tray whose keyword is `slot`.
//! Shape-declared Sidebar, Main, and Panel stay and only get "Back to defaults".
//! Clear empties the assignment. Remove does that and slides the sash shut;
//! a forgettable tray collapses when the close finishes. Split offers
//! Vertical or Horizontal — the divider, not the layout axis — and eases
//! the new place to the middle.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Split = core.widgets.Split;
const Layout = @import("Layout.zig");
const State = @import("State.zig");

const Picker = @This();

/// Whether the popup is showing. dvui clears it on escape or a click outside.
is_open: bool = false,
/// The region being edited, gpa-owned; valid while `is_open`.
region: []const u8 = "",
/// Where to put the popup; centred on the window when null.
anchor: ?dvui.Point.Natural = null,

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
        .color_fill = theme.color(.content, .fill).opacity(0.95),
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
            dvui.labelNoFmt(@src(), switch (region.shows) {
                .one => "shows one",
                .many => "shows any number",
            }, .{}, .{
                .font = dvui.Font.theme(.body).larger(-1),
                .padding = .{ .x = 8 },
                .gravity_y = 0.5,
                .color_text = theme.color(.window, .text).opacity(0.5),
            });
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
                dvui.icon(@src(), "split_choice", dvui.entypo.triangle_down, .{}, .{
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

        if (canClearOrRemove(state, &region) or state.assignment(region.name) != null) {
            var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer actions.deinit();
            if (canClearOrRemove(state, &region)) {
                if (actionButton(@src(), "Clear", 2)) {
                    clearRegion(f, region.name);
                }
                if (actionButton(@src(), "Remove", 3)) {
                    removeRegion(f, &region);
                    self.close(gpa);
                    state.discardSnapshots(gpa);
                    return;
                }
            }
            if (state.assignment(region.name) != null) {
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
        if (card(f, s, on, i)) {
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
    }

    if (state.store_catalog) |store| drawStoreSection(f, &region, store, &row, &col);
}

/// One surface: its snapshot scaled to fit, its title, its owner, and a highlight when it is in
/// the region. Returns true on click.
fn card(f: *Layout, s: *const sdk.Surface, on: bool, id_extra: usize) bool {
    const theme = dvui.themeGet();
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = id_extra,
        .margin = dvui.Rect.all(4),
        .padding = dvui.Rect.all(6),
        .corners = dvui.CornerRect.all(6),
        .background = true,
        .color_fill = if (on) theme.color(.highlight, .fill).opacity(0.25) else theme.color(.control, .fill),
        .border = dvui.Rect.all(1),
        .color_border = if (on) theme.color(.highlight, .fill) else theme.color(.control, .border),
    });
    defer bw.deinit();
    bw.processEvents();
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
            .color_fill = theme.color(.content, .fill),
        });
        defer tile.deinit();
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
        .color_text = if (on) theme.color(.highlight, .fill) else theme.color(.window, .text),
    });
    const owner = if (s.owner) |p| p.display_name else "";
    if (owner.len > 0) {
        dvui.labelNoFmt(@src(), owner, .{}, .{
            .padding = .{},
            .font = dvui.Font.theme(.heading),
            .color_text = theme.color(.control, .text),
        });
    }
    return bw.clicked();
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

/// A place the user made, not one the shape declared. Minted split leaves
/// (`Main/r1`, endless `Center/r1`) and leftover trays that kept `slot`.
fn canClearOrRemove(state: *State, region: *const Layout.Region) bool {
    if (region.forget_when_empty or state.splits.canForget(region.name)) return true;
    return isUserSlot(region);
}

/// A place the user made, not one the shape declared. Endless trays and leftover
/// Center use the bare `slot` word; fizzy's keyword regions never do. A
/// leftover under Main used to be `main.slot` and hid these buttons.
fn isUserSlot(region: *const Layout.Region) bool {
    if (!region.by_name) return false;
    const want = Layout.slot_keywords[0];
    for (region.keywords) |k| {
        if (std.mem.eql(u8, k, want)) return true;
        if (std.mem.endsWith(u8, k, ".slot")) return true;
    }
    return false;
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
/// The leftover (Center) can be emptied; it is not collapsed.
fn removeRegion(f: *Layout, region: *const Layout.Region) void {
    const gpa = f.gpa;
    f.state.assign(gpa, region.name, &.{}) catch |err| {
        dvui.log.err("failed to clear '{s}': {t}", .{ region.name, err });
    };
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
        .color_text = dvui.themeGet().color(.window, .text).opacity(0.6),
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
        .color_fill = theme.color(.control, .fill),
        .border = dvui.Rect.all(1),
        .color_border = theme.color(.control, .border),
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
            .color_fill = theme.color(.content, .fill),
        });
        defer tile.deinit();
        dvui.labelNoFmt(@src(), if (installing) "Installing…" else "Install", .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = theme.color(.control, .text),
        });
    }

    dvui.labelNoFmt(@src(), offer.title, .{}, .{
        .padding = .{ .y = 4 },
        .max_size_content = .width(preview.w),
    });
    dvui.labelNoFmt(@src(), "Store", .{}, .{
        .padding = .{},
        .font = dvui.Font.theme(.heading),
        .color_text = theme.color(.control, .text),
    });
    return bw.clicked() and !installing;
}
