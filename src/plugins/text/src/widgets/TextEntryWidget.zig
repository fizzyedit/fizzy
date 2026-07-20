//! Vendored from dvui `widgets/TextEntryWidget.zig` with code-editor extensions:
//! tree-sitter predicate filtering, query error fallback, optional focus ring.
const builtin = @import("builtin");
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const perf = @import("core").perf;

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
pub const EditNotify = struct {
    ctx: *anyopaque,
    beginEdit: *const fn (ctx: *anyopaque) void,
    noteRemoved: *const fn (ctx: *anyopaque, pos: usize, bytes: []const u8) void,
    noteInserted: *const fn (ctx: *anyopaque, pos: usize, bytes: []const u8) void,
    endEdit: *const fn (ctx: *anyopaque) void,
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
};

/// Byte span of a tree-sitter token, used by `hovered_span` below.
pub const Span = struct { start: usize, end: usize };

/// One completion candidate, as shown in `CompletionState.items` — either owned by
/// `Document.completion_items` (which both `TextEditor.zig` and this widget then just borrow
/// a slice of for the frame) or, in principle, any other caller. `text` is already trimmed to
/// a pure suffix (never re-shows characters already typed before the cursor) — see
/// `sdk.language.CompletionItem.insert_text`. `text` must not contain '\n': ghost text is
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

/// The completion list currently being shown: `items[selected]`'s text is spliced into
/// `draw()` as ghost text right after `anchor`, and the same list + selection drive the
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
    self.drawBeforeText();

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

            // Restrict the capture walk to the visible byte range instead of the whole document
            // — this is the dominant per-frame cost (see perf log above). `drawBeforeText`
            // already computed this exactly, from real measured line heights (not an assumed
            // bytes-per-pixel density): `cache_layout_bytes` — set via `TextLayoutWidget.
            // bytesNeeded`, which also extends the range to cover the cursor or an active
            // selection if either is off-screen. Null on the first frame (before
            // `byte_heights` exists yet), in which case we don't restrict — same as any frame
            // `cache_layout` isn't active. Text outside the queried range still renders via the
            // gap/leftover chunks below — it's just uncolored until scrolled into (padded) range.
            if (self.textLayout.cache_layout_bytes) |clb| {
                // Small pad for the *next* frame's scroll movement before this data is
                // refreshed — much smaller than an estimate-based pad needs, since the base
                // range itself is exact rather than approximate.
                const byte_pad: usize = @min(self.len / 20, 8_000);
                const byte_start = clb.start -| byte_pad;
                const byte_end = @min(self.len, clb.end + byte_pad);
                iter.setByteRange(byte_start, byte_end);
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
                    self.emitChunk(start, self.text[start..nstart], .{}, false);
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
                self.emitChunk(nstart, self.text[nstart..nend], opts, true);
                //perfAccumShape(shape_start);

                start = nend;
            }

            if (start < self.len) {
                // any leftover non highlighted text
                //const shape_start = perfBegin();
                self.emitChunk(start, self.text[start..self.len], .{}, false);
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
    self.emitChunk(0, self.text[0..self.len], self.data().options.strip(), false);
    self.textLayout.addTextDone(self.data().options.strip());

    self.drawAfterText();
}

/// One ghost-text splice resolved for this frame: `text` shown dimmed at byte offset `anchor`.
/// `emitChunk` sources this from `current_completion` (acceptable via Tab/Enter) when showing,
/// else `signature_hint` (purely informational, never acceptable) — see `signature_hint`'s doc
/// comment for why only one of the two ever occupies this slot at once.
const Ghost = struct { text: []const u8, anchor: usize };

/// Emits `chunk` — a slice of `self.text` starting at absolute byte offset `chunk_start` —
/// into `self.textLayout`, exactly like the plain `addText`/`addTextHover` call it replaces
/// (`is_hover` selects which, matching the call site), *unless* this frame's `Ghost.anchor`
/// falls inside this chunk, in which case the chunk is split at the anchor and the ghost text
/// is spliced in between the two halves, dimmed.
///
/// The splice needs `TextLayoutWidget.bytes_seen` rewound by the ghost text's length
/// afterward — `addTextEx` advances it unconditionally, and it must track only *real*
/// document bytes for cursor/selection hit-testing (`cursor_rect`, click routing) to stay
/// correct for every real chunk emitted after this one. `bytes_seen` is a plain public field
/// already reached into directly elsewhere in this codebase (e.g. `selection`, `cursor_rect`
/// at `TextEditor.zig`), so this isn't reaching past an abstraction that wants to stay
/// opaque — but the same call path also advances a *second*, independent counter
/// (`cache_layout_bytes_seen`) whenever `cache_layout` is on, which `addTextDone` asserts
/// stays equal to `bytes_seen` — rewinding only `bytes_seen` would desync that pair and trip
/// the assert. Rewinding both in lockstep keeps `cache_layout` usable during a completion —
/// needed now that tree-sitter-highlighted docs rely on `cache_layout` for viewport culling
/// (see `TextEditor.zig`).
fn emitChunk(self: *TextEntryWidget, chunk_start: usize, chunk: []const u8, opts: dvui.Options, is_hover: bool) void {
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

    const ghost: ?Ghost = blk: {
        if (self.current_completion) |completion| {
            // `drawCompletion` never sets `current_completion` with an empty `items` — see
            // `TextEditor.zig` — so `selected` is always a valid index here.
            break :blk .{ .text = completion.items[completion.selected].text, .anchor = completion.anchor };
        }
        if (self.signature_hint) |hint| {
            break :blk .{ .text = hint, .anchor = self.textLayout.selectionGet(self.len).cursor };
        }
        break :blk null;
    };
    const g = ghost orelse {
        emitPlain(self, chunk_start, chunk, opts, is_hover);
        return;
    };

    // Fast path: ghost text already spliced elsewhere this draw, anchor not in this chunk, or
    // ghost text unsafe to splice this frame (see `CompletionCandidate.text`'s doc comment on
    // the no-newline requirement) — stays branch-cheap for the common case, which is every
    // chunk on every frame without a completion or signature hint showing. `ghost_text_emitted`
    // matters because consecutive chunks touch (one's end byte offset equals the next one's
    // start), so when the anchor sits exactly on that shared boundary both chunks would
    // otherwise believe the anchor is theirs and splice the ghost text twice (e.g. typing `s`
    // and seeing `stdtd` instead of `std` — the ghost suffix `td` spliced in on both sides).
    if (self.ghost_text_emitted or g.anchor < chunk_start or g.anchor > chunk_start + chunk.len or
        std.mem.indexOfScalar(u8, g.text, '\n') != null)
    {
        emitPlain(self, chunk_start, chunk, opts, is_hover);
        return;
    }
    self.ghost_text_emitted = true;

    const split = g.anchor - chunk_start;
    emitPlain(self, chunk_start, chunk[0..split], opts, is_hover);

    self.textLayout.addText(g.text, .{
        .color_text = self.textLayout.data().options.color(.text).opacity(0.5),
    });
    self.textLayout.bytes_seen -= g.text.len;
    if (self.textLayout.cache_layout) {
        // `addTextEx` bumped this by `g.text.len` too (same call path as `bytes_seen`, whenever
        // cache_layout is on) — rewind it the same amount so it stays equal to `bytes_seen`,
        // which `addTextDone` asserts.
        self.textLayout.cache_layout_bytes_seen -= g.text.len;
    }

    emitPlain(self, g.anchor, chunk[split..], opts, is_hover);
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

    if (self.init_opts.edit_notify) |en| en.beginEdit(en.ctx);
    defer if (self.init_opts.edit_notify) |en| en.endEdit(en.ctx);

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

            if (ke.action == .down and ke.matchBind("text_start")) {
                e.handle(@src(), self.data());
                self.textLayout.selection.moveCursor(0, false);
                self.textLayout.scroll_to_cursor = true;
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("text_end")) {
                e.handle(@src(), self.data());
                self.textLayout.selection.moveCursor(std.math.maxInt(usize), false);
                self.textLayout.scroll_to_cursor = true;
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("line_start")) {
                e.handle(@src(), self.data());
                if (self.textLayout.sel_move == .none) {
                    self.textLayout.sel_move = .{ .expand_pt = .{ .select = false, .which = .home } };
                }
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("line_end")) {
                e.handle(@src(), self.data());
                if (self.textLayout.sel_move == .none) {
                    self.textLayout.sel_move = .{ .expand_pt = .{ .select = false, .which = .end } };
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("word_left")) {
                e.handle(@src(), self.data());
                if (!self.textLayout.selection.empty()) {
                    self.textLayout.selection.moveCursor(self.textLayout.selection.start, false);
                } else {
                    if (self.textLayout.sel_move == .none) {
                        self.textLayout.sel_move = .{ .word_left_right = .{ .select = false } };
                    }
                    if (self.textLayout.sel_move == .word_left_right) {
                        self.textLayout.sel_move.word_left_right.count -= 1;
                    }
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("word_right")) {
                e.handle(@src(), self.data());
                if (!self.textLayout.selection.empty()) {
                    self.textLayout.selection.moveCursor(self.textLayout.selection.end, false);
                    self.textLayout.selection.affinity = .before;
                } else {
                    if (self.textLayout.sel_move == .none) {
                        self.textLayout.sel_move = .{ .word_left_right = .{ .select = false } };
                    }
                    if (self.textLayout.sel_move == .word_left_right) {
                        self.textLayout.sel_move.word_left_right.count += 1;
                    }
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_left")) {
                e.handle(@src(), self.data());
                if (!self.textLayout.selection.empty()) {
                    self.textLayout.selection.moveCursor(self.textLayout.selection.start, false);
                } else {
                    if (self.textLayout.sel_move == .none) {
                        self.textLayout.sel_move = .{ .char_left_right = .{ .select = false } };
                    }
                    if (self.textLayout.sel_move == .char_left_right) {
                        self.textLayout.sel_move.char_left_right.count -= 1;
                    }
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_right")) {
                e.handle(@src(), self.data());
                if (!self.textLayout.selection.empty()) {
                    self.textLayout.selection.moveCursor(self.textLayout.selection.end, false);
                    self.textLayout.selection.affinity = .before;
                } else {
                    if (self.textLayout.sel_move == .none) {
                        self.textLayout.sel_move = .{ .char_left_right = .{ .select = false } };
                    }
                    if (self.textLayout.sel_move == .char_left_right) {
                        self.textLayout.sel_move.char_left_right.count += 1;
                    }
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_up")) {
                e.handle(@src(), self.data());
                if (self.textLayout.sel_move == .none) {
                    self.textLayout.sel_move = .{ .cursor_updown = .{ .select = false } };
                }
                if (self.textLayout.sel_move == .cursor_updown) {
                    self.textLayout.sel_move.cursor_updown.count -= 1;
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_down")) {
                e.handle(@src(), self.data());
                if (self.textLayout.sel_move == .none) {
                    self.textLayout.sel_move = .{ .cursor_updown = .{ .select = false } };
                }
                if (self.textLayout.sel_move == .cursor_updown) {
                    self.textLayout.sel_move.cursor_updown.count += 1;
                }
                break :blk;
            }

            switch (ke.code) {
                .backspace => {
                    if (ke.action == .down or ke.action == .repeat) {
                        e.handle(@src(), self.data());
                        if (self.init_opts.edit_notify) |en| en.beginEdit(en.ctx);
                        defer if (self.init_opts.edit_notify) |en| en.endEdit(en.ctx);
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
                        if (self.init_opts.edit_notify) |en| en.beginEdit(en.ctx);
                        defer if (self.init_opts.edit_notify) |en| en.endEdit(en.ctx);
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
                        self.textTyped(new, set.selected);
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

        // delete selection
        self.textChangedRemoved(sel.start, sel.end);
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
