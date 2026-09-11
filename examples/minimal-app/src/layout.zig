//! A one-region app: the workspace, and nothing else.
//!
//! Owned by this package — not a shipped fizzy preset. Surfaces that only match sidebar or
//! panel keywords have nowhere to go, which is the point: the same plugins run here unchanged.
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");

const Layout = @import("app").layout.Layout;

pub fn layout(_: ?*anyopaque, f: *Layout) !dvui.App.Result {
    var main = try f.region(@src(), .{
        .name = "Main",
        .keywords = sdk.keywords.ide.main,
    }, .{ .expand = .both });
    defer main.deinit();
    return .ok;
}
