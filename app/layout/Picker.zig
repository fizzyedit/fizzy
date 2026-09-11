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
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
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
        var head = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .h = 6 } });
        defer head.deinit();
        dvui.labelNoFmt(@src(), region.name, .{}, .{ .font = dvui.Font.theme(.heading), .gravity_y = 0.5 });
        // Why a click behaves differently here than in the panel: this region draws one surface,
        // so choosing is a swap rather than adding to a set.
        dvui.labelNoFmt(@src(), switch (region.shows) {
            .one => "shows one",
            .many => "shows any number",
        }, .{}, .{
            .padding = .{ .x = 8 },
            .gravity_y = 0.5,
            .color_text = theme.color(.window, .text).opacity(0.5),
        });
        if (state.assignment(region.name) != null) {
            if (dvui.button(@src(), "Back to defaults", .{}, .{ .gravity_x = 1.0, .gravity_y = 0.5 })) {
                state.unassign(gpa, region.name);
                state.markDirty();
                dvui.refresh(null, @src(), null);
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
            .one => if (f.selected(region.keywords)) |sel| std.mem.eql(u8, sel.id, s.id) else false,
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
                    f.host.setSelectionFor(region.keywords, s.id);
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

fn contains(list: []const *sdk.Surface, id: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s.id, id)) return true;
    return false;
}
