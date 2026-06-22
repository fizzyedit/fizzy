//! Monospace text editor: line numbers + local `TextEntryWidget` with optional tree-sitter
//! highlighting and an optional raw|preview split when a language plugin registers a preview.
const std = @import("std");
const text = @import("../text.zig");
const dvui = text.dvui;
const core = text.core;
const sdk = text.sdk;
const Document = text.Document;
const SyntaxHighlight = @import("SyntaxHighlight.zig");
const TextEntryWidget = @import("widgets/TextEntryWidget.zig");
const TooltipWidget = @import("widgets/TooltipWidget.zig");

const editor_pad_y: f32 = 8;
const editor_pad_right: f32 = 8;
const line_number_pad_left: f32 = 4;
const text_gap_after_numbers: f32 = 12;
const syntax_highlight_max_bytes: usize = 4 * 1024 * 1024;

const chromeless = dvui.Options{
    .background = false,
    .margin = dvui.Rect{},
    .padding = null,
    .border = dvui.Rect{},
    .corners = dvui.CornerRect{},
    .ninepatch_fill = &dvui.Ninepatch.none,
    .ninepatch_hover = &dvui.Ninepatch.none,
    .ninepatch_press = &dvui.Ninepatch.none,
};

pub fn draw(doc: *Document, id_extra: u64, gpa: std.mem.Allocator) !bool {
    const ext = std.fs.path.extension(doc.path);
    const preview = sdk.host().previewProviderFor(ext);

    // Set for the duration of the draw so previewPane/hover/gotoDefinition providers can
    // resolve this document's path (e.g. for relative-asset resolution or building an LSP
    // file:// URI) without extending every hook's signature with an extra parameter.
    sdk.language.setPreviewDocumentPath(doc.path);
    defer sdk.language.setPreviewDocumentPath("");

    if (preview == null) {
        return drawEditor(doc, ext, id_extra, gpa);
    }

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = false,
        .id_extra = @intCast(id_extra + 0x0F00),
    });
    defer outer.deinit();

    drawPreviewTogglePill(doc, id_extra);

    if (doc.preview_collapsed) {
        if (doc.preview_side == .raw) {
            return try drawEditor(doc, ext, id_extra, gpa);
        }
        try drawPreviewPane(doc, preview.?, ext, id_extra, gpa);
        return false;
    }

    var paned = core.dvui.paned(@src(), .{
        .direction = .horizontal,
        .collapsed_size = 0,
        .split_ratio = &doc.preview_split_ratio,
        .handle_size = 6,
        .handle_dynamic = .{},
    }, .{ .expand = .both, .background = false, .id_extra = @intCast(id_extra + 0x1000) });
    defer paned.deinit();

    var changed = false;
    if (paned.showFirst()) {
        changed = try drawEditor(doc, ext, id_extra, gpa);
    }
    if (paned.showSecond()) {
        try drawPreviewPane(doc, preview.?, ext, id_extra + 0x2000, gpa);
    }

    return changed;
}

fn drawPreviewPane(
    doc: *Document,
    provider: *sdk.LanguageSupport,
    ext: []const u8,
    id_extra: u64,
    gpa: std.mem.Allocator,
) !void {
    const hook = provider.vtable.previewPane orelse return;
    const owner = provider.owner orelse return;
    try hook(owner.state, ext, doc.text.items, id_extra, gpa);
}

fn drawPreviewTogglePill(doc: *Document, id_extra: u64) void {
    var pill_align = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .margin = .{ .y = 4, .w = 4, .h = 0, .x = 0 },
        .id_extra = @intCast(id_extra + 0x2FF0),
    });
    defer pill_align.deinit();

    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = @intCast(id_extra + 0x2FF1) });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = dvui.themeGet().fill.opacity(0.92),
        .corners = dvui.CornerRect.all(12),
        .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
        .id_extra = @intCast(id_extra + 0x3000),
    });
    defer row.deinit();

    drawPreviewPillButton(doc, "Raw", .raw, id_extra + 0x3001);
    drawPreviewPillButton(doc, "Preview", .preview, id_extra + 0x3002);
}

fn drawPreviewPillButton(doc: *Document, label: []const u8, side: Document.PreviewSide, id_extra: u64) void {
    const active = doc.preview_side == side;
    if (dvui.button(@src(), label, .{}, .{
        .background = active,
        .style = if (active) .highlight else .control,
        .id_extra = @intCast(id_extra),
    })) {
        if (doc.preview_collapsed and doc.preview_side == side) {
            doc.preview_collapsed = false;
        } else if (!doc.preview_collapsed) {
            doc.preview_side = side;
            doc.preview_collapsed = true;
        } else {
            doc.preview_side = side;
        }
    }
}

fn drawEditor(doc: *Document, ext: []const u8, id_extra: u64, gpa: std.mem.Allocator) !bool {
    const font = dvui.Font.theme(.mono);
    const line_height = font.lineHeight();
    const line_num_col = lineNumberColumnWidth(doc.line_count, font);

    var row = dvui.box(@src(), .{ .dir = .horizontal }, chromeless.override(.{
        .expand = .both,
        .font = font,
        .id_extra = @intCast(id_extra),
    }));
    defer row.deinit();

    const gutter_wd = dvui.spacer(@src(), chromeless.override(.{
        .min_size_content = .{ .w = line_num_col, .h = 1 },
        .expand = .vertical,
        .id_extra = @intCast(id_extra + 2),
    }));
    const gutter_rs = gutter_wd.borderRectScale();

    const out_of_band_edit = doc.pending_cursor != null;
    const tree_sitter_option = if (doc.text.items.len <= syntax_highlight_max_bytes)
        SyntaxHighlight.treeSitterOption(doc.path)
    else
        null;

    var te: TextEntryWidget = undefined;
    te.init(@src(), .{
        .multiline = true,
        .break_lines = false,
        // `TextLayoutWidget`'s cache_layout skip-ahead (`bytesNeeded`) jumps `insert_pt`/
        // `bytes_seen` to the scrolled-to position as a side effect of `drawBeforeText`, so
        // `cache_layout` must be decided once, here, before `drawBeforeText` runs — never
        // toggled mid-frame (that was the bug that used to force this off for highlighted
        // files: disabling it only inside the highlight path ran too late, after the jump had
        // already happened, leaving text rendering from byte 0 but pinned at the scrolled
        // y-offset). The tree-sitter highlight path's per-token `emitChunk` calls still feed
        // the whole document every frame (`TextEntryWidget.draw`), but that's fine — cache_layout
        // clips each call to the visible range internally; ghost-text splicing (completions/
        // signature hints) rewinds `cache_layout_bytes_seen` in lockstep with `bytes_seen` to
        // stay compatible (see `emitChunk`). Query/capture cost is separately bounded by
        // restricting the tree-sitter query itself to (an estimate of) the visible byte range.
        .cache_layout = !out_of_band_edit,
        .scroll_horizontal = true,
        .focus_border = false,
        .external_copy_paste = true,
        .text = .{ .array_list = .{ .backing = &doc.text, .allocator = gpa, .limit = max_text_bytes } },
        .tree_sitter = tree_sitter_option,
        .edit_notify = .{
            .ctx = @ptrCast(doc),
            .beginEdit = editNotifyBegin,
            .noteRemoved = editNotifyRemoved,
            .noteInserted = editNotifyInserted,
            .endEdit = editNotifyEnd,
        },
        // Tab always inserts indentation (VSCode-style) instead of changing focus — the
        // setting below only picks *what* it inserts (spaces vs a literal tab), not whether
        // it does so at all.
        .tab_inserts_indent = true,
        .tab_size = text.plugin.statePtr().tab_size,
        .insert_spaces = text.plugin.statePtr().insert_spaces_on_tab,
        // Same VSCode-style baseline as Tab above — not gated by a setting.
        .auto_indent_newline = true,
    }, chromeless.override(.{
        .expand = .both,
        .font = font,
        .padding = .{
            .x = 0,
            .y = editor_pad_y,
            .w = editor_pad_right,
            .h = editor_pad_y,
        },
        .color_text = dvui.themeGet().color(.content, .text),
        .id_extra = @intCast(id_extra + 1),
    }));
    // Not deferred: `pending_scroll_line` below needs to run *after* `te.deinit()` (which is
    // what actually commits `te.scroll.si.virtual_size` for this frame — see that block's
    // comment), so it's called explicitly near the bottom of this function instead.

    // `te` is a fresh struct every frame, but `te.processEvents()` (Up/Down-navigates,
    // Tab/Enter-accepts) runs *before* `drawCompletion()` below sets/refreshes
    // `te.current_completion` for this frame — so without restoring last frame's result here
    // first, `processEvents()` would always see `current_completion == null` (the field's
    // fresh-struct default) and navigation/acceptance could never fire, even though rendering
    // (which happens in `te.draw()`, after `drawCompletion()`) looked like it was working.
    // `doc.completion_anchor`/`completion_items`/`completion_selected` are what make the
    // completion list survive the frame boundary; see the matching write-back below.
    if (doc.completion_anchor) |anchor| {
        te.current_completion = .{
            .anchor = anchor,
            .items = doc.completion_items.items,
            .selected = doc.completion_selected,
        };
    }

    if (out_of_band_edit) {
        te.text_changed = true;
    }

    if (doc.pending_cursor) |pos| {
        const clamped = @min(pos, doc.text.items.len);
        te.textLayout.selection.* = .{ .start = clamped, .cursor = clamped, .end = clamped };
        doc.pending_cursor = null;
    }

    te.processEvents();
    drawCompletion(doc, ext, &te);
    if (te.current_completion) |completion| {
        doc.completion_anchor = completion.anchor;
        doc.completion_selected = completion.selected;
    } else if (doc.completion_anchor != null) {
        // Just accepted or dismissed (Tab/Enter/Escape) this frame — free the now-stale
        // candidates promptly rather than waiting for the next fetch to overwrite them.
        doc.clearCompletionItems();
        doc.completion_anchor = null;
    }
    const signature_hint_buf = fetchSignatureHint(doc, ext, &te, gpa);
    defer if (signature_hint_buf) |b| gpa.free(b);
    te.draw();

    drawHoverAndGotoDefinition(doc, ext, &te, id_extra, gpa);
    drawCompletionList(doc, ext, &te, id_extra, gpa);

    drawLineNumbers(
        gutter_rs,
        doc.line_count,
        te.scroll.si.viewport.y,
        font,
        line_height,
    );

    const editor_rs = row.data().borderRectScale();
    const scroll_rs = te.scroll.data().contentRectScale();
    drawScrollEdgeShadows(editor_rs, scroll_rs, te.scroll.si);

    if (te.text_changed) doc.refreshLineCount();

    doc.sel_start = te.textLayout.selection.start;
    doc.sel_end = te.textLayout.selection.end;

    const text_changed = te.text_changed;
    // `si` is a pointer into dvui's persistent per-widget-id data store (not a value owned by
    // `te`), so it stays valid after `te.deinit()` invalidates the rest of `te` below —
    // capture it (and the scroll widget's id, for the refresh call) before that happens.
    const scroll_si = te.scroll.si;
    const scroll_widget_id = te.scroll.data().id;
    // Must be read before `te.deinit()` below, which (via the scroll container's own
    // deinit) writes this frame's min-size record for `scroll_widget_id` — `firstFrame`
    // needs to see whether the id was recorded *last* frame (i.e. genuinely wasn't drawn),
    // not the value that's about to be written a few lines down. See `Document.scroll_y`'s
    // doc comment for why this matters: dvui GCs a widget id's scroll state the very next
    // frame it isn't drawn, true for any inactive/background tab.
    const scroll_reappeared = dvui.firstFrame(scroll_widget_id);

    // Explicit, not deferred (see the comment where `te` was constructed above):
    // `ScrollContainerWidget.deinit()` is what actually commits `si.virtual_size` for content
    // measured this frame — on a document's very first draw, `virtual_size` is still its
    // stale/zero default until this call, so both scroll adjustments below have to run
    // *after* it, not before. Everything above this line still needed `te` alive; nothing
    // below does.
    te.deinit();

    if (scroll_reappeared) {
        // This document's tab was inactive last frame (or this is its first-ever draw, in
        // which case `doc.scroll_y` is still its harmless `0` default) — restore wherever
        // the user last left it before `pending_scroll_line` below gets a chance to override
        // it with a specific goto-definition target.
        scroll_si.scrollToOffset(.vertical, doc.scroll_y);
    }

    const had_pending_scroll_line = doc.pending_scroll_line != null;
    if (doc.pending_scroll_line) |target_line| {
        // Scroll directly to the target line's computed Y instead of relying on
        // `TextEntryWidget`'s cursor-rect-discovery scroll (`scroll_to_cursor`), which only
        // fires while the layout pass happens to walk over the cursor's new byte range —
        // unreliable for a jump landing outside the currently laid-out/visible region. See
        // `Document.pending_scroll_line`'s doc comment. Scrolls to the nearest blank line
        // above the target (see `Document.scrollTargetLine`) so a leading doc-comment block
        // comes into view too, rather than the definition landing flush against the top edge
        // with its comments just out of frame; a null result means the definition is already
        // at the top of the file, so the viewport is left untouched.
        if (doc.scrollTargetLine(target_line)) |scroll_line| {
            const target_y = editor_pad_y + @as(f32, @floatFromInt(scroll_line)) * line_height;
            scroll_si.scrollToOffset(.vertical, target_y);
        }
        doc.pending_scroll_line = null;
    }

    if (scroll_reappeared or had_pending_scroll_line) dvui.refresh(null, @src(), scroll_widget_id);
    doc.scroll_y = scroll_si.viewport.y;

    return text_changed;
}

/// Max size a hover tooltip is allowed to grow to before its content becomes scrollable
/// instead of the box itself growing — an unbounded tooltip over a long doc comment would
/// otherwise cover the very token it's describing, which fights the hover detection driving
/// it (mouse ends up over the tooltip, not the source token, so it flickers open/closed).
const hover_tooltip_max_size: dvui.Size = .{ .w = 480, .h = 320 };

/// Drives the completion list (ghost text of the selected candidate + `drawCompletionList`'s
/// dropdown) shown by `te.draw()`/the caller. Must run after `te.processEvents()` (so the
/// cursor position is final for this frame) and before `te.draw()` (which splices
/// `te.current_completion`'s selected candidate into its output) — the opposite order from
/// `drawHoverAndGotoDefinition`, which only needs to know what was hovered *during* that same
/// draw call. `completionFor` is a no-op (returns null) when no language plugin registers the
/// hook, so this is cheap and silent for any file type without LSP-style support.
///
/// Scans backward from `pos` over identifier characters to find where the current word
/// starts — used by `drawCompletionList` to know how much of each candidate's label to
/// highlight as "already typed". Deliberately a plain alphanumeric/underscore scan, not
/// language-aware — matches the same convention `fizzyedit/zig`'s LSP client uses internally.
fn wordStartBefore(bytes: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0) {
        const c = bytes[i - 1];
        // Include `@` so the completion list's typed-prefix highlight matches Zig builtins
        // (`@import`) the same way the zig plugin's own prefix trim does.
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '@')) break;
        i -= 1;
    }
    return i;
}

fn drawCompletion(doc: *Document, ext: []const u8, te: *TextEntryWidget) void {
    const sel = te.textLayout.selection;
    if (!sel.empty() or dvui.focusedWidgetId() != te.data().id) {
        te.current_completion = null;
        return;
    }

    const cursor = sel.cursor;
    if (te.current_completion) |cur| {
        if (cur.anchor != cursor) te.current_completion = null;
    }

    if (te.current_completion == null) {
        if (sdk.host().completionFor(ext, doc.path, doc.text.items, cursor)) |items| {
            // Each `item.insert_text` is only valid for this call — own a copy of every
            // candidate on `doc` before handing a slice of them to `te` for this frame's
            // `draw()`. `items` is never empty per `CompletionItem`'s contract, but a dupe
            // failure could still leave the list short of what zls actually returned — that's
            // fine, a partial list beats none.
            doc.clearCompletionItems();
            const gpa = sdk.allocator();
            for (items) |item| {
                const owned_label = gpa.dupe(u8, item.label) catch continue;
                const owned_text = gpa.dupe(u8, item.insert_text) catch {
                    gpa.free(owned_label);
                    continue;
                };
                const owned_detail = gpa.dupe(u8, item.detail) catch {
                    gpa.free(owned_label);
                    gpa.free(owned_text);
                    continue;
                };
                const owned_documentation = gpa.dupe(u8, item.documentation) catch {
                    gpa.free(owned_label);
                    gpa.free(owned_text);
                    gpa.free(owned_detail);
                    continue;
                };
                doc.completion_items.append(gpa, .{
                    .label = owned_label,
                    .text = owned_text,
                    .replace_start = item.replace_start,
                    .replace_end = item.replace_end,
                    .kind = item.kind,
                    .detail = owned_detail,
                    .documentation = owned_documentation,
                }) catch {
                    gpa.free(owned_label);
                    gpa.free(owned_text);
                    gpa.free(owned_detail);
                    gpa.free(owned_documentation);
                    continue;
                };
            }
            if (doc.completion_items.items.len > 0) {
                te.current_completion = .{
                    .anchor = cursor,
                    .items = doc.completion_items.items,
                    .selected = 0,
                };
            }
        }
    }
}

/// Fetches signature help for the call the cursor currently sits inside and, unless a real
/// completion is already claiming the ghost-text slot at the cursor this frame (`te.signature_hint`
/// only matters when `te.current_completion == null` — see `emitChunk`'s `Ghost`), sets
/// `te.signature_hint` to the remaining portion of the signature starting at the active
/// parameter — e.g. right after typing `foo(`, dimmed ghost text reads `a: u32, b: []const
/// u8)`, shrinking/advancing as real arguments get typed. Parameters aren't completion items —
/// there's nothing sensible to Tab/Enter-accept (you don't want to literally insert "a: u32"
/// as an argument), so unlike `drawCompletion` this only ever renders, never persists past this
/// frame, and needs no round-trip through `Document`.
///
/// Must run *before* `te.draw()` (which is what actually splices the ghost text in), unlike
/// the hover tooltip / completion dropdown, which need `te.draw()` to have already run so
/// `cursor_rect` is valid. Returns an owned buffer the caller must keep alive at least until
/// `te.draw()` returns and free afterward — `SignatureHelpResult.label` is only valid for the
/// duration of the `signatureHelpFor` call itself, same convention as `HoverResult.text`.
fn fetchSignatureHint(doc: *Document, ext: []const u8, te: *TextEntryWidget, gpa: std.mem.Allocator) ?[]u8 {
    if (te.current_completion != null) return null;

    const sel = te.textLayout.selection;
    if (!sel.empty() or dvui.focusedWidgetId() != te.data().id) return null;

    const result = sdk.host().signatureHelpFor(ext, doc.path, doc.text.items, sel.cursor) orelse return null;
    if (result.active_param_start >= result.active_param_end or result.active_param_end > result.label.len) {
        // No resolved active parameter (e.g. a zero-arg call already at the closing paren) —
        // nothing useful to hint at.
        return null;
    }

    const hint = result.label[result.active_param_start..];
    if (std.mem.indexOfScalar(u8, hint, '\n') != null) return null;

    const owned = gpa.dupe(u8, hint) catch return null;
    te.signature_hint = owned;
    return owned;
}

/// Max width/height for the completion dropdown before it scrolls — kept narrower and
/// shorter than a hover tooltip since this is a scannable list of short candidates, not prose.
const completion_list_max_size: dvui.Size = .{ .w = 280, .h = 200 };

/// Picks a dropdown row's icon from dvui's generic `entypo` set — there's no VSCode-style
/// code-symbol icon set available here, so this is a best-effort semantic approximation
/// (e.g. `code` for anything callable, `box` for a plain value) rather than a faithful match.
fn iconForCompletionKind(kind: sdk.language.CompletionKind) []const u8 {
    return switch (kind) {
        .function, .method => dvui.entypo.code,
        .variable => dvui.entypo.box,
        .field => dvui.entypo.tag,
        .constant => dvui.entypo.lock,
        .type_ => dvui.entypo.layers,
        .module => dvui.entypo.folder,
        .keyword => dvui.entypo.flag,
        .other => dvui.entypo.dot_single,
    };
}

/// Maps a `CompletionKind` to a tree-sitter capture name and looks up its color in the
/// current file's own syntax-highlighting table (`sdk.host().treeSitterHighlightFor(ext)`) —
/// the same "fizzy palette" the editor already colors code with (function = green, type =
/// tan, etc. — whatever the language plugin registered), rather than a separate hardcoded
/// set of icon colors. Falls back to a muted neutral when tree-sitter is unavailable, the
/// file type has no registered highlighter, or that highlighter doesn't define the capture.
fn colorForCompletionKind(ext: []const u8, kind: sdk.language.CompletionKind) dvui.Color {
    const fallback = dvui.themeGet().color(.control, .text).opacity(0.6);
    if (!dvui.useTreeSitter) return fallback;
    const ts = sdk.host().treeSitterHighlightFor(ext) orelse return fallback;
    const capture_name: []const u8 = switch (kind) {
        .function, .method => "function",
        .variable => "variable",
        .field => "variable.member",
        .constant => "constant",
        .type_ => "type",
        .module => "module",
        .keyword => "keyword",
        .other => return fallback,
    };
    for (ts.highlights) |sh| {
        if (std.mem.eql(u8, sh.name, capture_name)) {
            if (sh.opts.color_text) |c| return c;
        }
    }
    return fallback;
}

/// The scrollable dropdown of every candidate in `te.current_completion`, positioned just
/// below the text cursor (not the mouse — this is keyboard-driven, the mouse could be
/// anywhere). Must run after `te.draw()`, which is what makes `te.textLayout.cursor_rect`
/// valid for this frame. Clicking a row selects and immediately accepts it; Up/Down (handled
/// in `TextEntryWidget.processEvents()`) and Tab/Enter/Escape (also there) are the keyboard
/// path for the same list.
fn drawCompletionList(doc: *Document, ext: []const u8, te: *TextEntryWidget, id_extra: u64, gpa: std.mem.Allocator) void {
    const completion = te.current_completion orelse return;
    if (completion.items.len == 0) return;

    const cursor_screen = te.textLayout.screenRectScale(te.textLayout.cursor_rect).r;
    // `cursor_rect` spans exactly the current line's height, so its bottom edge is already
    // the top of the line below — add a small horizontal offset so the dropdown's left edge
    // doesn't sit flush against the cursor's exact x pixel.
    const completion_list_horizontal_margin: f32 = 4;

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{
        .from = .{ .x = cursor_screen.x + completion_list_horizontal_margin, .y = cursor_screen.y + cursor_screen.h },
        // gravity=1 on an axis means the anchor point is that edge's start (left/top), so the
        // floating box grows right and down from `from` — gravity=0 (what this used to be) put
        // the anchor at the *opposite* edge (bottom-right), which is what made the dropdown
        // appear with its bottom-right corner pinned to the cursor instead of its top-left.
        .from_gravity_x = 1,
        .from_gravity_y = 1,
    }, .{
        .id_extra = @intCast(id_extra + 0x9000),
        .background = true,
        .color_fill = dvui.themeGet().color(.window, .fill).lighten(if (dvui.themeGet().dark) 5 else -5),
        .corners = dvui.CornerRect.all(6),
        .border = dvui.Rect.all(0),
        .box_shadow = .{
            .color = .black,
            .shrink = 0,
            .corners = dvui.CornerRect.all(6),
            .offset = .{ .x = 0, .y = 2 },
            .fade = 4,
            .alpha = 0.2,
        },
        .min_size_content = .{ .w = completion_list_max_size.w, .h = 0 },
        .max_size_content = .size(completion_list_max_size),
    });
    // Not deferred, unlike everything else here: the info panel drawn at the bottom of this
    // function is a *separate* floating widget positioned off this dropdown's on-screen rect
    // (captured below, right after layout fixes its width — both `min_size_content.w` and
    // `max_size_content.w` are pinned to the same value, so unlike its content-dependent
    // height, the width doesn't need to wait for the row loop to settle). Drawing it only
    // once this whole widget has actually finished (`fw.deinit()`, called explicitly near the
    // bottom) avoids nesting a second floating subwindow inside this one's still-open context.
    const dropdown_screen_rect = fw.data().rectScale().r;

    // dvui synthesizes a `.position` mouse event *every frame* at wherever the mouse currently
    // rests (see `dvui.clickedEx`'s doc comment: "a single .position mouse event is at the end
    // of each frame"), not only on genuine movement — so a naive `ButtonWidget.hover` check
    // would keep re-selecting whatever row the mouse happens to be sitting over every single
    // frame, permanently overriding arrow-key navigation the instant the cursor rests anywhere
    // in the list. Comparing against `mouse_pt_prev` (dvui's own last-frame mouse position)
    // distinguishes "the mouse just arrived here" (a real hover, should drive selection) from
    // "the mouse is merely resting here" (should not) — letting whichever of arrow keys or an
    // actual mouse move happened most recently be the one that wins, per row below.
    const mouse_moved = !std.meta.eql(dvui.currentWindow().mouse_pt, dvui.currentWindow().mouse_pt_prev);

    // A hover detected *this* frame is recorded below as "pending" rather than applied to
    // `selected` immediately — applying it mid-loop would leave `selected` different at the
    // start of the loop than partway through it, and since rows are drawn in order, whichever
    // row was selected *before* the hover-changed row (i.e. every row with a lower index) had
    // already been painted with the old, now-stale `is_selected` by the time the hover update
    // landed — both the old and new row would show highlighted in the same frame. Applying the
    // *previous* frame's pending hover here, before any row is drawn, means `selected` is fixed
    // for the whole loop below — one frame of latency (imperceptible) in exchange for never
    // having two rows highlighted at once.
    if (dvui.dataGet(null, fw.data().id, "_pending_hover_select", usize)) |pending| {
        te.current_completion.?.selected = pending;
        dvui.dataRemove(null, fw.data().id, "_pending_hover_select");
    }

    var scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .hide,
    }, .{
        .expand = .both,
        .background = false,
    });

    // The portion of the current word already typed, so each row can render that prefix in
    // the theme's highlight-fill color (matching what the user actually typed) with the rest
    // of the label in plain control text
    const word_start = wordStartBefore(doc.text.items, completion.anchor);
    const already_typed = doc.text.items[word_start..completion.anchor];

    for (completion.items, 0..) |candidate, i| {
        const matched_len = if (std.mem.startsWith(u8, candidate.label, already_typed)) already_typed.len else 0;

        // Inlined `dvui.button()` (rather than the convenience wrapper) so the row's own
        // rect is available afterward for `dvui.scrollTo` — the wrapper doesn't expose it.

        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .expand = .horizontal,
            .gravity_x = 0,
            .margin = dvui.Rect{},
            .border = dvui.Rect{},
            .corners = dvui.CornerRect{},
            .padding = .{ .x = 6, .y = 1, .w = 6, .h = 1 },
            .background = true,
            .id_extra = @intCast(i),
        });
        bw.processEvents();

        if (dvui.focusedWidgetId() == bw.data().id) {
            dvui.focusWidget(te.data().id, null, null);
        }

        if (mouse_moved and bw.hover) dvui.dataSet(null, fw.data().id, "_pending_hover_select", i);
        const is_selected = te.current_completion.?.selected == i;

        if (is_selected) {
            bw.data().borderAndBackground(.{ .fill_color = dvui.themeGet().color(.window, .fill) });
        }
        const click = bw.clicked();

        var row = dvui.box(@src(), .{ .dir = .horizontal }, bw.data().options.strip().override(.{ .expand = .horizontal, .gravity_y = 0.5, .background = false }));

        const kind_color = colorForCompletionKind(ext, candidate.kind);
        dvui.icon(@src(), "completion_kind_icon", iconForCompletionKind(candidate.kind), .{
            .fill_color = kind_color,
            .stroke_color = kind_color,
        }, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .gravity_y = 0.5,
            .margin = .{ .w = 2 },
        });

        const mono_font = dvui.Font.theme(.mono);
        var lbl = dvui.textLayout(@src(), .{ .break_lines = false }, .{ .expand = .horizontal, .gravity_y = 0.5, .background = false, .font = mono_font });
        if (matched_len > 0) {
            lbl.addText(candidate.label[0..matched_len], .{ .color_text = dvui.themeGet().color(.highlight, .fill) });
            lbl.addText(candidate.label[matched_len..], .{ .color_text = dvui.themeGet().color(.control, .text) });
        } else {
            lbl.addText(candidate.label, .{ .color_text = dvui.themeGet().color(.control, .text) });
        }
        lbl.deinit();

        if (candidate.detail.len > 0) {
            // Syntax-highlighted the same way a hover tooltip's code block is (`drawCodeBlock`
            // reuses the current file's own tree-sitter table — the "fizzy palette" — falling
            // back to plain mono text where tree-sitter is unavailable or parsing fails).
            var detail_tl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
                .gravity_y = 0.5,
                .background = false,
                .margin = .{ .x = 10 },
                .max_size_content = .width(120),
            });
            drawCodeBlock(detail_tl, candidate.detail, ext);
            detail_tl.deinit();
        }

        row.deinit();
        bw.drawFocus();

        // Arrow-key navigation moves `completion.selected` without any mouse/scroll input, so
        // the newly-selected row can end up outside the scroll area's visible viewport —
        // `scroll_to_selected` (set only by `TextEntryWidget`'s Up/Down handling, for exactly
        // the frame it changed `selected`) is what triggers this. Deliberately *not* triggered
        // by a hover-driven selection change: a hovered row is already visible by definition,
        // and scrolling to it anyway used to fight the mouse — see `scroll_to_selected`'s doc
        // comment for the feedback loop that created.
        if (is_selected and te.current_completion.?.scroll_to_selected) {
            dvui.scrollTo(.{ .screen_rect = bw.data().borderRectScale().r });
        }

        bw.deinit();

        if (click) {
            te.current_completion.?.selected = i;
            if (te.acceptCompletion()) {
                // The frame's `doc.completion_anchor`/`completion_items` write-back (in
                // `drawEditor`) already ran before `te.draw()`, using the pre-click
                // selection — this call lands after, so it has to clear Document's side of
                // the round-trip directly instead of relying on that write-back to notice.
                doc.clearCompletionItems();
                doc.completion_anchor = null;
            }
            // `clearCompletionItems()` just freed every candidate's owned text — including
            // ones at indices after `i` that this loop hasn't rendered yet this frame.
            // `completion.items` is that same (now stale) array, so continuing the loop
            // would read freed memory on the next iteration. Must stop immediately.
            break;
        }
    }

    scroll.deinit();
    fw.deinit();

    // Info panel: documentation for whichever candidate is currently highlighted, positioned
    // off the dropdown's own on-screen rect and rendered identically to a hover tooltip's
    // content (see `drawHoverBody`) rather than a second bespoke layout. `te.current_completion`
    // is null here if the loop above just accepted a click (which frees every candidate's
    // owned text, `.documentation` included) — nothing to show for a list that's now closed.
    if (te.current_completion) |cur| {
        var selected = cur.items[cur.selected];
        // Many language servers (zls included) send completion candidates with an empty
        // placeholder `documentation` up front and only return the real text on a follow-up
        // per-candidate `completionItem/resolve` request — poll for it every frame the panel
        // would show, same non-blocking convention as `hoverFor`. Falls back to whatever
        // `documentation` the original candidate already carried when no provider resolves
        // (or resolves to nothing new yet).
        if (sdk.host().resolveCompletionDocumentationFor(ext, doc.path, doc.text.items, cur.anchor, cur.selected)) |resolved| {
            selected.documentation = resolved;
        }
        // `detail` alone (e.g. a function's signature with no doc comment above it — common in
        // the stdlib, `std.AutoHashMap` among others) is still worth a panel: `drawCompletion-
        // InfoPanel` already renders `detail`/`documentation` as independent, individually
        // optional sections, so gating on `documentation` alone hid the panel entirely for any
        // candidate zls had a real signature for but no prose doc comment.
        if (selected.detail.len > 0 or selected.documentation.len > 0) {
            drawCompletionInfoPanel(ext, selected, dropdown_screen_rect, id_extra, gpa);
        }
    }
}

/// A hover-tooltip-styled floating panel showing `candidate.documentation`, positioned flush
/// against the right edge of the completion dropdown (`dropdown_screen_rect`) at the same top
/// edge — same visual language as the dropdown itself (fill/corners/shadow), but with no dwell
/// delay or fade: it should track the highlighted candidate exactly, appearing and updating
/// the instant selection changes rather than easing in like a genuine mouse-hover tooltip.
fn drawCompletionInfoPanel(ext: []const u8, candidate: TextEntryWidget.CompletionCandidate, dropdown_screen_rect: dvui.Rect.Physical, id_extra: u64, gpa: std.mem.Allocator) void {
    var panel: dvui.FloatingWidget = undefined;
    panel.init(@src(), .{
        .from = .{ .x = dropdown_screen_rect.x + dropdown_screen_rect.w, .y = dropdown_screen_rect.y },
        .from_gravity_x = 1,
        .from_gravity_y = 1,
    }, .{
        .id_extra = @intCast(id_extra + 0xA000),
        .background = true,
        .color_fill = dvui.themeGet().color(.window, .fill).lighten(if (dvui.themeGet().dark) 5 else -5),
        .corners = dvui.CornerRect.all(6),
        .border = dvui.Rect.all(0),
        .box_shadow = .{
            .color = .black,
            .shrink = 0,
            .corners = dvui.CornerRect.all(6),
            .offset = .{ .x = 0, .y = 2 },
            .fade = 4,
            .alpha = 0.2,
        },
        .max_size_content = .size(hover_tooltip_max_size),
    });
    defer panel.deinit();

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .max_size_content = .size(hover_tooltip_max_size),
        .background = false,
    });
    defer box.deinit();

    // Header: the candidate's own signature, syntax-highlighted as code. Unlike a hover
    // result (one combined string `drawHoverInfoContent` splits into header+body), a
    // completion candidate already carries these as separate fields — `detail` is a type/
    // signature snippet, `documentation` is pure prose with no code header baked in — so
    // there's nothing to split; each is rendered as exactly what it is.
    if (candidate.detail.len > 0) {
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "{s}: {s}", .{ candidate.label, candidate.detail }) catch candidate.label;
        var header_tl = dvui.textLayout(@src(), .{}, .{ .background = false });
        drawCodeBlock(header_tl, header, ext);
        header_tl.deinit();
    }

    if (candidate.documentation.len > 0) {
        const md = sdk.host().getServiceTyped(sdk.services.markdown.Api);
        if (md) |m| {
            m.render(candidate.documentation, gpa, .{ .id_extra = id_extra + 0xA100 }) catch |err| {
                dvui.log.err("completion info: markdown render failed: {any}", .{err});
            };
        } else {
            var scroll = dvui.scrollArea(@src(), .{
                .horizontal_bar = .hide,
            }, .{
                .expand = .both,
                .background = false,
            });
            defer scroll.deinit();
            var body_tl = dvui.textLayout(@src(), .{}, .{ .background = false });
            drawHoverBody(body_tl, candidate.documentation, ext);
            body_tl.deinit();
        }
    }
}

/// Hover tooltip (always-on dwell) + Ctrl/Cmd+click goto-definition, driven by `te.hovered_span`
/// / `te.definition_click` (set during this frame's `te.processEvents()`/`te.draw()` — see
/// `TextEntryWidget.hovered_span` doc comment). Both `hoverFor`/`gotoDefinitionFor` are no-ops
/// (return null) when no language plugin registers the corresponding hook, so this is cheap and
/// silent for any file type without LSP-style support.
fn drawHoverAndGotoDefinition(doc: *Document, ext: []const u8, te: *TextEntryWidget, id_extra: u64, gpa: std.mem.Allocator) void {
    if (te.definition_click) {
        if (te.hovered_span) |span| performGotoDefinition(doc, ext, span.start, te.definition_click_open_side);
    }

    var tt: TooltipWidget = undefined;
    tt.init(@src(), .{
        .active_rect = .{},
        // Once the mouse strays from the source token onto the tooltip itself (unavoidable
        // for a tooltip large enough to need scrolling), keep it open instead of closing —
        // otherwise a large tooltip and the hover detection driving it fight each other.
        .interactive = true,
        .id_extra = id_extra + 0x5000,
        // Double `TooltipWidget`'s 200ms default — hover/gotoDefinition tooltips fire on
        // every tree-sitter token, so a longer dwell avoids flashing one open on a quick
        // pass-through while scanning code.
        .open_delay_ms = 400,
    });
    defer tt.deinit();

    // `active_rect` gates `TooltipWidget.shown()`'s "is the mouse still somewhere relevant"
    // check (both "should the dwell timer even be running" and, once shown, "should this stay
    // open") — scoped to the hovered token's own on-screen rect, not the whole pane, so the
    // tooltip only ever opens directly above/below the actual term and closes once the mouse
    // truly leaves it (or the tooltip itself — `interactive` below is a separate check for
    // that). A raw `te.hover_rect` swapped in only while `te.hovered_span` is non-null very
    // nearly does this on its own, but `hovered_span` goes null on any frame the mouse sits
    // over a character tree-sitter didn't capture as a hoverable token — the `.` separators in
    // a dotted path like `dvui.App.StartOptions` — and `tt` is a fresh local reconstructed
    // every frame, so a naive swap would fall back to `tt.init()`'s `.{}` default on exactly
    // those gap frames and spuriously start closing mid-identifier. `effective_hover_rect`
    // below bridges real one-frame gaps like that with a short memory of the last real
    // `hover_rect`, while still resolving to `.{}` (nothing can ever be "inside" it — dwell
    // never commits, and an already-open tooltip starts its normal close-fade) once the mouse
    // has genuinely been off any token for `hover_grace_ms`.
    const hover_grace_ms: i64 = 150;
    var effective_hover_rect: ?dvui.Rect.Physical = null;
    if (te.hovered_span != null and te.hover_rect != null) {
        const r = te.textLayout.screenRectScale(te.hover_rect.?).r;
        effective_hover_rect = r;
        dvui.dataSet(null, tt.data().id, "_last_hover_rect", r);
        dvui.dataSet(null, tt.data().id, "_last_hover_rect_ns", dvui.frameTimeNS());
    } else if (dvui.dataGet(null, tt.data().id, "_last_hover_rect_ns", i128)) |last_ns| {
        const gap_elapsed_ms = @divTrunc(dvui.frameTimeNS() - last_ns, std.time.ns_per_ms);
        if (gap_elapsed_ms < hover_grace_ms) {
            effective_hover_rect = dvui.dataGet(null, tt.data().id, "_last_hover_rect", dvui.Rect.Physical);
            // Ask for another frame so this gets re-checked once the grace window elapses
            // even if the mouse doesn't move again (no further position events would
            // otherwise fire to re-run this check).
            dvui.refresh(null, @src(), tt.data().id);
        }
    }
    tt.init_options.active_rect = effective_hover_rect orelse .{};
    // Anchors directly to the term's own rect (or its very recent memory during a gap frame),
    // never the mouse position — `TooltipWidget.shown()` only falls back to the mouse point if
    // this stays null for the tooltip's entire (re)opening, which shouldn't happen in practice
    // since the dwell timer above can't commit without a non-`.{}` `active_rect` to begin with.
    tt.init_options.anchor_rect = effective_hover_rect;

    // Keep `_last_span`/`_query_span`/`_pending_query_span` alive across a momentary hover
    // *gap* — a frame where `te.hovered_span` is null even though the mouse is still resting
    // within the same identifier's visual span, e.g. sitting over a `.` separator in a
    // tightly-packed dotted path like `dvui.App.StartOptions`, which isn't itself a
    // tree-sitter-captured/hoverable token. dvui's per-widget data store (`Window.begin`'s
    // `data_store.reset`, once every real frame) evicts any key that wasn't read *or* written
    // since the previous reset — so without this touch, a single such gap frame would silently
    // wipe out whatever `_query_span`/`_pending_query_span` debounce progress was mid-flight,
    // restarting the "settle for two frames" cycle from scratch. That's the actual root cause
    // of hover getting stuck on "Just a moment" forever for compound identifiers: each gap
    // frame resets progress before it can ever commit, even though the LSP response for the
    // span it was about to commit to had long since arrived and been cached. A plain `dataGet`
    // counts as a touch (`TrackingAutoHashMap`'s `.get_and_put` mode), so reading-and-discarding
    // here is enough; no separate write needed.
    _ = dvui.dataGet(null, tt.data().id, "_last_span", TextEntryWidget.Span);
    _ = dvui.dataGet(null, tt.data().id, "_query_span", TextEntryWidget.Span);
    _ = dvui.dataGet(null, tt.data().id, "_pending_query_span", TextEntryWidget.Span);

    // `hovered_span` requires the mouse to be over the *source token*, so it goes null the
    // instant the mouse moves onto the tooltip itself — exactly the case `interactive` above
    // is meant to keep open. Remember the last real span (keyed to this tooltip's own widget
    // id, so it survives across frames and doesn't leak into other panes/splits) rather than
    // gating everything below on `hovered_span` directly, and always call `tt.shown()` so its
    // own mouse-over-tooltip tracking gets a chance to run every frame, not just frames where
    // the source token happens to still be hovered.
    if (te.hovered_span) |span| {
        dvui.dataSet(null, tt.data().id, "_last_span", span);

        // `_query_span` is deliberately a *debounced* value, not the raw per-frame
        // `hovered_span` above — the token actually sent to the language plugin. A single
        // frame's hit-test landing on a different token than the last isn't necessarily real
        // motion onto a new symbol: sub-pixel jitter (trackpad noise, or just resting near the
        // boundary between two adjacent tokens in a tightly-packed dotted path like
        // `dvui.App.StartOptions`) can flip the hit-tested span every other frame even with an
        // effectively stationary mouse — or, just as commonly, the mouse's path *toward* the
        // tooltip itself briefly grazes some unrelated underlying token it has to cross on the
        // way. If the query key (or the tooltip's reanchor/dwell-restart below) flapped in
        // lockstep with every such blip, neither would ever settle: each flap starts a *new*
        // LSP request for a *different* cache key (so the tooltip perpetually shows "Just a
        // moment" for whichever key is currently in flight even though earlier requests for
        // neighboring tokens genuinely did complete), and — the reanchor case — each blip was
        // *also* forcibly resetting `TooltipWidget`'s dwell timer back to zero every time the
        // mouse so much as grazed a different token en route to the content it was trying to
        // read, so the tooltip could get shown, hit a real cached result, and then immediately
        // discard all of it and restart a fresh 400ms dwell for an incidental token nobody
        // meant to hover. Require the same span to repeat on two consecutive frames before it
        // becomes the query key — a genuine move onto a new token holds for many frames, so
        // this costs at most one imperceptible frame of extra latency.
        const query_span = dvui.dataGet(null, tt.data().id, "_query_span", TextEntryWidget.Span);
        const query_matches = if (query_span) |qs| (qs.start == span.start and qs.end == span.end) else false;
        var query_span_committed = false;
        if (!query_matches) {
            const pending = dvui.dataGet(null, tt.data().id, "_pending_query_span", TextEntryWidget.Span);
            const pending_matches = if (pending) |p| (p.start == span.start and p.end == span.end) else false;
            if (pending_matches) {
                dvui.dataSet(null, tt.data().id, "_query_span", span);
                dvui.dataRemove(null, tt.data().id, "_pending_query_span");
                query_span_committed = true;
            } else {
                dvui.dataSet(null, tt.data().id, "_pending_query_span", span);
            }
        } else {
            dvui.dataRemove(null, tt.data().id, "_pending_query_span");
        }

        // Driven by the *debounced* commit above, not a raw per-frame span comparison — see
        // `query_span_committed`'s derivation for why: re-anchor to the current mouse position
        // and re-run the open dwell delay only once motion onto a new token has actually been
        // confirmed (held for two consecutive frames), not on every transient blip. See
        // `TooltipWidget.InitOptions.reanchor`.
        tt.init_options.reanchor = query_span_committed;
    }

    // Queried *before* `tt.shown()` (its result reused below, not re-queried) so
    // `tt.init_options.suppress` can be set ahead of time — see its doc comment for why the
    // ordering matters: `shown()` only skips ever committing to show at all if it already
    // knows there's nothing to show *before* the dwell period elapses. A confirmed-empty
    // answer suppresses unconditionally, open or not — there's no content to interact with
    // regardless of where the mouse is.
    const query_span = dvui.dataGet(null, tt.data().id, "_query_span", TextEntryWidget.Span);
    const hover = if (query_span) |span| sdk.host().hoverFor(ext, doc.path, doc.text.items, span.start) else null;
    tt.init_options.suppress = if (hover) |h| h.text.len == 0 else false;

    if (tt.shown()) {
        if (query_span) |span| {
            if (hover) |h| {
                if (h.text.len > 0) {
                    drawHoverContent(doc, ext, span, h.text, id_extra, gpa);
                }
                // Empty text: suppressed via `tt.init_options.suppress` above — `shown()`
                // either never committed to showing, or is mid-close-fade with nothing left
                // to draw. Either way, nothing to do here.
            } else {
                drawHoverLoading(id_extra);
            }
        }
    }
}

/// Placeholder shown in place of real hover content while a provider's lookup is still in
/// flight — see the call site's doc comment for why this and the real content are mutually
/// exclusive per frame rather than ever shown together.
fn drawHoverLoading(id_extra: u64) void {
    dvui.label(@src(), "Just a moment...", .{}, .{
        .color_text = dvui.themeGet().color(.window, .text).opacity(0.6),
        .id_extra = @intCast(id_extra + 0x7400),
    });
}

/// Looks up and jumps to the definition of the token at `byte_offset` — Ctrl/Cmd+click and
/// Shift+Ctrl/Cmd+click both drive this. Silently does nothing if no language plugin resolves
/// a definition here. `open_side` requests a new grouping/split for a not-yet-open target,
/// mirroring the file tree's "Open to the side" — see `Workbench.svcRevealPosition`'s doc
/// comment for why an already-open target ignores it and just gets focused.
fn performGotoDefinition(doc: *Document, ext: []const u8, byte_offset: usize, open_side: bool) void {
    const loc = sdk.host().gotoDefinitionFor(ext, doc.path, doc.text.items, byte_offset) orelse return;
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse return;
    _ = wb.revealPosition(loc.path, loc.line, loc.character, open_side) catch |err| {
        dvui.log.err("gotoDefinition: revealPosition failed: {any}", .{err});
    };
}

/// Renders hover content into the tooltip. zls (and similar) embed a `Go to [Type](file://…)`
/// link row in the markdown body — that row is stripped out here and redrawn as a pinned
/// footer under the scrollable signature/docs, always led by a link for the hovered term
/// itself (`Go to Io | Allocator | …`). Plain click reveals in place; Ctrl/Cmd+click (or
/// middle-click) opens to the side. The vertical box is owned here so the footer lands
/// *inside* it below the header/body — not as a sibling after the box has already closed.
fn drawHoverContent(doc: *Document, ext: []const u8, span: TextEntryWidget.Span, hover_text: []const u8, id_extra: u64, gpa: std.mem.Allocator) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .max_size_content = .size(hover_tooltip_max_size),
        .background = false,
    });
    defer box.deinit();

    const arena = dvui.currentWindow().arena();
    const split = splitHoverGoToLinks(hover_text, arena) catch HoverGoToSplit{ .body = hover_text, .links = &.{} };
    drawHoverInfoContent(ext, split.body, id_extra, gpa);

    const primary_label = if (span.end <= doc.text.items.len and span.start < span.end)
        doc.text.items[span.start..span.end]
    else
        "";
    // Function / builtin hovers already show the full signature above — linking the name
    // itself is redundant (and for `@import`-style builtins, gotoDefinition has nowhere to
    // go). Prefer the referenced parameter/return types zls embeds instead.
    const show_primary = primary_label.len > 0 and !hoverLooksLikeFunction(hover_text) and !isZigBuiltinLabel(primary_label);
    drawHoverGoToFooter(doc, ext, span.start, if (show_primary) primary_label else "", split.links, id_extra);
}

/// Header (code) + body (markdown or plain prose) only — no surrounding box, so callers can
/// stack whatever else they need (a footer, in `drawHoverContent`'s case; nothing, in
/// `drawCompletionInfoPanel`'s) inside their own vertical box alongside it. Walks `hover_text`
/// as an ordered sequence of ```-fenced code / prose segments (see `nextHoverSegment`) rather
/// than assuming a single header-then-body shape — a field-access hover (`a.b.c`) can carry
/// several declaration signatures back to back (zls's `hoverDefinitionFieldAccess` joins one
/// section per matching declaration), each its own fence. When the `"markdown"` service is
/// registered (native only — see `sdk.services.markdown`'s doc comment), each prose segment
/// renders through cmark-gfm for real links/lists/bold, with every code segment kept on our own
/// tree-sitter-colored renderer (cmark doesn't syntax-highlight fenced code — see
/// `drawCodeBlock`). Falls back to appending everything into one shared text layout (web build,
/// or markdown plugin disabled/uninstalled).
///
/// The *first* segment, when it's code, renders as a static header above everything else
/// rather than being folded into the scrollable body below — that first fence is always the
/// hovered symbol's own signature (the one-line answer to "what is this"), so it should stay
/// on screen the same way VSCode pins it, no matter how far the prose/additional-declarations
/// body underneath has been scrolled. Prose-first hovers (rare) have no natural header to pin
/// and fall straight through to the scrollable body unchanged.
fn drawHoverInfoContent(ext: []const u8, hover_text: []const u8, id_extra: u64, gpa: std.mem.Allocator) void {
    const md = sdk.host().getServiceTyped(sdk.services.markdown.Api);

    var body_text = hover_text;
    if (nextHoverSegment(hover_text)) |first| {
        const trimmed = std.mem.trim(u8, first.content, " \n\r");
        if (first.is_code and trimmed.len > 0) {
            var header_tl = dvui.textLayout(@src(), .{}, .{ .background = false });
            drawCodeBlock(header_tl, trimmed, ext);
            header_tl.deinit();
            body_text = first.rest;
        }
    }
    if (body_text.len == 0) return;

    // `TooltipWidget.install()` deliberately breaks out of whatever clip it was drawn under
    // (`dvui.clipSet(dvui.windowRectPixels())` — a tooltip must not be cut off by the
    // scrollable code pane it's hovering over) and this content sits directly in the outer
    // `hover_tooltip_max_size`-capped box with no clip of its own. `max_size_content` only
    // caps *layout* (how much space this box asks its parent for) — it does not clip
    // rendering, so content taller than that cap simply keeps drawing past it instead of
    // being cut off. For `drawHoverContent`'s caller, that pushes the "Go to …" footer
    // (this content's next sibling in that outer box) below the tooltip's actual
    // visible/painted bounds on any hover long enough to overflow.
    //
    // Explicit hardcoded cap, not `.expand = .both` relying on `BoxWidget`'s cross-frame
    // weight proration to work out "remaining space after the header and footer" on its own
    // — tried that (it's the normal, usually-correct dvui idiom, and is exactly what the
    // footer alone already relied on before the header was added above) and it didn't
    // reliably converge here in practice: the footer went back to not being drawn. Since nothing
    // actually *clips* this content (see above — there's no clip to rely on either way), a
    // fixed cap here doesn't lose anything a "smarter" computed one would have gained: it just
    // makes the scroll area's own height a known, frame-independent quantity, so the footer
    // (this function's caller's next sibling, right after this whole call returns) always ends
    // up at a deterministic offset from the top instead of depending on box-proration timing
    // that, empirically, isn't dependable for this specific header+scroll+footer shape.
    const hover_scroll_max_h: f32 = 220;
    var scroll = dvui.scrollArea(@src(), .{
        .horizontal_bar = .hide,
    }, .{
        .expand = .both,
        .max_size_content = .size(.{ .w = hover_tooltip_max_size.w, .h = hover_scroll_max_h }),
        // ScrollAreaWidget defaults to painting its own opaque, square background — left on,
        // it completely covers the tooltip's own rounded/colored background painted in
        // TooltipWidget.install().
        .background = false,
    });
    defer scroll.deinit();

    if (md) |m| {
        // `ScrollContainerWidget` only tolerates one expanding child, and it must be the last
        // one — a field-access hover (`a.b.c`) can carry several declaration signatures back
        // to back (see this function's own doc comment on `zls`'s `hoverDefinitionFieldAccess`),
        // each becoming its own `textLayout`/`m.render` call below. Direct children of `scroll`
        // above, that tripped the "got child after expanded child" check on every frame a
        // multi-segment hover was open — each segment defaults to an expanding child, and only
        // the first one is ever "last". A single inner `box` gives the scroll area exactly one
        // (non-expanding-conflict) child; the box itself has no such restriction and packs
        // however many segments it's given.
        var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .background = false });
        defer body.deinit();

        var rest = body_text;
        var seg_i: u64 = 0;
        while (nextHoverSegment(rest)) |seg| : (seg_i += 1) {
            rest = seg.rest;
            const trimmed = std.mem.trim(u8, seg.content, " \n\r");
            if (trimmed.len == 0) continue;
            if (seg.is_code) {
                var tl = dvui.textLayout(@src(), .{}, .{ .background = false, .id_extra = @intCast(id_extra + 0x7000 + seg_i) });
                drawCodeBlock(tl, trimmed, ext);
                tl.deinit();
            } else {
                m.render(trimmed, gpa, .{ .id_extra = id_extra + 0x7000 + seg_i }) catch |err| {
                    dvui.log.err("hover: markdown render failed: {any}", .{err});
                };
            }
        }
    } else {
        var tl = dvui.textLayout(@src(), .{}, .{ .background = false });
        defer tl.deinit();
        var rest = body_text;
        while (nextHoverSegment(rest)) |seg| {
            rest = seg.rest;
            if (seg.is_code) {
                drawCodeBlock(tl, seg.content, ext);
            } else if (seg.content.len > 0) {
                tl.addText(seg.content, .{});
            }
        }
    }
}

/// Footer: `Go to` in plain text, then highlight-colored links. Non-function hovers lead with
/// the hovered term itself (same gotoDefinition as Ctrl/Cmd+click); function hovers skip that
/// (the signature is already in the header) and only list referenced types from zls — skipping
/// base/primitive types that aren't useful to jump to. Plain click reveals in place;
/// Ctrl/Cmd+click or middle-click opens to the side.
fn drawHoverGoToFooter(
    doc: *Document,
    ext: []const u8,
    byte_offset: usize,
    primary_label: []const u8,
    links: []const HoverGoToLink,
    id_extra: u64,
) void {
    // Count how many links we'll actually draw so we can skip an empty footer entirely.
    var link_count: usize = if (primary_label.len > 0) 1 else 0;
    for (links) |link| {
        if (primary_label.len > 0 and std.mem.eql(u8, link.label, primary_label)) continue;
        if (isBaseTypeLabel(link.label) or isZigBuiltinLabel(link.label)) continue;
        link_count += 1;
    }
    if (link_count == 0) return;

    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .background = false,
        .margin = .{ .y = 6 },
        .id_extra = @intCast(id_extra + 0x7100),
    });
    defer tl.deinit();

    const plain_font = dvui.Font.theme(.body);
    const link_font = plain_font.withUnderline(.{});
    const plain: dvui.Options = .{ .font = plain_font, .color_text = dvui.themeGet().color(.window, .text) };
    const link_opts: dvui.Options = .{ .font = link_font, .color_text = dvui.themeGet().color(.highlight, .fill) };

    tl.addText("Go to ", plain);

    var drawn: usize = 0;
    if (primary_label.len > 0) {
        if (tl.addTextClick(primary_label, link_opts)) |click_event| {
            performGotoDefinition(doc, ext, byte_offset, clickOpensToSide(click_event));
        }
        drawn += 1;
    }

    for (links) |link| {
        if (primary_label.len > 0 and std.mem.eql(u8, link.label, primary_label)) continue;
        if (isBaseTypeLabel(link.label) or isZigBuiltinLabel(link.label)) continue;
        if (drawn > 0) tl.addText(" | ", plain);
        if (tl.addTextClick(link.label, link_opts)) |click_event| {
            revealHoverFileUri(link.url, clickOpensToSide(click_event));
        }
        drawn += 1;
    }
}

fn clickOpensToSide(click_event: dvui.Event.EventTypes) bool {
    return click_event == .mouse and (click_event.mouse.button == .middle or click_event.mouse.mod.matchBind("ctrl/cmd"));
}

/// True when the hover's leading code fence looks like a function signature (`fn name(`…),
/// so the footer can skip linking the function name itself. Also treats Zig builtin
/// signatures (`@import(…) type`) the same way — they aren't `fn …` but still show a full
/// definition in the header with nowhere useful for goto to land.
fn hoverLooksLikeFunction(hover_text: []const u8) bool {
    if (nextHoverSegment(hover_text)) |first| {
        if (!first.is_code) return false;
        const t = std.mem.trim(u8, first.content, " \t\n\r");
        // Builtin: `@name(`…
        if (t.len > 1 and t[0] == '@' and std.mem.indexOfScalar(u8, t, '(') != null) return true;
        // `pub fn foo(`, `fn foo(`, `inline fn (`, export/extern variants, etc.
        if (std.mem.indexOf(u8, t, "fn ")) |_| {
            return std.mem.indexOfScalar(u8, t, '(') != null;
        }
        if (std.mem.startsWith(u8, t, "fn(") or std.mem.startsWith(u8, t, "fn (")) return true;
    }
    return false;
}

/// Zig `@`-builtins (`@import`, `@sizeOf`, …) — goto has no definition to open.
fn isZigBuiltinLabel(label: []const u8) bool {
    return label.len > 0 and label[0] == '@';
}

/// Filters zls "Go to" labels that are Zig primitives / trivial composites (`u8`, `[]const u8`,
/// `?*anyopaque`, …) — jumping to those isn't useful. Named types (`Allocator`, `Io`) pass.
fn isBaseTypeLabel(label: []const u8) bool {
    var t = std.mem.trim(u8, label, " \t");
    // Peel pointer/optional/slice/const wrappers until a core name remains.
    while (t.len > 0) {
        if (t[0] == '?' or t[0] == '*') {
            t = std.mem.trimStart(u8, t[1..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, t, "[]")) {
            t = std.mem.trimStart(u8, t[2..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, t, "const ")) {
            t = t["const ".len..];
            continue;
        }
        if (std.mem.startsWith(u8, t, "volatile ")) {
            t = t["volatile ".len..];
            continue;
        }
        if (std.mem.startsWith(u8, t, "allowzero ")) {
            t = t["allowzero ".len..];
            continue;
        }
        break;
    }
    if (t.len == 0) return true;

    const primitives = [_][]const u8{
        "u8",         "u16",         "u32",          "u64",          "u128",
        "i8",         "i16",         "i32",          "i64",          "i128",
        "f16",        "f32",         "f64",          "f80",          "f128",
        "usize",      "isize",       "c_char",       "c_short",      "c_ushort",
        "c_int",      "c_uint",      "c_long",       "c_ulong",      "c_longlong",
        "c_ulonglong", "c_longdouble", "bool",        "void",         "noreturn",
        "type",       "anyopaque",   "anyerror",     "anytype",      "comptime_int",
        "comptime_float",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, t, p)) return true;
    }
    return false;
}

const HoverGoToLink = struct { label: []const u8, url: []const u8 };
const HoverGoToSplit = struct { body: []const u8, links: []const HoverGoToLink };

/// Pulls every zls-style `Go to [Name](url) | [Name](url)` row out of `hover_text` so the
/// body can render without them and the footer can host a single merged link row. Field-
/// access hovers may carry several such rows (one per joined declaration); links are kept in
/// first-seen order and de-duped by URL. Labels/urls are slices into `hover_text`; `body` is
/// either the original slice (nothing to strip) or arena-allocated.
fn splitHoverGoToLinks(hover_text: []const u8, arena: std.mem.Allocator) !HoverGoToSplit {
    var links: std.ArrayListUnmanaged(HoverGoToLink) = .empty;
    var remove_spans: std.ArrayListUnmanaged(struct { start: usize, end: usize }) = .empty;

    var search_from: usize = 0;
    while (findGoToSpan(hover_text, search_from)) |span| {
        try parseGoToLinks(hover_text[span.links_start..span.end], &links, arena);
        try remove_spans.append(arena, .{ .start = span.start, .end = span.end });
        search_from = span.end;
    }

    if (remove_spans.items.len == 0) {
        return .{ .body = hover_text, .links = &.{} };
    }

    var body: std.ArrayListUnmanaged(u8) = .empty;
    var cursor: usize = 0;
    for (remove_spans.items) |span| {
        if (span.start > cursor) try body.appendSlice(arena, hover_text[cursor..span.start]);
        cursor = span.end;
    }
    if (cursor < hover_text.len) try body.appendSlice(arena, hover_text[cursor..]);

    // Collapse runs of blank lines left behind where a Go-to row was excised between a code
    // fence and the doc comment that followed it.
    const compact = try compactBlankLines(arena, body.items);

    return .{ .body = compact, .links = try links.toOwnedSlice(arena) };
}

const GoToSpan = struct { start: usize, end: usize, links_start: usize };

fn findGoToSpan(src: []const u8, from: usize) ?GoToSpan {
    const needle = "Go to [";
    var i = from;
    while (i + needle.len <= src.len) : (i += 1) {
        if (!std.mem.startsWith(u8, src[i..], needle)) continue;
        const links_start = i + "Go to ".len;
        const end = endOfGoToLinks(src, links_start) orelse continue;
        var start = i;
        if (start >= 2 and src[start - 2] == '\n' and src[start - 1] == '\n') {
            start -= 2;
        } else if (start >= 1 and src[start - 1] == '\n') {
            start -= 1;
        }
        return .{ .start = start, .end = end, .links_start = links_start };
    }
    return null;
}

/// Extends past a run of `[label](url)` links separated by ` | `, starting at the first `[`.
fn endOfGoToLinks(src: []const u8, links_start: usize) ?usize {
    var i = links_start;
    var found_one = false;
    while (i < src.len and src[i] == '[') {
        const close_bracket = std.mem.indexOfScalarPos(u8, src, i + 1, ']') orelse break;
        if (close_bracket + 1 >= src.len or src[close_bracket + 1] != '(') break;
        const close_paren = std.mem.indexOfScalarPos(u8, src, close_bracket + 2, ')') orelse break;
        i = close_paren + 1;
        found_one = true;
        if (std.mem.startsWith(u8, src[i..], " | ")) {
            i += 3;
            continue;
        }
        break;
    }
    return if (found_one) i else null;
}

fn parseGoToLinks(links_text: []const u8, out: *std.ArrayListUnmanaged(HoverGoToLink), arena: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < links_text.len and links_text[i] == '[') {
        const close_bracket = std.mem.indexOfScalarPos(u8, links_text, i + 1, ']') orelse break;
        if (close_bracket + 1 >= links_text.len or links_text[close_bracket + 1] != '(') break;
        const close_paren = std.mem.indexOfScalarPos(u8, links_text, close_bracket + 2, ')') orelse break;
        const label = links_text[i + 1 .. close_bracket];
        const url = links_text[close_bracket + 2 .. close_paren];
        // De-dupe by URL — field-access joins can repeat the same referenced type.
        var seen = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing.url, url)) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(arena, .{ .label = label, .url = url });
        i = close_paren + 1;
        if (std.mem.startsWith(u8, links_text[i..], " | ")) {
            i += 3;
            continue;
        }
        break;
    }
}

fn compactBlankLines(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var newline_run: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\n') {
            newline_run += 1;
            if (newline_run <= 2) try out.append(arena, '\n');
            continue;
        }
        if (src[i] == '\r') continue;
        newline_run = 0;
        try out.append(arena, src[i]);
    }
    // Trim leading/trailing whitespace left after excision.
    return std.mem.trim(u8, out.items, " \t\n\r");
}

/// Opens a hover/footer `file://` link (with optional `#L` / `#L…C…` fragment) via workbench.
/// Same routing the markdown renderer uses for in-body links — kept here so the footer doesn't
/// depend on going through a full markdown re-render just to host a one-line link row.
fn revealHoverFileUri(url: []const u8, open_side: bool) void {
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse return;
    const arena = dvui.currentWindow().arena();
    const parsed = parseHoverFileUri(arena, url) orelse return;
    const line: u32 = if (parsed.line_1based > 0) parsed.line_1based - 1 else 0;
    const character: u32 = if (parsed.character_1based > 0) parsed.character_1based - 1 else 0;
    _ = wb.revealPosition(parsed.path, line, character, open_side) catch |err| {
        dvui.log.err("hover: revealPosition failed for {s}: {any}", .{ parsed.path, err });
    };
}

fn parseHoverFileUri(arena: std.mem.Allocator, url: []const u8) ?struct { path: []const u8, line_1based: u32, character_1based: u32 } {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) return null;

    var path_part = url[prefix.len..];
    var line_1based: u32 = 0;
    var character_1based: u32 = 0;
    if (std.mem.indexOfScalar(u8, path_part, '#')) |hash| {
        const frag = path_part[hash + 1 ..];
        path_part = path_part[0..hash];
        if (frag.len >= 2 and (frag[0] == 'L' or frag[0] == 'l')) {
            var i: usize = 1;
            var line: u32 = 0;
            while (i < frag.len and frag[i] >= '0' and frag[i] <= '9') : (i += 1) {
                line = line * 10 + (frag[i] - '0');
            }
            line_1based = line;
            if (i < frag.len and (frag[i] == 'C' or frag[i] == 'c' or frag[i] == ':')) {
                i += 1;
                var col: u32 = 0;
                while (i < frag.len and frag[i] >= '0' and frag[i] <= '9') : (i += 1) {
                    col = col * 10 + (frag[i] - '0');
                }
                character_1based = col;
            }
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < path_part.len) {
        if (path_part[i] == '%' and i + 2 < path_part.len) {
            const byte = std.fmt.parseInt(u8, path_part[i + 1 .. i + 3], 16) catch {
                out.append(arena, path_part[i]) catch return null;
                i += 1;
                continue;
            };
            out.append(arena, byte) catch return null;
            i += 3;
        } else {
            out.append(arena, path_part[i]) catch return null;
            i += 1;
        }
    }
    const path = out.toOwnedSlice(arena) catch return null;
    return .{ .path = path, .line_1based = line_1based, .character_1based = character_1based };
}

const HoverSegment = struct { is_code: bool, content: []const u8, rest: []const u8 };

/// Returns the next segment of `text` — code between a ```-fenced pair (language tag on the
/// opening fence, e.g. "zig" in "```zig\n", stripped rather than treated as code) or prose
/// outside any fence — plus the unconsumed remainder, or null once `text` is exhausted. Meant
/// to be called in a loop (`rest = seg.rest`) to walk a whole hover response as an ordered
/// sequence of segments; see `drawHoverInfoContent`'s doc comment for why a single fixed
/// header/body split doesn't hold in general.
fn nextHoverSegment(hover_text: []const u8) ?HoverSegment {
    if (hover_text.len == 0) return null;
    if (std.mem.indexOf(u8, hover_text, "```")) |fence_idx| {
        if (fence_idx > 0) {
            return .{ .is_code = false, .content = hover_text[0..fence_idx], .rest = hover_text[fence_idx..] };
        }
        var after = hover_text[3..];
        if (std.mem.indexOfScalar(u8, after, '\n')) |nl| after = after[nl + 1 ..];
        const close_idx = std.mem.indexOf(u8, after, "```");
        const code = if (close_idx) |c| after[0..c] else after;
        const rest = if (close_idx) |c| after[c + 3 ..] else "";
        return .{ .is_code = true, .content = code, .rest = rest };
    }
    return .{ .is_code = false, .content = hover_text, .rest = "" };
}

/// Draws doc-comment prose, splitting on any markdown fenced-code-block markers (` ``` `) the
/// comment embeds of its own (e.g. a usage example — see `dvui.App`'s hover for a real one):
/// prose in the tooltip's normal font, fenced code in syntax-highlighted monospace.
fn drawHoverBody(tl: *dvui.TextLayoutWidget, body_text: []const u8, ext: []const u8) void {
    const fence = "```";
    var rest = body_text;
    var in_code = false;
    while (rest.len > 0) {
        if (std.mem.indexOf(u8, rest, fence)) |idx| {
            const segment = rest[0..idx];
            if (in_code) {
                drawCodeBlock(tl, segment, ext);
            } else if (segment.len > 0) {
                tl.addText(segment, .{});
            }
            rest = rest[idx + fence.len ..];
            in_code = !in_code;
        } else {
            if (in_code) {
                drawCodeBlock(tl, rest, ext);
            } else {
                tl.addText(rest, .{});
            }
            break;
        }
    }
}

/// Draws one fenced code block in monospace, syntax-highlighted with whatever tree-sitter
/// grammar the hovered document's own language plugin registered (the same one the main
/// editor uses for `ext`) — falls back to plain (uncolored) monospace when no grammar is
/// registered, tree-sitter is unavailable on this build, or highlighting the snippet fails
/// for any reason.
fn drawCodeBlock(tl: *dvui.TextLayoutWidget, code_in: []const u8, ext: []const u8) void {
    const code = std.mem.trim(u8, code_in, "\n\r");
    if (code.len == 0) return;

    const mono_opts: dvui.Options = .{ .font = dvui.Font.theme(.mono) };

    if (dvui.useTreeSitter) {
        if (sdk.host().treeSitterHighlightFor(ext)) |ts| {
            if (drawHighlightedCode(tl, code, ts, mono_opts)) return;
        }
    }

    tl.addText(code, mono_opts);
}

/// Compiling a `TSQuery` from source (`ts_query_new`) parses the whole query text (~290
/// lines for `zig.scm`) — cheap once, but `drawHighlightedCode` used to do it fresh every
/// single call, which was fine back when a hover tooltip closed almost immediately but became
/// a genuine "every frame does real work" cost once tooltips started staying open for as long
/// as the mouse rests on them (dwelling to read a doc comment easily lasts seconds, i.e.
/// hundreds of frames). Mirrors how `TextEntryWidget` persists its own compiled query across
/// frames (`dvui.dataGetPtr`/`dataSet` keyed to the widget) — except this cache only needs to
/// key on `language`, since `ts.queries` (the source text) is a compile-time constant for a
/// given grammar and the *code being highlighted* (which does change per hover) only affects
/// parsing, not query compilation.
const HoverQueryCache = struct {
    language: ?*anyopaque = null,
    query: ?*dvui.c.TSQuery = null,
};
var hover_query_cache: HoverQueryCache = .{};

fn hoverQueryFor(ts: sdk.TreeSitterHighlight) ?*dvui.c.TSQuery {
    if (hover_query_cache.language == ts.language) return hover_query_cache.query;
    if (hover_query_cache.query) |q| dvui.c.ts_query_delete(q);
    var error_offset: u32 = undefined;
    var error_type: dvui.c.TSQueryError = undefined;
    const query = dvui.c.ts_query_new(@ptrCast(@alignCast(ts.language)), ts.queries.ptr, @intCast(ts.queries.len), &error_offset, &error_type);
    hover_query_cache = .{ .language = ts.language, .query = query };
    return query;
}

/// Parses `code` fresh with the given grammar (small and effectively static for as long as
/// a given hover is shown, so a full re-parse per frame is cheap) and walks the cached
/// highlight query's captures, mirroring `TextEntryWidget`'s own highlight loop (reusing its
/// `TreeSitterParser.QueryCursorCaptureIterator` for the exact same overlapping-capture
/// handling). Returns false (drawing nothing) on any tree-sitter setup failure, leaving the
/// plain-monospace fallback in `drawCodeBlock` to handle it.
fn drawHighlightedCode(tl: *dvui.TextLayoutWidget, code: []const u8, ts: sdk.TreeSitterHighlight, mono_opts: dvui.Options) bool {
    if (dvui.useTreeSitter) {
        const p = dvui.c.ts_parser_new() orelse return false;
        defer dvui.c.ts_parser_delete(p);
        _ = dvui.c.ts_parser_set_language(p, @ptrCast(@alignCast(ts.language)));
        const tree = dvui.c.ts_parser_parse_string(p, null, code.ptr, @intCast(code.len)) orelse return false;
        defer dvui.c.ts_tree_delete(tree);

        const query = hoverQueryFor(ts) orelse return false;

        const ts_parser: TextEntryWidget.TreeSitterParser = .{ .parser = p, .tree = tree, .query = query };

        const root = dvui.c.ts_tree_root_node(tree);
        const qc = dvui.c.ts_query_cursor_new() orelse return false;
        defer dvui.c.ts_query_cursor_delete(qc);
        // See `TextEntryWidget.tree_sitter_match_limit`'s doc comment — same unbounded-growth
        // pathology is possible here in principle (a short snippet is unlikely to trigger it,
        // but the cursor default has no cap either way, so match every other call site).
        dvui.c.ts_query_cursor_set_match_limit(qc, TextEntryWidget.tree_sitter_match_limit);
        dvui.c.ts_query_cursor_exec(qc, query, root);

        var iter = ts_parser.queryCursorCaptureIterator(qc, code);
        var start: usize = 0;
        while (iter.next()) |match| {
            const nstart = dvui.c.ts_node_start_byte(match.node);
            const nend = dvui.c.ts_node_end_byte(match.node);
            if (start < nstart) {
                tl.addText(code[start..nstart], mono_opts);
            } else if (nstart < start) {
                continue;
            }

            var opts = mono_opts;
            const capture_name = match.captureName();
            for (0..ts.highlights.len) |i| {
                const sh = ts.highlights[ts.highlights.len - i - 1];
                if (std.mem.startsWith(u8, capture_name, sh.name)) {
                    opts = mono_opts.override(sh.opts);
                    break;
                }
            }

            tl.addText(code[nstart..nend], opts);
            start = nend;
        }

        if (start < code.len) {
            tl.addText(code[start..code.len], mono_opts);
        }

        return true;
    }
    return false;
}

fn docFromCtx(ctx: *anyopaque) *Document {
    return @ptrCast(@alignCast(ctx));
}
fn editNotifyBegin(ctx: *anyopaque) void {
    docFromCtx(ctx).history.begin();
}
fn editNotifyRemoved(ctx: *anyopaque, pos: usize, bytes: []const u8) void {
    docFromCtx(ctx).history.noteRemoved(sdk.allocator(), pos, bytes);
}
fn editNotifyInserted(ctx: *anyopaque, pos: usize, bytes: []const u8) void {
    docFromCtx(ctx).history.noteInserted(sdk.allocator(), pos, bytes);
}
fn editNotifyEnd(ctx: *anyopaque) void {
    docFromCtx(ctx).history.end(sdk.allocator());
}

const max_text_bytes: usize = 64 * 1024 * 1024;

fn lineNumberColumnWidth(line_count: usize, font: dvui.Font) f32 {
    var buf: [16]u8 = undefined;
    const sample = std.fmt.bufPrint(&buf, "{d}", .{line_count}) catch "9999";
    return line_number_pad_left + font.textSize(sample).w + text_gap_after_numbers;
}

fn drawScrollEdgeShadows(
    vertical_rs: dvui.RectScale,
    horizontal_rs: dvui.RectScale,
    si: *const dvui.ScrollInfo,
) void {
    const vertical_scroll = si.offset(.vertical);
    const horizontal_scroll = si.offset(.horizontal);

    if (vertical_scroll > 0.0 and !vertical_rs.r.empty()) {
        core.dvui.drawEdgeShadow(vertical_rs, .top, .{});
    }
    if (si.virtual_size.h > si.viewport.h and !vertical_rs.r.empty()) {
        core.dvui.drawEdgeShadow(vertical_rs, .bottom, .{});
    }
    if (si.virtual_size.w > si.viewport.w and !horizontal_rs.r.empty()) {
        core.dvui.drawEdgeShadow(horizontal_rs, .right, .{});
    }
    if (horizontal_scroll > 0.0 and !horizontal_rs.r.empty()) {
        core.dvui.drawEdgeShadow(horizontal_rs, .left, .{});
    }
}

fn drawLineNumbers(
    rs: dvui.RectScale,
    line_count: usize,
    scroll_y: f32,
    font: dvui.Font,
    line_height: f32,
) void {
    if (rs.r.empty()) return;

    const prev_clip = dvui.clip(rs.r);
    defer dvui.clipSet(prev_clip);

    const line_number_color = dvui.themeGet().color(.content, .text).opacity(0.55);

    const first_line: usize = @intCast(@max(0, @as(i64, @intFromFloat((scroll_y - editor_pad_y) / line_height))));

    var line: usize = first_line;
    var y: f32 = editor_pad_y + @as(f32, @floatFromInt(line)) * line_height - scroll_y;

    var num_buf: [32]u8 = undefined;

    while (line < line_count and y < rs.r.h + line_height) : ({
        line += 1;
        y += line_height;
    }) {
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line + 1}) catch continue;
        const text_size = font.textSize(num_str).scale(rs.s, dvui.Size.Physical);
        const x = rs.r.x + line_number_pad_left * rs.s;
        const y_phys = rs.r.y + y * rs.s;

        dvui.renderText(.{
            .font = font,
            .text = num_str,
            .rs = .{ .r = .{ .x = x, .y = y_phys, .w = text_size.w, .h = text_size.h }, .s = rs.s },
            .color = line_number_color,
        }) catch |err| {
            dvui.log.err("line number text: {any}", .{err});
        };
    }
}
