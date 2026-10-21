//! Place settings: what one region shows, and how it shows it.
//!
//! Opened by name from anywhere — the settings table, a region's own corner button — through
//! `State.openPicker`, and drawn once per frame by the application through `draw` so it floats
//! above whatever opened it. One at a time.
//!
//! A place holding one view shows it alone; holding more, it grows a tab strip
//! (`Layout.tabbedIn`). A card toggles its view in or out of the place.
//!
//! Cards assign a surface here. That is how a sidebar view stays in the
//! sidebar, and how a plugin readme lands in the center — keywords are the
//! default guess, an assignment is the answer. Reset undoes it.
//! The cards are listed under the place holding them, or else the place their
//! keywords are for — this place first, then each other place by its name, then
//! "Other" — so a view made for the panel reads as one, wherever the picker was
//! opened, and a view the user moved reads under where it went.
//!
//! A card is also a handle. Dragged out of the popup it becomes the same
//! floating view the corner button lifts out of a place (`ViewDrag`), and
//! lands the same way — swapped onto a place, or split off one of its edges —
//! with the popup gone and the drag previewing on the places themselves. The
//! picker keeps driving that drag until the button comes up, because the
//! card that started it went away with the popup.
//!
//! Each card carries a **snapshot** of the surface, not the live surface.
//!
//! The header is icons only, each a command (`place_commands`): split right or
//! down, clear, reset to the layout's default, delete (in red). A **pinned**
//! place (Sidebar, Main, Panel, Center) can be cleared or reset to its keywords;
//! it cannot be deleted. A **created** place (`Main/r1`) can. A split keeps this
//! place's view beside the new empty one — see `SPLITS.md`.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const icons = @import("icons");
const Split = core.widgets.Split;
const Layout = @import("Layout.zig");
const State = @import("State.zig");
const ViewDrag = @import("ViewDrag.zig");
const place_commands = @import("place_commands.zig");

const Picker = @This();

/// Whether the popup is showing. dvui clears it on escape or a click outside.
is_open: bool = false,
/// The region being edited, gpa-owned; valid while `is_open`.
region: []const u8 = "",
/// Where to put the popup; centred on the window when null.
anchor: ?dvui.Point.Natural = null,
/// The control it was opened from, which it grows out of (`core.widgets.popup`'s `grow_from`): the
/// corner's button turning into the picker. Set after `open` by whoever opened it.
grow_from: ?dvui.Rect.Natural = null,
/// A card was dragged out of the popup and is riding the pointer as a loose
/// `ViewDrag`. The popup is closed; `draw` drives the drag instead until the
/// button comes up.
lifted: bool = false,
/// What place commands asked of places (`place_commands`), in order, carried out by the next
/// `draw`, where the live `Layout` is.
requests: [max_requests]Request = undefined,
request_n: usize = 0,
/// The place commands' owner (`place_commands.register`): a pseudo-plugin whose state is the
/// layout state this picker is part of, so each layout's commands reach their own.
commands_owner: sdk.Plugin = .{ .state = undefined, .vtable = &place_commands.vtable, .id = "layout", .display_name = "Layout" },
/// When the list last laid its cards out (`dvui.frameTimeNS`): a view being drawn for its picture
/// whose card was not in view then has left the list (`Layout.captureUnplaced`). A draw that
/// returned before the list leaves it alone.
list_ns: i128 = 0,

/// What the menu's header can do to a place, each a command (`place_commands`).
pub const Action = enum {
    split_right,
    split_down,
    clear,
    reset,
    delete,

    /// The anchor name a control publishes says it this way: `region.menu.split-right:Main`.
    pub fn format(self: Action, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (@tagName(self)) |ch| try w.writeByte(if (ch == '_') '-' else ch);
    }
};

pub const Request = struct {
    action: Action,
    buf: [128]u8 = undefined,
    len: usize = 0,

    pub fn place(self: *const Request) []const u8 {
        return self.buf[0..self.len];
    }
};

/// How many place commands can wait for the next draw.
const max_requests = 8;

/// Ask for `action` on place `name` in the next draw. False when the name does not fit, or too
/// many are waiting.
pub fn ask(self: *Picker, action: Action, name: []const u8) bool {
    if (self.request_n == max_requests) return false;
    var r: Request = .{ .action = action };
    if (name.len > r.buf.len) return false;
    @memcpy(r.buf[0..name.len], name);
    r.len = name.len;
    self.requests[self.request_n] = r;
    self.request_n += 1;
    dvui.refresh(null, @src(), null);
    return true;
}

/// Whether `action` applies to place `region`: `allows`, and Clear only while it shows something —
/// which takes the live layout to know. The one rule the menu's buttons and the requests both
/// follow.
fn applies(f: *Layout, region: *const Layout.Region, action: Action) bool {
    if (!allows(f.state, region.name, action)) return false;
    if (action != .clear) return true;
    return if (f.state.assignment(region.name)) |ids| ids.len > 0 else f.selectedIn(region) != null;
}

/// Whether `action` applies to place `name`, as far as the layout state says (`applies` adds what
/// only the layout knows).
pub fn allows(state: *State, name: []const u8, action: Action) bool {
    const created = state.isMinted(name);
    return switch (action) {
        .split_right, .split_down => true,
        .clear => !created,
        .reset => !created and state.assignment(name) != null,
        // On the tree, any leaf with a sibling can go — a declared place's pin moves to the
        // sibling. Off it, only a minted leaf can. A float can always go: it closes, and what it
        // holds goes home. A minted half split again goes by merging its other half into it
        // (`ViewDrag.closeEmptied`); with that half split too there is nothing to merge, and
        // deleting would only clear it.
        .delete => blk: {
            const merges = !state.splits.isSplit(name) or state.siblingLeaf(name) != null;
            break :blk (created and merges) or state.canRemove(name) or state.floats.find(name) != null;
        },
    };
}

/// Carry out what place commands asked, in order, each on the place it named.
fn applyRequests(self: *Picker, f: *Layout) void {
    const n = self.request_n;
    self.request_n = 0;
    for (self.requests[0..n]) |*req| self.applyRequest(f, req);
}

fn applyRequest(self: *Picker, f: *Layout, req: *const Request) void {
    const name = req.place();
    const region = for (f.state.regions.items) |r| {
        if (std.mem.eql(u8, r.name, name)) break r;
    } else return dvui.log.warn("{s}: no place named '{s}' now", .{ place_commands.title(req.action), name });
    if (!applies(f, &region, req.action)) return dvui.log.warn("{s}: does not apply to '{s}' now", .{ place_commands.title(req.action), name });
    switch (req.action) {
        // Vertical / horizontal name the divider: a vertical bar is side by side (the layout axis
        // is horizontal).
        .split_right, .split_down => if (f.splitOn(name, if (req.action == .split_right) .right else .bottom) == null) {
            return dvui.log.warn("{s}: '{s}' is too small to split", .{ place_commands.title(req.action), name });
        },
        .clear => clearRegion(f, name),
        .reset => {
            f.state.unassign(f.gpa, name);
            f.state.markDirty();
            dvui.refresh(null, @src(), null);
        },
        .delete => removeRegion(f, &region),
    }
    // A split or a deleted place leaves the menu with nothing that is still true to show.
    switch (req.action) {
        .split_right, .split_down, .delete => if (self.is_open and std.mem.eql(u8, self.region, name)) {
            self.close(f.gpa);
            f.state.discardSnapshots(f.gpa);
        },
        .clear, .reset => {},
    }
}

/// Card geometry, in points. The preview keeps the snapshot's aspect inside this box.
const preview: dvui.Size = .{ .w = 150, .h = 100 };
const columns: usize = 2;
const list_height: f32 = 420;
/// Points of the popup around its contents, top and bottom — its 8pt padding each side — with
/// a little to spare so rounding never tips it into scrolling.
const popup_chrome_h: f32 = 2 * 8 + 10;

pub fn open(self: *Picker, gpa: std.mem.Allocator, region: []const u8, anchor: ?dvui.Point.Natural) void {
    self.close(gpa);
    self.region = gpa.dupe(u8, region) catch return;
    self.anchor = anchor;
    self.grow_from = null;
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
    self.applyRequests(f);
    if (self.lifted) return self.drawLifted(f);
    if (!self.is_open) return;
    const prof = core.profile.begin("fizzy", "picker");
    defer prof.end();
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

    // A float's place opens its picker in the float's window: a popup shuts itself the moment the
    // window it was opened from is not the focused one, and the press on the corner button that
    // opened it focused the float — opened from the app's own window, it shut as it opened.
    const float_win: ?dvui.Id = if (state.floatRoot(region.name)) |root| win: {
        const i = state.floats.find(root) orelse break :win null;
        const id = state.floats.items.items[i].win_id;
        break :win if (id == .zero) null else id;
    } else null;
    const prev_subwindow = if (float_win) |id| dvui.subwindowCurrentSet(id, null) else null;
    defer if (prev_subwindow) |prev| {
        _ = dvui.subwindowCurrentSet(prev.id, prev.rect);
    };

    // The one floating surface (`core.dialogs`): frosted, the dialogs' fill, corners and shadow
    // — what the command palette, the dialogs and every menu wear. It had its own card (an
    // opaque-ish content fill, no blur), so it read as a different kind of thing from them.
    var popup = core.widgets.popup(@src(), .{
        .open_flag = &self.is_open,
        .from = self.anchor,
        .frost = core.widgets.menuFrost(),
        .grow_from = self.grow_from,
    }, core.widgets.menuSurfaceOptions().override(.{
        .padding = dvui.Rect.all(8),
    })) orelse {
        // Just closed.
        self.close(gpa);
        state.discardSnapshots(gpa);
        return;
    };
    defer popup.deinit();

    // The title, the controls and the filter stay put; only the views under them scroll. The
    // popup scrolls whatever does not fit the window, so the list takes only the room left
    // under this — measured as it last laid out — and the popup never has anything to scroll.
    const filter_text, const head_h = head: {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer box.deinit();

        {
            // The place's name, and on the same row what the menu can do to the place: icons
            // only, each a command (`place_commands`), each running its command. Those that do
            // not apply keep their places, dimmed: coming and going they shoved the row around
            // under the pointer.
            var title = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .padding = .{ .h = 6 },
            });
            defer title.deinit();
            dvui.labelNoFmt(@src(), region.name, .{}, .{
                .font = dvui.Font.theme(.heading),
                .gravity_y = 0.5,
            });
            var actions = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0, .gravity_y = 0.5 });
            defer actions.deinit();
            inline for (place_commands.all, 0..) |c, i| {
                const enabled = applies(f, &region, c.action);
                if (controlButton(@src(), c, region.name, enabled, i)) {
                    f.host.runCommand(c.id) catch |err| dvui.log.err("{s}: {t}", .{ c.id, err });
                    dvui.refresh(null, @src(), null);
                }
            }
        }

        // The same filter box as the file tree's, the settings' and the store's. It matches what a
        // card says and what it does not: the view's title, the plugin it comes from, its tags (the
        // keywords it asks for) and the place showing it now.
        break :head .{
            core.widgets.filterRow(@src(), "Filter views...", .{ .margin = .{ .y = 2, .h = 4 } }),
            if (dvui.minSizeGet(box.data().id)) |m| m.h else 0,
        };
    };
    const query = core.fuzzy.Query.init(filter_text);

    const width = @as(f32, @floatFromInt(columns)) * (preview.w + 16) + 16;
    const list_h = std.math.clamp(dvui.windowRect().h - head_h - popup_chrome_h, preview.h, list_height);
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .min_size_content = .{ .w = width, .h = list_h },
        .max_size_content = .size(.{ .w = width, .h = list_h }),
        .background = false,
    });
    defer scroll.deinit();
    defer core.widgets.scrollShadows(scroll);

    var grid = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    self.list_ns = dvui.frameTimeNS();
    defer grid.deinit();

    var row: ?*dvui.BoxWidget = null;
    defer if (row) |r| r.deinit();
    var col: usize = 0;
    const places = placesFor(f, &region);
    const ranked_all = offered(f, &region, &query);
    // Each card under the place holding it, or else the place its keywords make it for; this one
    // first, so what belongs in the explorer and what in the panel reads off the headers. A
    // query ranks within each. Each card's section is worked out once, not once per section.
    const sections = f.arena.alloc(usize, ranked_all.len) catch return;
    for (ranked_all, sections) |ranked, *section| {
        const s = &f.host.surfaces.items[ranked.item];
        section.* = sectionOf(places, s.id, s.keywords) orelse places.len;
    }
    var current: ?usize = null;
    for (0..places.len + 1) |section| for (ranked_all, sections) |ranked, card_section| {
        // `i` is the surface's place in the registry, not in this list: a card keeps its widget
        // id while the filter reorders what is around it.
        const i = ranked.item;
        const s = &f.host.surfaces.items[i];
        if (card_section != section) continue;
        if (current != section) {
            // This place's own header was drawn above, empty, when nothing else came first.
            if (current == null and section != 0) emptyHome(&region, &query);
            current = section;
            if (row) |r| r.deinit();
            row = null;
            col = 0;
            sectionHeader(if (section < places.len) places[section].name else "Other", section);
        }
        if (col == 0) {
            if (row) |r| r.deinit();
            row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
        }
        col = (col + 1) % columns;

        // Highlighted: the place holds it, as a tab or as the one view.
        const on = contains(contents, s.id);
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
        // A toggle: the region's contents, plus or minus this one, in the order they were
        // already in. Not the last view out of the place, though: a lit card that is all the
        // place shows only says so (Clear empties a place on purpose).
        if (on and contents.len == 1) continue;
        var ids = std.ArrayListUnmanaged([]const u8).initCapacity(f.arena, contents.len + 1) catch return;
        for (contents) |c| if (!std.mem.eql(u8, c.id, s.id)) ids.appendAssumeCapacity(c.id);
        if (!on) ids.appendAssumeCapacity(s.id);
        state.assign(gpa, region.name, ids.items) catch |err| {
            dvui.log.err("failed to assign '{s}': {t}", .{ region.name, err });
        };
        if (!on) f.host.setSelectionForKey(region.selectionKey(), s.id);
        state.markDirty();
        dvui.refresh(null, @src(), null);
    };
    if (current == null) emptyHome(&region, &query);

    if (state.store_catalog) |store| drawStoreSection(f, &region, store, &row, &col, &query);
}

/// The surfaces this region's picker offers — what the region may show at all (`Layout.offers`:
/// no document in a plain place, only documents in a document pane) — that match `query`, best
/// first. In registry order while the query is empty. Indices into `host.surfaces`.
fn offered(f: *Layout, region: *const Layout.Region, query: *const core.fuzzy.Query) []core.fuzzy.Ranked(usize) {
    var out: std.ArrayListUnmanaged(core.fuzzy.Ranked(usize)) = .empty;
    for (f.host.surfaces.items, 0..) |*s, i| {
        if (s.hidden) continue;
        if (!f.offers(region, s)) continue;
        const score = if (query.isEmpty()) 0 else core.fuzzy.score(searchText(f, s), query, .{}) orelse continue;
        out.append(f.arena, .{ .item = i, .score = score, .tie = i }) catch break;
    }
    if (!query.isEmpty()) core.fuzzy.sort(usize, out.items);
    return out.items;
}

/// A place a card can be listed under: a region's name, the keywords it accepts and the views it
/// holds now.
const Place = struct {
    name: []const u8,
    keywords: []const []const u8,
    holds: []const *sdk.Surface = &.{},
};

/// The places the picker sorts cards under: `region` itself first, then each other place the
/// shape declared, in its order — never a document pane, which offers only documents. Places
/// resolved by keywords are one per keyword group (the icon rail and the explorer it chooses for
/// are one place); a place resolved by name (a split's leaf, a float) is its own.
fn placesFor(f: *Layout, region: *const Layout.Region) []const Place {
    var out: std.ArrayListUnmanaged(Place) = .empty;
    out.append(f.arena, .{ .name = region.name, .keywords = region.keywords, .holds = f.matchingIn(region) }) catch return &.{};
    for (f.state.regions.items) |*r| {
        if (r.name.len == 0 or r.kind_slot) continue;
        const seen = for (out.items) |p| {
            if (std.mem.eql(u8, p.name, r.name)) break true;
            if (!r.by_name and sdk.keywords.groupKey(p.keywords) == sdk.keywords.groupKey(r.keywords)) break true;
        } else false;
        if (!seen) out.append(f.arena, .{ .name = r.name, .keywords = r.keywords, .holds = f.matchingIn(r) }) catch break;
    }
    return out.items;
}

/// The place a card is listed under. The place holding the view, when one does: a view the user
/// moved reads under where it is, not where it came from. Otherwise the place its keywords are
/// for, by the fit `Layout` binds with (`sdk.keywords.strength`); between equals the first,
/// which puts `places[0]`, the place being edited, ahead of the rest. Null when neither.
fn sectionOf(places: []const Place, id: []const u8, keywords: []const []const u8) ?usize {
    for (places, 0..) |p, i| if (contains(p.holds, id)) return i;
    var best: ?usize = null;
    var best_fit: sdk.keywords.Fit = .none;
    for (places, 0..) |p, i| {
        const fit = sdk.keywords.strength(p.keywords, keywords);
        if (@backingInt(fit) > @backingInt(best_fit)) {
            best = i;
            best_fit = fit;
        }
    }
    return best;
}

test "a view is listed under the place its keywords are for, the edited place first" {
    const kw = sdk.keywords.ide;
    const places = [_]Place{
        .{ .name = "Panel", .keywords = kw.panel },
        .{ .name = "Sidebar", .keywords = kw.sidebar },
        .{ .name = "Main", .keywords = kw.main },
    };
    try std.testing.expectEqual(@as(?usize, 1), sectionOf(&places, "v", &.{"explorer"}));
    try std.testing.expectEqual(@as(?usize, 0), sectionOf(&places, "v", &.{"output"}));
    // Made for both: the place being edited wins the tie.
    try std.testing.expectEqual(@as(?usize, 0), sectionOf(&places, "v", &.{ "sidebar", "panel" }));
    // A specific sub-place still lands under the area that holds it.
    try std.testing.expectEqual(@as(?usize, 2), sectionOf(&places, "v", &.{"main.document"}));
    try std.testing.expectEqual(@as(?usize, null), sectionOf(&places, "v", &.{"inspector"}));
    try std.testing.expectEqual(@as(?usize, null), sectionOf(&places, "v", &.{}));
}

test "a view a place holds is listed under that place, whatever its keywords" {
    var files: sdk.Surface = .{ .id = "files", .title = "Files", .keywords = sdk.keywords.ide.sidebar, .draw = undefined };
    const holding = [_]*sdk.Surface{&files};
    const places = [_]Place{
        .{ .name = "Sidebar", .keywords = sdk.keywords.ide.sidebar },
        .{ .name = "Panel", .keywords = sdk.keywords.ide.panel, .holds = &holding },
    };
    try std.testing.expectEqual(@as(?usize, 1), sectionOf(&places, "files", files.keywords));
    // A split's new leaf accepts no view's keywords, and still takes the one put in it.
    const leaf = [_]Place{
        .{ .name = "Panel/r1", .keywords = &.{"slot"}, .holds = &holding },
        .{ .name = "Sidebar", .keywords = sdk.keywords.ide.sidebar },
    };
    try std.testing.expectEqual(@as(?usize, 0), sectionOf(&leaf, "files", files.keywords));
}

/// The place being edited, when no card falls under it: its header still leads, so the popup
/// says which place it fills — a split's new leaf accepts no view's keywords until one is put in.
fn emptyHome(region: *const Layout.Region, query: *const core.fuzzy.Query) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer box.deinit();
    core.anchor.mark(box.data(), "picker.empty", .{});
    sectionHeader(region.name, 0);
    dvui.labelNoFmt(@src(), if (query.isEmpty()) "Nothing here yet." else "No matching views here.", .{}, .{
        .padding = .{ .x = 4, .h = 4 },
        .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.45) },
    });
}

/// A heading over a run of cards — a place's name, or the store.
fn sectionHeader(title: []const u8, id_extra: usize) void {
    dvui.labelNoFmt(@src(), title, .{}, .{
        .id_extra = id_extra,
        .font = dvui.Font.theme(.heading),
        .padding = .{ .y = 10, .x = 4 },
        .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.6) },
    });
}

/// Where a view comes from, as its card says it: the plugin's name, or "Built-in" for one the app
/// itself registered (Output, Settings). Not the app's own name — this picker is the framework's,
/// and an app built on it is not fizzy.
fn ownerName(s: *const sdk.Surface) []const u8 {
    return if (s.owner) |p| p.display_name else "Built-in";
}

/// Everything a view is found by, as one line, so a query can span fields: `files workbench`
/// finds Files through its title and its plugin together, where scoring each field on its own
/// would need both words in one of them.
fn searchText(f: *Layout, s: *const sdk.Surface) []const u8 {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    const a = f.arena;
    text.appendSlice(a, s.title) catch return s.title;
    text.print(a, " {s}", .{ownerName(s)}) catch {};
    if (s.owner) |p| text.print(a, " {s}", .{p.id}) catch {};
    for (s.keywords) |k| text.print(a, " {s}", .{k}) catch {};
    for (f.state.regions.items) |*r| {
        if (r.name.len == 0) continue;
        if (contains(f.matchingIn(r), s.id)) text.print(a, " {s}", .{r.name}) catch {};
    }
    return text.items;
}

/// How long a finger holds still on a card before it lifts rather than scrolls the list — the
/// same hold as every other draggable thing in a scrolling list.
const hold_to_lift_ns = core.widgets.Tabs.touch_hold_ns;

/// A finger is down on the card `id` and has held there long enough to lift it.
fn armedTouch(id: dvui.Id) bool {
    if (!dvui.captured(id)) return false;
    const down = dvui.dataGet(null, id, "_touch_down", i128) orelse return false;
    return dvui.frameTimeNS() - down >= hold_to_lift_ns;
}

/// What a card did this frame.
const Hit = union(enum) {
    none,
    clicked,
    /// Dragged past dvui's threshold: where the preview tile was, and the
    /// event that crossed it, so the drag can take the capture over.
    lifted: struct { tile: dvui.Rect.Physical, event_num: u16 },
};

/// Choose surface `s` (at `index` in the registry) to be drawn offscreen for its picture
/// (`State.offscreen`, `Layout.captureUnplaced`) when none is: its card in view, as the list laid
/// it out, and the view one that may be (`Layout.mayDrawOffscreen`). Not on the card's first
/// frame, before it has a size: every card then packs into the top of the list. The card of the
/// view already chosen stamps that it is still in view (`card_ns`).
fn nextOffscreen(f: *Layout, s: *const sdk.Surface, index: usize, card_data: *dvui.WidgetData) void {
    const state = f.state;
    if (dvui.firstFrame(card_data.id) or card_data.borderRectScale().r.intersect(dvui.clipGet()).empty()) return;
    const now = dvui.frameTimeNS();
    if (state.offscreen) |*o| {
        if (o.index == index) o.card_ns = now;
        return;
    }
    if (!f.mayDrawOffscreen(s)) return;
    state.offscreen = .{ .index = index, .id = std.hash.Wyhash.hash(0, s.id), .card_ns = now };
    dvui.refresh(null, @src(), null);
}

/// One surface: its snapshot scaled to fit, its title, its owner, and a highlight when it is in
/// the region. A press that moves far enough lifts the card into a drag instead of clicking.
fn card(f: *Layout, s: *const sdk.Surface, on: bool, id_extra: usize) Hit {
    const theme = dvui.themeGet();
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = id_extra,
        .margin = dvui.Rect.all(4),
        .padding = dvui.Rect.all(6),
        .corners = core.corners.all(core.corners.small),
        .background = true,
        .color_fill = .{ .color = if (on) theme.color(.highlight, .fill).opacity(0.25) else theme.color(.control, .fill) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = if (on) theme.color(.highlight, .fill) else theme.color(.control, .border) },
    });
    defer bw.deinit();
    const id = bw.data().id;
    nextOffscreen(f, s, id_extra, bw.data());
    // For demo tapes (`docs/AUTOMATION.md`): the card, to lift a view out of the picker by.
    core.anchor.mark(bw.data(), "picker:{s}", .{s.id});

    // The tile's rect is remembered from last frame: the press that starts a
    // drag is read here, before the tile is laid out.
    const tile_rect = dvui.dataGet(null, id, "_tile", dvui.Rect.Physical) orelse bw.data().borderRectScale().r;
    // A finger on a card is also how the list under it scrolls, so a finger has to hold still
    // for a moment before the card lifts; moving sooner scrolls, as it does anywhere else in the
    // list. A mouse lifts on any drag. Read ahead of the button's own events, because the button
    // gives the pointer up the moment a finger moves past dvui's threshold — it takes every touch
    // drag for a scroll, and with it went the only drag a card could start.
    const armed = armedTouch(id);
    var lifted: ?Hit = null;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .motion or !dvui.captured(id)) continue;
        if (me.button.touch() and !armed) continue;
        if (dvui.dragging(me.p, "fizzy_view") != null) {
            e.handle(@src(), bw.data());
            lifted = .{ .lifted = .{ .tile = tile_rect, .event_num = e.num } };
            break;
        } else if (me.button.touch()) {
            // Armed but not yet past the threshold: still ours, not a scroll's.
            e.handle(@src(), bw.data());
        }
    }
    bw.processEvents();

    // The button took the press and the capture; from here the pointer is ours.
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (!dvui.captured(id)) continue;
        if (me.action == .press and me.button.pointer()) {
            dvui.dragPreStart(me.button, me.p, .{
                .offset = tile_rect.topLeft().diff(me.p),
                .size = tile_rect.size(),
                .name = "fizzy_view",
                .cursor = ViewDrag.cursor,
            });
            if (me.button.touch()) {
                dvui.dataSet(null, id, "_touch_down", dvui.frameTimeNS());
                // Wake when the hold is up, so the card shows it can be moved without the
                // finger having to move first.
                dvui.timer(id, @intCast(@divTrunc(hold_to_lift_ns, std.time.ns_per_us)));
            } else {
                dvui.dataRemove(null, id, "_touch_down");
            }
        }
    }
    if (!dvui.captured(id)) dvui.dataRemove(null, id, "_touch_down");
    bw.drawBackground();
    if (armed and lifted == null) {
        // Held long enough: the card is ready to move, and says so before the finger does.
        const rs = bw.data().borderRectScale();
        rs.r.stroke(core.corners.all(core.corners.small).scale(rs.s, dvui.CornerRect.Physical), .{
            .color = .{ .color = theme.color(.highlight, .fill) },
            .thickness = 2 * rs.s,
        });
    }

    var col = dvui.box(@src(), .{ .dir = .vertical }, .{});
    defer col.deinit();

    // The preview tile: the snapshot letterboxed into a fixed box so cards line up.
    {
        var tile = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = preview,
            .max_size_content = .size(preview),
            .background = true,
            .corners = core.corners.all(3),
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
    dvui.labelNoFmt(@src(), ownerName(s), .{}, .{
        .padding = .{},
        .font = dvui.Font.theme(.heading),
        .color_text = .{ .color = theme.color(.control, .text) },
    });
    if (lifted) |hit| return hit;
    return if (bw.clicked()) .clicked else .none;
}

/// The capture a loose drag holds while no widget of the picker exists to
/// hold it: the card is gone with the popup, so the drag is its own widget as
/// far as dvui's mouse routing is concerned. One id for every such drag, in
/// the base window, over the whole of it.
pub fn looseCapture() dvui.CaptureMouse {
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
    // The card itself is drawn once, over everything, with the drops (`ViewDrag.drawOverlay`);
    // drawn here as well it was a second card, and one frame apart from the first as it changed
    // shape over a strip.
    ViewDrag.tick(f);
}

/// One of the header's controls: an icon, a tooltip naming it, and its command run when pressed.
/// Published as `region.menu.<action>:<place>` while it can be pressed — a dimmed one swallows the
/// click, and a driver waiting for the name should wait for the action, not for the button.
/// Delete wears the theme's error colour. Disabled, it keeps its place (dimmed, no hover).
fn controlButton(src: std.lang.SourceLocation, c: place_commands.Command, place: []const u8, enabled: bool, id_extra: usize) bool {
    const theme = dvui.themeGet();
    const destructive = c.action == .delete;
    // Destructive controls wear the error fill lightened as `core.dialogs`' close does; `.err`'s
    // text colour is not red in every theme.
    const tint = if (destructive) theme.color(.err, .fill).lighten(if (theme.dark) -10 else 10) else theme.color(.control, .text);
    // Disabled keeps the place's slot but dimmer; delete stays red enough to read as delete.
    const dim: f32 = if (destructive) 0.6 else 0.35;
    var bw: dvui.ButtonWidget = undefined;
    bw.init(src, .{}, .{
        .id_extra = id_extra,
        .padding = dvui.Rect.all(5),
        .margin = .{ .x = 2 },
        .gravity_y = 0.5,
        .color_fill_hover = if (enabled) null else .{ .color = theme.color(.control, .fill) },
        .color_fill_press = if (enabled) null else .{ .color = theme.color(.control, .fill) },
    });
    defer bw.deinit();
    if (enabled) core.anchor.mark(bw.data(), "region.menu.{f}:{s}", .{ c.action, place });
    bw.processEvents();
    bw.drawBackground();
    core.icon.icon(@src(), c.id, c.icon, .{
        .stroke_color = .{ .color = if (enabled) tint else tint.opacity(dim) },
        // Clear fill takes the single-colour path, so the stroke shows in the tint as given.
        .fill_color = if (destructive) .{ .color = .transparent } else .white,
    }, .{
        .min_size_content = .{ .w = 14, .h = 14 },
        .gravity_x = 0.5,
        .gravity_y = 0.5,
    });
    bw.drawFocus();
    // Its title less the "Place: " every command of the palette's carries.
    const title = if (std.mem.find(u8, c.title, ": ")) |at| c.title[at + 2 ..] else c.title;
    core.widgets.tooltip(@src(), .{ .active_rect = bw.data().borderRectScale().r }, "{s}", .{title}, .{});
    return enabled and bw.clicked();
}

fn contains(list: []const *sdk.Surface, id: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s.id, id)) return true;
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
/// The leftover (Center) can be emptied; it is not collapsed. A pinned seed leaf cannot
/// be removed.
fn removeRegion(f: *Layout, region: *const Layout.Region) void {
    const gpa = f.gpa;
    // A float closes, and its views go back where it came from rather than being cleared.
    if (f.state.floats.find(region.name) != null) return f.closeFloat(region.name);
    f.state.assign(gpa, region.name, &.{}) catch |err| {
        dvui.log.err("failed to clear '{s}': {t}", .{ region.name, err });
    };
    // A split of a float is the split forest's, whatever the shape is built from.
    if (f.state.floatRoot(region.name) == null) {
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
    }
    const forget = region.forget_when_empty or f.state.splits.canForget(region.name);
    if (forget and f.state.splits.canForget(region.name) and f.state.splits.isSplit(region.name)) {
        // Split again, the place under this name is its whole split: the half that kept the
        // name goes the way emptying it does, its other half's views merging into it.
        _ = ViewDrag.closeEmptied(f, region.name);
    } else if (forget) {
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

    // Beside what the place holds, as a card picked there goes.
    const held = f.matchingIn(region);
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    for (held) |h| ids.append(f.arena, h.id) catch return;
    var first: ?[]const u8 = null;
    for (f.host.surfaces.items) |*s| {
        const owner = s.owner orelse continue;
        if (s.hidden) continue;
        if (!std.mem.eql(u8, owner.id, state.pending_store_plugin)) continue;
        if (first == null) first = s.id;
        if (!contains(held, s.id)) ids.append(f.arena, s.id) catch return;
    }
    const shown = first orelse return;

    state.assign(f.gpa, region.name, ids.items) catch |err| {
        dvui.log.err("failed to assign store plugin to '{s}': {t}", .{ region.name, err });
        return;
    };
    f.host.setSelectionForKey(region.selectionKey(), shown);
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
    query: *const core.fuzzy.Query,
) void {
    var offers: std.ArrayListUnmanaged(State.StoreOffer) = .empty;
    for (store.uninstalled(f.arena)) |offer| {
        const fields = [_][]const u8{ offer.title, offer.id };
        if (core.fuzzy.scoreBest(&fields, query, .{}) == null) continue;
        offers.append(f.arena, offer) catch break;
    }
    if (offers.items.len == 0) return;

    if (row.*) |r| {
        r.deinit();
        row.* = null;
    }
    col.* = 0;

    sectionHeader("Store", 10_000);

    for (offers.items, 0..) |offer, i| {
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
        .corners = core.corners.all(core.corners.small),
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
            .corners = core.corners.all(3),
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
