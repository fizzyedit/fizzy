//! A box whose face is glass, placed by dvui in the same frame as its children.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("../glass.zig");
const glass_look = @import("glass_look");
const LiquidField = @import("glass").LiquidField;
const Glass = @This();

pub const InitOptions = struct {
    group: u16 = 0,
    role: ?glass_look.Role = null,
    merge: f32 = 0,
    /// Physical window coordinates, borrowed for this frame; hosts precede nested seams. Only
    /// the first `LiquidField.max_seams` are used; the rest are dropped.
    seams: []const LiquidField.Seam = &.{},
    blur: f32 = 1,
    lens: f32 = 1,
    /// 0…1: how much light the rim catches, as `LiquidField.Shape`.
    light: f32 = 0,
};

src: std.builtin.SourceLocation,
init_opts: InitOptions,
opts: dvui.Options,
box: dvui.BoxWidget = undefined, // Initialized in install, at its final address.
owned_layer: glass.Layer = .{},
material: ?LiquidField.Panel = null,

/// Call install at the returned value's final address, then deinit after its children.
pub fn init(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) Glass {
    return .{ .src = src, .init_opts = init_opts, .opts = opts };
}

pub fn install(self: *Glass) void {
    self.box.init(self.src, .{}, self.opts);
    const rs = self.data().borderRectScale();
    const opts = self.data().options;
    const corners = opts.cornersGet().finalize(opts.themeGet()).scale(rs.s, dvui.CornerRect.Physical);
    const radii: [4]f32 = .{ corners.tl.radius(), corners.tr.radius(), corners.br.radius(), corners.bl.radius() };
    const o = self.init_opts;
    const seams = o.seams[0..@min(o.seams.len, LiquidField.max_seams)];
    self.material = if (seams.len > 0) .{ .rect = rs.r, .radii = radii, .seams = seams, .blur = o.blur, .lens = o.lens } else null;
    var layer = glass.current();
    if (!layer.active() or !std.meta.eql(layer.clip().?, dvui.clipGet())) {
        self.owned_layer = glass.layer(self.data().id, .{ .role = o.role, .merge = o.merge });
        layer = self.owned_layer;
    }
    if (!layer.add(.{
        .shape = if (self.material) |p| .{ .panel = p } else .{ .box = .{
            .rect = rs.r,
            .radii = radii,
            .round = @reduce(.Min, @as(@Vector(4, f32), radii)) >= 4 * rs.s,
        } },
        .group = o.group,
        .blur = o.blur,
        .lens = o.lens,
        .light = o.light,
    })) {
        const background = self.data().options.background;
        self.data().options.background = true;
        self.box.drawBackground();
        self.data().options.background = background;
    }
}

pub fn data(self: *Glass) *dvui.WidgetData {
    return self.box.data();
}

/// The panel for piece layout and hit tests, borrowing the caller's seams for this frame.
pub fn panel(self: *Glass) ?LiquidField.Panel {
    return self.material;
}

pub fn deinit(self: *Glass) void {
    self.owned_layer.end();
    self.box.deinit();
}

var t_seam_count: usize = 0;

fn seamsFrame() !dvui.App.Result {
    const over: [LiquidField.max_seams + 3]LiquidField.Seam = @splat(.{ .axis = .vertical, .at = 10, .reach = 4 });
    var g = Glass.init(@src(), .{ .seams = &over }, .{ .expand = .both });
    g.install();
    defer g.deinit();
    t_seam_count = if (g.panel()) |p| p.seams.len else 0;
    return .ok;
}

test "an over-long seams slice is clamped to max_seams" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 100 } });
    defer t.deinit();
    try dvui.testing.settle(seamsFrame);
    try std.testing.expectEqual(LiquidField.max_seams, t_seam_count);
}
