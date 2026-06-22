//! A single open text document: its path, contents, and grouping. The contents are kept
//! in an `ArrayList(u8)` so the editing widget can grow/shrink it in place; the shell stores
//! only an opaque `DocHandle` whose `id` maps back to the registered `Document`.
const std = @import("std");
const builtin = @import("builtin");
const internal = @import("../text.zig");
const dvui = internal.dvui;
const sdk = internal.sdk;
const UndoStack = internal.UndoStack;
const TextEntryWidget = @import("widgets/TextEntryWidget.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

const Document = @This();

/// Which side is shown while the raw|preview split is collapsed.
pub const PreviewSide = enum { raw, preview };

/// Shell document id (monotonic, allocated from the host).
id: u64,
/// Absolute path on disk, heap-owned.
path: []u8,
/// Tab grouping (which split/tab group this document lives in).
grouping: u64 = 0,
/// File contents. The text-editing widget reads from and writes back to `items`.
text: std.ArrayList(u8) = .empty,
/// Cached `\n` count + 1; refreshed on load and when the editor reports edits.
line_count: usize = 1,
/// True for a document created via `createDocument` ("New File") that has never been
/// written to a real on-disk path yet. Drives `documentHasRecognizedSaveExtension`, so
/// `Editor.save()` routes an untitled document straight to Save As. Deliberately not
/// inferred from the path (e.g. `""`/no extension) — an intentionally extensionless real
/// file like `Makefile` must not be mistaken for an untitled document.
unsaved: bool = false,

/// Selection, mirrored from the `TextEntryWidget` after every draw (`TextEditor.draw`) so
/// the Copy/Paste commands — invoked from the Edit menu / native menu, outside any frame's
/// widget instance — have somewhere durable to read "what's currently selected" from.
sel_start: usize = 0,
sel_end: usize = 0,
/// Byte offset the next `TextEditor.draw` should move the caret to, set by Paste/Undo/Redo
/// (which all edit `text` from outside the widget's own frame) and consumed once.
pending_cursor: ?usize = null,
/// Vertical scroll offset, mirrored from the editor's `ScrollInfo` after every draw and
/// restored on the widget's next `dvui.firstFrame` (see `TextEditor.zig`). dvui garbage-
/// collects a widget id's persisted per-frame data (including its scroll position) the very
/// next frame it isn't drawn — true for any inactive/background tab, since the workbench only
/// draws the active document per pane. Without this, switching away to another document (a
/// goto-definition jump, or just clicking another tab) for even one frame and back reset the
/// original document's scroll to the top, discarding wherever the user had actually been
/// reading. `Document` is fizzy-owned and outlives dvui's per-frame GC, so this is the durable
/// copy; the field is written every frame regardless (cheap), not just on the restore frame.
scroll_y: f32 = 0,
/// 0-based source line the next `TextEditor.draw` should scroll into view, set by
/// `revealPosition` (goto-definition) alongside `pending_cursor` and consumed once. A
/// separate field, not derived from `pending_cursor`, because the editor scrolls to it
/// directly (`ScrollInfo.scrollToOffset`) rather than relying on the text layout's own
/// cursor-rect-discovery scroll (`TextEntryWidget`'s `scroll_to_cursor`), which only fires
/// while the layout pass happens to walk over the cursor's new byte range — unreliable for a
/// jump that lands outside the currently-laid-out/visible region (a fresh document's first
/// draw, or a large jump within an already-open one). Editor never wraps lines
/// (`break_lines = false`), so one source line is exactly one visual row and `line *
/// line_height` is an exact, not approximate, scroll target.
pending_scroll_line: ?u32 = null,

/// Owned completion candidates for the current completion list, if any — each `.label`/`.text`
/// is a copy (`sdk.language.CompletionItem` fields from `sdk.host().completionFor(...)` are
/// only valid for the duration of that call, same convention as `HoverResult.text`) made by
/// `TextEditor.drawCompletion`. Empty exactly when `completion_anchor == null`.
completion_items: std.ArrayListUnmanaged(TextEntryWidget.CompletionCandidate) = .empty,
/// Which candidate is "current" — shown as ghost text and highlighted in the dropdown list.
/// Moved by Up/Down in `TextEntryWidget.processEvents()`.
completion_selected: usize = 0,
/// Byte offset `completion_items` is valid for, or null when no completion is showing.
/// Round-tripped with `completion_selected`/`TextEntryWidget.current_completion` every frame
/// (`TextEditor.drawEditor`), the same way `sel_start`/`sel_end` round-trip — `te` is a fresh
/// struct every frame, but `te.processEvents()` (Up/Down-navigates, Tab/Enter-accepts) needs
/// to see whatever was showing as of the *previous* frame's `draw()`, since `drawCompletion`
/// (which sets/refreshes it for the new frame) doesn't run until after `processEvents()`.
completion_anchor: ?usize = null,

/// Raw|preview split state when a language plugin registers a preview pane.
preview_split_ratio: f32 = 0.5,
preview_collapsed: bool = false,
preview_side: PreviewSide = .raw,

/// Undo/redo history — see `UndoStack` for the capture strategy.
history: UndoStack = .{},
/// `history.topOpId()` as of the last successful save; the document is dirty exactly when
/// the two differ. Deliberately an id, not `undo.items.len` — a length can return to its
/// saved value via undo-then-new-edit while content differs from disk, but an id can't:
/// undo/redo move the same `EditOp` (and its id) back and forth, while any genuinely new
/// edit gets a fresh id that never collides with the one recorded at save time.
clean_op_id: u64 = 0,

/// 64 MiB — generous for source files; guards against opening something huge by mistake.
const max_file_bytes: usize = 64 * 1024 * 1024;

/// Build a document from in-memory bytes (browser file picker, or after reading from disk).
pub fn fromBytes(path: []const u8, bytes: []const u8) !Document {
    const gpa = sdk.allocator();
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    try text.appendSlice(gpa, bytes);
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);
    var doc = Document{
        .id = sdk.host().allocDocId(),
        .path = path_copy,
        .text = text,
    };
    doc.refreshLineCount();
    return doc;
}

pub fn refreshLineCount(self: *Document) void {
    self.line_count = if (self.text.items.len == 0) 1 else std.mem.count(u8, self.text.items, "\n") + 1;
}

/// Resolves a 0-based `{line, character}` position (LSP `Position`-shaped, `character` a byte
/// count within the line) against this document's own loaded `text`, for `revealPosition` —
/// see `sdk.language.DefinitionLocation`'s doc comment for why goto-definition hands over a
/// line/character pair instead of a pre-resolved byte offset. `line` past the end of the
/// document clamps to the last line; `character` past the end of `line` clamps to the line's
/// actual length (a stale/imprecise position from the provider should still land somewhere
/// sane in the file, not panic or silently pick byte 0).
pub fn byteOffsetForLineCharacter(self: *const Document, line: u32, character: u32) usize {
    var line_start: usize = 0;
    var lines_seen: u32 = 0;
    while (lines_seen < line) {
        const nl = std.mem.indexOfScalarPos(u8, self.text.items, line_start, '\n') orelse break;
        line_start = nl + 1;
        lines_seen += 1;
    }
    var line_end = line_start;
    while (line_end < self.text.items.len and self.text.items[line_end] != '\n') : (line_end += 1) {}
    return line_start + @min(character, line_end - line_start);
}

/// Where `revealPosition` should scroll to for a goto-definition landing on `target_line`:
/// the nearest blank (whitespace-only) line at or above it, so a leading doc-comment/
/// attribute block sitting directly above the definition (no blank line separating them from
/// it) stays in view too, rather than the definition itself landing right at the top edge
/// with its comments scrolled just out of frame. Returns null when no blank line is found
/// before reaching the start of the file — the definition (and everything above it) is
/// already at the top of the file, so the caller should leave the viewport untouched rather
/// than force a scroll to line 0.
pub fn scrollTargetLine(self: *const Document, target_line: u32) ?u32 {
    if (target_line == 0) return null;
    const text = self.text.items;

    // Forward scan to the byte offset where `target_line` starts.
    var start: usize = 0;
    var line_num: u32 = 0;
    while (line_num < target_line) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
        start = nl + 1;
        line_num += 1;
    }

    // Walk upward one line at a time from `target_line - 1`, checking each for blankness.
    // `line_end` is the exclusive end (its trailing '\n') of the line about to be examined.
    var line = target_line;
    var line_end = start;
    while (line > 0) {
        line -= 1;
        if (line_end == 0) break; // defensive; see the loop-invariant note below.
        const content_end = line_end - 1; // exclude the line's own trailing '\n'
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..content_end], '\n')) |i| i + 1 else 0;
        if (std.mem.trim(u8, text[line_start..content_end], " \t\r").len == 0) return line;
        // `line_start == 0` only happens on line 0 itself, which is also exactly when `line`
        // reaches 0 and the loop condition ends it — so `line_end` never reaches 0 with `line`
        // still positive on the next iteration; the check above is a guard against that
        // invariant ever being wrong, not a path expected to trigger in practice.
        line_end = line_start;
    }
    return null;
}

/// Build a document by reading `path` from disk. Runs on the shell's load worker thread.
/// Web has no filesystem; documents there are opened from bytes (`fromBytes`) instead.
pub fn fromPath(path: []const u8) !Document {
    if (comptime is_wasm) return error.Unsupported;
    const gpa = sdk.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(bytes);
    return fromBytes(path, bytes);
}

pub fn deinit(self: *Document) void {
    const gpa = sdk.allocator();
    gpa.free(self.path);
    self.text.deinit(gpa);
    self.history.deinit(gpa);
    self.clearCompletionItems();
    self.completion_items.deinit(gpa);
}

/// Frees every candidate's owned `.text` and empties the list (but keeps its capacity) —
/// call before replacing with a fresh fetch or when dismissing/accepting.
pub fn clearCompletionItems(self: *Document) void {
    const gpa = sdk.allocator();
    for (self.completion_items.items) |it| {
        gpa.free(it.label);
        gpa.free(it.text);
        gpa.free(it.detail);
        gpa.free(it.documentation);
    }
    self.completion_items.clearRetainingCapacity();
}

pub fn isDirty(self: *const Document) bool {
    return self.history.topOpId() != self.clean_op_id;
}

/// Write the current contents back to `path`.
pub fn save(self: *Document) !void {
    if (comptime is_wasm) return error.Unsupported;
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = self.path, .data = self.text.items });
    self.clean_op_id = self.history.topOpId();
}

/// Retarget the document at `new_path` and write it there (Save As). Once this succeeds the
/// document behaves exactly like one opened from disk at `new_path` (no longer `unsaved`).
pub fn saveAs(self: *Document, new_path: []const u8) !void {
    if (comptime is_wasm) return error.Unsupported;
    const gpa = sdk.allocator();
    const path_copy = try gpa.dupe(u8, new_path);
    errdefer gpa.free(path_copy);
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path_copy, .data = self.text.items });
    gpa.free(self.path);
    self.path = path_copy;
    self.unsaved = false;
    self.clean_op_id = self.history.topOpId();
}

/// Replace `text.items[start..end)` with `new` as one complete, undoable edit — used by the
/// `text.paste` command, which (unlike the widget-driven keystroke path) builds a single
/// edit outside any frame's `TextEntryWidget` instance.
pub fn replaceRange(self: *Document, start: usize, end: usize, new: []const u8) !void {
    const gpa = sdk.allocator();
    try self.history.pushComplete(gpa, start, self.text.items[start..end], new);
    try self.text.replaceRange(gpa, start, end - start, new);
    self.refreshLineCount();
    self.sel_start = start + new.len;
    self.sel_end = self.sel_start;
    self.pending_cursor = self.sel_start;
}

/// Reverses the most recent edit, if any, and relocates the caret to it (applied on the next
/// `TextEditor.draw` via `pending_cursor`).
pub fn undo(self: *Document) void {
    const gpa = sdk.allocator();
    const cursor = self.history.applyUndo(gpa, &self.text) orelse return;
    self.refreshLineCount();
    self.sel_start = cursor;
    self.sel_end = cursor;
    self.pending_cursor = cursor;
}

/// Re-applies the most recently undone edit, if any.
pub fn redo(self: *Document) void {
    const gpa = sdk.allocator();
    const cursor = self.history.applyRedo(gpa, &self.text) orelse return;
    self.refreshLineCount();
    self.sel_start = cursor;
    self.sel_end = cursor;
    self.pending_cursor = cursor;
}
