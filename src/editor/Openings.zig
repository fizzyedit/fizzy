//! Documents on their way: the tab a file gets the moment it is opened, before a byte of it has
//! been read.
//!
//! Every open — a file on disk (`FileLoadJob`) or on a mount (`DocumentIo`) — starts an `Opening`
//! first: a placeholder surface in the pane the document will land in, drawing "Loading <name>…"
//! over a spinner, with a tab of its own (the workbench draws it from `Workbench.loading`). When
//! the document lands, `land` gives the placeholder's tab slot to the document's surface and the
//! pane's swap transition blurs one into the other (`Layout.drawSwapped`). That transition draws
//! the outgoing surface once more to capture it, which is why a landed placeholder stays
//! registered for `linger_frames`. A load that fails leaves the placeholder saying why; closing
//! its tab cancels the load (`tick`).
const Openings = @This();

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const icons = @import("icons");
const Editor = @import("Editor.zig");
const sdk = Editor.sdk;

gpa: std.mem.Allocator,
/// By canonical path — the key every load already uses. Keys are the `Opening`'s own `path`.
entries: std.StringArrayHashMapUnmanaged(*Opening) = .empty,

pub const Opening = struct {
    editor: *Editor,
    path: []u8,
    /// `fizzy.loading:<path>` — distinct from the document's own surface id, so the swap
    /// transition sees two surfaces and has the placeholder to capture.
    surface_id: []u8,
    grouping: u64,
    preview: bool,
    /// Why the load failed, once it has. The placeholder shows it until its tab is closed.
    failed: ?[]u8 = null,
    /// Frames since the document took the tab. Null while still loading.
    landed: ?u8 = null,
    /// Asked to be shown before its pane had a region to show it in (an open at launch, before
    /// the first draw): shown on the first `tick` that pane exists.
    show_when_ready: bool = false,

    fn name(self: *const Opening) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

const surface_prefix = "fizzy.loading:";
const linger_frames: u8 = 2;

pub fn init(gpa: std.mem.Allocator) Openings {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Openings) void {
    for (self.entries.values()) |o| self.free(o);
    self.entries.deinit(self.gpa);
}

fn free(self: *Openings, o: *Opening) void {
    if (o.failed) |f| self.gpa.free(f);
    self.gpa.free(o.surface_id);
    self.gpa.free(o.path);
    self.gpa.destroy(o);
}

/// Whether a document is still being read. A failed load's placeholder stays until its tab is
/// closed, and is waiting on nothing: anyone asking whether the app has settled (a live tape, an
/// agent) would otherwise wait on it forever.
pub fn loading(self: *const Openings) bool {
    for (self.entries.values()) |o| if (o.failed == null) return true;
    return false;
}

/// The load of `path` has started: put its placeholder in front of the user. `owner` is the
/// plugin the document will belong to (the tab slot a restored session kept for it is named by
/// its surface id); `take_slot_of` is a tab whose place it takes — the preview it replaces.
pub fn begin(self: *Openings, editor: *Editor, path: []const u8, grouping: u64, preview: bool, owner: *sdk.Plugin, take_slot_of: ?[]const u8) void {
    if (self.entries.contains(path)) return;
    const o = self.gpa.create(Opening) catch return;
    o.* = .{
        .editor = editor,
        .path = self.gpa.dupe(u8, path) catch {
            self.gpa.destroy(o);
            return;
        },
        .surface_id = undefined,
        .grouping = grouping,
        .preview = preview,
    };
    o.surface_id = std.mem.concat(self.gpa, u8, &.{ surface_prefix, path }) catch {
        self.gpa.free(o.path);
        self.gpa.destroy(o);
        return;
    };
    self.entries.put(self.gpa, o.path, o) catch {
        self.free(o);
        return;
    };
    const host = &editor.app.host;
    host.registerSurface(.{
        .id = o.surface_id,
        .title = o.name(),
        .keywords = sdk.document.keywords,
        .ctx = o,
        .draw = draw,
    }) catch {
        _ = self.entries.swapRemove(o.path);
        self.free(o);
        return;
    };
    const wb = &editor.workbench;
    wb.loading.put(self.gpa, o.surface_id, .{ .path = o.path, .preview = preview }) catch {};

    // The slot: the preview this replaces, else the one a restored session kept for this
    // document, else the end of the pane it is opened toward.
    const restored = sdk.document.surfaceId(host.arena(), owner.id, path) catch null;
    const slot: ?[]const u8 = take_slot_of orelse if (restored) |r| (if (wb.hasTabAnywhere(r)) r else null) else null;
    if (slot) |old| {
        const was_selected = editor.surfaceSelected(old);
        if (wb.swapTabId(old, o.surface_id)) |ws| {
            // A replaced preview is replaced by what was just clicked, so it shows; a restored
            // slot shows only if it was showing.
            if (take_slot_of != null or was_selected) self.show(editor, o, ws);
            host.refresh();
            return;
        }
    }
    const ws = wb.pane(grouping) catch return;
    ws.addTab(o.surface_id, true);
    self.show(editor, o, ws);
    host.refresh();
}

fn show(self: *Openings, editor: *Editor, o: *Opening, ws: *Editor.Workspace) void {
    _ = self;
    editor.workbench.selectLoading(ws, o.surface_id);
    o.show_when_ready = !editor.tabRegionReady(o.surface_id);
}

/// `doc` has loaded at `path`: its surface takes the placeholder's tab, in place and selected
/// if the placeholder was, and a preview open becomes a preview document.
pub fn land(self: *Openings, editor: *Editor, path: []const u8, doc: sdk.DocHandle) void {
    const o = self.entries.get(path) orelse return;
    if (o.landed != null) return;
    const host = &editor.app.host;
    const wb = &editor.workbench;
    if (sdk.document.surfaceId(host.arena(), doc.owner.id, path)) |doc_id| {
        const was_selected = editor.surfaceSelected(o.surface_id);
        // Read before the swap: after it, no pane holds the placeholder's tab.
        const region_key = editor.tabRegionKey(o.surface_id);
        if (wb.swapTabId(o.surface_id, doc_id)) |ws| {
            if (was_selected) {
                // The pane blurs from the placeholder (still registered — see `linger_frames`)
                // into the document, as it does for any change of what it shows.
                var buf: [32]u8 = undefined;
                host.selectInRegion(Editor.Workspace.name(&buf, ws.grouping), doc_id);
            } else if (region_key) |k| {
                // Landed out of sight (a restored background tab): draw it once now, unseen,
                // so a view that measures itself on its first draw does it while loading
                // rather than on the click that shows it.
                editor.app.layout.warmIn(editor.app.gpa, k, doc_id);
            }
        }
    } else |_| {}
    if (o.preview) editor.setDocumentPreview(doc.id, true);
    _ = wb.loading.swapRemove(o.surface_id);
    o.landed = 0;
    host.refresh();
}

/// The load of `path` failed: the placeholder says so. False when there is no placeholder to
/// say it in, and the caller reports it some other way.
pub fn fail(self: *Openings, editor: *Editor, path: []const u8, why: []const u8) bool {
    const o = self.entries.get(path) orelse return false;
    if (o.landed != null) return false;
    if (o.failed) |f| self.gpa.free(f);
    o.failed = self.gpa.dupe(u8, why) catch null;
    editor.app.host.refresh();
    return true;
}

/// Take `path`'s placeholder away without a document to replace it: the load was cancelled, or
/// the document turned out to be open already.
pub fn drop(self: *Openings, editor: *Editor, path: []const u8) void {
    const i = self.entries.getIndex(path) orelse return;
    editor.workbench.removeTabEverywhere(self.entries.values()[i].surface_id);
    self.remove(editor, i);
}

/// The still-loading preview in `grouping`, if any: the next preview open takes its place.
pub fn previewIn(self: *Openings, grouping: u64) ?*Opening {
    for (self.entries.values()) |o| {
        if (o.preview and o.grouping == grouping and o.landed == null) return o;
    }
    return null;
}

/// Once a frame. A landed placeholder lingers until the transition has captured it; one whose
/// tab the user closed takes its load with it.
pub fn tick(self: *Openings, editor: *Editor) void {
    var i: usize = 0;
    while (i < self.entries.count()) {
        const o = self.entries.values()[i];
        if (o.landed) |n| {
            if (n >= linger_frames) {
                self.remove(editor, i);
                continue;
            }
            o.landed = n + 1;
            // Frames have to keep coming until it is gone, or it lingers until the next input.
            editor.app.host.refresh();
        } else if (!editor.workbench.hasTabAnywhere(o.surface_id)) {
            editor.cancelOpen(o.path);
            self.remove(editor, i);
            continue;
        } else if (o.show_when_ready and editor.tabRegionReady(o.surface_id)) {
            o.show_when_ready = false;
            editor.workbench.selectLoadingById(o.surface_id);
        }
        i += 1;
    }
}

fn remove(self: *Openings, editor: *Editor, i: usize) void {
    const o = self.entries.values()[i];
    _ = editor.workbench.loading.swapRemove(o.surface_id);
    editor.app.host.unregisterSurface(o.surface_id);
    self.entries.swapRemoveAt(i);
    self.free(o);
}

/// "Loading <name>…" over a spinner, centred in the pane; or, once it failed, why.
fn draw(ctx: ?*anyopaque) anyerror!dvui.App.Result {
    const o: *Opening = @ptrCast(@alignCast(ctx orelse return .ok));
    const theme = dvui.themeGet();
    // Blended toward the pane's fill rather than made translucent: a see-through glyph shows its
    // own overlapping strokes darker where they cross, and whatever is behind the pane through it.
    const dim = theme.color(.window, .text).lerp(theme.color(.window, .fill), 0.4);

    // Keyed by path: a swap photographs one placeholder in the same pane another is shown in.
    var fill = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .id_extra = @truncate(std.hash.Wyhash.hash(0, o.path)),
    });
    defer fill.deinit();
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
    defer col.deinit();

    if (o.failed) |why| {
        core.icon.icon(@src(), "OpenFailed", icons.tvg.lucide.@"file-x", .{
            .stroke_color = .{ .color = dim },
        }, .{ .gravity_x = 0.5, .min_size_content = .{ .w = 28, .h = 28 }, .margin = .{ .h = 8 } });
        dvui.label(@src(), "Couldn't open {s}", .{o.name()}, .{ .gravity_x = 0.5 });
        dvui.labelNoFmt(@src(), why, .{}, .{ .gravity_x = 0.5, .color_text = .{ .color = dim } });
        return .ok;
    }
    core.dialogs.bubbleSpinner(@src(), .{
        .gravity_x = 0.5,
        .min_size_content = .{ .w = 28, .h = 28 },
        .margin = .{ .h = 8 },
        .color_text = .{ .color = theme.color(.window, .text) },
    }, .{});
    dvui.label(@src(), "Loading {s}\u{2026}", .{o.name()}, .{ .gravity_x = 0.5, .color_text = .{ .color = dim } });
    return .ok;
}
