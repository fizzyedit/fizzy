const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

pub const CanvasWidget = @This();

id: dvui.Id = undefined,
installed: bool = false,
init_opts: InitOptions = undefined,
scroll: *dvui.ScrollAreaWidget = undefined,
scaler: *dvui.ScaleWidget = undefined,
rect: dvui.Rect.Physical = .{},
scroll_container: *dvui.ScrollContainerWidget = undefined,
scroll_rect_scale: dvui.RectScale = .{},
screen_rect_scale: dvui.RectScale = .{},
scroll_info: dvui.ScrollInfo = .{ .vertical = .given, .horizontal = .given },
origin: dvui.Point = .{},
scale: f32 = 1.0,
prev_size: dvui.Size = .{},
prev_scale: f32 = 0.0,

// This is a mess but i cant figure out why the first call to center on the first install doesn't work correctly
first_center: bool = true,
second_center: bool = true,
hovered: bool = false,

pub const InitOptions = struct {
    id: dvui.Id,
    data_size: dvui.Size,
    center: bool = false,
};

pub fn recenter(self: *CanvasWidget) void {
    const parent = dvui.parentGet().data().rect;

    const file_width: f32 = self.init_opts.data_size.w;
    const file_height: f32 = self.init_opts.data_size.h;
    const target_width = parent.w;
    const target_height = parent.h;

    // Center the canvas within the viewport
    self.scroll_info.virtual_size.w = file_width * self.scale;
    self.scroll_info.virtual_size.h = file_height * self.scale;

    // Calculate the amount of blank space for centering
    const view_w = target_width;
    const view_h = target_height;
    const virt_w = self.scroll_info.virtual_size.w;
    const virt_h = self.scroll_info.virtual_size.h;

    // Center by default if content is smaller than viewport, else 0
    const offset_x = (view_w - virt_w) * 0.5;
    const offset_y = (view_h - virt_h) * 0.5;

    self.origin.x = -offset_x;
    self.origin.y = -offset_y;

    if (self.first_center) {
        self.first_center = false;
    } else if (self.second_center) {
        self.second_center = false;
    }
}

pub fn rescale(self: *CanvasWidget) void {
    const parent = dvui.parentGet().data().rect;

    const file_width: f32 = self.init_opts.data_size.w;
    const file_height: f32 = self.init_opts.data_size.h;
    const target_width = parent.w;
    const target_height = parent.h;
    const target_scale: f32 = @min(target_width / (file_width * 1.25), target_height / (file_height * 1.25));

    self.prev_scale = self.scale;
    self.scale = target_scale;
}

pub fn install(self: *CanvasWidget, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) void {
    self.id = init_opts.id;
    self.init_opts = init_opts;

    defer self.prev_size = self.init_opts.data_size;

    if (self.prev_size.h != self.init_opts.data_size.h or self.prev_size.w != self.init_opts.data_size.w or self.second_center or self.init_opts.center) {
        self.rescale();
        self.recenter();
        dvui.refresh(null, @src(), self.id);
    }

    self.scroll = dvui.scrollArea(src, .{ .scroll_info = &self.scroll_info }, opts);

    self.scroll_container = &self.scroll.scroll.?;

    self.scaler = dvui.scale(src, .{ .scale = &self.scale }, .{ .rect = .{ .x = -self.origin.x, .y = -self.origin.y } });

    self.syncTransformCachesFromWidgets();
}

/// Re-read scroll/scaler `RectScale` and `rect` from the widget tree. Call at end of `install`, or
/// after changing `scale` / `origin` / `virtual_size` while the scroll area still exists (e.g. fit pass).
pub fn syncTransformCachesFromWidgets(self: *CanvasWidget) void {
    self.scroll_rect_scale = self.scroll_container.screenRectScale(.{});
    self.screen_rect_scale = self.scaler.screenRectScale(.{});
    self.rect = self.screenFromDataRect(dvui.Rect.fromSize(.{ .w = self.init_opts.data_size.w, .h = self.init_opts.data_size.h }));
}

/// Contain `content` inside `host` (natural px) with margin; updates `scale`, `scroll_info.virtual_size`,
/// and `origin` for centered letterboxing. Prefer calling **before** `install` when the host size comes
/// from the previous frame’s viewport so the scaler is created with the right offset; if you must run
/// after `install`, follow with `syncTransformCachesFromWidgets` (scaler child offset may lag one frame).
pub fn fitContentContainInHost(self: *CanvasWidget, content: dvui.Size, host: dvui.Rect, margin: f32) void {
    const fw = content.w;
    const fh = content.h;
    if (fw <= 0 or fh <= 0 or host.w <= 1 or host.h <= 1) return;

    self.scale = @max(
        @min(host.w / (fw * margin), host.h / (fh * margin)),
        0.0001,
    );

    self.scroll_info.virtual_size.w = fw * self.scale;
    self.scroll_info.virtual_size.h = fh * self.scale;

    const virt_w = self.scroll_info.virtual_size.w;
    const virt_h = self.scroll_info.virtual_size.h;
    self.origin.x = -(host.w - virt_w) * 0.5;
    self.origin.y = -(host.h - virt_h) * 0.5;
}

pub fn deinit(self: *CanvasWidget) void {
    self.scaler.deinit();
    self.scroll.deinit();
}

pub fn dataFromScreenPoint(self: *CanvasWidget, screen: dvui.Point.Physical) dvui.Point {
    return self.screen_rect_scale.pointFromPhysical(screen);
}

pub fn screenFromDataPoint(self: *CanvasWidget, data: dvui.Point) dvui.Point.Physical {
    return self.screen_rect_scale.pointToPhysical(data);
}

pub fn viewportFromScreenPoint(self: *CanvasWidget, screen: dvui.Point.Physical) dvui.Point {
    return self.scroll_rect_scale.pointFromPhysical(screen);
}

pub fn screenFromViewportPoint(self: *CanvasWidget, viewport: dvui.Point) dvui.Point.Physical {
    return self.scroll_rect_scale.pointToPhysical(viewport);
}

pub fn dataFromScreenRect(self: *CanvasWidget, screen: dvui.Rect.Physical) dvui.Rect {
    return self.screen_rect_scale.rectFromPhysical(screen);
}

pub fn screenFromDataRect(self: *CanvasWidget, data: dvui.Rect) dvui.Rect.Physical {
    return self.screen_rect_scale.rectToPhysical(data);
}

pub fn viewportFromScreenRect(self: *CanvasWidget, screen: dvui.Rect.Physical) dvui.Rect {
    return self.scroll_rect_scale.rectFromPhysical(screen);
}

pub fn screenFromViewportRect(self: *CanvasWidget, viewport: dvui.Rect) dvui.Rect.Physical {
    return self.scroll_rect_scale.rectToPhysical(viewport);
}

/// If the mouse position is currently contained within the canvas rect,
/// Returns the data/world point of the mouse, which corresponds to the pixel input of
/// Layer functions
// pub fn hovered(self: *CanvasWidget) ?dvui.Point {
//     for (dvui.events()) |*e| {
//         if (!self.scroll_container.matchEvent(e)) {
//             continue;
//         }

//         if (e.evt == .mouse and e.evt.mouse.action == .position) {
//             if (self.rect.contains(e.evt.mouse.p)) {
//                 return self.dataFromScreenPoint(e.evt.mouse.p);
//             }
//         }
//     }

//     return null;
// }

/// Returns the mouse event if one occured this frame
pub fn mouse(self: *CanvasWidget) ?dvui.Event.Mouse {
    for (dvui.events()) |*e| {
        if (!self.scroll_container.matchEvent(e))
            continue;

        switch (e.evt) {
            .mouse => |me| {
                return me;
            },
            else => {},
        }
    }

    return null;
}

pub fn processEvents(self: *CanvasWidget) void {
    //const file = self.file;

    var zoom: f32 = 1;
    var zoomP: dvui.Point.Physical = .{};

    // process scroll area events after boxes so the boxes get first pick (so
    // the button works)
    for (dvui.events()) |*e| {
        if (!self.scroll_container.matchEvent(e)) {
            self.hovered = false;
            continue;
        }

        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .position) {
                    if (self.rect.contains(me.p)) {
                        self.hovered = true;
                    } else {
                        self.hovered = false;
                    }
                }

                if (me.action == .press and me.button == .middle) {
                    e.handle(@src(), self.scroll_container.data());
                    dvui.captureMouse(self.scroll_container.data(), e.num);
                    dvui.dragPreStart(me.p, .{ .name = "scroll_drag" });
                } else if (me.action == .release and me.button == .middle) {
                    if (dvui.captured(self.scroll_container.data().id)) {
                        e.handle(@src(), self.scroll_container.data());
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                    }
                } else if (me.action == .motion) {
                    if (dvui.captured(self.scroll_container.data().id)) {
                        if (dvui.dragging(me.p, "scroll_drag")) |dps| {
                            const rs = self.scroll_rect_scale;
                            self.scroll_info.viewport.x -= dps.x / rs.s;
                            self.scroll_info.viewport.y -= dps.y / rs.s;
                            dvui.refresh(null, @src(), self.scroll_container.data().id);
                        }
                    }
                } else if (me.action == .wheel_y or me.action == .wheel_x) {
                    switch (fizzy.editor.settings.input_scheme) {
                        .mouse => {
                            const base: f32 = if (me.mod.matchBind("shift")) 1.005 else 1.005;
                            if ((me.mod.matchBind("shift") and me.mod.matchBind("ctrl/cmd")) or !me.mod.matchBind("shift") and !me.mod.matchBind("ctrl/cmd")) {
                                e.handle(@src(), self.scroll_container.data());
                                if (me.action == .wheel_y) {
                                    const zs = @exp(@log(base) * me.action.wheel_y);
                                    if (zs != 1.0) {
                                        zoom *= zs;
                                        zoomP = me.p;
                                    }
                                }
                            }
                        },
                        .trackpad => {
                            if (me.mod.matchBind("zoom")) {
                                e.handle(@src(), self.scroll_container.data());
                                if (me.action == .wheel_y) {
                                    const base: f32 = if (me.mod.matchBind("shift")) 1.001 else 1.001;
                                    const zs = @exp(@log(base) * me.action.wheel_y);
                                    if (zs != 1.0) {
                                        zoom *= zs;
                                        zoomP = me.p;
                                    }
                                }
                            }
                        },
                    }
                }
            },
            else => {},
        }
    }

    // scale around mouse point
    // first get data point of mouse
    // data from screen
    const prevP = self.dataFromScreenPoint(zoomP);

    // scale
    var pp = prevP.scale(1 / self.scale, dvui.Point);
    self.scale *= zoom;
    pp = pp.scale(self.scale, dvui.Point);

    // get where the mouse would be now
    // data to screen
    const newP = self.screenFromDataPoint(pp);

    if (zoom != 1.0) {

        // convert both to viewport
        const diff = self.viewportFromScreenPoint(newP).diff(self.viewportFromScreenPoint(zoomP));
        self.scroll_info.viewport.x += diff.x;
        self.scroll_info.viewport.y += diff.y;

        dvui.refresh(null, @src(), self.scroll_container.data().id);
    }

    // // don't mess with scrolling if we aren't being shown (prevents weirdness
    // // when starting out)
    if (!self.scroll_info.viewport.empty()) {
        // add current viewport plus padding
        const pad = 10;
        var bbox = self.scroll_info.viewport.outsetAll(pad);
        const scrollbbox = self.viewportFromScreenRect(self.rect);
        bbox = bbox.unionWith(scrollbbox);

        // adjust top if needed
        if (bbox.y != 0) {
            const adj = -bbox.y;
            self.scroll_info.virtual_size.h += adj;
            self.scroll_info.viewport.y += adj;
            self.origin.y -= adj;
            dvui.refresh(null, @src(), self.scroll.data().id);
        }

        // adjust left if needed
        if (bbox.x != 0) {
            const adj = -bbox.x;
            self.scroll_info.virtual_size.w += adj;
            self.scroll_info.viewport.x += adj;
            self.origin.x -= adj;
            dvui.refresh(null, @src(), self.scroll.data().id);
        }

        // adjust bottom if needed
        if (bbox.h != self.scroll_info.virtual_size.h) {
            self.scroll_info.virtual_size.h = bbox.h;
            dvui.refresh(null, @src(), self.scroll.data().id);
        }

        // adjust right if needed
        if (bbox.w != self.scroll_info.virtual_size.w) {
            self.scroll_info.virtual_size.w = bbox.w;
            dvui.refresh(null, @src(), self.scroll.data().id);
        }
    }
}
