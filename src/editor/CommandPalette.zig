//! VSCode-style Quick Open: a dropdown from the top centre of the window.
//!
//! Two modes, distinguished exactly the way VSCode does it — by what you type:
//!
//! - **Files** (default, `mod+p`): fuzzy search every file under the project folder, with the
//!   same file-type icons the explorer uses. Selecting one opens it.
//! - **Commands** (`>` prefix, or `mod+shift+p` which just seeds the entry with `>`): fuzzy
//!   search registered commands. Document verbs (Copy/Paste/…) are flattened to the shell
//!   forwarder that would actually run — see `document_verbs` / `shouldShowCommand`.
//!
//! Mode is derived from the text rather than held as state, so backspacing over the `>` slides
//! straight back to file search, as it does in VSCode.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const icons = @import("icons");
const fizzy = @import("../fizzy.zig");
const fuzzy = @import("core").fuzzy;
const wdvui = @import("core").dvui;
const keymap = @import("keymap/keymap.zig");
const Keybinds = @import("Keybinds.zig");

const Editor = @import("Editor.zig");
const CommandPalette = @This();

/// Same guards the explorer's own filter index uses — a palette must never be the reason
/// opening a folder hangs.
const max_index_files: usize = 20_000;
const max_index_depth: usize = 24;
/// Rows are virtualised only by truncation: past this many hits the ranking is meaningless
/// anyway, and the list is scrollable.
const max_rows: usize = 300;

const width_max: f32 = 640;
const width_margin: f32 = 80;
const top_offset: f32 = 64;
const row_height: f32 = 28;

/// Reveal timing. The query row is full-height from the first frame — only the suggestion list
/// grows — so the palette's top edge never moves and the bottom edge is what springs down.
/// Scrim fade timings. The panel's own geometry is animated by `FloatingWindowWidget`'s
/// auto-size (300ms `outBack`) and close (400ms `inBack`) machinery; these match those so the
/// dim lands with the panel.
const open_secs: f32 = 0.3;
const close_secs: f32 = 0.4;

/// A frame's worth of time, clamped. `secondsSinceLastFrame` reports the *real* gap since the
/// previous frame, and fizzy sleeps when idle — so the frame that opens the palette typically
/// carries hundreds of ms of accumulated idle. Fed raw into the fade it consumed the whole
/// animation in one step, which is why the open never appeared while the close (always mid-
/// interaction, frames already flowing) looked fine.
fn frameDelta() f32 {
    return @min(dvui.secondsSinceLastFrame(), 1.0 / 30.0);
}

pub const Mode = enum { files, commands };

open: bool = false,
/// Reveal progress, 0 closed → 1 open. Drives the scrim fade and the open/close lifecycle; the
/// panel's own height is a separate, retargetable animation (see `list_h`).
anim: f32 = 0,

/// Measured height of the suggestion rows — last frame's `ScrollInfo.virtual_size.h`, capped at
/// the ceiling. The scroll viewport is then sized to exactly this, which is the whole point of
/// measuring rather than computing `rows * row_height`: a viewport even a fraction of a pixel
/// under its content makes the scrollbar appear permanently (`virtual_size.h > viewport.h`).
/// Sizing the viewport from the same number the container measured makes them agree exactly.
list_content_h: f32 = 0,
/// Playing the outro. `open` stays true throughout so the palette keeps drawing — this is also
/// what lets an activated row hold its pressed highlight instead of vanishing on click.
closing: bool = false,
/// Row the user activated, kept highlighted through the outro.
activated: ?usize = null,
/// The floating window's own close flag. Watched rather than aliased to `open` so a close driven
/// from inside dvui still plays the outro instead of cutting the palette dead.
fw_open: bool = true,
/// True on the frame the palette opens, so the entry can claim keyboard focus exactly once.
just_opened: bool = false,
/// Remaining frames to re-assert entry focus after open (guards against a same-chord dialog
/// stealing focus before the entry exists).
focus_frames: u8 = 0,
/// Remaining frames to park the entry's cursor at the end of the seeded text. The entry keeps its
/// own selection across opens, so seeding `">"` would otherwise leave the cursor at offset 0 and
/// every typed character would land in front of the prefix.
tail_frames: u8 = 0,
/// Position/size fed to the modal floating window each frame.
fw_rect: dvui.Rect = .{},
selected: usize = 0,
scroll_to_selected: bool = false,
/// Query text. Owned here rather than left in dvui's internal store so opening in command mode
/// can seed a `>` (dvui derives length from the first zero byte for a buffer-backed entry).
text_buf: [256]u8 = @splat(0),

/// Absolute paths under the project folder, built on open. Owned.
index: std.ArrayList([]u8) = .empty,
/// Folder `index` was built for; empty when never built.
index_root: []u8 = &.{},
/// Whether `index` reflects a completed walk of `index_root`. Tracked separately from
/// `index.items.len` because a legitimately empty result (unreadable folder, every entry
/// ignored) would otherwise re-walk the whole tree on every frame the palette is open.
index_built: bool = false,

pub fn deinit(self: *CommandPalette, gpa: std.mem.Allocator) void {
    self.freeIndex(gpa);
    if (self.index_root.len > 0) gpa.free(self.index_root);
    self.* = .{};
}

fn freeIndex(self: *CommandPalette, gpa: std.mem.Allocator) void {
    for (self.index.items) |p| gpa.free(p);
    self.index.clearRetainingCapacity();
}

fn queryText(self: *const CommandPalette) []const u8 {
    const end = std.mem.indexOfScalar(u8, &self.text_buf, 0) orelse self.text_buf.len;
    return self.text_buf[0..end];
}

fn setText(self: *CommandPalette, s: []const u8) void {
    @memset(&self.text_buf, 0);
    const n = @min(s.len, self.text_buf.len - 1);
    @memcpy(self.text_buf[0..n], s[0..n]);
}

pub fn show(self: *CommandPalette, mode: Mode) void {
    self.open = true;
    // Deliberately not resetting `anim`: re-opening mid-outro springs back from wherever the
    // close got to rather than snapping shut and replaying from zero.
    self.closing = false;
    self.fw_open = true;
    self.activated = null;
    self.just_opened = true;
    self.focus_frames = 3;
    self.tail_frames = 3;
    self.selected = 0;
    self.scroll_to_selected = true;
    self.setText(switch (mode) {
        .files => "",
        .commands => ">",
    });
    dvui.refresh(null, @src(), null);
}

/// Start the outro. The palette keeps drawing (and stays modal) until `finishClose`.
pub fn close(self: *CommandPalette) void {
    if (!self.open or self.closing) return;
    self.closing = true;
    self.just_opened = false;
    self.focus_frames = 0;
    self.tail_frames = 0;
    dvui.refresh(null, @src(), null);
}

/// Whether the panel's height is still moving — either auto-sizing to a new content height or
/// collapsing on close.
fn animatingGeometry(self: *const CommandPalette, win: *fizzy.dvui.FloatingWindowWidget) bool {
    if (self.closing) return true;
    return dvui.animationGet(win.data().id, "_auto_height") != null;
}

fn finishClose(self: *CommandPalette) void {
    self.open = false;
    self.closing = false;
    self.anim = 0;
    self.activated = null;
    self.list_content_h = 0;
    // The scrim fade and the widget's collapse are the same length but the collapse starts a
    // frame later, so it can still have a frame to run when the palette stops drawing. Reset the
    // height explicitly rather than leaving a partly-collapsed rect for the next open to spring
    // from.
    self.fw_rect.h = 1;
    dvui.refresh(null, @src(), null);
}

pub fn toggle(self: *CommandPalette, mode: Mode) void {
    if (self.open and !self.closing) self.close() else self.show(mode);
}

/// `>` selects command mode; everything after it is the query.
fn modeAndQuery(text: []const u8) struct { mode: Mode, query: []const u8 } {
    if (text.len > 0 and text[0] == '>') {
        return .{ .mode = .commands, .query = std.mem.trimStart(u8, text[1..], " ") };
    }
    return .{ .mode = .files, .query = text };
}

// ---- file index ---------------------------------------------------------------------------

fn ensureIndex(self: *CommandPalette, editor: *Editor) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const root = editor.folder orelse return;
    if (self.index_built and std.mem.eql(u8, self.index_root, root)) return;

    const gpa = fizzy.app.allocator;
    self.freeIndex(gpa);
    if (!std.mem.eql(u8, self.index_root, root)) {
        if (self.index_root.len > 0) gpa.free(self.index_root);
        self.index_root = gpa.dupe(u8, root) catch &.{};
    }
    self.indexDir(editor, root, 0);
    self.index_built = std.mem.eql(u8, self.index_root, root);
}

/// Depth-first walk that **prunes** ignored directories rather than filtering after the fact —
/// descending into `node_modules` and discarding the results afterwards is the slow thing. Uses
/// `Host.isPathIgnored`, the same rules the explorer tree uses, so the palette can never surface
/// a file the tree deliberately hides.
fn indexDir(self: *CommandPalette, editor: *Editor, directory: []const u8, depth: usize) void {
    if (depth > max_index_depth or self.index.items.len >= max_index_files) return;

    const io = dvui.io;
    const gpa = fizzy.app.allocator;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch return;
    defer dir.close(io);

    const root = editor.folder orelse return;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (self.index.items.len >= max_index_files) return;

        const abs_path = std.fs.path.join(gpa, &.{ directory, entry.name }) catch continue;
        var keep = false;
        defer if (!keep) gpa.free(abs_path);

        if (editor.host.isPathIgnored(root, abs_path, entry.name, entry.kind)) continue;

        switch (entry.kind) {
            .file => {
                self.index.append(gpa, abs_path) catch continue;
                keep = true;
            },
            .directory => self.indexDir(editor, abs_path, depth + 1),
            else => {},
        }
    }
}

/// Invalidate the index — call when the project folder changes or the tree is known stale.
pub fn invalidate(self: *CommandPalette) void {
    self.freeIndex(fizzy.app.allocator);
    self.index_built = false;
}

// ---- rows ---------------------------------------------------------------------------------

const Row = union(Mode) {
    files: []const u8, // absolute path
    commands: struct { id: []const u8, title: []const u8, enabled: bool },
};

fn collectFileRows(self: *CommandPalette, editor: *Editor, query: *const fuzzy.Query) []Row {
    const arena = dvui.currentWindow().arena();
    const root = editor.folder orelse return &.{};

    var hits: std.ArrayListUnmanaged(fuzzy.Ranked(usize)) = .empty;
    for (self.index.items, 0..) |abs, i| {
        const rel = std.fs.path.relativePosix(arena, ".", root, abs) catch continue;
        // `plain = false`: these are real paths, so zf's basename weighting is what makes
        // `filz` rank `src/files.zig` above a path that merely contains those letters.
        const score = if (query.isEmpty()) @as(f64, 0) else (fuzzy.score(rel, query, .{ .plain = false }) orelse continue);
        hits.append(arena, .{ .item = i, .score = score, .tie = rel.len }) catch break;
        if (query.isEmpty() and hits.items.len >= max_rows) break;
    }
    fuzzy.sort(usize, hits.items);

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    for (hits.items) |h| {
        if (rows.items.len >= max_rows) break;
        rows.append(arena, .{ .files = self.index.items[h.item] }) catch break;
    }
    return rows.items;
}

const document_verbs = Keybinds.document_verbs;
const commandActionSuffix = Keybinds.commandActionSuffix;

/// Whether `id` should appear in the command palette given the current active document.
fn shouldShowCommand(editor: *Editor, id: []const u8) bool {
    for (document_verbs) |v| {
        if (v.fizzy_id) |fid| {
            if (std.mem.eql(u8, id, fid)) return true;
        }
    }

    const suffix = commandActionSuffix(id);
    for (document_verbs) |v| {
        if (!std.mem.eql(u8, v.action, suffix)) continue;
        // Plugin (or other) implementation of a document verb.
        if (v.fizzy_id != null) return false;
        const doc = editor.activeDoc() orelse return false;
        var buf: [128]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "{s}.{s}", .{ doc.owner.id, v.action }) catch return false;
        return std.mem.eql(u8, id, want);
    }
    return true;
}

fn collectCommandRows(editor: *Editor, query: *const fuzzy.Query) []Row {
    const arena = dvui.currentWindow().arena();

    var hits: std.ArrayListUnmanaged(fuzzy.Ranked(usize)) = .empty;
    for (editor.host.commands.items, 0..) |c, i| {
        if (!shouldShowCommand(editor, c.id)) continue;
        // Match against the title *and* the id, so both "Save All" and "fizzy.saveAll" find it.
        const score = if (query.isEmpty())
            @as(f64, 0)
        else
            (fuzzy.scoreBest(&.{ c.title, c.id }, query, .{ .plain = true }) orelse continue);
        hits.append(arena, .{ .item = i, .score = score, .tie = c.title.len }) catch break;
    }
    fuzzy.sort(usize, hits.items);

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    for (hits.items) |h| {
        if (rows.items.len >= max_rows) break;
        const c = editor.host.commands.items[h.item];
        rows.append(arena, .{ .commands = .{
            .id = c.id,
            .title = c.title,
            .enabled = editor.host.commandEnabled(c.id),
        } }) catch break;
    }
    return rows.items;
}

/// Shortcut hint for a command, or null when it has none.
fn shortcutFor(editor: *Editor, id: []const u8) ?[]const u8 {
    const arena = dvui.currentWindow().arena();
    const found = editor.keymap.bindingsFor(arena, id) catch return null;
    if (found.len == 0) return null;
    const platform: keymap.Platform = if (fizzy.platform.isMacOS()) .mac else .other;
    return keymap.formatKeys(arena, found[0].stroke, platform) catch null;
}

// ---- activation ---------------------------------------------------------------------------

fn activate(self: *CommandPalette, editor: *Editor, rows: []const Row) void {
    if (rows.len == 0) return;
    const idx = @min(self.selected, rows.len - 1);
    const row = rows[idx];
    // The work happens now, not when the outro ends — the palette animating away over a file
    // that is already opening is the point; deferring it would just read as lag. `activated` is
    // set only on a path that actually closes, so a disabled command can't leave a row stuck
    // looking pressed.
    switch (row) {
        .files => |abs| {
            self.activated = idx;
            self.close();
            _ = editor.openFilePath(abs, editor.currentGroupingID()) catch {
                dvui.log.err("palette: failed to open {s}", .{abs});
            };
        },
        .commands => |c| {
            if (!c.enabled) return;
            self.activated = idx;
            self.close();
            editor.host.runCommand(c.id) catch |err| {
                dvui.log.err("palette: command '{s}' failed: {s}", .{ c.id, @errorName(err) });
            };
        },
    }
}

// ---- draw ----------------------------------------------------------------------------------

pub fn draw(self: *CommandPalette, editor: *Editor) void {
    if (!self.open) return;

    // dvui closed the window from the inside (its own escape/close path). Turn that into an
    // outro rather than letting the palette blink out.
    if (!self.fw_open and !self.closing) {
        self.fw_open = true;
        self.close();
    }

    const win_rect = dvui.windowRect();
    const theme = dvui.themeGet();

    const w = @min(width_max, @max(320, win_rect.w - width_margin * 2));
    const x = (win_rect.w - w) / 2;
    // Half the window is the ceiling, not the fixed size — the panel is only as tall as its
    // results and never fills the app.
    const list_max_h = win_rect.h * 0.5;

    { // scrim fade + close lifecycle; the panel's geometry is the widget's job now
        const dt = frameDelta();
        if (dvui.reduce_motion) {
            self.anim = if (self.closing) 0 else 1;
        } else if (self.closing) {
            self.anim = @max(0, self.anim - dt / close_secs);
        } else {
            self.anim = @min(1, self.anim + dt / open_secs);
        }

        // The scrim fade runs for exactly as long as the widget's close animation, so it is also
        // the clock for when the palette stops drawing.
        if (self.closing and self.anim <= 0) {
            self.finishClose();
            return;
        }
        if (self.anim < 1 or self.closing) dvui.refresh(null, @src(), null);
    }

    // Only x/y/w are ours. Height comes back from the widget's auto-size each frame through this
    // same rect — overwriting it here would stomp the animation mid-flight.
    self.fw_rect.x = x;
    self.fw_rect.y = top_offset;
    self.fw_rect.w = w;
    if (self.fw_rect.h == 0) self.fw_rect.h = 1;

    // Same shell as Grid Layout / other dialogs: modal floating window focuses its subwindow
    // (so the text entry can receive keys) and paints a black scrim via `color_text = .black`.
    fizzy.dvui.modal_dim_titlebar = true;
    // Scrim tracks the reveal, so the dim arrives and leaves with the panel instead of snapping
    // to full black on frame one and popping off at the end of the outro. Same base values dvui
    // picks per theme (60 dark / 80 light), scaled.
    const dim_base: f32 = if (theme.dark) 60 else 80;
    const dim_alpha: u8 = @intFromFloat(@round(dim_base * std.math.clamp(self.anim, 0, 1)));

    var win = fizzy.dvui.floatingWindow(@src(), .{
        .modal = true,
        .modal_alpha = dim_alpha,
        .open_flag = &self.fw_open,
        .resize = .none,
        .window_avoid = .none,
        .rect = &self.fw_rect,
        // The panel hangs from a fixed top edge and grows downward, and its width is chosen
        // here rather than by its contents — so auto-size gets the height axis only, pinned
        // at the top instead of the default grow-about-the-centre.
        .size_anchor = .top,
        .auto_size_axes = .vertical,
        .process_events_in_deinit = true,
    }, .{
        // Drives the modal dim fill (`options.color(.text)` + alpha) — must be black like dialogs,
        // not theme text (which is light on dark themes and looked wrong).
        .color_text = .black,
        .color_fill = theme.color(.content, .fill).opacity(0.85),
        .corners = dvui.CornerRect.all(8),
        .padding = dvui.Rect.all(6),
        .border = .all(0),
        .box_shadow = .{
            .fade = 8,
            .corners = .all(8),
            .alpha = 0.25,
        },
    });
    // `deinit` writes the live (animated) rect back into `fw_rect`, which is how the height
    // carries to the next frame. Only the axes we own are restored.
    defer {
        win.deinit();
        self.fw_rect.x = x;
        self.fw_rect.y = top_offset;
        self.fw_rect.w = w;
    }
    // Grow/shrink to fit the real content min size, the same way dialogs do. While closing, hand
    // over to the collapse animation instead — calling both would have them fight.
    if (self.closing) win.closeAnimateCollapse() else win.autoSize();
    // Palette isn't draggable — an empty drag area keeps processEventsAfter from claiming
    // pointer presses (which blocked row clicks) and from forcing the move (`arrow_all`) cursor.
    win.dragAreaSet(.{});

    // Content text must not inherit the black used for the scrim.
    const text_color = theme.color(.window, .text);

    // The query drives everything below, so it has to be read before the rows are built. It's
    // last frame's text at this point, which is exactly right: the entry hasn't processed this
    // frame's keystrokes yet, and rebuilding the list a frame later would lag the selection.
    const parsed = modeAndQuery(self.queryText());
    var query = fuzzy.Query.init(parsed.query);

    if (parsed.mode == .files) self.ensureIndex(editor);
    const rows = switch (parsed.mode) {
        .files => self.collectFileRows(editor, &query),
        .commands => collectCommandRows(editor, &query),
    };
    if (self.selected >= rows.len) self.selected = if (rows.len == 0) 0 else rows.len - 1;

    // Keyboard first: the text entry would otherwise swallow Up/Down (dvui's TextEntryWidget
    // treats them as cursor motion) and Enter. Dead during the outro — the palette is on screen
    // but no longer the thing you're driving.
    if (!self.closing) self.handleKeys(editor, rows, win.data());

    { // query row
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .color_text = text_color,
        });
        defer hbox.deinit();

        _ = dvui.icon(
            @src(),
            "palette-icon",
            if (parsed.mode == .commands) icons.tvg.lucide.terminal else icons.tvg.lucide.search,
            .{ .stroke_color = text_color },
            .{ .gravity_y = 0.5, .padding = dvui.Rect.all(4) },
        );

        var entry = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &self.text_buf },
            .placeholder = if (parsed.mode == .commands) "Run a command…" else "Search files by name…",
        }, .{
            .expand = .horizontal,
            .background = false,
            .color_text = text_color,
            .id_extra = 1,
        });
        // FloatingWindow focuses its subwindow on first frame (size 0); claim the entry for a
        // few frames after that so typing works without a click.
        if (self.just_opened or self.focus_frames > 0) {
            dvui.focusWidget(entry.data().id, win.data().id, null);
            self.just_opened = false;
            if (self.focus_frames > 0) self.focus_frames -= 1;
        }
        // Same window as the focus claim: park the cursor past the seeded prefix so the first
        // keystroke appends instead of landing before the `>`.
        if (self.tail_frames > 0) {
            self.tail_frames -= 1;
            entry.textLayout.selection.moveCursor(std.math.maxInt(usize), false);
        }
        entry.deinit();
    }

    if (rows.len == 0) {
        // No scroll area, so the label's own min size is the panel's — auto-size shrinks to it.
        self.list_content_h = 0;
        dvui.label(@src(), "{s}", .{switch (parsed.mode) {
            .files => if (editor.folder == null) "No folder open" else "No matching files",
            .commands => "No matching commands",
        }}, .{
            .expand = .horizontal,
            .padding = dvui.Rect.all(8),
            .color_text = text_color.opacity(0.6),
        });
    } else {
        // Viewport is last frame's measured content, capped. Below the cap it equals the content
        // exactly, so no scrollbar; at the cap the content genuinely overflows and one appears.
        const viewport_h = @min(list_max_h, @max(row_height, self.list_content_h));
        var scroll = dvui.scrollArea(@src(), .{
            // The panel spends its first frames animating to this height, during which the
            // viewport really is shorter than the content. Hiding the bar until the geometry
            // settles keeps it from flashing on every open and every resize.
            .vertical_bar = if (self.animatingGeometry(win)) .hide else .auto,
        }, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 0, .h = viewport_h },
            .max_size_content = .height(viewport_h),
            .background = false,
            .color_text = text_color,
        });
        // `si` lives in dvui's data store, not in the widget, so it outlives `deinit` — which is
        // where `ScrollContainerWidget` finalises `virtual_size` from the rows just laid out.
        const si = scroll.si;

        for (rows, 0..) |row, i| {
            self.drawRow(editor, row, i, parsed.mode, &query, rows);
        }
        scroll.deinit();

        self.list_content_h = si.virtual_size.h;
    }

    // Click the scrim (outside the palette content) dismisses — modal owns all mouse targets.
    if (self.closing) return;
    const palette_r = win.data().rectScale().r;
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .press or !me.button.pointer()) continue;
        if (palette_r.contains(me.p)) continue;
        e.handle(@src(), win.data());
        self.close();
        return;
    }
}

fn drawRow(
    self: *CommandPalette,
    editor: *Editor,
    row: Row,
    i: usize,
    mode: Mode,
    query: *const fuzzy.Query,
    rows: []const Row,
) void {
    const theme = dvui.themeGet();

    // Build the row first so we have a screen rect, then decide selection from mouse vs
    // keyboard. Painting the highlight after means hover updates on the same frame.
    var rb = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = i,
        .expand = .horizontal,
        .min_size_content = .{ .w = 0, .h = row_height },
        .background = false,
        .corners = dvui.CornerRect.all(4),
        .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
    });
    defer rb.deinit();

    const row_r = rb.data().borderRectScale().r;
    const mouse_pt = dvui.currentWindow().mouse_pt;
    const mouse_over = !self.closing and row_r.contains(mouse_pt) and dvui.clipGet().contains(mouse_pt);

    // Moving the mouse onto a row takes selection (same highlight as arrow keys). Stay put
    // when the mouse is still so Up/Down keyboard nav isn't stolen by a resting cursor.
    if (mouse_over and dvui.mouseTotalMotion().nonZero() and self.selected != i) {
        self.selected = i;
        self.scroll_to_selected = false;
    }

    // Click to activate. Handled before the highlight is painted so the pressed fill lands on
    // this very frame, and the row keeps drawing afterwards rather than returning early — it has
    // to survive the outro to be seen at all.
    if (!self.closing) {
        for (dvui.events()) |*e| {
            if (!dvui.eventMatchSimple(e, rb.data())) continue;
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (me.action == .press and me.button.pointer()) {
                e.handle(@src(), rb.data());
                self.selected = i;
                self.activate(editor, rows);
                break;
            }
        }
    }

    // The activated row reads as pressed for the whole outro. Before this the palette closed on
    // the same frame as the click, so the row you picked disappeared out from under the cursor
    // with no acknowledgement that it was the one that ran.
    const is_activated = if (self.activated) |a| a == i else false;
    const is_selected = i == self.selected;
    if (is_activated) {
        row_r.fill(.all(4), .{ .color = theme.color(.control, .fill_press) });
    } else if (is_selected) {
        row_r.fill(.all(4), .{ .color = theme.color(.control, .fill_hover) });
    }

    if (is_selected and self.scroll_to_selected) {
        dvui.scrollTo(.{ .screen_rect = row_r });
        self.scroll_to_selected = false;
    }

    if (mouse_over) {
        dvui.cursorSet(.arrow);
    }

    const text_color = theme.color(.window, .text);

    switch (row) {
        .files => |abs| {
            const ext = std.fs.path.extension(abs);
            // Same fixed glyph slot as the file tree / tabs — `drawFileIcon` drawers use
            // `expand = .ratio` and must not size against the whole palette row.
            {
                var icon_slot = wdvui.treeRowGlyph(@src(), .{ .gravity_y = 0.5, .margin = .{ .w = 4 } });
                defer icon_slot.deinit();
                if (!editor.host.drawFileIcon(ext, abs, text_color)) {
                    dvui.icon(@src(), "file", icons.tvg.lucide.file, .{
                        .stroke_color = text_color,
                    }, wdvui.treeRowIconOptions(.{}));
                }
            }
            // Basename is what users type most often; `.plain = false` still weights it like a
            // path segment when the query hits directory letters that also appear in the name.
            wdvui.labelHighlighted(@src(), std.fs.path.basename(abs), query, false, .{
                .gravity_y = 0.5,
                .padding = .{ .x = 6, .y = 0, .w = 6, .h = 0 },
                .color_text = text_color,
                .expand = .none,
            });
            // Dimmed project-relative directory, VSCode-style — also highlight matches so a
            // query like `src/` lights up the path rather than looking like a miss.
            if (editor.folder) |root| {
                const arena = dvui.currentWindow().arena();
                const dir = std.fs.path.dirname(abs) orelse root;
                const rel = std.fs.path.relativePosix(arena, ".", root, dir) catch "";
                if (rel.len > 0) {
                    wdvui.labelHighlighted(@src(), rel, query, false, .{
                        .gravity_y = 0.5,
                        .gravity_x = 0.0,
                        .color_text = text_color.opacity(0.5),
                        .expand = .none,
                    });
                }
            }
        },
        .commands => |c| {
            const color = if (c.enabled) text_color else text_color.opacity(0.4);
            wdvui.labelHighlighted(@src(), c.title, query, true, .{
                .gravity_y = 0.5,
                .padding = .{ .x = 4, .y = 0, .w = 6, .h = 0 },
                .color_text = color,
                .expand = .none,
            });
            if (shortcutFor(editor, c.id)) |keys| {
                dvui.label(@src(), "{s}", .{keys}, .{
                    .gravity_y = 0.5,
                    .gravity_x = 1.0,
                    .expand = .horizontal,
                    .color_text = text_color.opacity(0.55),
                });
            }
        },
    }
    _ = mode;
}

fn handleKeys(self: *CommandPalette, editor: *Editor, rows: []const Row, wd: *const dvui.WidgetData) void {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .key) continue;
        const ke = e.evt.key;
        if (ke.action != .down and ke.action != .repeat) continue;

        if (ke.matchBind("char_down")) {
            e.handle(@src(), wd);
            if (rows.len > 0) self.selected = (self.selected + 1) % rows.len;
            self.scroll_to_selected = true;
        } else if (ke.matchBind("char_up")) {
            e.handle(@src(), wd);
            if (rows.len > 0) {
                self.selected = if (self.selected == 0) rows.len - 1 else self.selected - 1;
            }
            self.scroll_to_selected = true;
        } else if (ke.code == .enter or ke.code == .kp_enter) {
            e.handle(@src(), wd);
            self.activate(editor, rows);
            return;
        } else if (ke.code == .escape) {
            e.handle(@src(), wd);
            self.close();
            return;
        }
    }
}
