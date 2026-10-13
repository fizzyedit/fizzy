//! The question a document's owner wants asked before a save (`Plugin.saveQuestion`): pixi's
//! "flatten layers?", a lossy format, a change of encoding. fizzy asks it wherever a save starts
//! (Save, Save All, Save and Close, the quit walk) and goes on by itself with the answer, so an
//! owner never drives a save: go ahead, save as another format instead (Save As with the name
//! kept), or cancel. Once the person has gone ahead, the document is not asked again while it is
//! open (`Editor.save_answered`).
const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const sdk = fizzy.sdk;

/// What the save was part of, so the answer can go on with it.
pub const Then = enum {
    /// A plain save.
    save,
    /// The unsaved-changes dialog's Save and Close: close once it has saved.
    save_and_close,
    /// The quit walk: rejoin it once this document is dealt with.
    quit,
};

/// The open question: the document, the owner's words (copied), and what the save was part of.
pub const Pending = struct {
    doc_id: u64,
    then: Then,
    title: []u8,
    message: []u8,
    proceed: []u8,
    instead: []u8,
    instead_extension: []u8,

    pub fn deinit(self: Pending, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.message);
        gpa.free(self.proceed);
        gpa.free(self.instead);
        gpa.free(self.instead_extension);
    }
};

/// Ask `q` about `doc_id` before saving it as part of `then`.
pub fn request(doc_id: u64, q: sdk.Plugin.SaveQuestion, then: Then) void {
    const editor = fizzy.editor();
    const gpa = editor.app.gpa;
    const pending: Pending = .{
        .doc_id = doc_id,
        .then = then,
        .title = gpa.dupe(u8, q.title) catch return,
        .message = gpa.dupe(u8, q.message) catch return,
        .proceed = gpa.dupe(u8, q.proceed) catch return,
        .instead = gpa.dupe(u8, q.instead) catch return,
        .instead_extension = gpa.dupe(u8, q.instead_extension) catch return,
    };
    if (editor.save_question) |old| old.deinit(gpa);
    editor.save_question = pending;
    var mutex = fizzy.core.dialogs.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = pending.title,
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .max_size = .width(520),
        .header_kind = .warning,
    });
    mutex.mutex.unlock(dvui.io);
}

pub fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) !void {}

fn button(src: std.builtin.SourceLocation, label_text: []const u8, style: dvui.Theme.Style.Name, tab_idx: u16, id_extra: usize) bool {
    const opts: dvui.Options = .{
        .tab_index = tab_idx,
        .style = style,
        .id_extra = id_extra,
        .margin = .{ .x = 5, .w = 5 },
        .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
    };
    var b: dvui.ButtonWidget = undefined;
    b.init(src, .{}, opts);
    defer b.deinit();
    b.processEvents();
    b.drawFocus();
    b.drawBackground();
    dvui.labelNoFmt(src, label_text, .{}, opts.strip().override(b.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));
    return b.clicked();
}

pub fn dialog(_: dvui.Id) anyerror!bool {
    const editor = fizzy.editor();
    const q = editor.save_question orelse return false;

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer outer.deinit();
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
        tl.addText(q.message, .{});
        tl.deinit();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 16 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
    defer row.deinit();
    var answer: ?enum { proceed, instead, cancel } = null;
    if (button(@src(), "Cancel", .control, 3, 0)) answer = .cancel;
    if (q.instead_extension.len > 0 and button(@src(), if (q.instead.len > 0) q.instead else "Save As Another Format", .control, 2, 1)) answer = .instead;
    if (button(@src(), q.proceed, .highlight, 1, 2)) answer = .proceed;

    const a = answer orelse return true;
    fizzy.core.dialogs.closeFloatingDialogAnchored();
    editor.save_question = null;
    defer q.deinit(editor.app.gpa);
    switch (a) {
        .proceed => proceed(q),
        .instead => instead(q),
        .cancel => if (q.then == .quit) editor.app.abortSaveAllQuit(),
    }
    return false;
}

/// Go ahead: not asked again while the document is open, and the save it was part of goes on.
fn proceed(q: Pending) void {
    const editor = fizzy.editor();
    editor.save_answered.put(editor.app.gpa, q.doc_id, {}) catch {};
    switch (q.then) {
        .save => {
            const doc = editor.app.docById(q.doc_id) orelse return;
            editor.writeDocument(doc) catch |err| dvui.log.err("Save: {t}", .{err});
        },
        .save_and_close => @import("UnsavedClose.zig").saveAndClose(q.doc_id) catch |err| dvui.log.err("Save and Close: {t}", .{err}),
        // The walk asks again and finds it answered.
        .quit => editor.app.pending_quit_continue = true,
    }
}

/// Save as the other format instead: Save As to the same name with the owner's extension, which
/// the document then is. Closed after, when the save was part of a close or the quit.
fn instead(q: Pending) void {
    const editor = fizzy.editor();
    const gpa = editor.app.gpa;
    const doc = editor.app.docById(q.doc_id) orelse return;
    const path = doc.owner.documentPath(doc);
    const stem = path[0 .. path.len - std.fs.path.extension(path).len];
    const new_path = std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, q.instead_extension }) catch return;
    defer gpa.free(new_path);
    editor.save_answered.put(gpa, q.doc_id, {}) catch {};
    editor.doc_io.save(doc, new_path) catch |err| {
        dvui.log.err("Save As {s}: {t}", .{ new_path, err });
        if (q.then == .quit) editor.app.abortSaveAllQuit();
        return;
    };
    switch (q.then) {
        .save => {},
        .save_and_close => editor.app.pending_close_after_save.put(gpa, q.doc_id, {}) catch {},
        .quit => {
            // In flight now: the walk closes it once it lands clean, and goes on.
            if (std.mem.indexOfScalar(u64, editor.app.quit_save_all_ids.items, q.doc_id)) |i| _ = editor.app.quit_save_all_ids.swapRemove(i);
            editor.app.quit_saves_in_flight.put(gpa, q.doc_id, {}) catch {};
            editor.app.pending_quit_continue = true;
        },
    }
}
