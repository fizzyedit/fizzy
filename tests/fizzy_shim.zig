//! Minimum bring-up of fizzy globals for headless integration tests.
//!
//! Why a shim and not `Editor.init`? Because `Editor.init` reads from
//! disk (config dir via known_folders), allocates fonts and themes,
//! and runs asset loading. None of that is wanted in unit-flavored
//! tests that just want to call e.g. `Internal.File.fillPoint` against
//! an in-memory file.
//!
//! Strategy: heap-allocate `fizzy.app` and `fizzy.editor`, zero-initialize
//! the editor, then set only the fields tests actually read. Convention:
//! if a new test fails because some `fizzy.editor.foo` is zero/empty/null,
//! set just that field at the top of that test rather than expanding
//! the shim.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("fizzy");

pub const Ctx = struct {
    t: dvui.testing,
    app: *fizzy.App,
    editor: *fizzy.Editor,

    pub fn deinit(self: *Ctx, gpa: std.mem.Allocator) void {
        self.editor.arena.deinit();
        gpa.destroy(self.editor);
        gpa.destroy(self.app);
        self.t.deinit();
    }
};

pub fn init(gpa: std.mem.Allocator) !Ctx {
    var t = try dvui.testing.init(.{ .allocator = gpa });
    errdefer t.deinit();

    const app_ptr = try gpa.create(fizzy.App);
    app_ptr.* = .{
        .allocator = gpa,
        .window = t.window,
        .root_path = "",
    };
    fizzy.app = app_ptr;

    // fizzy.Editor contains many non-nullable pointer / non-zeroable
    // fields, so `std.mem.zeroes(fizzy.Editor)` rejects at comptime.
    // Allocate via `create` (proper alignment + pairs with `destroy`)
    // and `@memset` the bytes to zero — every byte of the struct is
    // now 0, which is safe as long as tests only read fields they
    // explicitly set below. If a new test fails because some
    // `fizzy.editor.foo` is zero/null/empty, set just that field at the
    // top of that test rather than expanding the shim.
    const editor_ptr = try gpa.create(fizzy.Editor);
    @memset(@as([*]u8, @ptrCast(editor_ptr))[0..@sizeOf(fizzy.Editor)], 0);
    editor_ptr.arena = std.heap.ArenaAllocator.init(gpa);
    editor_ptr.host.allocator = gpa;
    fizzy.editor = editor_ptr;

    return .{ .t = t, .app = app_ptr, .editor = editor_ptr };
}
