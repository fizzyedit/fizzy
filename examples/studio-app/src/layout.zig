//! A Blender-ish shape: large canvas, short bottom strip, explorer on the right.
//!
//! Owned by this package — not a shipped fizzy preset. The right-hand stack accepts the same
//! `sidebar`/`explorer` keywords fizzy's left explorer does, so the file tree lands here
//! without the workbench plugin knowing it moved.
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");

const Layout = @import("app").layout.Layout;

pub fn layout(_: ?*anyopaque, f: *Layout) !dvui.App.Result {
    var body = try f.region(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
    });
    defer body.deinit();

    var work = try f.region(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer work.deinit();

    {
        var left = try f.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer left.deinit();

        {
            var canvas = try f.region(@src(), .{
                .name = "Canvas",
                .keywords = sdk.keywords.studio.canvas,
            }, .{ .expand = .both });
            defer canvas.deinit();
        }

        f.split(@src(), .{});

        {
            var strip = try f.region(@src(), .{
                .name = "Strip",
                .keywords = sdk.keywords.studio.strip,
                .resize = true,
                .collapsible = true,
                .hide_when_empty = true,
            }, .{ .min_size_content = .{ .h = 150 }, .expand = .horizontal });
            defer strip.deinit();
        }
    }

    f.split(@src(), .{});

    {
        var stack = try f.region(@src(), .{
            .name = "Stack",
            .keywords = sdk.keywords.studio.stack,
            .resize = true,
            .collapsible = true,
        }, .{ .min_size_content = .{ .w = 300 }, .expand = .vertical });
        defer stack.deinit();
    }

    return .ok;
}
