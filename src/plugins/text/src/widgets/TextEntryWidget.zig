//! Vendored from dvui `widgets/TextEntryWidget.zig` with code-editor extensions:
//! tree-sitter predicate filtering, query error fallback, optional focus ring.
const builtin = @import("builtin");
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const perf = @import("core").perf;
const palette = @import("core").palette;
const tc = @import("../textcore/textcore.zig");

pub const HighlightStyle = sdk.language.HighlightStyle;
pub const TreeSitterHighlight = sdk.language.TreeSitterHighlight;

const Event = dvui.Event;
const Options = dvui.Options;
const Rect = dvui.Rect;
const CornerRect = dvui.CornerRect;
const RectScale = dvui.RectScale;
const ScrollInfo = dvui.ScrollInfo;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;
const ScrollAreaWidget = dvui.ScrollAreaWidget;
const TextLayoutWidget = dvui.TextLayoutWidget;
const AccessKit = dvui.AccessKit;

const TreeSitterQueryPredicates = if (dvui.useTreeSitter) @import("TreeSitterQueryPredicates.zig") else struct {
    pub fn matchApplies(_: *const dvui.c.TSQuery, _: dvui.c.TSQueryMatch, _: []const u8) bool {
        return true;
    }
};

/// Self-contained tree-sitter perf logging (see call sites in `draw()`). `core.gfx.perf`'s
/// counters can't be read back from the host exe's log loop (separate dylib, separate
/// globals — see comment at the query-timer call site), so this accumulates and prints
/// directly from inside this plugin instead.
var diag_reparse_calls: u32 = 0;
var diag_reparse_ns: u64 = 0;
var diag_query_calls: u32 = 0;
var diag_query_ns: u64 = 0;
var diag_query_bytes: usize = 0;
/// Time in `iter.next()` — the tree-sitter query-cursor capture walk, excluding shaping.
var diag_capture_ns: u64 = 0;
var diag_capture_calls: u32 = 0;
/// Time in `emitChunk` (→ `TextLayoutWidget.addText`/`addTextHover`) — text shaping/layout.
var diag_shape_ns: u64 = 0;
var diag_shape_calls: u32 = 0;
const diag_log_every: u32 = 60;

/// Caps `TSQueryCursor`'s internal in-progress-match list, which by default is *unbounded* —
/// tree-sitter dynamically grows it as needed, and against certain tree shapes (dense runs of
/// declarations each with several doc-comment lines, e.g. an enum with many long-commented
/// variants — a real example: `std.Io.Threaded`'s `Thread.Status` around line ~840) that growth
/// gets pathological: measured 18-50ms for a single 16KB-byte-range query on that region with
/// no limit set, versus a uniform ~1-2ms with `ts_query_cursor_set_match_limit` capped, for a
/// <0.1% difference in resulting captures (a few of the earliest-started candidate matches get
/// silently dropped once the cap is hit, per `ts_query_cursor_did_exceed_match_limit`'s doc
/// comment — imperceptible against thousands of captures in a real viewport). This is a query
/// cursor property, not a per-language setting, so it has to be applied at every
/// `ts_query_cursor_new()` call site, not just this one.
pub const tree_sitter_match_limit: u32 = 256;

/// Gates the `nanoTimestamp()` call itself (not just what happens with the result) behind
/// `perf.record` — mirrors `core/gfx/perf.zig`'s own `renderLayersBegin`/`spritePreviewBegin`
/// pattern. This loop's capture walk can call this once per visible tree-sitter token, every
/// frame while scrolling/typing, so paying for a real timestamp read in release builds (where
/// `perf.record` is false and the result would just be discarded by `perfLog*`/`perfAccum*`
/// below) is a real per-frame cost, not a no-op.
inline fn perfBegin() i128 {
    if (!perf.record) return 0;
    return perf.nanoTimestamp();
}

fn perfLogReparse(start: i128) void {
    if (!perf.record) return;
    diag_reparse_ns +%= @intCast(perf.nanoTimestamp() - start);
    diag_reparse_calls += 1;
}

fn perfAccumCapture(start: i128) void {
    if (!perf.record) return;
    diag_capture_ns +%= @intCast(perf.nanoTimestamp() - start);
    diag_capture_calls += 1;
}

fn perfAccumShape(start: i128) void {
    if (!perf.record) return;
    diag_shape_ns +%= @intCast(perf.nanoTimestamp() - start);
    diag_shape_calls += 1;
}

fn perfLogQuery(start: i128, bytes: usize) void {
    if (!perf.record) return;
    diag_query_ns +%= @intCast(perf.nanoTimestamp() - start);
    diag_query_calls += 1;
    diag_query_bytes = bytes;
    if (diag_query_calls % diag_log_every != 0) return;
    const avg_query_us = diag_query_ns / diag_query_calls / 1000;
    const avg_reparse_us = if (diag_reparse_calls > 0) diag_reparse_ns / diag_reparse_calls / 1000 else 0;
    const avg_capture_us = if (diag_capture_calls > 0) diag_capture_ns / diag_query_calls / 1000 else 0;
    const avg_shape_us = if (diag_shape_calls > 0) diag_shape_ns / diag_query_calls / 1000 else 0;
    std.log.info(
        "tree-sitter[text.dll]: last {d} frames — total avg {d}us/frame ({d} bytes/doc) = capture {d}us/frame ({d} calls) + shape {d}us/frame ({d} calls) | reparse {d} calls, avg {d}us/call",
        .{ diag_log_every, avg_query_us, diag_query_bytes, avg_capture_us, diag_capture_calls, avg_shape_us, diag_shape_calls, diag_reparse_calls, avg_reparse_us },
    );
    diag_query_calls = 0;
    diag_query_ns = 0;
    diag_reparse_calls = 0;
    diag_reparse_ns = 0;
    diag_capture_ns = 0;
    diag_capture_calls = 0;
    diag_shape_ns = 0;
    diag_shape_calls = 0;
}

const TextEntryWidget = @This();

/// If min_size_content is not given, use Font.sizeM(defaultMWidth, 1).
/// If multiline is false and max_size_content is not given, use min_size_content.
pub var defaultMWidth: f32 = 14;

pub var defaults: Options = .{
    .name = "TextEntry",
    .role = .text_input, // can change to multiline in init
    .margin = Rect.all(4),
    .corners = CornerRect.all(5),
    .border = Rect.all(1),
    .padding = Rect.all(6),
    .background = true,
    .style = .content,
    // min_size_content/max_size_content is calculated in init()
};

const realloc_bin_size = 100;

pub const SyntaxHighlight = HighlightStyle;

pub const TreeSitterParser = if (dvui.useTreeSitter) struct {
    parser: *dvui.c.TSParser,
    tree: *dvui.c.TSTree,
    query: *dvui.c.TSQuery,

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));

        dvui.c.ts_query_delete(self.query);
        dvui.c.ts_tree_delete(self.tree);
        dvui.c.ts_parser_delete(self.parser);
    }

    pub fn queryCursorCaptureIterator(self: *const TreeSitterParser, qc: *dvui.c.TSQueryCursor, text: []const u8) QueryCursorCaptureIterator {
        return .{
            .query_cursor = qc,
            .prev_match = null,
            .query = self.query,
            .text = text,
        };
    }

    pub const QueryCursorCaptureIterator = struct {
        pub const Match = struct {
            iter: *const QueryCursorCaptureIterator,
            node: dvui.c.TSNode,
            capture_index: u32,

            pub fn captureName(self: *const Match) []const u8 {
                var len: u32 = undefined;
                const name = dvui.c.ts_query_capture_name_for_id(self.iter.query, self.capture_index, &len);
                return name[0..len];
            }

            pub fn debugLog(self: *const Match, comptime kind: []const u8) void {
                const start = dvui.c.ts_node_start_byte(self.node);
                const end = dvui.c.ts_node_end_byte(self.node);
                dvui.log.debug(kind ++ " capture @{s} : {s}", .{ self.captureName(), self.iter.text[start..end] });
            }
        };

        query_cursor: *dvui.c.TSQueryCursor,
        prev_match: ?Match,

        // used for debugging
        debug: bool = false,
        query: *dvui.c.TSQuery,
        text: []const u8,

        /// Restricts capture iteration to nodes overlapping `[start, end)`. Call before `next`.
        /// Mirrors `dvui.TreeSitter.ParseIterator.setByteRange`.
        pub fn setByteRange(self: *QueryCursorCaptureIterator, start: usize, end: usize) void {
            _ = dvui.c.ts_query_cursor_set_byte_range(self.query_cursor, @intCast(start), @intCast(end));
        }

        pub fn next(self: *QueryCursorCaptureIterator) ?Match {
            var match: dvui.c.TSQueryMatch = undefined;
            var captureIdx: u32 = undefined;
            loop: while (dvui.c.ts_query_cursor_next_capture(self.query_cursor, &match, &captureIdx)) {
                if (!TreeSitterQueryPredicates.matchApplies(self.query, match, self.text))
                    continue :loop;
                const capture = match.captures[captureIdx];
                if (self.prev_match) |pm| {
                    if (dvui.c.ts_node_eq(pm.node, capture.node)) {
                        // same node as previous
                        self.prev_match = .{ .iter = self, .node = capture.node, .capture_index = capture.index };
                        if (self.debug) self.prev_match.?.debugLog("ts same ");
                        continue :loop;
                    }

                    // not the same
                    const ret = self.prev_match;
                    self.prev_match = .{ .iter = self, .node = capture.node, .capture_index = capture.index };
                    if (self.debug) self.prev_match.?.debugLog("ts new  ");
                    return ret;
                } else {
                    // first time
                    self.prev_match = .{ .iter = self, .node = capture.node, .capture_index = capture.index };
                    if (self.debug) self.prev_match.?.debugLog("ts first");
                    continue :loop;
                }
            }

            const ret = self.prev_match;
            if (ret) |r| {
                if (self.debug) r.debugLog("ts last ");
            }
            self.prev_match = null;
            return ret;
        }
    };
} else void;

/// Notified around every buffer mutation (typing, paste-into-focus, backspace, delete) so a
/// caller can build an undo/redo history without diffing the buffer itself. `beginEdit` opens
/// one logical edit; 0-1 `noteRemoved` + 0-1 `noteInserted` calls describe it (both can fire —
/// e.g. typing over a selection replaces it); `endEdit` commits it. Fired at the same points
/// as the pre-existing `textChangedRemoved`/`textChangedAdded` calls, so `bytes` is always
/// read before it's overwritten by the mutation that follows.
/// Undo/redo capture hook. `beginEdit`/`endEdit` carry the selection either side of the
/// mutation: `beginEdit`'s is what undo restores (so undoing "type over a selection"
/// re-selects the restored text), and it also tells the history whether a removal was a
/// backspace or a forward delete, which decides undo grouping.
pub const EditNotify = struct {
    ctx: *anyopaque,
    beginEdit: *const fn (ctx: *anyopaque, sel_before: tc.Range) void,
    noteRemoved: *const fn (ctx: *anyopaque, pos: usize, bytes: []const u8) void,
    noteInserted: *const fn (ctx: *anyopaque, pos: usize, bytes: []const u8) void,
    endEdit: *const fn (ctx: *anyopaque, sel_after: tc.Range) void,
};

pub const InitOptions = struct {
    pub const TextOption = union(enum) {
        /// Use this slice of bytes, cannot add more.
        buffer: []u8,

        /// Use and grow with realloc and shrink with resize as needed.
        buffer_dynamic: struct {
            backing: *[]u8,
            allocator: std.mem.Allocator,
            limit: usize = 10_000,
        },

        /// Use std.ArrayList(u8).  The limit is total characters, the
        /// arraylist might allocate more capacity.  ArrayList.items is updated
        /// in deinit() (file an issue if this is a problem).
        array_list: struct {
            backing: *std.ArrayList(u8),
            allocator: std.mem.Allocator,
            limit: usize = 10_000,
        },

        /// Use internal buffer up to limit.
        /// - use getText() to get contents.
        internal: struct {
            limit: usize = 10_000,
        },
    };

    pub const TreeSitterOption = TreeSitterHighlight;

    text: TextOption = .{ .internal = .{} },
    tree_sitter: ?TreeSitterHighlight = null,
    /// Faded text shown when the textEntry is empty
    placeholder: ?[]const u8 = null,

    /// If true, assume text (and text height) is the same (excepting edits we
    /// do internally) as we saw last frame and only process what is needed for
    /// visibility (and copy).
    cache_layout: bool = false,

    break_lines: bool = false,
    kerning: ?bool = null,
    scroll_vertical: ?bool = null, // default is value of multiline
    scroll_vertical_bar: ?ScrollInfo.ScrollBarMode = null, // default .auto
    scroll_horizontal: ?bool = null, // default true
    scroll_horizontal_bar: ?ScrollInfo.ScrollBarMode = null, // default .auto if multiline, .hide if not

    // must be a single utf8 character
    password_char: ?[]const u8 = null,
    multiline: bool = false,
    /// Draw the theme focus ring when this text entry has keyboard focus.
    focus_border: bool = true,
    /// Optional undo/redo capture hook — see `EditNotify`.
    edit_notify: ?EditNotify = null,
    /// When true, this widget does not handle Cmd/Ctrl+C / Cmd/Ctrl+V itself — the host owns
    /// copy/paste (e.g. registers `Command`s the shell's Edit menu / native menu / global
    /// keybind dispatch to). Otherwise both the widget's own key handling *and* the host's
    /// path fire for the same keystroke (a native menu item's key equivalent doesn't stop the
    /// underlying key event from also reaching the focused widget in this app), inserting
    /// pasted text twice.
    external_copy_paste: bool = false,
    /// When true (and `multiline`), a plain Tab keydown inserts indentation at the cursor
    /// instead of moving focus to the next widget (dvui's default `next_widget` behavior).
    /// Off by default — this widget is reused outside the text plugin's own editor, where
    /// Tab-changes-focus is normal/expected. The text plugin turns this on from its own
    /// "Insert spaces on Tab" setting. Doesn't affect Shift+Tab, which always moves focus
    /// backward regardless (no de-indent in this first pass — see `State.zig`).
    tab_inserts_indent: bool = false,
    /// Column width indentation snaps to when `tab_inserts_indent` and inserting spaces
    /// (`insert_spaces`) — e.g. after 2 typed characters, Tab adds 2 spaces to reach column
    /// 4, not a flat 4 more. Ignored when inserting a literal tab character.
    tab_size: u8 = 4,
    /// Whether `tab_inserts_indent` inserts spaces (snapped to `tab_size`) or a literal `\t`.
    insert_spaces: bool = true,
    /// When true (and `multiline`), Enter carries the current line's leading whitespace onto
    /// the new line (VSCode-style "maintain indent"), and adds one more level after an opening
    /// bracket — or, if the cursor sits directly between a matching bracket pair, splits it
    /// onto three lines with the closer re-dedented. Off by default for the same reusability
    /// reason as `tab_inserts_indent`; the text plugin turns this on unconditionally since it's
    /// baseline code-editing behavior, not a user preference.
    auto_indent_newline: bool = false,
    /// When true (and `multiline`), typing one of `auto_pairs`' openers also inserts its closer
    /// and leaves the cursor between the two, typing a closer that's already sitting right after
    /// the cursor steps over it instead of inserting a second one, Backspace between an empty
    /// pair deletes both halves, and typing an opener with a selection active wraps the selection
    /// instead of replacing it — VSCode's `editor.autoClosingBrackets`/`autoSurround`. Off by
    /// default for the same reusability reason as `tab_inserts_indent`.
    auto_close_pairs: bool = false,
    /// When true, the bracket next to the caret and its partner are drawn with a highlight
    /// behind them (VSCode's `editor.matchBrackets`). Recomputed every frame from the buffer —
    /// see `tc.pairs.matchAt`, including what it deliberately doesn't handle.
    highlight_matching_bracket: bool = false,
    /// When true, every `{`/`(`/`[` (and closer) is tinted from `core.palette.bracket` by
    /// **indent level + kind offset** — matching pairs of one kind share a colour, but a
    /// paren and a brace at the same indent do not. Off by default for the same reusability
    /// reason as `tab_inserts_indent`.
    rainbow_brackets: bool = false,
};

/// Byte span of a tree-sitter token, used by `hovered_span` below.
pub const Span = struct { start: usize, end: usize };

/// One completion candidate, as shown in `CompletionState.items` — either owned by
/// `Document.completion_items` (which both `TextEditor.zig` and this widget then just borrow
/// a slice of for the frame) or, in principle, any other caller. `text` is the **full**
/// replacement for `[replace_start, replace_end)`, not a suffix of what's already typed — see
/// `sdk.language.CompletionItem.insert_text`, and `completionGhost` for how the ghost-text
/// preview derives a suffix from it (and declines to show one when it can't). `text` must not contain '\n': ghost text is
/// spliced in by rewinding `TextLayoutWidget.bytes_seen`, which only accounts for a
/// single-line visual advance; multi-line snippets aren't supported by this SDK's
/// intentionally minimal `CompletionItem` shape in the first place. `label` is the full,
/// untrimmed display text (e.g. "orelse" where `text` is just "else") — used only by
/// `TextEditor.drawCompletionList`'s dropdown row, never spliced as ghost text.
pub const CompletionCandidate = struct {
    label: []const u8,
    text: []const u8,
    replace_start: usize,
    replace_end: usize,
    kind: sdk.language.CompletionKind,
    /// Type/signature text shown on the right of the dropdown row — empty when the provider
    /// had nothing to show.
    detail: []const u8,
    /// Doc comment / prose documentation, shown in an info panel next to the dropdown while
    /// this candidate is highlighted — empty when the provider had nothing to show, in which
    /// case no panel is shown at all.
    documentation: []const u8,
};

/// The completion list currently being shown: the untyped remainder of `items[selected]`'s text
/// is spliced into `draw()` as ghost text right after `anchor` (when there is one — see
/// `completionGhost`), and the same list + selection drive the
/// dropdown rendered by `TextEditor.drawCompletionList`. Up/Down (`processEvents`) change
/// `selected`; Tab/Enter accept `items[selected]`; Escape clears this entirely.
pub const CompletionState = struct {
    /// Must equal the live cursor position for this state to still be considered valid
    /// (checked by the caller — `TextEditor.zig`'s `drawCompletion` — not by this widget).
    anchor: usize,
    items: []const CompletionCandidate,
    selected: usize,
    /// True for exactly the frame `selected` changed via Up/Down keyboard navigation — tells
    /// `TextEditor.drawCompletionList` to auto-scroll the dropdown to reveal the new selection.
    /// Deliberately *not* set by mouse hover: a row can only be hovered while it's already
    /// visible in the (possibly clipped) scroll viewport, so scrolling to reveal a
    /// hover-selected row would just fight the mouse — the scroll shifts row positions, which
    /// moves a different row under the still-resting cursor, which hovers *that* one, which
    /// scrolls again. Defaults false every frame (this struct is rebuilt fresh from
    /// `Document.completion_anchor`/`completion_selected` each draw), so it only ever reads
    /// true on the one frame a key press actually set it.
    scroll_to_selected: bool = false,
};

wd: WidgetData,
prevClip: Rect.Physical = undefined,
scroll: ScrollAreaWidget = undefined,
scrollClip: Rect.Physical = undefined,
textLayout: TextLayoutWidget = undefined,
textClip: Rect.Physical = undefined,
padding: Rect,

/// Byte span of the tree-sitter token currently under the mouse, refreshed every `draw()`
/// call from the highlight loop's `addTextHover` calls (only set when `init_opts.tree_sitter`
/// is active). Read by the caller after `draw()` to drive hover tooltips / goto-definition.
hovered_span: ?Span = null,
/// Local (widget-content-relative) bounding box of `hovered_span`'s own text run — set
/// alongside it, from the same `TextLayoutWidget.HoverMatch` an `addTextHover` match returns,
/// so a caller (e.g. a hover tooltip positioning itself flush against the hovered term) reads
/// both from this widget at the same level instead of also reaching into
/// `self.textLayout.hover_rect` separately.
hover_rect: ?Rect = null,
/// True for exactly the frame a Ctrl/Cmd+left-click landed on this widget, set during
/// `processEvents()`. `processEvents()` runs before `draw()` within the same frame, and
/// `draw()`'s `addTextHover` hit-test uses the mouse position already recorded by
/// `processEvents()` this frame — so by the time both have run, `definition_click` and
/// `hovered_span` describe the same mouse position and the caller can safely combine them
/// after `draw()` returns to know which token, if any, was Ctrl/Cmd-clicked.
definition_click: bool = false,
/// True alongside `definition_click` when Shift was also held — "open to the side" (a new
/// grouping/split) instead of revealing in the current one. Meaningless when
/// `definition_click` is false.
definition_click_open_side: bool = false,

/// Byte span of the token that should render underlined + with a hand cursor this frame —
/// the same visual affordance as a real hyperlink, signaling "Ctrl/Cmd+click here would
/// attempt goto-definition". Computed once at the top of `draw()` from *last* frame's
/// `hovered_span`, gated on Ctrl/Cmd currently being held: the token's display `Options` have
/// to be decided before this frame's `addTextHover` hit-test for that exact chunk even runs,
/// so there's no way to know within the same call whether it's the hovered one — one frame of
/// lag, imperceptible at normal frame rates, and only visible at all on the single frame the
/// mouse first lands on/leaves a token. Deliberately not narrowed to tokens that would
/// actually resolve a definition — same tradeoff `performGotoDefinition` already makes for the
/// click itself (a per-click LSP request, too expensive to speculatively probe every hovered
/// token every frame) — so this affordance covers exactly the same tokens Ctrl/Cmd+click
/// already attempts on, never promising more than the click already does.
link_span: ?Span = null,

/// The completion list to splice/render for this frame, if any. Lifecycle (fetching,
/// invalidating on cursor move/edit/selection/blur) is owned by the caller (`TextEditor.zig`'s
/// `drawCompletion`, run before `draw()`) — this widget only renders whatever's set here and
/// handles Up/Down-to-navigate/Tab/Enter-to-accept/Escape-to-dismiss during `processEvents()`.
current_completion: ?CompletionState = null,
/// Purely informational ghost text — e.g. the remaining portion of a function's signature
/// while the cursor sits inside its call's parens — shown dimmed at the *current* cursor
/// position, same styling as `current_completion`'s ghost text but never acceptable via
/// Tab/Enter (there's no `CompletionCandidate` here, nothing to splice into the buffer).
/// Recomputed fresh every frame by the caller (`TextEditor.zig`'s signature-help fetch, run
/// just before `draw()`) — unlike `current_completion`, nothing needs to survive a frame
/// boundary, since there's no accept path whose `processEvents()` timing to worry about.
/// `current_completion` wins when both would apply at once (see `emitChunk`'s `Ghost` — only
/// one ghost-text slot exists at the cursor).
signature_hint: ?[]const u8 = null,
/// Set once `emitChunk` has spliced the ghost text in for this `draw()` call — consecutive
/// chunks touch (one's end equals the next one's start), so when the anchor sits exactly on
/// that shared boundary, both chunks independently believe the anchor falls within their own
/// range and would otherwise splice the ghost text twice (visibly duplicating it, e.g. typing
/// `s` and seeing `stdtd` instead of `std`). Reset at the top of `draw()`.
ghost_text_emitted: bool = false,
/// Byte offsets (ascending) of the matched bracket pair to highlight this frame, or null when
/// the caret isn't next to one / `highlight_matching_bracket` is off. Computed once at the top
/// of `draw()` and consumed by `emitChunk`, rather than per chunk — the scan is over the whole
/// buffer, and every chunk would otherwise redo it.
bracket_match: ?[2]usize = null,
/// Nesting-depth marks for rainbow brackets this frame (sorted by byte). Points into a stack
/// buffer owned by `draw()` for the duration of the call; empty when `rainbow_brackets` is off.
bracket_nests: []const tc.pairs.NestMark = &.{},

init_opts: InitOptions,
text: []u8,
len: usize,
enter_pressed: bool = false, // not valid if multiline
text_changed: bool = false,

// see textChanged()
text_changed_start: usize = std.math.maxInt(usize),
text_changed_end: usize = 0, // index of bytes before edits (so matches previous frame)
text_changed_added: i64 = 0, // bytes added
edited_outside_last_frame: *bool = undefined,

/// It's expected to call this when `self` is `undefined`
pub fn init(self: *TextEntryWidget, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) void {
    var scroll_init_opts = ScrollAreaWidget.InitOpts{
        .vertical = if (init_opts.scroll_vertical orelse init_opts.multiline) .auto else .none,
        .vertical_bar = init_opts.scroll_vertical_bar orelse .auto,
        .horizontal = if (init_opts.scroll_horizontal orelse true) .auto else .none,
        .horizontal_bar = init_opts.scroll_horizontal_bar orelse (if (init_opts.multiline) .auto else .hide),
    };

    var options = defaults.min_sizeM(defaultMWidth, 1);

    if (init_opts.password_char != null) {
        options.role = .password_input;
    } else if (init_opts.multiline) {
        options.role = .multiline_text_input;
    }

    options = options.override(opts);
    if (!init_opts.multiline and options.max_size_content == null) {
        options = options.override(.{ .max_size_content = .size(options.min_size_contentGet()) });
    }

    // padding is interpreted as the padding for the TextLayoutWidget, but
    // we also need to add it to content size because TextLayoutWidget is
    // inside the scroll area
    const padding = options.paddingGet();
    options.padding = null;
    options.min_size_content.?.w += padding.x + padding.w;
    options.min_size_content.?.h += padding.y + padding.h;
    if (options.max_size_content != null) {
        options.max_size_content.?.w += padding.x + padding.w;
        options.max_size_content.?.h += padding.y + padding.h;
    }

    const wd = WidgetData.init(src, .{}, options);
    scroll_init_opts.focus_id = wd.id;

    var text: []u8 = undefined;
    var find_zero = true;
    var len_utf8_boundary: usize = undefined;
    switch (init_opts.text) {
        .buffer => |b| text = b,
        .buffer_dynamic => |b| text = b.backing.*,
        .internal => text = dvui.dataGetSliceDefault(null, wd.id, "_buffer", []u8, &.{}),
        .array_list => |al| {
            find_zero = false;
            text = al.backing.items.ptr[0..@min(al.limit, al.backing.capacity)];
            len_utf8_boundary = dvui.findUtf8Start(text, al.backing.items.len);
        },
    }

    if (find_zero) {
        const len_byte = std.mem.findScalar(u8, text, 0) orelse text.len;
        len_utf8_boundary = dvui.findUtf8Start(text[0..len_byte], len_byte);
    }

    self.* = .{
        .wd = wd,
        .padding = padding,
        .init_opts = init_opts,
        .text = text,
        .len = len_utf8_boundary,

        // SAFETY: The following fields are set bellow
        .prevClip = undefined,
        .scroll = undefined,
        .scrollClip = undefined,
        .textLayout = undefined,
        .textClip = undefined,
    };

    self.data().register();

    dvui.tabIndexSet(self.data().id, self.data().options.tab_index, self.data().rectScale().r);

    dvui.parentSet(self.widget());

    self.data().borderAndBackground(.{});

    self.prevClip = dvui.clip(self.data().borderRectScale().r);
    const borderClip = dvui.clipGet();

    // We do this dance with last_focused_id_this_frame so scroll will process
    // key events we skip (like page up/down). Normally it would not (text
    // entry is not a child of scroll). So with this we make scroll think that
    // text entry ran as a child.
    const focused = (self.data().id == dvui.lastFocusedIdInFrame());
    if (focused) dvui.currentWindow().last_focused_id_this_frame = .zero;

    // scrollbars process mouse events here
    self.scroll.init(@src(), scroll_init_opts, self.data().options.strip().override(.{ .role = .none, .expand = .both }));

    if (focused) dvui.currentWindow().last_focused_id_this_frame = self.data().id;

    self.scrollClip = dvui.clipGet();

    self.edited_outside_last_frame = dvui.dataGetPtrDefault(null, self.data().id, "_edited_outside", bool, false);
    if (self.init_opts.cache_layout and self.edited_outside_last_frame.*) {
        dvui.log.debug("TextEntryWidget forcing cache_layout false due to text being edited after drawing last frame", .{});
        self.init_opts.cache_layout = false;
        self.edited_outside_last_frame.* = false;
        self.text_changed = true; // trigger tree_sitter full reparse
    }

    self.textLayout.init(@src(), .{
        .break_lines = self.init_opts.break_lines,
        .kerning = self.init_opts.kerning,
        .touch_edit_just_focused = false,
        .cache_layout = self.init_opts.cache_layout,
        .focused = self.data().id == dvui.focusedWidgetId(),
        .show_touch_draggables = (self.len > 0),
    }, self.data().options.strip().override(.{
        .role = .none,
        .expand = .both,
        .padding = self.padding,
    }));

    // if textLayout forced cache_layout to false, we need to honor that
    self.init_opts.cache_layout = self.textLayout.cache_layout;

    self.textClip = dvui.clipGet();

    if (self.textLayout.touchEditing()) |floating_widget| {
        defer floating_widget.deinit();

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .corners = dvui.ButtonWidget.defaults.cornersGet(),
            .background = true,
            .border = dvui.Rect.all(1),
        });
        defer hbox.deinit();

        if (dvui.buttonIcon(@src(), "paste", dvui.entypo.clipboard, .{}, .{}, .{
            .min_size_content = .{ .h = 20 },
            .margin = Rect.all(2),
        })) {
            self.paste();
        }

        if (dvui.buttonIcon(@src(), "select all", dvui.entypo.swap, .{}, .{}, .{
            .min_size_content = .{ .h = 20 },
            .margin = Rect.all(2),
        })) {
            self.textLayout.selection.selectAll();
        }

        if (dvui.buttonIcon(@src(), "cut", dvui.entypo.scissors, .{}, .{}, .{
            .min_size_content = .{ .h = 20 },
            .margin = Rect.all(2),
        })) {
            self.cut();
        }

        if (dvui.buttonIcon(@src(), "copy", dvui.entypo.copy, .{}, .{}, .{
            .min_size_content = .{ .h = 20 },
            .margin = Rect.all(2),
        })) {
            self.copy();
        }
    }

    // don't call textLayout.processEvents here, we forward events inside our own processEvents

    // textLayout is maintaining the selection for us, but if the text
    // changed, we need to update the selection to be valid before we
    // process any events
    var sel = self.textLayout.selection;
    sel.start = dvui.findUtf8Start(self.text[0..self.len], sel.start);
    sel.cursor = dvui.findUtf8Start(self.text[0..self.len], sel.cursor);
    sel.end = dvui.findUtf8Start(self.text[0..self.len], sel.end);

    // textLayout clips to its content, but we need to get events out to our border
    dvui.clipSet(borderClip);
    if (self.data().accesskit_node()) |ak_node| {
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.focus);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.set_value);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.set_text_selection);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.replace_selected_text);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.scroll_into_view); // AK TODO - not yet implemented
        AccessKit.nodeSetClipsChildren(ak_node); // AK TODO: Check this is correct?

        if (self.data().options.role != .password_input) {
            const str = self.text[0..self.len];
            AccessKit.nodeSetValueWithLength(ak_node, str.ptr, str.len);
        }
    }
}

pub fn matchEvent(self: *TextEntryWidget, e: *Event) bool {
    // textLayout could be passively listening to events in matchEvent, so
    // don't short circuit
    const match1 = dvui.eventMatchSimple(e, self.data());
    const match2 = self.scroll.scroll.?.matchEvent(e);
    const match3 = self.textLayout.matchEvent(e);
    return match1 or match2 or match3;
}

pub fn processEvents(self: *TextEntryWidget) void {
    self.definition_click = false;
    self.definition_click_open_side = false;
    const evts = dvui.events();
    for (evts) |*e| {
        if (!self.matchEvent(e))
            continue;

        // Peek (don't consume) Ctrl/Cmd+left-click for goto-definition, independent of the
        // normal click-to-place-caret handling `processEvent` does below — see `addLink` in
        // dvui's TextLayoutWidget for the same modifier-check convention. Shift held at the
        // same time means "open to the side" — `matchBind("ctrl/cmd")` doesn't care about
        // Shift either way (the "ctrl/cmd" keybind leaves that modifier unconstrained), so it
        // stays checked separately via the raw modifier rather than a second named bind.
        if (e.evt == .mouse and e.evt.mouse.action == .press and
            e.evt.mouse.button.pointer() and e.evt.mouse.mod.matchBind("ctrl/cmd"))
        {
            self.definition_click = true;
            self.definition_click_open_side = e.evt.mouse.mod.shift();
        }

        self.processEvent(e);
    }
}

pub fn draw(self: *TextEntryWidget) void {
    // `link_span` (see its own doc comment) needs *last* frame's `hovered_span` — but `self`
    // is a fresh struct every frame (this widget is stack-allocated and re-`init`'d by its
    // caller each draw, same as `current_completion` needing `TextEditor.zig` to restore it
    // from `doc.completion_anchor`), so `self.hovered_span` itself is always this frame's
    // default (null) at this point, never carrying anything over from before. Persisting it
    // through dvui's data store — keyed to this widget's own (frame-to-frame stable) id — is
    // what actually bridges the frame boundary; without it, the condition below never once
    // saw a non-null span and `link_span` was dead code, permanently null, no matter how long
    // Ctrl/Cmd was held over a token. Mirrors `TextEditor.zig`'s own `_last_span`/`_query_span`
    // pattern for the hover tooltip.
    const prev_hovered_span = dvui.dataGet(null, self.data().id, "_hovered_span", Span);
    self.link_span = if (prev_hovered_span != null and dvui.currentWindow().modifiers.matchBind("ctrl/cmd"))
        prev_hovered_span
    else
        null;
    self.hovered_span = null;
    self.hover_rect = null;
    // Runs on every exit path (several early `return`s below), not just the bottom of the
    // function — a `defer` here is simpler and less error-prone than duplicating this at each
    // return site. Removes the stored span entirely when nothing's hovered this frame (rather
    // than leaving a stale one around) so the *next* frame's `prev_hovered_span` above
    // correctly sees "nothing" too.
    defer if (self.hovered_span) |hs| {
        dvui.dataSet(null, self.data().id, "_hovered_span", hs);
    } else {
        dvui.dataRemove(null, self.data().id, "_hovered_span");
    };
    self.ghost_text_emitted = false;
    self.bracket_match = blk: {
        if (!self.init_opts.highlight_matching_bracket) break :blk null;
        // Only for the focused editor, and only with a collapsed caret: with a split open, two
        // editors both marking "their" bracket pair reads as though both are live, and while a
        // selection is up the selection highlight is what the eye is tracking anyway.
        if (self.data().id != dvui.focusedWidgetId()) break :blk null;
        const sel = self.textLayout.selectionGet(self.len);
        if (!sel.empty()) break :blk null;
        break :blk tc.pairs.matchAt(self.text[0..self.len], sel.cursor);
    };
    self.drawBeforeText();

    // Rainbow nesting must run *after* `drawBeforeText` so `cache_layout_bytes` (and therefore
    // `highlightByteRange`) is valid — otherwise the first frame with `cache_layout` on would
    // colour the whole document instead of the viewport.
    var nest_buf: [512]tc.pairs.NestMark = undefined;
    self.bracket_nests = &.{};
    if (self.init_opts.rainbow_brackets) {
        const range = self.highlightByteRange() orelse ByteRange{ .start = 0, .end = self.len };
        const tab_size: u8 = if (self.init_opts.tab_size == 0) 4 else self.init_opts.tab_size;
        const n = tc.pairs.nestMarks(self.text[0..self.len], range.start, range.end, tab_size, &nest_buf);
        self.bracket_nests = nest_buf[0..n];
    }

    if (self.len == 0) {
        if (self.init_opts.placeholder) |placeholder| {
            if (self.data().accesskit_node()) |ak_node| {
                AccessKit.nodeSetPlaceholderWithLength(ak_node, placeholder.ptr, placeholder.len);

                // Create an empty text run for the empty text entry.
                dvui.currentWindow().accesskit.text_run_parent = self.data().id;
                self.textLayout.textRunCreateEmpty(self.data().id, true);
                // prevent textLayout from making a text run for the placeholder text
                dvui.currentWindow().accesskit.text_run_parent = null;
            }
            self.textLayout.addText(placeholder, .{ .color_text = self.textLayout.data().options.color(.text).opacity(0.65) });
        }
    }

    if (dvui.accesskit_enabled) {
        // parent text runs to us
        dvui.currentWindow().accesskit.text_run_parent = self.data().id;
    }

    if (self.init_opts.password_char) |pc| {
        {
            // adjust selection for obfuscation
            var count: usize = 0;
            var bytes: usize = 0;
            var sel = self.textLayout.selection;
            var sstart: ?usize = null;
            var scursor: ?usize = null;
            var send: ?usize = null;
            var utf8it = (std.unicode.Utf8View.initUnchecked(self.text[0..self.len])).iterator();
            while (utf8it.nextCodepoint()) |codepoint| {
                if (sstart == null and sel.start == bytes) sstart = count * pc.len;
                if (scursor == null and sel.cursor == bytes) scursor = count * pc.len;
                if (send == null and sel.end == bytes) send = count * pc.len;
                count += 1;
                bytes += std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            } else {
                if (sstart == null and sel.start >= bytes) sstart = count * pc.len;
                if (scursor == null and sel.cursor >= bytes) scursor = count * pc.len;
                if (send == null and sel.end >= bytes) send = count * pc.len;
            }
            sel.start = sstart.?;
            sel.cursor = scursor.?;
            sel.end = send.?;
            const password_str: ?[]u8 = dvui.currentWindow().lifo().alloc(u8, count * pc.len) catch null;
            if (password_str) |pstr| {
                defer dvui.currentWindow().lifo().free(pstr);
                for (0..count) |i| {
                    for (0..pc.len) |pci| {
                        pstr[i * pc.len + pci] = pc[pci];
                    }
                }
                self.textLayout.addText(pstr, self.data().options.strip());
            } else {
                dvui.log.warn("Could not allocate password_str, falling back to one single password_str", .{});
                self.textLayout.addText(pc, self.data().options.strip());
            }
        }

        self.textLayout.addTextDone(self.data().options.strip());

        {
            // reset selection
            var count: usize = 0;
            var bytes: usize = 0;
            var sel = self.textLayout.selection;
            var sstart: ?usize = null;
            var scursor: ?usize = null;
            var send: ?usize = null;
            // NOTE: We assume that all text in the area it valid utf8, loop with exit early on invalid utf8
            var utf8it = (std.unicode.Utf8View.initUnchecked(self.text[0..self.len])).iterator();
            while (utf8it.nextCodepoint()) |codepoint| {
                if (sstart == null and sel.start == count * pc.len) sstart = bytes;
                if (scursor == null and sel.cursor == count * pc.len) scursor = bytes;
                if (send == null and sel.end == count * pc.len) send = bytes;
                count += 1;
                bytes += std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            } else {
                if (sstart == null and sel.start >= count * pc.len) sstart = bytes;
                if (scursor == null and sel.cursor >= count * pc.len) scursor = bytes;
                if (send == null and sel.end >= count * pc.len) send = bytes;
            }
            sel.start = sstart.?;
            sel.cursor = scursor.?;
            sel.end = send.?;
        }

        self.drawAfterText();
        return;
    }

    if (dvui.useTreeSitter) {
        if (self.init_opts.tree_sitter) |ts| {
            if (dvui.dataGet(null, self.data().id, "ts_query_failed", bool)) |failed| {
                if (failed) {
                    self.textLayout.addText(self.text[0..self.len], self.data().options.strip());
                    self.textLayout.addTextDone(self.data().options.strip());
                    self.drawAfterText();
                    return;
                }
            }

            // syntax highlighting
            const parser = dvui.dataGetPtr(null, self.data().id, "parser", TreeSitterParser) orelse blk: {
                const p = dvui.c.ts_parser_new();
                _ = dvui.c.ts_parser_set_language(p, @ptrCast(@alignCast(ts.language)));
                const tree = dvui.c.ts_parser_parse_string(p, null, self.text.ptr, @intCast(self.len));

                var errorOffset: u32 = undefined;
                var errorType: dvui.c.TSQueryError = undefined;
                const query = dvui.c.ts_query_new(@ptrCast(@alignCast(ts.language)), ts.queries.ptr, @intCast(ts.queries.len), &errorOffset, &errorType);

                if (query == null) {
                    dvui.log.err("TextEntry tree-sitter query error {} at offset {}", .{ errorType, errorOffset });
                    if (tree) |t| dvui.c.ts_tree_delete(t);
                    if (p) |parser_ptr| dvui.c.ts_parser_delete(parser_ptr);
                    dvui.dataSet(null, self.data().id, "ts_query_failed", true);
                    break :blk null;
                }

                const parser: TreeSitterParser = .{ .parser = p.?, .tree = tree.?, .query = query.? };
                dvui.dataSet(null, self.data().id, "parser", parser);
                dvui.dataSetDeinitFunction(null, self.data().id, "parser", &TreeSitterParser.deinit);
                break :blk dvui.dataGetPtr(null, self.data().id, "parser", TreeSitterParser).?;
            };

            if (parser == null) {
                self.textLayout.addText(self.text[0..self.len], self.data().options.strip());
                self.textLayout.addTextDone(self.data().options.strip());
                self.drawAfterText();
                return;
            }

            var ts_parser = parser.?;

            // used to output text that's not highlighted
            var start: usize = 0;

            if (self.text_changed and !dvui.firstFrame(self.data().id)) {
                const reparse_start = perfBegin();
                defer perfLogReparse(reparse_start);
                if (self.init_opts.cache_layout) {
                    var edit: dvui.c.TSInputEdit = undefined;
                    edit.start_byte = @intCast(self.text_changed_start);
                    edit.old_end_byte = @intCast(self.text_changed_end);
                    edit.new_end_byte = @intCast(@as(i64, @intCast(self.text_changed_end)) + self.text_changed_added);

                    edit.start_point = .{ .row = 0, .column = 0 };
                    edit.old_end_point = .{ .row = 0, .column = 0 };
                    edit.new_end_point = .{ .row = 0, .column = 0 };

                    dvui.c.ts_tree_edit(ts_parser.tree, &edit);

                    const tree = dvui.c.ts_parser_parse_string(ts_parser.parser, ts_parser.tree, self.text.ptr, @intCast(self.len));
                    dvui.c.ts_tree_delete(ts_parser.tree);
                    ts_parser.tree = tree.?;
                } else {
                    const tree = dvui.c.ts_parser_parse_string(ts_parser.parser, null, self.text.ptr, @intCast(self.len));
                    dvui.c.ts_tree_delete(ts_parser.tree);
                    ts_parser.tree = tree.?;
                }
            }

            // parsing
            const root = dvui.c.ts_tree_root_node(ts_parser.tree);

            // queries
            //
            // Self-contained perf logging: `core.gfx.perf`'s counters live in a *separate*
            // copy of that module's globals inside this dylib (the host exe compiles its own
            // copy too — dylib boundaries don't share `pub var` state), so the host's periodic
            // "perf frame" log always reads its own always-zero copy. Log directly from here
            // instead, using file-local statics, so the numbers actually reach the console.
            // const query_start = perfBegin();
            // defer perfLogQuery(query_start, self.len);

            const qc = dvui.c.ts_query_cursor_new();
            defer dvui.c.ts_query_cursor_delete(qc);
            dvui.c.ts_query_cursor_set_match_limit(qc, tree_sitter_match_limit);

            dvui.c.ts_query_cursor_exec(qc, ts_parser.query, root);

            var iter = ts_parser.queryCursorCaptureIterator(qc.?, self.text);
            iter.debug = ts.log_captures;

            // Restrict the capture walk to what's actually on screen — this is the dominant
            // per-frame cost of a highlighted document (see `highlightByteRange` for why it
            // can't just reuse dvui's layout range). Text outside the queried range still
            // renders via the gap/leftover chunks below; it's just uncolored until scrolled
            // into range.
            if (self.highlightByteRange()) |r| {
                iter.setByteRange(r.start, r.end);
            }
            while (true) {
                //const capture_start = perfBegin();
                const maybe_match = iter.next();
                //perfAccumCapture(capture_start);
                const match = maybe_match orelse break;

                const nstart = dvui.c.ts_node_start_byte(match.node);
                const nend = dvui.c.ts_node_end_byte(match.node);
                if (start < nstart) {
                    // render non highlighted text up to this node
                    //const shape_start = perfBegin();
                    self.emitChunk(start, self.text[start..nstart], .{}, false, true);
                    //perfAccumShape(shape_start);
                } else if (nstart < start) {
                    // this match is inside (or overlapping) the previous match
                    // maybe we could be smarter here, but for now drop it
                    continue;
                }

                var opts: dvui.Options = .{};
                const capture_name = match.captureName();
                for (0..ts.highlights.len) |i| {
                    const sh = ts.highlights[ts.highlights.len - i - 1];
                    if (std.mem.startsWith(u8, capture_name, sh.name)) {
                        opts = sh.opts;
                        break;
                    }
                }

                //const shape_start = perfBegin();
                self.emitChunk(nstart, self.text[nstart..nend], opts, true, captureAllowsRainbow(capture_name));
                //perfAccumShape(shape_start);

                start = nend;
            }

            if (start < self.len) {
                // any leftover non highlighted text
                //const shape_start = perfBegin();
                self.emitChunk(start, self.text[start..self.len], .{}, false, true);
                //perfAccumShape(shape_start);
            }

            //const done_start = perfBegin();
            self.textLayout.addTextDone(self.data().options.strip());
            //perfAccumShape(done_start);
            self.drawAfterText();
            return;
        }
    }

    // simple text
    self.emitChunk(0, self.text[0..self.len], self.data().options.strip(), false, true);
    self.textLayout.addTextDone(self.data().options.strip());

    self.drawAfterText();
}

pub const ByteRange = struct { start: usize, end: usize };

/// Byte range the tree-sitter capture walk should cover this frame: what the viewport shows,
/// plus a screenful of headroom on each side so a scroll doesn't outrun the highlighting before
/// the next frame recomputes it. Null means "don't restrict" (first frame, before any layout
/// data exists, or `cache_layout` off).
///
/// Deliberately *not* just `TextLayoutWidget.cache_layout_bytes`, which is what this used to
/// pass straight through. That range answers a different question — which bytes does *layout*
/// have to walk — and it is wrong for highlighting in two ways that both scale badly:
///
///  1. It stretches to cover the caret whenever the caret is off screen (see `bytesNeeded`'s
///     `include_cursor`), so scrolling away from the caret in a large file grew the queried
///     range toward the whole document. Measured on a 3.4k-line file: 2,868 captures per frame
///     while scrolling versus 1,231 sitting still, for pixels that are identical either way.
///  2. The old pad around it was `len / 20` (capped at 8KB), i.e. proportional to the
///     *document*. On that same file it queried ~13.6KB of padding around a ~2KB viewport —
///     87% of the work thrown away — which is why per-frame cost tracked file size even
///     though the visible line count never changed.
///
/// The result is intersected with the layout range because bytes outside that never get emitted
/// this frame anyway, so querying them could only produce captures with nothing to color.
///
/// `byte_heights` is last frame's data, recorded every `ByteHeight.dist` logical pixels — the
/// same source and staleness `bytesNeeded` itself works from, and the coarse spacing only ever
/// makes the range a superset of what's visible.
pub fn highlightByteRange(self: *TextEntryWidget) ?ByteRange {
    const clb = self.textLayout.cache_layout_bytes orelse return null;
    const heights = self.textLayout.byte_heights;
    if (heights.len == 0) return .{ .start = clb.start, .end = clb.end };

    const viewport = self.scroll.si.viewport;
    // Headroom on each side, sized from the viewport rather than the document: enough that a
    // normal scroll stays colored between recomputes, without dragging in text nobody can see.
    const pad = viewport.h / 2;
    const top = viewport.y - pad;
    const bottom = viewport.y + viewport.h + pad;

    var start: usize = 0;
    var end: usize = self.len;
    for (heights) |bh| {
        if (bh.height <= top) start = bh.byte;
        if (bh.height >= bottom) {
            end = bh.byte;
            break;
        }
    }

    return .{
        .start = @max(start, clb.start),
        .end = @min(@min(end, clb.end), self.len),
    };
}

/// One ghost-text splice resolved for this frame: `text` shown dimmed at byte offset `anchor`.
/// `emitChunk` sources this from `current_completion` (acceptable via Tab/Enter) when showing,
/// else `signature_hint` (purely informational, never acceptable) — see `signature_hint`'s doc
/// comment for why only one of the two ever occupies this slot at once.
const Ghost = struct { text: []const u8, anchor: usize };

/// The dimmed suffix to show after the cursor for the selected candidate, or null when this
/// candidate has nothing that can honestly be rendered inline — see `tc.completion.ghostSuffix`
/// for the rules (and why the answer is often "nothing", by design).
fn completionGhost(self: *TextEntryWidget, completion: CompletionState) ?Ghost {
    // `drawCompletion` never sets `current_completion` with an empty `items` — see
    // `TextEditor.zig` — so `selected` is always a valid index here.
    const candidate = completion.items[completion.selected];
    const suffix = tc.completion.ghostSuffix(
        self.text[0..self.len],
        completion.anchor,
        candidate.text,
        candidate.replace_start,
        candidate.replace_end,
    ) orelse return null;
    return .{ .text = suffix, .anchor = completion.anchor };
}

/// Tree-sitter highlight captures where brackets are *content*, not structure — rainbow
/// tint would override the grey comment / green string styling. Names are dotted prefixes
/// (`comment.line`, `string.special`, …), matching how highlight styles are resolved above.
fn captureAllowsRainbow(capture_name: []const u8) bool {
    if (std.mem.startsWith(u8, capture_name, "comment")) return false;
    if (std.mem.startsWith(u8, capture_name, "string")) return false;
    if (std.mem.startsWith(u8, capture_name, "character")) return false;
    return true;
}

/// Emits `chunk` — a slice of `self.text` starting at absolute byte offset `chunk_start` —
/// into `self.textLayout`, exactly like the plain `addText`/`addTextHover` call it replaces
/// (`is_hover` selects which, matching the call site) — except that the chunk is split wherever
/// this frame wants something extra drawn inside it:
///
/// - this frame's `Ghost.anchor`, where dimmed ghost text is spliced between the two halves;
/// - either byte of `bracket_match`, re-emitted on its own with a highlight behind it.
///
/// `allow_rainbow` is false for comment/string captures so brackets inside them keep the
/// capture's colour (grey comments, etc.) instead of the rainbow override. The caret-match
/// wash still applies — it's a fill behind the glyph, not a text-colour steal.
///
/// Doing both through the same text pipeline (rather than painting rects at computed
/// coordinates) is what keeps them correct under wrapping, horizontal scrolling, and
/// `cache_layout`'s viewport culling — a split chunk is still just text runs, laid out by the
/// same code as everything around it.
fn emitChunk(self: *TextEntryWidget, chunk_start: usize, chunk: []const u8, opts: dvui.Options, is_hover: bool, allow_rainbow: bool) void {
    const emitPlain = struct {
        fn call(w: *TextEntryWidget, start: usize, text: []const u8, o: dvui.Options, hover: bool) void {
            if (text.len == 0) return;
            if (hover) {
                // `link_span` (last frame's hover, gated on Ctrl/Cmd — see its doc comment)
                // decides the underline *before* this frame's own hit-test runs below, so a
                // stale span from a token that no longer exists at these exact byte offsets
                // (the document was just edited) simply fails the equality check and falls
                // back to `o` unchanged rather than underlining the wrong text.
                var hover_opts = o;
                if (w.link_span) |ls| {
                    if (ls.start == start and ls.end == start + text.len) {
                        hover_opts = o.override(.{ .font = w.data().options.fontGet().withUnderline(.{}) });
                    }
                }
                if (w.textLayout.addTextHover(text, hover_opts)) |match| {
                    w.hovered_span = .{ .start = start, .end = start + text.len };
                    w.hover_rect = match.rect;
                    // Real-time, unlike the underline above: this is *this* frame's actual
                    // hit-test result, so the hand cursor can react to Ctrl/Cmd the instant
                    // it's pressed or released, not a frame behind.
                    if (dvui.currentWindow().modifiers.matchBind("ctrl/cmd")) {
                        dvui.cursorSet(.hand);
                    }
                }
            } else {
                w.textLayout.addText(text, o);
            }
        }
    }.call;

    const chunk_end = chunk_start + chunk.len;

    // Ghost text to splice inside *this* chunk, if any. `ghost_text_emitted` matters because
    // consecutive chunks touch (one's end byte offset equals the next one's start), so when the
    // anchor sits exactly on that shared boundary both chunks would otherwise believe the
    // anchor is theirs and splice the ghost text twice (e.g. typing `s` and seeing `stdtd`
    // instead of `std` — the ghost suffix `td` spliced in on both sides).
    const ghost: ?Ghost = blk: {
        if (self.ghost_text_emitted) break :blk null;
        const g: Ghost = found: {
            if (self.current_completion) |completion| {
                // A completion showing always claims the ghost-text slot, even when it has no
                // suffix worth drawing (`completionGhost` returning null) — falling through to
                // the signature hint there would flash a hint under an open completion list.
                break :found self.completionGhost(completion) orelse break :blk null;
            }
            if (self.signature_hint) |hint| {
                break :found .{ .text = hint, .anchor = self.textLayout.selectionGet(self.len).cursor };
            }
            break :blk null;
        };
        // Not in this chunk, or unsafe to splice at all (see `CompletionCandidate.text`'s doc
        // comment on the no-newline requirement).
        if (g.anchor < chunk_start or g.anchor > chunk_end) break :blk null;
        if (std.mem.indexOfScalar(u8, g.text, '\n') != null) break :blk null;
        break :blk g;
    };

    // Bracket restyles falling in this chunk — rainbow nesting marks and/or the caret-adjacent
    // match pair. `< chunk_end` rather than `<=`: a bracket exactly on the shared boundary
    // belongs to the next chunk, which is where its byte actually gets emitted. Nest marks are
    // already sorted ascending; the caret pair is at most two bytes and gets merged in.
    var marks_buf: [256]BracketMark = undefined;
    var marks_n: usize = 0;
    {
        var nest_i: usize = 0;
        // Skip nests before this chunk so subsequent chunks don't re-walk them.
        while (nest_i < self.bracket_nests.len and self.bracket_nests[nest_i].byte < chunk_start) : (nest_i += 1) {}
        while (nest_i < self.bracket_nests.len and marks_n < marks_buf.len) : (nest_i += 1) {
            const nm = self.bracket_nests[nest_i];
            if (nm.byte >= chunk_end) break;
            // Skip rainbow marks inside comments/strings — still walk past them so later
            // chunks don't re-scan these bytes. Caret-match merge below can still flag them.
            if (!allow_rainbow) continue;
            marks_buf[marks_n] = .{ .byte = nm.byte, .depth = nm.depth, .caret_match = false };
            marks_n += 1;
        }
        if (self.bracket_match) |bm| {
            for (bm) |m| {
                if (m < chunk_start or m >= chunk_end) continue;
                // Merge onto an existing nest mark at the same byte, or append.
                var merged = false;
                for (marks_buf[0..marks_n]) |*existing| {
                    if (existing.byte == m) {
                        existing.caret_match = true;
                        merged = true;
                        break;
                    }
                }
                if (!merged and marks_n < marks_buf.len) {
                    marks_buf[marks_n] = .{ .byte = m, .depth = null, .caret_match = true };
                    marks_n += 1;
                    // Keep ascending — caret-only marks are rare (≤2) so a tiny insertion is fine.
                    var j = marks_n - 1;
                    while (j > 0 and marks_buf[j].byte < marks_buf[j - 1].byte) : (j -= 1) {
                        const tmp = marks_buf[j - 1];
                        marks_buf[j - 1] = marks_buf[j];
                        marks_buf[j] = tmp;
                    }
                }
            }
        }
    }
    const marks = marks_buf[0..marks_n];

    // The overwhelmingly common case: nothing to splice or restyle in this chunk. Kept first so
    // the per-chunk cost of both features is one null check on frames where neither is showing.
    if (ghost == null and marks.len == 0) {
        emitPlain(self, chunk_start, chunk, opts, is_hover);
        return;
    }

    // Walk the chunk left to right, emitting each plain stretch up to the next splice point.
    // A ghost anchor coinciding with a bracket goes first (it sits *at* the caret, before that
    // byte). Nest marks and the caret-match wash share a single emission when they land on the
    // same glyph.
    var pos = chunk_start;
    var mark_i: usize = 0;
    var pending_ghost = ghost;
    while (mark_i < marks.len or pending_ghost != null) {
        const ghost_at: ?usize = if (pending_ghost) |g| g.anchor else null;
        const mark_at: ?usize = if (mark_i < marks.len) marks[mark_i].byte else null;
        const take_ghost = if (ghost_at) |ga| (mark_at == null or ga <= mark_at.?) else false;
        const at = if (take_ghost) ghost_at.? else mark_at.?;

        emitPlain(self, pos, chunk[pos - chunk_start .. at - chunk_start], opts, is_hover);
        pos = at;

        if (take_ghost) {
            self.emitGhost(pending_ghost.?.text);
            pending_ghost = null;
        } else {
            // Deliberately not `is_hover`: this is a single bracket byte carved out of the
            // middle of a token, and registering it as its own hover span would report a
            // one-byte token to goto-definition/hover. Brackets are never a definition target,
            // so dropping the hit-test for exactly this byte costs nothing.
            emitPlain(self, at, chunk[at - chunk_start ..][0..1], opts.override(bracketStyle(marks[mark_i])), false);
            pos = at + 1;
            mark_i += 1;
        }
    }
    emitPlain(self, pos, chunk[pos - chunk_start ..], opts, is_hover);
}

const BracketMark = struct {
    byte: usize,
    /// Indent-level palette index when rainbow-coloured; null when this mark exists only as a caret match.
    depth: ?u8,
    caret_match: bool,
};

/// Rainbow text colour from the fixed Fizzy palette, plus the caret-match wash when this glyph
/// is the pair next to the caret. The wash still comes from the active theme's highlight so it
/// follows the chrome; the glyph colour does not — that's the point of a fixed palette.
fn bracketStyle(mark: BracketMark) dvui.Options {
    var o: dvui.Options = .{};
    if (mark.depth) |d| o.color_text = palette.bracket(d);
    if (mark.caret_match) o.color_fill = dvui.themeGet().color(.highlight, .fill).opacity(0.35);
    return o;
}

/// Splices `text` into the layout at the current position, dimmed, without letting it count as
/// real document bytes.
///
/// `addTextEx` advances `TextLayoutWidget.bytes_seen` unconditionally, and that counter must
/// track only *real* document bytes for cursor/selection hit-testing (`cursor_rect`, click
/// routing) to stay correct for every chunk emitted after this one — so it gets rewound by the
/// ghost text's length. `bytes_seen` is a plain public field already reached into directly
/// elsewhere in this codebase (e.g. `selection`, `cursor_rect` at `TextEditor.zig`), so this
/// isn't reaching past an abstraction that wants to stay opaque — but the same call path also
/// advances a *second*, independent counter (`cache_layout_bytes_seen`) whenever `cache_layout`
/// is on, which `addTextDone` asserts stays equal to `bytes_seen`; rewinding only `bytes_seen`
/// would desync that pair and trip the assert. Rewinding both in lockstep keeps `cache_layout`
/// usable during a completion — needed now that tree-sitter-highlighted docs rely on it for
/// viewport culling (see `TextEditor.zig`).
fn emitGhost(self: *TextEntryWidget, text: []const u8) void {
    self.ghost_text_emitted = true;
    self.textLayout.addText(text, .{
        .color_text = self.textLayout.data().options.color(.text).opacity(0.5),
    });
    self.textLayout.bytes_seen -= text.len;
    if (self.textLayout.cache_layout) {
        self.textLayout.cache_layout_bytes_seen -= text.len;
    }
}

pub fn drawBeforeText(self: *TextEntryWidget) void {
    const focused = (self.data().id == dvui.focusedWidgetId());

    if (focused) {
        dvui.wantTextInput(self.data().borderRectScale().r.toNatural());
    }

    // set clip back to what textLayout had, so we don't draw over the scrollbars
    dvui.clipSet(self.textClip);

    if (self.init_opts.cache_layout) {
        self.textLayout.cache_layout_bytes = self.textLayout.bytesNeeded(
            self.text_changed_start,
            self.text_changed_end,
            self.text_changed_added,
        );
    }
}

pub fn drawAfterText(self: *TextEntryWidget) void {
    const focused = (self.data().id == dvui.focusedWidgetId());
    if (focused) {
        self.drawCursor();
    }

    dvui.clipSet(self.prevClip);

    if (focused and self.init_opts.focus_border) {
        self.data().focusBorder();
    }
}

pub fn drawCursor(self: *TextEntryWidget) void {
    var sel = self.textLayout.selectionGet(self.len);
    if (sel.empty()) {
        // the cursor can be slightly outside the textLayout clip
        dvui.clipSet(self.scrollClip);

        var crect = self.textLayout.cursor_rect.plus(.{ .x = -1 });
        crect.w = 2;
        self.textLayout.screenRectScale(crect).r.fill(.{}, .{ .color = dvui.themeGet().focus, .fade = 1.0 });
    }
}

pub fn widget(self: *TextEntryWidget) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *TextEntryWidget) *WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *TextEntryWidget, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    _ = id;
    return dvui.placeIn(self.data().contentRect().justSize(), min_size, e, g);
}

pub fn screenRectScale(self: *TextEntryWidget, rect: Rect) RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *TextEntryWidget, s: Size) void {
    self.data().minSizeMax(self.data().options.padSize(s));
}

pub fn textChangedRemoved(self: *TextEntryWidget, start: usize, end: usize) void {
    self.textChanged(start, end, @as(i64, @intCast(start)) - @as(i64, @intCast(end)));
}

// Inserting text is at a single point in the previous frame's indexing.
pub fn textChangedAdded(self: *TextEntryWidget, pos: usize, added: usize) void {
    self.textChanged(pos, pos, @intCast(added));
}

// Only needed when cache_layout is true.  We are maintaining an interval of
// bytes from last frame plus a total number added (might be negative) in that
// interval.  This is sent to textLayout so it will process at least this
// interval (plus whatever is visible).
pub fn textChanged(self: *TextEntryWidget, start: usize, end: usize, added: i64) void {
    self.text_changed = true;
    if (end > self.text_changed_start) {
        // end is in current bytes, so we update it to previous frame's indexing
        var end_old: usize = undefined;
        if (self.text_changed_added >= 0) {
            end_old = end - @as(usize, @intCast(self.text_changed_added));
        } else {
            end_old = end + @as(usize, @intCast(-self.text_changed_added));
        }
        // This assumes that the current update happens after (in bytes) all
        // previous updates.  This is not exact, but will always give an
        // interval that includes all the updates.
        self.text_changed_end = @max(self.text_changed_end, end_old);
    } else {
        // before previous updates then indexing is the same
        self.text_changed_end = @max(self.text_changed_end, end);
    }

    // if we are before the previous updates then the indexing is the same
    self.text_changed_start = @min(self.text_changed_start, start);
    self.text_changed_added += added;

    if (self.textLayout.add_text_done) {
        self.edited_outside_last_frame.* = true;
    }

    //std.debug.print("textChanged {d} {d} {d}\n", .{ self.text_changed_start, self.text_changed_end, self.text_changed_added });
}

/// Return text as a slice to the backing storage.  The returned slice is
/// valid after `deinit`, and is only invalidated by events or functions that
/// change the text (like `textSet` or `paste`).
pub fn textGet(self: *const TextEntryWidget) []u8 {
    return self.text[0..self.len];
}

/// Deprecated in favor of `textGet`.
pub fn getText(self: *const TextEntryWidget) []u8 {
    return self.textGet();
}

pub fn textSet(self: *TextEntryWidget, text: []const u8, selected: bool) void {
    self.textLayout.selection.selectAll();
    self.textTyped(text, selected);
}

pub fn textTyped(self: *TextEntryWidget, new: []const u8, selected: bool) void {
    // strip out carriage returns, which we get from copy/paste on windows
    if (std.mem.findScalar(u8, new, '\r')) |idx| {
        self.textTyped(new[0..idx], selected);
        self.textTyped(new[idx + 1 ..], selected);
        return;
    }

    if (self.init_opts.edit_notify) |en| en.beginEdit(en.ctx, self.currentRange());
    defer if (self.init_opts.edit_notify) |en| en.endEdit(en.ctx, self.currentRange());

    var sel = self.textLayout.selectionGet(self.len);
    if (!sel.empty()) {
        // delete selection
        self.textChangedRemoved(sel.start, sel.end);
        if (self.init_opts.edit_notify) |en| en.noteRemoved(en.ctx, sel.start, self.text[sel.start..sel.end]);
        @memmove(self.text[sel.start..][0 .. self.len - sel.end], self.text[sel.end..self.len]);
        self.len -= (sel.end - sel.start);
        sel.end = sel.start;
        sel.cursor = sel.start;
    }

    const space_left = self.text.len - self.len;
    if (space_left < new.len) {
        var new_size = realloc_bin_size * (@divTrunc(self.len + new.len, realloc_bin_size) + 1);
        switch (self.init_opts.text) {
            .buffer => {},
            .buffer_dynamic => |b| {
                new_size = @min(new_size, b.limit);
                b.backing.* = b.allocator.realloc(self.text, new_size) catch |err| blk: {
                    dvui.logError(@src(), err, "{x} TextEntryWidget.textTyped failed to realloc backing (current size {d}, new size {d})", .{ self.data().id, self.text.len, new_size });
                    break :blk b.backing.*;
                };
                self.text = b.backing.*;
            },
            .array_list => |al| {
                new_size = @min(new_size, al.limit);
                al.backing.ensureTotalCapacity(al.allocator, new_size) catch |err| {
                    dvui.logError(@src(), err, "{x} TextEntryWidget.textTyped failed to realloc ArrayList backing (current size {d}, new size {d})", .{ self.data().id, self.text.len, new_size });
                };
                self.text = al.backing.items.ptr[0..@min(al.limit, al.backing.capacity)];
            },
            .internal => |i| {
                new_size = @min(new_size, i.limit);
                // If we are the same size then there is no work to do
                // This is important because same sized data allocations will be reused
                if (new_size != self.text.len) {
                    // NOTE: Using prev_text is safe because data is trashed and stays valid until the end of the frame
                    const prev_text = self.text;
                    dvui.dataSetSliceCopies(null, self.data().id, "_buffer", &[_]u8{0}, new_size);
                    self.text = dvui.dataGetSlice(null, self.data().id, "_buffer", []u8).?;
                    const min_len = @min(prev_text.len, self.text.len);
                    if (self.text.ptr != prev_text.ptr) {
                        @memcpy(self.text[0..min_len], prev_text[0..min_len]);
                    }
                }
            },
        }
    }
    var new_len = @min(new.len, self.text.len - self.len);

    // find start of last utf8 char
    var last: usize = new_len -| 1;
    while (last < new_len and new[last] & 0xc0 == 0x80) {
        last -|= 1;
    }

    // if the last utf8 char can't fit, don't include it
    if (last < new_len) {
        const utf8_size = std.unicode.utf8ByteSequenceLength(new[last]) catch 0;
        if (utf8_size != (new_len - last)) {
            new_len = last;
        }
    }

    // make room if we can
    if (new_len > 0 and sel.cursor + new_len < self.text.len) {
        @memmove(self.text[sel.cursor + new_len ..][0 .. self.len - sel.cursor], self.text[sel.cursor..self.len]);
    }

    if (new_len > 0) {
        self.textChangedAdded(sel.cursor, new_len);
        if (self.init_opts.edit_notify) |en| en.noteInserted(en.ctx, sel.cursor, new[0..new_len]);
    }

    // update our len and maintain 0 termination if possible
    self.setLen(self.len + new_len);

    // insert
    @memmove(self.text[sel.cursor..][0..new_len], new[0..new_len]);
    if (selected) {
        sel.start = sel.cursor;
        sel.cursor += new_len;
        sel.end = sel.cursor;
    } else {
        sel.cursor += new_len;
        sel.end = sel.cursor;
        sel.start = sel.cursor;
    }
    if (std.mem.findScalar(u8, new[0..new_len], '\n') != null) {
        sel.affinity = .after;
    }

    // we might have dropped to a new line, so make sure the cursor is visible
    self.textLayout.scroll_to_cursor_next_frame = true;
    dvui.refresh(null, @src(), self.data().id);
}

/// Remove all characters that not present in filter_chars.
/// Designed to run after event processing and before drawing.
pub fn filterIn(self: *TextEntryWidget, filter_chars: []const u8) void {
    if (filter_chars.len == 0) {
        return;
    }

    var i: usize = 0;
    var j: usize = 0;
    const n = self.len;
    while (i < n) {
        if (std.mem.findScalar(u8, filter_chars, self.text[i]) == null) {
            self.len -= 1;
            var sel = self.textLayout.selection;
            if (sel.start > i) sel.start -= 1;
            if (sel.cursor > i) sel.cursor -= 1;
            if (sel.end > i) sel.end -= 1;
            self.text_changed = true;

            i += 1;
        } else {
            self.text[j] = self.text[i];
            i += 1;
            j += 1;
        }
    }

    if (j < self.text.len)
        self.text[j] = 0;
}

/// Remove all instances of the string needle.
/// Designed to run after event processing and before drawing.
pub fn filterOut(self: *TextEntryWidget, needle: []const u8) void {
    if (needle.len == 0) {
        return;
    }

    var i: usize = 0;
    var j: usize = 0;
    const n = self.len;
    while (i < n) {
        if (std.mem.startsWith(u8, self.text[i..], needle)) {
            self.len -= needle.len;
            var sel = self.textLayout.selection;
            if (sel.start > i) sel.start -= needle.len;
            if (sel.cursor > i) sel.cursor -= needle.len;
            if (sel.end > i) sel.end -= needle.len;
            self.text_changed = true;

            i += needle.len;
        } else {
            self.text[j] = self.text[i];
            i += 1;
            j += 1;
        }
    }

    if (j < self.text.len)
        self.text[j] = 0;
}

/// Sets the new length and does fixups:
/// - add null terminator if there is space
/// - shrink allocation if needed
/// - fixup array_list backing
pub fn setLen(self: *TextEntryWidget, newlen: usize) void {
    self.len = newlen;

    // add null terminator if there is space
    if (self.len < self.text.len) {
        self.text[self.len] = 0;
    }

    // shrink allocation if needed
    const needed_binds = @divTrunc(self.len, realloc_bin_size) + 1;
    const current_bins = @divTrunc(self.text.len, realloc_bin_size);
    // dvui.log.debug("TextEntry {x} needs {d} bins, has {d}", .{ self.data().id, needed_binds, current_bins });
    if (self.len == 0 or needed_binds < current_bins) {
        // we want to shrink the allocation
        const new_len = if (self.len == 0) 0 else realloc_bin_size * needed_binds;
        switch (self.init_opts.text) {
            .buffer => {},
            .buffer_dynamic => |b| {
                if (b.allocator.resize(self.text, new_len)) {
                    b.backing.*.len = new_len;
                    self.text.len = new_len;
                } else {
                    dvui.logError(@src(), std.mem.Allocator.Error.OutOfMemory, "{x} TextEntryWidget.textTyped failed to realloc backing (current size {d}, new size {d})", .{ self.data().id, self.text.len, new_len });
                }
            },
            .array_list => |al| {
                if (new_len < al.backing.capacity / 2) {
                    al.backing.items.len = al.backing.capacity;
                    al.backing.shrinkAndFree(al.allocator, new_len);
                    self.text = al.backing.items.ptr[0..@min(al.limit, al.backing.capacity)];
                }
            },
            .internal => {
                // NOTE: Using prev_text is safe because data is trashed and stays valid until the end of the frame
                const prev_text = self.text;
                dvui.dataSetSliceCopies(null, self.data().id, "_buffer", &[_]u8{0}, new_len);
                self.text = dvui.dataGetSlice(null, self.data().id, "_buffer", []u8).?;
                const min_len = @min(prev_text.len, self.text.len);
                @memcpy(self.text[0..min_len], prev_text[0..min_len]);
            },
        }
    }

    // fixup array_list backing
    switch (self.init_opts.text) {
        .array_list => |al| {
            al.backing.items.len = self.len;
        },
        else => {},
    }
}

pub fn processEvent(self: *TextEntryWidget, e: *Event) void {
    // scroll gets first crack, because it is logically outside the text area
    self.scroll.scroll.?.processEvent(e);
    if (e.handled) return;

    switch (e.evt) {
        .key => |ke| blk: {
            // No `matchBind` name for escape exists anywhere in this codebase (checked
            // directly by name, e.g. in dvui's own `Window.zig`) — mirror that rather than
            // inventing a keybind. Only consumes the event when a completion is actually
            // showing, so it falls through to whatever else handles Escape otherwise.
            if (self.current_completion != null and ke.code == .escape and ke.action == .down) {
                e.handle(@src(), self.data());
                self.current_completion = null;
                break :blk;
            }

            // Up/Down move the selected candidate instead of the caret while a completion
            // list is showing — intercepted ahead of the normal `char_up`/`char_down` caret
            // movement below. Wraps at either end, matching common dropdown-list convention.
            if (self.current_completion) |*completion| {
                if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_up")) {
                    e.handle(@src(), self.data());
                    completion.selected = if (completion.selected == 0) completion.items.len - 1 else completion.selected - 1;
                    completion.scroll_to_selected = true;
                    break :blk;
                }
                if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_down")) {
                    e.handle(@src(), self.data());
                    completion.selected = if (completion.selected + 1 >= completion.items.len) 0 else completion.selected + 1;
                    completion.scroll_to_selected = true;
                    break :blk;
                }
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("next_widget")) {
                if (self.acceptCompletion()) {
                    e.handle(@src(), self.data());
                    break :blk;
                }
                if (self.init_opts.multiline and self.init_opts.tab_inserts_indent) {
                    e.handle(@src(), self.data());
                    self.insertIndent();
                    break :blk;
                }
                e.handle(@src(), self.data());
                dvui.tabIndexNext(e.num);
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("prev_widget")) {
                e.handle(@src(), self.data());
                dvui.tabIndexPrev(e.num);
                break :blk;
            }

            if (!self.init_opts.external_copy_paste and ke.action == .down and ke.matchBind("paste")) {
                e.handle(@src(), self.data());
                self.paste();
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("cut")) {
                e.handle(@src(), self.data());
                self.cut();
                break :blk;
            }

            if (!self.init_opts.external_copy_paste and ke.action == .down and ke.matchBind("copy")) {
                e.handle(@src(), self.data());
                self.copy();
                break :blk;
            }

            // All keyboard motion, resolved in-model. See `motion_binds` / `applyMotion`.
            if (ke.action == .down or ke.action == .repeat) {
                inline for (motion_binds) |m| {
                    if (ke.matchBind(m.bind)) {
                        e.handle(@src(), self.data());
                        self.applyMotion(m.granularity, m.dir, false);
                        break :blk;
                    }
                    if (ke.matchBind(m.bind ++ "_select")) {
                        e.handle(@src(), self.data());
                        self.applyMotion(m.granularity, m.dir, true);
                        break :blk;
                    }
                }
            }

            switch (ke.code) {
                .backspace => {
                    if (ke.action == .down or ke.action == .repeat) {
                        e.handle(@src(), self.data());
                        if (self.init_opts.edit_notify) |en| en.beginEdit(en.ctx, self.currentRange());
                        defer if (self.init_opts.edit_notify) |en| en.endEdit(en.ctx, self.currentRange());
                        var sel = self.textLayout.selectionGet(self.len);
                        if (!sel.empty()) {
                            // just delete selection
                            self.textChangedRemoved(sel.start, sel.end);
                            if (self.init_opts.edit_notify) |en| en.noteRemoved(en.ctx, sel.start, self.text[sel.start..sel.end]);
                            @memmove(self.text[sel.start..][0 .. self.len - sel.end], self.text[sel.end..self.len]);
                            self.setLen(self.len - (sel.end - sel.start));
                            sel.end = sel.start;
                            sel.cursor = sel.start;
                            self.textLayout.scroll_to_cursor = true;
                        } else if (ke.matchBind("delete_prev_word")) {
                            // delete word before cursor

                            const oldcur = sel.cursor;
                            // find end of last word
                            if (sel.cursor > 0 and std.mem.findAny(u8, self.text[sel.cursor - 1 ..][0..1], " \n") != null) {
                                sel.cursor = std.mem.findLastNone(u8, self.text[0..sel.cursor], " \n") orelse 0;
                            }

                            // find start of word
                            if (std.mem.findLastAny(u8, self.text[0..sel.cursor], " \n")) |last_space| {
                                sel.cursor = last_space + 1;
                            } else {
                                sel.cursor = 0;
                            }

                            // delete from sel.cursor to oldcur
                            if (sel.cursor != oldcur) {
                                self.textChangedRemoved(sel.cursor, oldcur);
                                if (self.init_opts.edit_notify) |en| en.noteRemoved(en.ctx, sel.cursor, self.text[sel.cursor..oldcur]);
                            }
                            @memmove(self.text[sel.cursor..][0 .. self.len - oldcur], self.text[oldcur..self.len]);
                            self.setLen(self.len - (oldcur - sel.cursor));
                            sel.end = sel.cursor;
                            sel.start = sel.cursor;
                            self.textLayout.scroll_to_cursor = true;
                        } else if (self.betweenEmptyPair(sel.cursor)) {
                            // Take out both halves of an empty pair at once — deleting the `{` of
                            // `{|}` and leaving the orphaned `}` behind is never what was meant.
                            const start = sel.cursor - 1;
                            const end = sel.cursor + 1;
                            self.textChangedRemoved(start, end);
                            if (self.init_opts.edit_notify) |en| en.noteRemoved(en.ctx, start, self.text[start..end]);
                            @memmove(self.text[start..][0 .. self.len - end], self.text[end..self.len]);
                            self.setLen(self.len - 2);
                            sel.cursor = start;
                            sel.start = start;
                            sel.end = start;
                            self.textLayout.scroll_to_cursor = true;
                        } else if (sel.cursor > 0) {
                            // delete character just before cursor
                            //
                            // A utf8 char might consist of more than one byte.
                            // Find the beginning of the last byte by iterating over
                            // the string backwards. The first byte of a utf8 char
                            // does not have the pattern 10xxxxxx.
                            var i: usize = 1;
                            while (sel.cursor - i > 0 and self.text[sel.cursor - i] & 0xc0 == 0x80) : (i += 1) {}
                            self.textChangedRemoved(sel.cursor - i, sel.cursor);
                            if (self.init_opts.edit_notify) |en| en.noteRemoved(en.ctx, sel.cursor - i, self.text[sel.cursor - i .. sel.cursor]);
                            @memmove(self.text[sel.cursor - i ..][0 .. self.len - sel.cursor], self.text[sel.cursor..self.len]);
                            self.setLen(self.len - i);
                            sel.cursor -= i;
                            sel.start = sel.cursor;
                            sel.end = sel.cursor;
                            self.textLayout.scroll_to_cursor = true;
                        }
                    }
                },
                .delete => {
                    if (ke.action == .down or ke.action == .repeat) {
                        e.handle(@src(), self.data());
                        if (self.init_opts.edit_notify) |en| en.beginEdit(en.ctx, self.currentRange());
                        defer if (self.init_opts.edit_notify) |en| en.endEdit(en.ctx, self.currentRange());
                        var sel = self.textLayout.selectionGet(self.len);
                        if (!sel.empty()) {
                            // just delete selection
                            self.textChangedRemoved(sel.start, sel.end);
                            if (self.init_opts.edit_notify) |en| en.noteRemoved(en.ctx, sel.start, self.text[sel.start..sel.end]);
                            @memmove(self.text[sel.start..][0 .. self.len - sel.end], self.text[sel.end..self.len]);
                            self.setLen(self.len - (sel.end - sel.start));
                            sel.end = sel.start;
                            sel.cursor = sel.start;
                            self.textLayout.scroll_to_cursor = true;
                        } else if (ke.matchBind("delete_next_word")) {
                            // delete word after cursor

                            const oldcur = sel.cursor;
                            // find start of next word
                            if (sel.cursor < self.len and std.mem.findAny(u8, self.text[sel.cursor..][0..1], " \n") != null) {
                                sel.cursor = std.mem.findNonePos(u8, self.text, sel.cursor, " \n") orelse self.len;
                            }

                            // find end of word
                            if (std.mem.findAny(u8, self.text[sel.cursor..self.len], " \n")) |last_space| {
                                sel.cursor = sel.cursor + last_space;
                            } else {
                                sel.cursor = self.len;
                            }

                            // delete from oldcur to sel.cursor
                            if (sel.cursor != oldcur) {
                                self.textChangedRemoved(oldcur, sel.cursor);
                                if (self.init_opts.edit_notify) |en| en.noteRemoved(en.ctx, oldcur, self.text[oldcur..sel.cursor]);
                            }
                            @memmove(self.text[oldcur..][0 .. self.len - sel.cursor], self.text[sel.cursor..self.len]);
                            self.setLen(self.len - (sel.cursor - oldcur));
                            sel.cursor = oldcur;
                            sel.end = sel.cursor;
                            sel.start = sel.cursor;
                            self.textLayout.scroll_to_cursor = true;
                        } else if (sel.cursor < self.len) {
                            // delete the character just after the cursor
                            //
                            // A utf8 char might consist of more than one byte.
                            const ii = std.unicode.utf8ByteSequenceLength(self.text[sel.cursor]) catch 1;
                            const i = @min(ii, self.len - sel.cursor);

                            self.textChangedRemoved(sel.cursor, sel.cursor + i);
                            if (self.init_opts.edit_notify) |en| en.noteRemoved(en.ctx, sel.cursor, self.text[sel.cursor..][0..i]);
                            const remaining = self.len - (sel.cursor + i);
                            @memmove(self.text[sel.cursor..][0..remaining], self.text[sel.cursor + i ..][0..remaining]);
                            self.setLen(self.len - i);
                            self.textLayout.scroll_to_cursor = true;
                        }
                    }
                },
                .enter => {
                    if (ke.action == .down or ke.action == .repeat) {
                        e.handle(@src(), self.data());
                        if (self.acceptCompletion()) {
                            // Accepted, not inserted — a second Enter (now with nothing
                            // showing) inserts the newline normally.
                        } else if (self.init_opts.multiline and self.init_opts.auto_indent_newline) {
                            self.insertNewlineWithIndent();
                        } else if (self.init_opts.multiline) {
                            self.textTyped("\n", false);
                        } else if (ke.action == .down) {
                            self.enter_pressed = true;
                            dvui.refresh(null, @src(), self.data().id);
                        }
                    }
                },
                else => {},
            }
        },
        .text => |te| {
            switch (te.action) {
                .value => |set| {
                    e.handle(@src(), self.data());
                    var new = std.mem.sliceTo(set.txt, 0);
                    if (self.init_opts.multiline) {
                        // Only single, committed characters take the auto-pair path: `set.selected`
                        // marks in-progress IME composition (which gets replaced wholesale on the
                        // next event, so inserting a closer mid-composition would strand it), and a
                        // multi-byte `new` is a paste or a composed sequence, never a keystroke.
                        const auto_paired = self.init_opts.auto_close_pairs and new.len == 1 and
                            !set.selected and self.handleAutoPair(new[0]);
                        if (!auto_paired) self.textTyped(new, set.selected);
                    } else {
                        var i: usize = 0;
                        while (i < new.len) {
                            if (std.mem.findScalar(u8, new[i..], '\n')) |idx| {
                                self.textTyped(new[i..][0..idx], set.selected);
                                i += idx + 1;
                            } else {
                                self.textTyped(new[i..], set.selected);
                                break;
                            }
                        }
                    }
                },
                else => {},
            }
        },
        .mouse => |me| {
            if (me.action == .focus) {
                e.handle(@src(), self.data());
                dvui.focusWidget(self.data().id, null, e.num);
            }
        },
        else => {},
    }

    if (!e.handled) {
        self.textLayout.processEvent(e);

        if (!e.handled and e.evt == .key) {
            switch (e.evt.key.code) {
                .page_up, .page_down => {}, // handled by scroll container
                else => {
                    // Mark all remaining key events as handled. This allows
                    // checking a keybind (like "d") after the textEntry, but
                    // where textEntry will get it first. Ctrl/Command/Alt combos are
                    // excluded: those never produce a `.text` composition event (so there's
                    // nothing here to protect from double-typing), and on Windows/Linux
                    // global shell shortcuts (save, save-as, paste, ...) are only ever
                    // delivered through this same dvui event stream — macOS instead routes
                    // them via native NSMenu key equivalents, so this swallow was invisible
                    // there. Without this exclusion, focusing the editor silently ate every
                    // Ctrl-modified hotkey (see Keybinds.tick's `if (e.handled) continue`).
                    if (!e.evt.key.mod.control() and !e.evt.key.mod.command() and !e.evt.key.mod.alt()) {
                        e.handle(@src(), self.data());
                    }
                },
            }
        }
    }
}

pub fn paste(self: *TextEntryWidget) void {
    const clip_text = dvui.clipboardText();

    if (self.init_opts.multiline) {
        self.textTyped(clip_text, false);
    } else {
        var i: usize = 0;
        while (i < clip_text.len) {
            if (std.mem.findScalar(u8, clip_text[i..], '\n')) |idx| {
                self.textTyped(clip_text[i..][0..idx], false);
                i += idx + 1;
            } else {
                self.textTyped(clip_text[i..], false);
                break;
            }
        }
    }
}

/// If a completion list is currently showing, replaces `[replace_start, replace_end)` with
/// the *selected* candidate's text (via `textTyped`, which already deletes whatever the
/// selection covers before inserting — the same mechanism a normal keystroke uses to replace
/// a selection), clears `current_completion`, and returns true. Returns false (no-op) when
/// nothing is showing. Shared by Tab and Enter (which both accept-if-showing before falling
/// through to their normal behavior — indent / newline) and by `TextEditor.drawCompletionList`
/// (clicking a row selects it, then calls this to accept the click).
pub fn acceptCompletion(self: *TextEntryWidget) bool {
    const completion = self.current_completion orelse return false;
    self.current_completion = null;
    const candidate = completion.items[completion.selected];

    const sel = self.textLayout.selectionGet(self.len);
    sel.start = candidate.replace_start;
    sel.cursor = candidate.replace_end;
    sel.end = candidate.replace_end;

    self.textTyped(candidate.text, false);
    self.textLayout.scroll_to_cursor = true;

    if (candidate.kind == .function or candidate.kind == .method) {
        self.autoInsertCallParens();
    }
    return true;
}

/// After accepting a function/method completion, adds `()` and leaves the cursor between them
/// so the user can start typing arguments immediately — VSCode does the same. Skips inserting
/// (just moves the cursor inside instead) when the cursor already sits directly before an
/// existing `()`, so completing a call whose parens were already typed doesn't duplicate them.
fn autoInsertCallParens(self: *TextEntryWidget) void {
    const cursor = self.textLayout.selectionGet(self.len).cursor;
    if (cursor + 1 < self.len and self.text[cursor] == '(' and self.text[cursor + 1] == ')') {
        const sel = self.textLayout.selectionGet(self.len);
        sel.start = cursor + 1;
        sel.cursor = cursor + 1;
        sel.end = cursor + 1;
        self.textLayout.scroll_to_cursor = true;
        return;
    }

    self.textTyped("()", false);
    const sel = self.textLayout.selectionGet(self.len);
    sel.start -= 1;
    sel.cursor -= 1;
    sel.end -= 1;
    self.textLayout.scroll_to_cursor = true;
}

/// Single-cursor indentation insert only — no multi-line block indent in this first pass (an
/// active selection just gets replaced by the indent text, same as typing any other
/// character over a selection; see `tab_inserts_indent`'s doc comment). Snaps to the next
/// tab stop when inserting spaces, matching VSCode's default Tab behavior: after 2 typed
/// characters, Tab adds 2 spaces to reach column 4, not a flat 4 more.
// -- keyboard motion ---------------------------------------------------------------------------
//
// Motion is resolved in `textcore.movement` against the byte buffer, immediately, and only
// then written into dvui's `Selection`. The previous path instead set
// `TextLayoutWidget.sel_move` — a **single-slot** union resolved later during the render pass,
// which meant a second motion arriving in the same frame was dropped on the floor (every
// handler was guarded by `if (sel_move == .none)`) and up/down round-tripped through
// `dataSet`/`dataGet` across two frames. dvui's Selection is now a projection, not the source
// of truth; the only place layout still owns a selection change is mouse hit-testing, which
// genuinely needs glyph positions.

/// Sticky goal column for vertical motion. Lives in dvui's per-widget store because the
/// widget struct itself is rebuilt every frame. dvui garbage-collects this the first frame
/// the widget isn't drawn, which is the behaviour we want — switching tabs should not carry a
/// stale target column back.
const goal_col_key = "_textcore_goal_col";

fn currentRange(self: *TextEntryWidget) tc.Range {
    const sel = self.textLayout.selectionGet(self.len);
    // dvui stores an ordered {start, end} plus a cursor; recover the anchor/head direction
    // from which end the cursor sits at, so a backwards selection keeps extending backwards.
    const r: tc.Range = if (sel.cursor == sel.start and sel.start != sel.end)
        .init(sel.end, sel.start)
    else
        .init(sel.start, sel.end);
    return .{
        .anchor = r.anchor,
        .head = r.head,
        .goal_col = dvui.dataGet(null, self.data().id, goal_col_key, u32),
    };
}

fn setRange(self: *TextEntryWidget, r: tc.Range) void {
    const sel = self.textLayout.selectionGet(self.len);
    sel.cursor = r.head;
    sel.start = r.start();
    sel.end = r.end();
    sel.affinity = .after;

    if (r.goal_col) |g| {
        dvui.dataSet(null, self.data().id, goal_col_key, g);
    } else {
        dvui.dataRemove(null, self.data().id, goal_col_key);
    }
    self.textLayout.scroll_to_cursor = true;
}

fn moveOpts(self: *TextEntryWidget) tc.MoveOpts {
    return .{ .tab_size = if (self.init_opts.tab_size == 0) 4 else @intCast(self.init_opts.tab_size) };
}

fn applyMotion(self: *TextEntryWidget, g: tc.Granularity, dir: tc.Dir, extend: bool) void {
    self.setRange(tc.movement.move(
        self.text[0..self.len],
        self.currentRange(),
        g,
        dir,
        extend,
        self.moveOpts(),
    ));
}

/// Keyboard motions, as (dvui keybind name, granularity, direction). Each entry also covers
/// its `<name>_select` shift variant — dvui defines those binds, but neither this widget nor
/// upstream's ever handled them, so shift+arrow selected nothing at all.
const motion_binds = [_]struct {
    bind: []const u8,
    granularity: tc.Granularity,
    dir: tc.Dir,
}{
    // Most-specific modifiers first. The binds are mutually exclusive on both platforms
    // (`char_left` requires alt/control *up*, `word_left` requires it down), so this is
    // ordering for readability rather than correctness.
    .{ .bind = "text_start", .granularity = .document, .dir = .backward },
    .{ .bind = "text_end", .granularity = .document, .dir = .forward },
    .{ .bind = "line_start", .granularity = .line_boundary, .dir = .backward },
    .{ .bind = "line_end", .granularity = .line_boundary, .dir = .forward },
    .{ .bind = "word_left", .granularity = .word, .dir = .backward },
    .{ .bind = "word_right", .granularity = .word, .dir = .forward },
    .{ .bind = "char_left", .granularity = .char, .dir = .backward },
    .{ .bind = "char_right", .granularity = .char, .dir = .forward },
    .{ .bind = "char_up", .granularity = .line, .dir = .backward },
    .{ .bind = "char_down", .granularity = .line, .dir = .forward },
};

fn insertIndent(self: *TextEntryWidget) void {
    const tab_size: usize = if (self.init_opts.tab_size == 0) 4 else self.init_opts.tab_size;
    if (!self.init_opts.insert_spaces) {
        self.textTyped("\t", false);
        return;
    }

    const cursor = self.textLayout.selectionGet(self.len).cursor;
    const line_start = if (std.mem.lastIndexOfScalar(u8, self.text[0..cursor], '\n')) |nl| nl + 1 else 0;
    const column = cursor - line_start;
    const n = tab_size - (column % tab_size);

    var buf: [16]u8 = undefined;
    const spaces = buf[0..@min(n, buf.len)];
    @memset(spaces, ' ');
    self.textTyped(spaces, false);
}

/// Copies the leading whitespace (spaces/tabs) of the line containing byte offset `pos`,
/// bounded by `buf.len` — indentation deeper than that just stops growing on Enter, not a
/// correctness issue at any indentation depth anyone would actually use.
fn copyLineIndent(text: []const u8, pos: usize, buf: []u8) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |nl| nl + 1 else 0;
    var end = line_start;
    while (end < text.len and (text[end] == ' ' or text[end] == '\t') and (end - line_start) < buf.len) : (end += 1) {
        buf[end - line_start] = text[end];
    }
    return buf[0 .. end - line_start];
}

/// One level of indentation, using the same `insert_spaces`/`tab_size` settings as
/// `insertIndent`.
fn oneIndentUnit(self: *TextEntryWidget, buf: []u8) []const u8 {
    if (!self.init_opts.insert_spaces) {
        buf[0] = '\t';
        return buf[0..1];
    }
    const tab_size: usize = if (self.init_opts.tab_size == 0) 4 else self.init_opts.tab_size;
    const n = @min(tab_size, buf.len);
    @memset(buf[0..n], ' ');
    return buf[0..n];
}

/// Applies `tc.pairs.onTyped`'s decision for a single typed character — see `auto_close_pairs`
/// for the behavior and `pairs.zig` for the rules. Returns true when it fully handled `ch` (the
/// caller must not also insert it), false to let the normal insert path run.
fn handleAutoPair(self: *TextEntryWidget, ch: u8) bool {
    const sel = self.textLayout.selectionGet(self.len);
    switch (tc.pairs.onTyped(self.text[0..self.len], sel.start, sel.end, ch)) {
        .insert => return false,
        .step_over => {
            sel.cursor += 1;
            sel.start = sel.cursor;
            sel.end = sel.cursor;
            self.textLayout.scroll_to_cursor = true;
            return true;
        },
        .surround => |p| return self.surroundSelection(p),
        .close_pair => |p| {
            const both = [_]u8{ p.open, p.close };
            self.textTyped(&both, false);

            const after = self.textLayout.selectionGet(self.len);
            if (after.cursor > 0) {
                after.cursor -= 1;
                after.start = after.cursor;
                after.end = after.cursor;
            }
            self.textLayout.scroll_to_cursor = true;
            return true;
        },
    }
}

/// Wraps the active selection in `p` instead of replacing it (VSCode's `editor.autoSurround`),
/// leaving the same text selected inside the new pair. Built as one `textTyped` call over an
/// arena copy so it lands as a single undo step; on allocation failure it returns false and the
/// caller falls back to the plain "typing replaces the selection" behavior.
fn surroundSelection(self: *TextEntryWidget, p: tc.pairs.Pair) bool {
    const sel = self.textLayout.selectionGet(self.len);
    const start = sel.start;
    const end = @min(sel.end, self.len);
    if (end <= start) return false;

    const inner = self.text[start..end];
    const arena = dvui.currentWindow().arena();
    const wrapped = arena.alloc(u8, inner.len + 2) catch return false;
    wrapped[0] = p.open;
    @memcpy(wrapped[1..][0..inner.len], inner);
    wrapped[inner.len + 1] = p.close;

    self.textTyped(wrapped, false);

    // `textTyped` can insert less than asked when the buffer hits its limit, so re-derive the
    // inner span from where the cursor actually ended up rather than trusting `inner.len`.
    const after = self.textLayout.selectionGet(self.len);
    const inner_end = after.cursor -| 1;
    after.start = @min(start + 1, inner_end);
    after.end = inner_end;
    after.cursor = inner_end;
    self.textLayout.scroll_to_cursor = true;
    return true;
}

fn betweenEmptyPair(self: *TextEntryWidget, cursor: usize) bool {
    return self.init_opts.auto_close_pairs and tc.pairs.deletesPair(self.text[0..self.len], cursor);
}

/// VSCode-style Enter: carries the current line's leading whitespace onto the new line, adds
/// one more indent level after an opening bracket (`{`, `(`, `[`), and — when the cursor sits
/// directly between a matching bracket pair — splits it onto three lines with the closer
/// re-dedented to the original line's indent, cursor left on the middle (indented) line.
fn insertNewlineWithIndent(self: *TextEntryWidget) void {
    const cursor = self.textLayout.selectionGet(self.len).cursor;
    var indent_buf: [128]u8 = undefined;
    const indent = copyLineIndent(self.text[0..self.len], cursor, &indent_buf);

    const prev: ?u8 = if (cursor > 0) self.text[cursor - 1] else null;
    const next: ?u8 = if (cursor < self.len) self.text[cursor] else null;
    const opens = "{([";
    const closes = "})]";
    const opener_idx = if (prev) |p| std.mem.indexOfScalar(u8, opens, p) else null;

    var unit_buf: [16]u8 = undefined;
    const unit = if (opener_idx != null) self.oneIndentUnit(&unit_buf) else "";

    var first_buf: [160]u8 = undefined;
    var first_len: usize = 0;
    first_buf[first_len] = '\n';
    first_len += 1;
    @memcpy(first_buf[first_len..][0..indent.len], indent);
    first_len += indent.len;
    @memcpy(first_buf[first_len..][0..unit.len], unit);
    first_len += unit.len;
    self.textTyped(first_buf[0..first_len], false);

    if (opener_idx) |idx| {
        if (next != null and next.? == closes[idx]) {
            const cursor_after_first = self.textLayout.selectionGet(self.len).cursor;

            var second_buf: [136]u8 = undefined;
            var second_len: usize = 0;
            second_buf[second_len] = '\n';
            second_len += 1;
            @memcpy(second_buf[second_len..][0..indent.len], indent);
            second_len += indent.len;
            self.textTyped(second_buf[0..second_len], false);

            const sel = self.textLayout.selectionGet(self.len);
            sel.start = cursor_after_first;
            sel.cursor = cursor_after_first;
            sel.end = cursor_after_first;
        }
    }

    self.textLayout.scroll_to_cursor = true;
}

pub fn cut(self: *TextEntryWidget) void {
    var sel = self.textLayout.selectionGet(self.len);
    if (!sel.empty()) {
        // copy selection to clipboard
        dvui.clipboardTextSet(self.text[sel.start..sel.end]);

        // Same begin/note/end path as backspace-over-selection — without it the buffer
        // shrinks while History still thinks the cut bytes are there, and the next undo
        // either partially applies then hits EditOutOfRange, or key-repeat spams that error.
        if (self.init_opts.edit_notify) |en| en.beginEdit(en.ctx, self.currentRange());
        defer if (self.init_opts.edit_notify) |en| en.endEdit(en.ctx, self.currentRange());

        self.textChangedRemoved(sel.start, sel.end);
        if (self.init_opts.edit_notify) |en| en.noteRemoved(en.ctx, sel.start, self.text[sel.start..sel.end]);
        @memmove(self.text[sel.start..][0 .. self.len - sel.end], self.text[sel.end..self.len]);
        self.setLen(self.len - (sel.end - sel.start));
        sel.end = sel.start;
        sel.cursor = sel.start;
        self.textLayout.scroll_to_cursor = true;
    }
}

/// This could use textLayout.copy(), but that doesn't work if we have a masked
/// password field (textLayout only sees the password char).
pub fn copy(self: *TextEntryWidget) void {
    var sel = self.textLayout.selectionGet(self.len);
    if (!sel.empty()) {
        // copy selection to clipboard
        dvui.clipboardTextSet(self.text[sel.start..sel.end]);
    }
}

pub fn deinit(self: *TextEntryWidget) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    // set clip back to what textLayout had, because it might need it to set
    // the mouse cursor
    dvui.clipSet(self.textClip);
    self.textLayout.deinit();
    self.scroll.deinit();

    dvui.clipSet(self.prevClip);
    self.data().minSizeSetAndRefresh();
    self.data().minSizeReportToParent();
    dvui.parentReset(self.data().id, self.data().parent);
}

/// Same lifecycle as `dvui.textEntry`.
pub fn textEntry(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) *TextEntryWidget {
    var ret = dvui.widgetAlloc(TextEntryWidget);
    ret.init(src, init_opts, opts);
    ret.processEvents();
    ret.draw();
    return ret;
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "text internal" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const Local = struct {
        var text: []const u8 = "";

        // Set a limit that is not a multiple of the bin size
        const limit = realloc_bin_size * 5 / 2;

        fn frame() !dvui.App.Result {
            var entry: TextEntryWidget = undefined;
            entry.init(@src(), .{
                .text = .{ .internal = .{ .limit = limit } },
            }, .{ .tag = "entry" });
            defer entry.deinit();

            entry.processEvents();
            entry.draw();
            text = entry.getText();
            return .ok;
        }
    };

    try dvui.testing.settle(Local.frame);
    try dvui.testing.pressKey(.tab, .none);
    try dvui.testing.settle(Local.frame);
    try dvui.testing.expectFocused("entry");

    const text = "This is some short sample text!";
    // text length should not be a multiple of the limit or bin size
    try std.testing.expect(Local.limit % text.len != 0);
    try std.testing.expect(realloc_bin_size % text.len != 0);

    try dvui.testing.writeText(text);
    try dvui.testing.settle(Local.frame);
    try std.testing.expectEqualStrings(text, Local.text);

    for (0..@divFloor(Local.limit, text.len)) |_| {
        // Fill the internal buffer
        try dvui.testing.writeText(text);
    }
    try dvui.testing.settle(Local.frame);

    const full_text_buffer = comptime blk: {
        var text_buf: []const u8 = text;
        while (text_buf.len < Local.limit) text_buf = text_buf ++ text;
        break :blk text_buf;
    }[0..Local.limit];
    try std.testing.expectEqualStrings(full_text_buffer, Local.text);
}

test "text dynamic buffer" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const Local = struct {
        var text: []const u8 = "";

        // Set a limit that is not a multiple of the bin size
        const limit = realloc_bin_size * 5 / 2;

        var buffer: [limit]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        var backing: []u8 = &.{};

        fn frame() !dvui.App.Result {
            var entry: TextEntryWidget = undefined;
            entry.init(@src(), .{
                .text = .{ .buffer_dynamic = .{
                    .backing = &backing,
                    .allocator = fba.allocator(),
                    .limit = limit,
                } },
            }, .{ .tag = "entry" });
            defer entry.deinit();

            entry.processEvents();
            entry.draw();
            text = entry.getText();
            return .ok;
        }
    };

    try dvui.testing.settle(Local.frame);
    try dvui.testing.pressKey(.tab, .none);
    try dvui.testing.settle(Local.frame);
    try dvui.testing.expectFocused("entry");

    const text = "This is some short sample text!";
    // limit should not be a multiple of the text length
    try std.testing.expect(Local.limit % text.len != 0);
    try std.testing.expect(realloc_bin_size % text.len != 0);

    try dvui.testing.writeText(text);
    try dvui.testing.settle(Local.frame);
    try std.testing.expectEqualStrings(text, Local.text);

    for (0..@divFloor(Local.limit, text.len)) |_| {
        // Fill the internal buffer
        // This verifies that any OOM error is handled by writing past the buffer size
        try dvui.testing.writeText(text);
    }
    try dvui.testing.settle(Local.frame);

    const full_text_buffer = comptime blk: {
        var text_buf: []const u8 = text;
        while (text_buf.len < Local.limit) text_buf = text_buf ++ text;
        break :blk text_buf;
    }[0..Local.limit];
    try std.testing.expectEqualStrings(full_text_buffer, Local.text);
}

test "text buffer" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const Local = struct {
        var text: []const u8 = "";

        // Set a limit that is not a multiple of the bin size
        const limit = realloc_bin_size * 5 / 2;

        var buffer: [limit]u8 = undefined;

        fn frame() !dvui.App.Result {
            var entry: TextEntryWidget = undefined;
            entry.init(@src(), .{
                .text = .{ .buffer = &buffer },
            }, .{ .tag = "entry" });
            defer entry.deinit();

            entry.processEvents();
            entry.draw();
            text = entry.getText();
            return .ok;
        }
    };

    try dvui.testing.settle(Local.frame);
    try dvui.testing.pressKey(.tab, .none);
    try dvui.testing.settle(Local.frame);
    try dvui.testing.expectFocused("entry");

    const text = "This is some short sample text!";
    // limit should not be a multiple of the text length
    try std.testing.expect(Local.limit % text.len != 0);
    try std.testing.expect(realloc_bin_size % text.len != 0);

    try dvui.testing.writeText(text);
    try dvui.testing.settle(Local.frame);
    try std.testing.expectEqualStrings(text, Local.text);

    for (0..@divFloor(Local.limit, text.len)) |_| {
        // Fill the internal buffer
        // This verifies that any OOM error is handled by writing past the buffer size
        try dvui.testing.writeText(text);
    }
    try dvui.testing.settle(Local.frame);

    const full_text_buffer = comptime blk: {
        var text_buf: []const u8 = text;
        while (text_buf.len < Local.limit) text_buf = text_buf ++ text;
        break :blk text_buf;
    }[0..Local.limit];
    try std.testing.expectEqualStrings(full_text_buffer, Local.text);
}

test "text array_list" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const Local = struct {
        var text: []const u8 = "";
        var al: std.ArrayList(u8) = .empty;

        fn frame() !dvui.App.Result {
            var entry: TextEntryWidget = undefined;
            entry.init(@src(), .{ .text = .{ .array_list = .{
                .backing = &al,
                .allocator = std.testing.allocator,
            } } }, .{ .tag = "entry" });
            defer entry.deinit();

            entry.processEvents();
            entry.draw();
            text = entry.getText();

            return .ok;
        }
    };

    defer Local.al.deinit(std.testing.allocator);

    _ = try dvui.testing.step(Local.frame);
    try dvui.testing.pressKey(.tab, .none);
    _ = try dvui.testing.step(Local.frame);
    try dvui.testing.expectFocused("entry");

    const text = "Testing text";
    try dvui.testing.writeText(text);
    _ = try dvui.testing.step(Local.frame);
    try std.testing.expectEqualStrings(text, Local.text);
}
