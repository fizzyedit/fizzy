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
    /// Physical window coordinates, borrowed for this frame; hosts precede nested seams.
    seams: []const LiquidField.Seam = &.{},
    blur: f32 = 1,
    lens: f32 = 1,
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
    self.material = if (o.seams.len > 0) .{ .rect = rs.r, .radii = radii, .seams = o.seams, .blur = o.blur, .lens = o.lens } else null;
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
