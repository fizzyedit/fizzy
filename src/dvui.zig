const std = @import("std");
const fizzy = @import("fizzy.zig");
const dvui = @import("dvui");
const builtin = @import("builtin");
const icons = @import("icons");
const Widgets = @import("editor/widgets/Widgets.zig");

pub const FileWidget = Widgets.FileWidget;
pub const TabsWidget = Widgets.TabsWidget;
pub const ImageWidget = Widgets.ImageWidget;
pub const CanvasWidget = Widgets.CanvasWidget;
pub const ReorderWidget = Widgets.ReorderWidget;
pub const PanedWidget = Widgets.PanedWidget;
pub const FloatingWindowWidget = Widgets.FloatingWindowWidget;
pub const TreeWidget = Widgets.TreeWidget;
pub const TreeSelection = Widgets.TreeSelection;

/// Currently this is specialized for the layers paned widget, just includes icon and dragging flag so we know when the pane is dragging
pub fn paned(src: std.builtin.SourceLocation, init_opts: PanedWidget.InitOptions, opts: dvui.Options) *PanedWidget {
    var ret = dvui.widgetAlloc(PanedWidget);
    ret.init(src, init_opts, opts);
    ret.processEvents();
    return ret;
}

pub fn floatingWindow(src: std.builtin.SourceLocation, floating_opts: FloatingWindowWidget.InitOptions, opts: dvui.Options) *FloatingWindowWidget {
    var ret = dvui.widgetAlloc(FloatingWindowWidget);
    ret.init(src, floating_opts, opts);
    ret.processEventsBefore();
    ret.drawBackground();
    return ret;
}

pub fn hovered(wd: *dvui.WidgetData) bool {
    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, wd)) {
            continue;
        }

        switch (event.evt) {
            .mouse => |mouse| {
                return wd.borderRectScale().r.contains(mouse.p);
            },
            else => {},
        }
    }

    return false;
}

pub fn reorder(src: std.builtin.SourceLocation, init_opts: ReorderWidget.InitOptions, opts: dvui.Options) *ReorderWidget {
    var ret = dvui.widgetAlloc(ReorderWidget);
    ret.init(src, init_opts, opts);
    ret.processEvents();
    return ret;
}

pub const DisplayFn = *const fn (dvui.Id) anyerror!bool;
pub const CallAfterFn = *const fn (dvui.Id, dvui.enums.DialogResponse) anyerror!void;

/// Header type icon for `windowHeader` (glyph only). Placement follows `dvui.currentWindow().button_order`:
/// `.cancel_ok` (macOS): dismiss close on the leading edge, icon on the trailing edge.
/// `.ok_cancel` (e.g. Windows): icon on the leading edge, close on the trailing edge.
pub const DialogHeaderKind = enum(u8) {
    none = 0,
    info,
    warning,
    err,
};

/// Yellow for `.warning` header glyphs (readable in light and dark themes).
pub const dialog_header_warning_fill: dvui.Color = .{ .r = 234, .g = 179, .b = 8 };

/// Emerald success green for save-complete checkmarks (not theme `.highlight`).
pub fn saveDoneCheckFill(alpha: f32) dvui.Color {
    const c: dvui.Color = if (dvui.themeGet().dark)
        .{ .r = 74, .g = 222, .b = 128 }
    else
        .{ .r = 22, .g = 163, .b = 74 };
    return c.opacity(alpha);
}

pub const DialogOptions = struct {
    window: ?*dvui.Window = null,
    id_extra: usize = 0,
    windowFn: dvui.Dialog.DisplayFn = dialogWindow,
    displayFn: DisplayFn = defaultDialogDisplay,
    callafterFn: CallAfterFn = defaultDialogCallAfter,
    resizeable: bool = true,
    modal: bool = true,
    title: []const u8 = "",
    ok_label: []const u8 = "Ok",
    cancel_label: []const u8 = "Cancel",
    default: dvui.enums.DialogResponse = .ok,
    /// When set, caps the floating window content (e.g. unsaved prompt). Omit for Export / New File so they can grow vertically.
    max_size: ?dvui.Options.MaxSize = null,
    /// When true, only the header and `displayFn` are shown; footer OK/Cancel are omitted (e.g. three custom actions).
    hide_footer: bool = false,
    /// Optional header type icon; side follows `button_order` like the footer (see `DialogHeaderKind`).
    header_kind: DialogHeaderKind = .none,
};

pub fn defaultDialogDisplay(id: dvui.Id) anyerror!bool {
    // Placeholder body; every real dialog supplies its own `displayFn`. Kept free
    // of plugin (atlas/sprite) draws so the core dialog code stays plugin-agnostic.
    _ = id;
    return true;
}

pub fn defaultDialogCallAfter(id: dvui.Id, response: dvui.enums.DialogResponse) anyerror!void {
    switch (response) {
        .ok => {
            dvui.log.info("Dialog callafter for {d} returned {any}", .{ id, response });
        },
        .cancel => {
            dvui.log.info("Dialog callafter for {d} returned {any}", .{ id, response });
        },
        else => {},
    }
}

/// True when the main workspace canvas should not hide the OS cursor, draw tool cursors, or
/// consume pointer events.
/// - Modal dialogs: always block the editor canvas (not in-dialog previews).
/// - Non-modal floating windows (e.g. Export): block only while the cursor is over that window.
pub fn canvasPointerInputSuppressed() bool {
    const cw = dvui.currentWindow();
    const main_id = cw.data().id;
    for (cw.subwindows.stack.items[1..]) |sub| {
        if (sub.modal) return true;
    }
    const target = cw.subwindows.windowFor(cw.mouse_pt);
    return target != .zero and target != main_id;
}

/// In-dialog preview canvases (Grid Layout): allow pan/zoom while the pointer is over the
/// dialog subwindow that owns the preview.
pub fn dialogCanvasPointerInputSuppressed() bool {
    const cw = dvui.currentWindow();
    const sub = cw.subwindows.current() orelse return true;
    const target = cw.subwindows.windowFor(cw.mouse_pt);
    return target != sub.id;
}

/// Creates a new file dialog with necessary data set and returns the id mutex.
/// Caller must unlock the mutex after setting any additional data on the id.
pub fn dialog(src: std.builtin.SourceLocation, opts: DialogOptions) dvui.IdMutex {
    const id_mutex = dvui.dialogAdd(opts.window, src, opts.id_extra, opts.windowFn);
    const id = id_mutex.id;

    dvui.dataSet(opts.window, id, "_modal", opts.modal);
    dvui.dataSetSlice(opts.window, id, "_title", opts.title);
    //dvui.dataSet(opts.window, id, "_center_on", (opts.window orelse dvui.currentWindow()).subwindows.current_rect);
    dvui.dataSetSlice(opts.window, id, "_ok_label", opts.ok_label);
    dvui.dataSetSlice(opts.window, id, "_cancel_label", opts.cancel_label);
    dvui.dataSet(opts.window, id, "_default", opts.default);
    dvui.dataSet(opts.window, id, "_callafter", opts.callafterFn);
    dvui.dataSet(opts.window, id, "_displayFn", opts.displayFn);
    dvui.dataSet(opts.window, id, "_resizeable", opts.resizeable);
    dvui.dataSet(opts.window, id, "_hide_footer", opts.hide_footer);
    if (opts.max_size) |ms| {
        dvui.dataSet(opts.window, id, "_max_size", ms);
    }
    dvui.dataSet(opts.window, id, "_open", true);
    dvui.dataSet(opts.window, id, "_header_kind", @intFromEnum(opts.header_kind));

    return id_mutex;
}

/// Shrink the current modal subwindow to a point to run the standard close animation. Call from dialog content (e.g. custom buttons).
pub fn closeFloatingDialogAnchored() void {
    const sub = dvui.currentWindow().subwindows.current() orelse return;
    var close_rect = sub.rect_pixels;
    close_rect.x = close_rect.center().x;
    close_rect.y = close_rect.center().y;
    close_rect.w = 1;
    close_rect.h = 1;
    dvui.dataSet(null, sub.id, "_close_rect", close_rect);
}

pub fn dialogWindow(id: dvui.Id) anyerror!void {
    const modal = dvui.dataGet(null, id, "_modal", bool) orelse {
        dvui.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    if (modal) {
        fizzy.editor.dim_titlebar = true;
    }

    const title = dvui.dataGetSlice(null, id, "_title", []u8) orelse {
        dvui.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    const ok_label = dvui.dataGetSlice(null, id, "_ok_label", []u8) orelse {
        dvui.log.err("dialogDisplay lost data for dialog {x}\n", .{id});
        dvui.dialogRemove(id);
        return;
    };

    const resizeable = dvui.dataGet(null, id, "_resizeable", bool) orelse false;

    const center_on = dvui.currentWindow().subwindows.current_rect;

    const cancel_label = dvui.dataGetSlice(null, id, "_cancel_label", []u8);
    const default = dvui.dataGet(null, id, "_default", dvui.enums.DialogResponse);

    const callafter = dvui.dataGet(null, id, "_callafter", CallAfterFn);
    const displayFn = dvui.dataGet(null, id, "_displayFn", DisplayFn);

    const maxSize = dvui.dataGet(null, id, "_max_size", dvui.Options.MaxSize);
    const hide_footer = dvui.dataGet(null, id, "_hide_footer", bool) orelse false;

    var win = fizzy.dvui.floatingWindow(@src(), .{
        .modal = modal,
        .center_on = center_on,
        .window_avoid = .nudge,
        .process_events_in_deinit = true,
        .resize = if (resizeable) .all else .none,
    }, .{
        .id_extra = id.asUsize(),
        .color_text = .black,
        .corner_radius = dvui.Rect.all(10),
        .max_size_content = maxSize,
        .border = .all(0),
        .color_fill = dvui.themeGet().color(.content, .fill).opacity(0.85),
        .box_shadow = .{
            .color = .black,
            .alpha = 0.35,
            .fade = 10,
            .corner_radius = dvui.Rect.all(10),
        },
    });
    defer win.deinit();

    if (dvui.animationGet(win.data().id, "_close_x")) |a| {
        if (a.done()) {
            fizzy.Editor.Explorer.files.new_file_close_rect = null;
            dvui.dialogRemove(id);
        }
    } else if (fizzy.Editor.Explorer.files.new_file_close_rect) |close_rect| {
        dvui.dataSet(null, win.data().id, "_close_rect", close_rect);
        fizzy.Editor.Explorer.files.new_file_close_rect = null;
    } else {
        win.autoSize();
    }

    { // Common window header
        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer vbox.deinit();

        const header_kind: DialogHeaderKind = switch (dvui.dataGet(null, id, "_header_kind", u8) orelse 0) {
            @intFromEnum(DialogHeaderKind.none) => .none,
            @intFromEnum(DialogHeaderKind.info) => .info,
            @intFromEnum(DialogHeaderKind.warning) => .warning,
            @intFromEnum(DialogHeaderKind.err) => .err,
            else => .none,
        };

        var header_openflag = true;
        win.dragAreaSet(fizzy.dvui.windowHeader(title, "", &header_openflag, header_kind));
        if (!header_openflag) {
            if (callafter) |ca| {
                ca(id, .cancel) catch {
                    dvui.log.err("Dialog callafter for {x} returned {any}", .{ id, error.FailedToCallAfter });
                    return;
                };
            }

            var close_rect = win.data().rectScale().r;
            close_rect.x = close_rect.center().x;
            close_rect.y = close_rect.center().y;
            close_rect.w = 1;
            close_rect.h = 1;

            dvui.dataSet(null, win.data().id, "_close_rect", close_rect);
        }
    }

    var valid: bool = true;

    { // Actual dialog content
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .padding = .all(8),
            .expand = .horizontal,
            .gravity_x = 0.5,
        });
        defer hbox.deinit();

        const clip = dvui.clip(hbox.data().contentRectScale().r);
        defer dvui.clipSet(clip);

        if (displayFn) |df| {
            valid = df(id) catch false;
        }
    }

    if (!hide_footer) { // OK and Cancel buttons
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
        defer hbox.deinit();

        if (cancel_label) |cl| {
            var cancel_data: dvui.WidgetData = undefined;
            const gravx: f32, const tindex: u16 = switch (dvui.currentWindow().button_order) {
                .cancel_ok => .{ 0.0, 1 },
                .ok_cancel => .{ 1.0, 3 },
            };
            if (dvui.button(@src(), cl, .{}, .{
                .tab_index = tindex,
                .data_out = &cancel_data,
                .gravity_x = gravx,
                .box_shadow = .{
                    .color = .black,
                    .alpha = 0.25,
                    .offset = .{ .x = -4, .y = 4 },
                    .fade = 8,
                },
            })) {
                if (callafter) |ca| {
                    ca(id, .cancel) catch {
                        dvui.log.err("Dialog callafter for {x} returned {any}", .{ id, error.FailedToCallAfter });
                        return;
                    };
                }

                var close_rect = win.data().rectScale().r;
                close_rect.x = close_rect.center().x;
                close_rect.y = close_rect.center().y;
                close_rect.w = 1;
                close_rect.h = 1;

                dvui.dataSet(null, win.data().id, "_close_rect", close_rect);
            }
            if (default != null and dvui.firstFrame(hbox.data().id) and default.? == .cancel and !valid) {
                dvui.focusWidget(cancel_data.id, null, null);
            }
        }

        const alpha = dvui.alpha(if (valid) 1.0 else 0.5);
        defer dvui.alphaSet(alpha);

        var ok_data: dvui.WidgetData = undefined;
        const ok_opts: dvui.Options = .{
            .tab_index = 2,
            .data_out = &ok_data,
            .style = if (valid) .highlight else .control,
            .box_shadow = .{
                .color = .black,
                .alpha = 0.25,
                .offset = .{ .x = -4, .y = 4 },
                .fade = 8,
            },
        };
        var ok_button: dvui.ButtonWidget = undefined;
        ok_button.init(@src(), .{}, ok_opts);

        if (valid) ok_button.processEvents();
        ok_button.drawFocus();
        ok_button.drawBackground();

        dvui.labelNoFmt(@src(), ok_label, .{}, ok_opts.strip().override(ok_button.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));

        defer ok_button.deinit();

        if (ok_button.clicked()) {
            if (!valid) return;
            const fly_to_explorer_row = dvui.dataGetSlice(null, id, "_parent_path", []u8) != null;
            if (callafter) |ca| {
                ca(id, .ok) catch {
                    dvui.log.err("Dialog callafter for {x} returned {any}", .{ id, error.FailedToCallAfter });
                    return;
                };
            }
            if (!fly_to_explorer_row) {
                var close_rect_ok = win.data().rectScale().r;
                close_rect_ok.x = close_rect_ok.center().x;
                close_rect_ok.y = close_rect_ok.center().y;
                close_rect_ok.w = 1;
                close_rect_ok.h = 1;
                dvui.dataSet(null, win.data().id, "_close_rect", close_rect_ok);
            }
        }
        if (default != null and dvui.firstFrame(hbox.data().id) and default.? == .ok and valid) {
            dvui.focusWidget(ok_data.id, null, null);
        }
    }
}

/// Margin on the circular close control in `windowHeader`. Keep in sync with title label padding in `windowHeader`.
pub const window_header_close_margin = dvui.Rect.all(6);

/// Sum of top + bottom padding on the `windowHeader` title label (`.padding` `.y` + `.h`).
pub const window_header_title_vertical_pad: f32 = 8.0;

/// Inner width/height of the red close circle (dialog header + workspace tabs).
/// Blends the full title-row target (tab-style) with cap-height (what a ratio-only overlay close tended to land on) so both match.
pub fn windowHeaderCloseInnerSide() f32 {
    const fh = dvui.themeGet().font_heading;
    const row = fh.lineHeight() + window_header_title_vertical_pad;
    const m = window_header_close_margin.y + window_header_close_margin.h;
    const row_inner = @max(6.0, row - m);
    const cap_inner = @max(6.0, fh.textHeight());
    return (row_inner + cap_inner) * 0.5;
}

/// Base `Options` for the dialog header close button. Tabs pass `.override(.{ .expand = .none, .min_size_content = …, .id_extra = … })`.
pub fn windowHeaderCloseButtonOptions(over: dvui.Options) dvui.Options {
    const base: dvui.Options = .{
        .font = .theme(.heading),
        .corner_radius = dvui.Rect.all(1000),
        .padding = dvui.Rect.all(0),
        .margin = window_header_close_margin,
        .gravity_y = 0.5,
        .expand = .ratio,
        .style = .err,
        .box_shadow = .{
            .color = .black,
            .alpha = 0.25,
            .offset = .{ .x = -2, .y = 2 },
            .fade = 4,
        },
    };
    return base.override(over);
}

fn windowHeaderPaintClose(openflag: ?*bool) void {
    if (openflag) |of| {
        const close_side = windowHeaderCloseInnerSide();
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, windowHeaderCloseButtonOptions(.{
            .min_size_content = .{ .w = close_side, .h = close_side },
            .expand = .none,
        }));
        defer button.deinit();

        button.processEvents();
        button.drawBackground();
        button.drawFocus();

        if (button.hovered()) {
            dvui.icon(@src(), "close", icons.tvg.lucide.x, .{
                .stroke_color = dvui.themeGet().color(.err, .fill).lighten(if (dvui.themeGet().dark) -10 else 10),
                .fill_color = dvui.themeGet().color(.err, .fill).lighten(if (dvui.themeGet().dark) -10 else 10),
            }, .{
                .expand = .ratio,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = .white,
            });
        }

        if (button.clicked()) {
            of.* = false;
        }
    }
}

fn windowHeaderPaintKindIcon(header_kind: DialogHeaderKind) void {
    if (header_kind == .none) return;

    const close_side = windowHeaderCloseInnerSide();
    const tvg = switch (header_kind) {
        .none => unreachable,
        .info => icons.tvg.lucide.@"circle-help",
        .warning, .err => icons.tvg.lucide.@"circle-alert",
    };
    const icon_color: dvui.Color = switch (header_kind) {
        .none => unreachable,
        .info => dvui.themeGet().color(.content, .text),
        .warning => dialog_header_warning_fill,
        .err => dvui.themeGet().color(.err, .fill),
    };

    dvui.icon(@src(), "dialog_header_accent", tvg, .{
        .stroke_color = icon_color,
        .fill_color = icon_color,
    }, .{
        .expand = .none,
        .min_size_content = .{ .w = close_side, .h = close_side },
        .margin = window_header_close_margin,
        .gravity_y = 0.5,
        .color_text = .white,
    });
}

pub fn windowHeader(str: []const u8, right_str: []const u8, openflag: ?*bool, header_kind: DialogHeaderKind) dvui.Rect.Physical {
    // Order matches dialog footer `button_order`: `.cancel_ok` → dismiss (close) leading like Cancel;
    // `.ok_cancel` → icon leading, dismiss trailing (same role split as OK vs Cancel horizontal placement).
    const dismiss_close_leading = switch (dvui.currentWindow().button_order) {
        .cancel_ok => true,
        .ok_cancel => false,
    };

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .name = "WindowHeader",
        .background = true,
        .color_fill = dvui.themeGet().color(.content, .fill),
        .corner_radius = .{ .x = 10, .y = 10 },
    });
    defer row.deinit();

    if (dismiss_close_leading) {
        windowHeaderPaintClose(openflag);
    } else {
        windowHeaderPaintKindIcon(header_kind);
    }

    dvui.labelNoFmt(@src(), str, .{ .align_x = 0.5 }, .{
        .expand = .horizontal,
        .font = .theme(.heading),
        .gravity_y = 0.5,
        .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
        .label = .{ .for_id = dvui.subwindowCurrentId() },
    });

    dvui.labelNoFmt(@src(), right_str, .{}, .{ .expand = .none, .gravity_y = 0.5 });

    if (dismiss_close_leading) {
        windowHeaderPaintKindIcon(header_kind);
    } else {
        windowHeaderPaintClose(openflag);
    }

    const evts = dvui.events();
    for (evts) |*e| {
        if (!dvui.eventMatch(e, .{ .id = row.data().id, .r = row.data().contentRectScale().r }))
            continue;

        if (e.evt == .mouse and e.evt.mouse.action == .press and e.evt.mouse.button.pointer()) {
            // raise this subwindow but let the press continue so the window
            // will do the drag-move
            dvui.raiseSubwindow(dvui.subwindowCurrentId());
        } else if (e.evt == .mouse and e.evt.mouse.action == .focus) {
            // our window will already be focused, but this prevents the window
            // from clearing the focused widget
            e.handle(@src(), row.data());
        }
    }

    return row.data().rectScale().r;
}

pub const SpinnerOptions = struct {
    end_time: i32 = 1_000_000,
};

pub fn spinner(src: std.builtin.SourceLocation, spinner_opts: SpinnerOptions, opts: dvui.Options) void {
    var defaults: dvui.Options = .{
        .name = "Spinner",
        .min_size_content = .{ .w = 50, .h = 50 },
    };
    const options = defaults.override(opts);
    var wd = dvui.WidgetData.init(src, .{}, options);
    wd.register();
    wd.minSizeSetAndRefresh();
    wd.minSizeReportToParent();

    if (wd.rect.empty()) {
        return;
    }

    const rs = wd.contentRectScale();
    const r = rs.r;

    var t: f32 = 0;
    const anim = dvui.Animation{ .end_time = spinner_opts.end_time };
    if (dvui.animationGet(wd.id, "_t")) |a| {
        // existing animation
        var aa = a;
        if (aa.done()) {
            // this animation is expired, seamlessly transition to next animation
            aa = anim;
            aa.start_time = a.end_time;
            aa.end_time += a.end_time;
            dvui.animation(wd.id, "_t", aa);
        }
        t = aa.value();
    } else {
        // first frame we are seeing the spinner
        dvui.animation(wd.id, "_t", anim);
    }

    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();

    const full_circle = 2 * std.math.pi;
    // start begins fast, speeding away from end
    const start = full_circle * dvui.easing.outSine(t);
    // end begins slow, catching up to start
    const end = full_circle * dvui.easing.inSine(t);

    path.addArc(r.center(), @min(r.w, r.h) / 3, start, end, false);
    path.build().stroke(.{ .thickness = 3.0 * rs.s, .color = options.color(.text) });
}

pub fn toastDisplay(id: dvui.Id) !void {
    const message = dvui.dataGetSlice(null, id, "_message", []u8) orelse {
        dvui.log.err("toastDisplay lost data for toast {x}\n", .{id});
        return;
    };

    var box = dvui.box(@src(), .{}, .{
        .id_extra = id.asUsize(),
        .background = true,
        .corner_radius = dvui.Rect.all(1000),
        .margin = .all(2),
        .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
        .color_fill = dvui.themeGet().color(.control, .fill),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -2.0, .y = 2.0 },
            .fade = 6.0,
            .alpha = 0.25,
            .corner_radius = dvui.Rect.all(10000),
        },
        .gravity_x = 0.5,
    });
    defer box.deinit();

    var animator = dvui.animate(@src(), .{ .kind = .alpha, .duration = 400_000 }, .{ .id_extra = id.asUsize(), .gravity_x = 0.5 });
    defer animator.deinit();

    dvui.labelNoFmt(@src(), message, .{}, .{
        .gravity_x = 0.5,
    });

    if (dvui.timerDone(id)) {
        animator.startEnd();
    }

    if (animator.end()) {
        dvui.toastRemove(id);
    }
}

pub const BubbleSpinnerInit = struct {
    complete_elapsed_ns: ?i128 = null,
};

/// Finish animation after save (wall-clock, driven by the file flash timer):
/// 1. **Sync** — bubbles around the ring sequentially grow to the same size, filling the ring.
/// 2. **Pop** — ring radius expands quickly while dots shrink and fade.
/// 3. **Check** — only the highlight checkmark until the flash window ends.
const bubble_save_sync_ns: i128 = 400 * std.time.ns_per_ms;
const bubble_save_pop_ns: i128 = 160 * std.time.ns_per_ms;
pub const bubble_save_transition_ns: i128 = bubble_save_sync_ns + bubble_save_pop_ns;

/// True when save-complete feedback is showing the check (tab close may appear on hover).
pub fn bubbleSpinnerSaveInCheckPhase(complete_elapsed_ns: i128) bool {
    return complete_elapsed_ns >= bubble_save_transition_ns;
}
const bubble_save_check_fade_ns: i128 = 120 * std.time.ns_per_ms;
const bubble_spinner_period_micros: i32 = 1_050_000;
const bubble_dot_count: u32 = 9;

/// Fizzy-themed bubble spinner. N small filled dots arranged on a ring; each pulses size
/// and alpha in a sine wave with a phase offset around the circle, giving a wave of
/// brightness that rotates — like bubbles rising in a fizzy drink.
///
/// When `init.save_done_elapsed_ns` is set, plays the save-complete finish (sync → pop → check)
/// instead of the looping wave. `options.color(.text)` is the dot colour.
pub fn bubbleSpinner(
    src: std.builtin.SourceLocation,
    opts: dvui.Options,
    init: BubbleSpinnerInit,
) void {
    var defaults: dvui.Options = .{
        .name = "BubbleSpinner",
        .min_size_content = .{ .w = 50, .h = 50 },
    };
    const options = defaults.override(opts);
    var wd = dvui.WidgetData.init(src, .{}, options);
    wd.register();
    wd.minSizeSetAndRefresh();
    wd.minSizeReportToParent();
    if (wd.rect.empty()) return;

    const rs = wd.contentRectScale();
    const text_color = options.color(.text);

    if (init.complete_elapsed_ns) |elapsed_ns| {
        if (elapsed_ns >= bubble_save_transition_ns) {
            const check_elapsed = elapsed_ns - bubble_save_transition_ns;
            const check_alpha = if (check_elapsed >= bubble_save_check_fade_ns)
                1.0
            else
                @as(f32, @floatFromInt(check_elapsed)) / @as(f32, @floatFromInt(bubble_save_check_fade_ns));
            bubbleSpinnerPaintCheck(rs, check_alpha);
            return;
        }
        if (elapsed_ns < bubble_save_sync_ns) {
            var spin_t: f32 = 0;
            const anim: dvui.Animation = .{ .end_time = bubble_spinner_period_micros };
            if (dvui.animationGet(wd.id, "_t")) |a| {
                var aa = a;
                if (aa.done()) {
                    aa = anim;
                    aa.start_time = a.end_time;
                    aa.end_time += a.end_time;
                    dvui.animation(wd.id, "_t", aa);
                }
                spin_t = aa.value();
            } else {
                dvui.animation(wd.id, "_t", anim);
            }
            bubbleSpinnerPaintSaveSync(rs.r, spin_t, text_color, elapsed_ns);
            return;
        }
        bubbleSpinnerPaintSavePop(rs.r, text_color, elapsed_ns - bubble_save_sync_ns);
        return;
    }

    var t: f32 = 0;
    const anim: dvui.Animation = .{ .end_time = bubble_spinner_period_micros };
    if (dvui.animationGet(wd.id, "_t")) |a| {
        var aa = a;
        if (aa.done()) {
            aa = anim;
            aa.start_time = a.end_time;
            aa.end_time += a.end_time;
            dvui.animation(wd.id, "_t", aa);
        }
        t = aa.value();
    } else {
        dvui.animation(wd.id, "_t", anim);
    }

    bubbleSpinnerPaintSpin(rs.r, t, text_color);
}

fn bubbleSpinnerGeom(r: dvui.Rect.Physical) struct {
    center: dvui.Point.Physical,
    ring_radius: f32,
    dot_max_radius: f32,
} {
    const bounding_radius = @min(r.w, r.h) * 0.5;
    return .{
        .center = r.center(),
        .ring_radius = bounding_radius * 0.78,
        .dot_max_radius = bounding_radius * 0.18,
    };
}

/// Centered in the same content rect as the bubble ring (not a child `icon` widget).
fn bubbleSpinnerPaintCheck(rs: dvui.RectScale, alpha: f32) void {
    // Match tab close X (`expand = .ratio` in the same slot). Lucide `check` has a bit more
    // viewbox padding than `x`, so render slightly larger than the content square.
    const slot = @min(rs.r.w, rs.r.h);
    const side = slot * 1.08;
    const cx = rs.r.x + rs.r.w * 0.5;
    const cy = rs.r.y + rs.r.h * 0.5;
    const icon_rs: dvui.RectScale = .{
        .r = .{
            .x = cx - side * 0.5,
            .y = cy - side * 0.5,
            .w = side,
            .h = side,
        },
        .s = rs.s,
    };
    const check_color = saveDoneCheckFill(alpha);
    dvui.renderIcon("bubble_save_done", icons.tvg.lucide.check, icon_rs, .{}, .{
        .stroke_color = check_color,
        .fill_color = check_color,
    }) catch |err| {
        dvui.logError(@src(), err, "bubble save check icon", .{});
    };
}

fn bubbleSpinnerPaintDot(
    center: dvui.Point.Physical,
    ring_radius: f32,
    angle: f32,
    dot_radius: f32,
    color: dvui.Color,
) void {
    const dot_center: dvui.Point.Physical = .{
        .x = center.x + ring_radius * @cos(angle),
        .y = center.y + ring_radius * @sin(angle),
    };
    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();
    path.addArc(dot_center, dot_radius, 2 * std.math.pi, 0, true);
    path.build().fillConvex(.{ .color = color });
}

fn bubbleSpinnerSmoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return t * t * (3.0 - 2.0 * t);
}

fn bubbleSpinnerPaintSpin(r: dvui.Rect.Physical, t: f32, text_color: dvui.Color) void {
    const geom = bubbleSpinnerGeom(r);
    const dot_min_scale: f32 = 0.35;
    const base_alpha_f: f32 = @floatFromInt(text_color.a);
    const n = @as(f32, @floatFromInt(bubble_dot_count));

    var i: u32 = 0;
    while (i < bubble_dot_count) : (i += 1) {
        const angle = -std.math.pi * 0.5 + 2 * std.math.pi * @as(f32, @floatFromInt(i)) / n;
        const phase = @as(f32, @floatFromInt(i)) / n;
        const local_t = @mod(t + phase, 1.0);
        const pulse = @sin(std.math.pi * local_t);
        const dot_radius = geom.dot_max_radius * (dot_min_scale + (1.0 - dot_min_scale) * pulse);
        const alpha_floor: f32 = 0.25;
        const alpha_mul = alpha_floor + (1.0 - alpha_floor) * pulse;
        const dot_color: dvui.Color = .{
            .r = text_color.r,
            .g = text_color.g,
            .b = text_color.b,
            .a = @intFromFloat(base_alpha_f * alpha_mul),
        };
        bubbleSpinnerPaintDot(geom.center, geom.ring_radius, angle, dot_radius, dot_color);
    }
}

/// Sequential sync: each bubble in turn reaches full size so the ring reads as filled.
fn bubbleSpinnerPaintSaveSync(r: dvui.Rect.Physical, spin_t: f32, text_color: dvui.Color, elapsed_ns: i128) void {
    const geom = bubbleSpinnerGeom(r);
    const dot_min_scale: f32 = 0.35;
    const fill_scale: f32 = 1.08; // slightly oversized so adjacent dots meet on the ring
    const base_alpha_f: f32 = @floatFromInt(text_color.a);
    const n = @as(f32, @floatFromInt(bubble_dot_count));
    const sync_p = @as(f32, @floatFromInt(elapsed_ns)) / @as(f32, @floatFromInt(bubble_save_sync_ns));

    var i: u32 = 0;
    while (i < bubble_dot_count) : (i += 1) {
        const angle = -std.math.pi * 0.5 + 2 * std.math.pi * @as(f32, @floatFromInt(i)) / n;
        const phase = @as(f32, @floatFromInt(i)) / n;
        const local_t = @mod(spin_t + phase, 1.0);
        const wave = @sin(std.math.pi * local_t);

        const slot = (@as(f32, @floatFromInt(i)) + 0.5) / n;
        const lock = bubbleSpinnerSmoothstep(slot - 0.12, slot + 0.08, sync_p);
        const pulse = wave * (1.0 - lock) + lock;
        const dot_radius = geom.dot_max_radius * (dot_min_scale + (1.0 - dot_min_scale) * pulse * fill_scale);
        const alpha_floor: f32 = 0.25;
        const alpha_mul = alpha_floor + (1.0 - alpha_floor) * pulse;
        const dot_color: dvui.Color = .{
            .r = text_color.r,
            .g = text_color.g,
            .b = text_color.b,
            .a = @intFromFloat(base_alpha_f * alpha_mul),
        };
        bubbleSpinnerPaintDot(geom.center, geom.ring_radius, angle, dot_radius, dot_color);
    }
}

/// Ring expands outward while dots shrink and vanish.
fn bubbleSpinnerPaintSavePop(r: dvui.Rect.Physical, text_color: dvui.Color, pop_elapsed_ns: i128) void {
    const geom = bubbleSpinnerGeom(r);
    const base_alpha_f: f32 = @floatFromInt(text_color.a);
    const n = @as(f32, @floatFromInt(bubble_dot_count));
    const pop_p = std.math.clamp(
        @as(f32, @floatFromInt(pop_elapsed_ns)) / @as(f32, @floatFromInt(bubble_save_pop_ns)),
        0,
        1,
    );
    const pop_ease = 1.0 - std.math.pow(f32, 1.0 - pop_p, 3.0);
    const ring_mul = 1.0 + 0.62 * pop_ease;
    const dot_scale = 1.08 * (1.0 - pop_ease);
    const alpha_mul = 1.0 - pop_ease;

    var i: u32 = 0;
    while (i < bubble_dot_count) : (i += 1) {
        const angle = -std.math.pi * 0.5 + 2 * std.math.pi * @as(f32, @floatFromInt(i)) / n;
        const dot_radius = geom.dot_max_radius * dot_scale;
        const dot_color: dvui.Color = .{
            .r = text_color.r,
            .g = text_color.g,
            .b = text_color.b,
            .a = @intFromFloat(base_alpha_f * alpha_mul),
        };
        bubbleSpinnerPaintDot(geom.center, geom.ring_radius * ring_mul, angle, dot_radius, dot_color);
    }
}

/// Paints the fizzy ring (same geometry as [`bubbleSpinner`]) for compositing with other layers.
pub fn bubbleSpinnerPaintDots(r: dvui.Rect.Physical, t: f32, text_color: dvui.Color) void {
    bubbleSpinnerPaintSpin(r, t, text_color);
}

/// Subwindow id used for save-complete toasts. Distinct from the canvas subwindow so
/// `Workspace.drawCanvas`'s `toastsShow` won't render them — instead `Editor.drawSaveToasts`
/// iterates this id and renders centered cards matching the loading-overlay style.
pub const save_toast_subwindow_id: dvui.Id = @enumFromInt(0xF12_5A4E_71D0_5A4E);

/// Custom toast display for save-complete events. Visually matches `Editor.drawLoadingOverlay`:
/// content-fill @ 0.85 background, drop shadow, checkmark icon + "Saved <basename>" label.
/// Auto-fades when the toast timer expires. The message is read from `_message` data on the
/// toast id (set by `toastAdd` caller).
pub fn saveCompleteToastDisplay(id: dvui.Id) !void {
    const message = dvui.dataGetSlice(null, id, "_message", []u8) orelse {
        dvui.log.err("saveCompleteToastDisplay lost data for toast {x}\n", .{id});
        return;
    };

    var animator = dvui.animate(@src(), .{ .kind = .alpha, .duration = 350_000 }, .{
        .id_extra = id.asUsize(),
    });
    defer animator.deinit();

    var card = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id.asUsize(),
        .background = true,
        .corner_radius = dvui.Rect.all(8),
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        .color_fill = dvui.themeGet().color(.content, .fill).opacity(0.85),
        .box_shadow = .{
            .color = .black,
            .offset = .{ .x = -2.0, .y = 2.0 },
            .fade = 12.0,
            .alpha = 0.35,
            .corner_radius = dvui.Rect.all(8),
        },
    });
    defer card.deinit();

    dvui.icon(@src(), "save_check", icons.tvg.lucide.check, .{
        .stroke_color = dvui.themeGet().color(.highlight, .fill),
        .fill_color = dvui.themeGet().color(.highlight, .fill),
    }, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 20, .h = 20 },
        .padding = .{ .w = 10 },
    });

    dvui.labelNoFmt(@src(), message, .{}, .{
        .gravity_y = 0.5,
        .color_text = dvui.themeGet().color(.content, .text),
    });

    if (dvui.timerDone(id)) {
        animator.startEnd();
    }
    if (animator.end()) {
        dvui.toastRemove(id);
    }
}


pub fn labelWithKeybind(label_str: []const u8, hotkey: dvui.enums.Keybind, enabled: bool, label_opts: dvui.Options, opts: dvui.Options) void {
    const box = dvui.box(@src(), .{ .dir = .horizontal }, opts);
    defer box.deinit();

    var new_opts = label_opts.strip();
    new_opts.gravity_y = 0.5;
    if (!enabled) {
        if (new_opts.color_text) |c| {
            new_opts.color_text = c.opacity(0.5);
        } else {
            new_opts.color_text = dvui.themeGet().color(.window, .text).opacity(0.5);
        }
    }

    dvui.labelNoFmt(@src(), label_str, .{}, new_opts);
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(12) });

    var second_opts = opts.strip();
    second_opts.color_text = dvui.themeGet().color(.control, .text);
    second_opts.gravity_y = 0.5;
    second_opts.gravity_x = 1.0;
    second_opts.font = dvui.Font.theme(.heading);

    keybindLabels(&hotkey, enabled, second_opts);
}

pub fn keybindLabels(self: *const dvui.enums.Keybind, enabled: bool, opts: dvui.Options) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 1.0 });
    defer box.deinit();

    var color = if (opts.color_text) |c| c else dvui.themeGet().color(.control, .text);
    if (true or enabled) {
        color = color.opacity(0.5);
    }

    var second_opts = opts.strip();
    second_opts.color_text = color;
    second_opts.font = dvui.Font.theme(.mono).larger(-2.0);
    second_opts.gravity_y = 0.5;

    var needs_space = false;
    if (self.control) |ctrl| {
        if (ctrl) {
            needs_space = true;
            if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
            //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
            //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;

            dvui.labelNoFmt(@src(), "ctrl", .{}, second_opts);
        }
    }

    if (self.command) |cmd| {
        if (cmd) {
            needs_space = true;
            if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
            //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
            //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;
            if (fizzy.platform.isMacOS()) {
                dvui.icon(@src(), "cmd", icons.tvg.lucide.command, .{ .stroke_color = color }, .{ .gravity_y = 0.5 });
            } else {
                dvui.labelNoFmt(@src(), "cmd", .{}, second_opts);
            }
        }
    }

    if (self.alt) |alt| {
        if (alt) {
            needs_space = true;
            if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
            //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
            //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;
            if (fizzy.platform.isMacOS()) {
                dvui.icon(@src(), "option", icons.tvg.lucide.option, .{ .stroke_color = color }, .{ .gravity_y = 0.5 });
            } else {
                dvui.labelNoFmt(@src(), "alt", .{}, second_opts);
            }
        }
    }

    if (self.shift) |shift| {
        if (shift) {
            needs_space = true;
            if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
            //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
            //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;
            dvui.labelNoFmt(@src(), "shift", .{}, second_opts);
        }
    }

    if (self.key) |key| {
        needs_space = true;
        if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip());
        //if (needs_plus) dvui.labelNoFmt(@src(), "+", .{}, opts.strip()) else needs_plus = true;
        //if (needs_space) dvui.labelNoFmt(@src(), " ", .{}, opts.strip()) else needs_space = true;
        dvui.labelNoFmt(@src(), @tagName(key), .{}, second_opts);
    }
}

const Shadow = enum {
    top,
    bottom,
    right,
    left,
};

const ShadowOptions = struct {
    color: dvui.Color = .black,
    opacity: f32 = 0.25,
    offset: dvui.Rect = .{},
    thickness: f32 = 20.0,
    radius: f32 = 0.0,
};

const EdgeGradient = struct {
    axis: enum { x, y },
    opaque_at_zero: bool,
};

fn drawGradientRect(r: dvui.Rect.Physical, corner_radius: dvui.Rect.Physical, opts: ShadowOptions, gradient: EdgeGradient) void {
    var path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
    path.addRect(r, corner_radius);
    var triangles = path.build().fillConvexTriangles(dvui.currentWindow().arena(), .{ .center = r.center(), .color = .white }) catch {
        path.deinit();
        return;
    };
    defer {
        triangles.deinit(dvui.currentWindow().arena());
        path.deinit();
    }

    const total_opacity = if (dvui.themeGet().dark) opts.opacity else opts.opacity * 0.5;

    const ca0 = opts.color.opacity(if (gradient.opaque_at_zero) total_opacity else 0.0);
    const ca1 = opts.color.opacity(if (gradient.opaque_at_zero) 0.0 else total_opacity);

    const t_scale_x = if (r.w > 0) 1.0 / r.w else 0.0;
    const t_scale_y = if (r.h > 0) 1.0 / r.h else 0.0;

    for (triangles.vertexes) |*v| {
        const t = std.math.clamp(
            if (gradient.axis == .y)
                (v.pos.y - r.y) * t_scale_y
            else
                (v.pos.x - r.x) * t_scale_x,
            0.0,
            1.0,
        );
        v.col = v.col.multiply(.fromColor(dvui.Color.lerp(ca0, ca1, t)));
    }
    dvui.renderTriangles(triangles, null) catch {
        dvui.log.err("Failed to render triangles", .{});
    };
}

pub fn drawEdgeShadow(container: dvui.RectScale, shadow: Shadow, opts: ShadowOptions) void {
    var rs = container;
    switch (shadow) {
        .top => {
            rs.r.h = opts.thickness;
            rs.r = rs.r.plus(.cast(opts.offset));
            drawGradientRect(rs.r, dvui.Rect.Physical.all(opts.radius), opts, .{ .axis = .y, .opaque_at_zero = true });
        },
        .bottom => {
            rs.r.y += rs.r.h - opts.thickness;
            rs.r.h = opts.thickness;
            rs.r = rs.r.plus(.cast(opts.offset));
            drawGradientRect(rs.r, dvui.Rect.Physical.all(opts.radius), opts, .{ .axis = .y, .opaque_at_zero = false });
        },
        .right => {
            rs.r.x += rs.r.w - opts.thickness;
            rs.r.w = opts.thickness;
            rs.r = rs.r.plus(.cast(opts.offset));
            drawGradientRect(rs.r, dvui.Rect.Physical.all(opts.radius), opts, .{ .axis = .x, .opaque_at_zero = false });
        },
        .left => {
            rs.r.w = opts.thickness;
            rs.r = rs.r.plus(.cast(opts.offset));
            drawGradientRect(rs.r, dvui.Rect.Physical.all(opts.radius), opts, .{ .axis = .x, .opaque_at_zero = true });
        },
    }
}
