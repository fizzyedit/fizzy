//! Layer 2 (headless integration) test target.
//!
//! These tests run real fizzy drawing functions against a *headless*
//! `dvui.Window` provided by dvui's testing backend. The shim in
//! `fizzy_shim.zig` brings up just enough of `fizzy.app` / `fizzy.editor`
//! for the code paths exercised here to read the globals they need
//! without booting the full editor (no assets, no themes, no SDL).
//!
//! Pixel-art-specific coverage (`Internal.File`, `Layer`, `Packer`,
//! `Animation`, grid/pack/flood-fill regressions) moved out with the
//! pixi plugin extraction — pixi now ships from its own repo
//! (`fizzyedit/pixi`) and owns that coverage there. This target keeps
//! the headless dvui harness alive for future fizzy-shell-level
//! integration tests (workbench, text, image, menu/sidebar flows).
//!
//! See `tests/README.md` for the overall layering.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("fizzy");
const shim = @import("fizzy_shim.zig");

test "shim brings up a dvui.testing window with usable fizzy globals" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const arena = dvui.currentWindow().arena();
    const buf = try arena.alloc(u8, 16);
    @memset(buf, 0);

    try std.testing.expect(fizzy.app == ctx.app);
    try std.testing.expect(fizzy.editor == ctx.editor);
}
