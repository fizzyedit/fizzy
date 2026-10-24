//! PROTOTYPE (fizzyedit/work#201), throwaway: a card overview over the open documents, behind
//! `FIZZY_CARDS=<n>` (n cards; fewer documents are repeated). F8 opens and closes the overview,
//! F7 toggles the sheen, F6 cycles the layout of the opened cards. A click on a card zooms it to full
//! and makes its document active.
//!
//! A card is a photograph (`core.FrameTarget.snapshot`, one at a time) drawn as an 8x8
//! perspective mesh; its pose is seven spring lanes (x, y, rotation, scale, lift, tilt x, tilt y)
//! chasing targets that layout formulas set with a stagger. Measures its own frames (`report`).
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const Editor = @import("Editor.zig");

const motion = core.motion;
const max_cards = 32;
const grid_n = 8;

const Lanes = 7;
const Lane = enum(u3) { x, y, rot, scale, lift, tilt_x, tilt_y };
/// Rest tolerance per lane: pixels, radians, a scale, a lift, radians.
const rest_tol = [Lanes]f32{ 0.3, 0.3, 0.0005, 0.001, 0.002, 0.001, 0.001 };

const Pose = [Lanes]f32;

const Spring = struct {
    pos: Pose = @splat(0),
    vel: Pose = @splat(0),
    placed: bool = false,

    fn damping(play: f32) f32 {
        return 1 + (0.45 - 1) * play;
    }

    /// Returns whether it still moves.
    fn step(self: *Spring, target: Pose, dt_s: f32, hz: f32) bool {
        if (!self.placed or motion.off()) {
            self.pos = target;
            self.vel = @splat(0);
            self.placed = true;
            return false;
        }
        const play = std.math.clamp((motion.level() - 0.5) * 2, 0, 1);
        const w = 2 * std.math.pi * hz * motion.rate();
        const z = damping(play);
        var left = std.math.clamp(dt_s, 0, 0.1);
        while (left > 0) {
            const h = @min(left, 0.004);
            left -= h;
            for (0..Lanes) |i| {
                const a = -w * w * (self.pos[i] - target[i]) - 2 * z * w * self.vel[i];
                self.vel[i] += a * h;
                self.pos[i] += self.vel[i] * h;
            }
        }
        var moving = false;
        for (0..Lanes) |i| {
            const rest = @abs(self.pos[i] - target[i]) < rest_tol[i] and @abs(self.vel[i]) < rest_tol[i] * 20;
            if (rest) {
                self.pos[i] = target[i];
                self.vel[i] = 0;
            } else moving = true;
        }
        return moving;
    }

    /// A short decaying wobble: a write to the velocity, in one place.
    fn kick(self: *Spring, lane: Lane, impulse: f32) void {
        self.vel[@backingInt(lane)] += impulse;
    }
};

const Layout = enum { grid, fan };

const Card = struct {
    spring: Spring = .{},
    target: Pose = @splat(0),
    /// Frame time (ns) at which `pending` becomes the target: the stagger.
    arm_ns: i128 = 0,
    pending: ?Pose = null,
    /// Which document's photograph it shows.
    doc: usize = 0,
};

const Photo = struct {
    tex: ?dvui.Texture = null,
    hires: bool = false,
};

const State = struct {
    inited: bool = false,
    enabled: bool = false,
    n: usize = 0,
    open: bool = false,
    /// The overview is drawn while open or while the cards still travel home.
    visible: bool = false,
    sheen: bool = false,
    layout: Layout = .grid,
    cards: [max_cards]Card = @splat(.{}),
    photos: [max_cards]Photo = @splat(.{}),
    ndocs: usize = 0,
    picked: ?usize = null,
    hover_prev: usize = max_cards,
    dim: f32 = 0,
    dim_target: f32 = 0,
    last_ns: i128 = 0,
    frame: u64 = 0,
    // measure
    dts: [512]f32 = undefined,
    draws: [512]f32 = undefined,
    nd: usize = 0,
    motion_name: []const u8 = "",
    photo_bytes: usize = 0,
    worst_open_ms: f32 = 0,
    // scripted run (FIZZY_CARDS_AUTO=<outdir>)
    auto_dir: ?[]const u8 = null,
    auto_frames: bool = false,
    auto_t0: i128 = 0,
    auto_step: usize = 0,
    auto_mouse: ?dvui.Point.Physical = null,
    auto_from: dvui.Point.Physical = .{},
    shot_pending: ?dvui.TextureTarget = null,
    shot_n: usize = 0,
    level_override: ?f32 = null,
};
var s: State = .{};

fn init() void {
    s.inited = true;
    const v = std.c.getenv("FIZZY_CARDS") orelse return;
    const n = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 10;
    s.n = std.math.clamp(n, 1, max_cards);
    s.enabled = true;
    if (std.c.getenv("FIZZY_CARDS_AUTO")) |d| s.auto_dir = std.mem.span(d);
    s.auto_frames = std.c.getenv("FIZZY_CARDS_FRAMES") != null;
    if (std.c.getenv("FIZZY_CARDS_LEVEL")) |l| s.level_override = std.fmt.parseFloat(f32, std.mem.span(l)) catch null;
    s.sheen = std.c.getenv("FIZZY_CARDS_SHEEN") != null;
    std.log.info("CARDS enabled n={d}", .{s.n});
}

fn winRect() dvui.Rect.Physical {
    return dvui.windowRectPixels();
}

// ---- layouts: pure formulas -------------------------------------------------------------

/// A deck: a small offset per card, the front card (0) exactly over the window.
fn stackPose(i: usize, w: dvui.Rect.Physical) Pose {
    const layer: f32 = @floatFromInt(@min(i, 6));
    const jit = @sin(@as(f32, @floatFromInt(i)) * 12.9898) * 0.025;
    return .{ w.x + w.w / 2 + layer * 3, w.y + w.h / 2 - layer * 3, jit * @as(f32, if (i == 0) 0 else 1), 1, 0, 0, 0 };
}

/// Rows of cards at about a quarter of the window, centred.
fn gridPose(i: usize, n: usize, w: dvui.Rect.Physical) Pose {
    const nf: f32 = @floatFromInt(n);
    const aspect = w.w / w.h;
    const cols: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(nf * aspect * 0.8)))));
    const rows = (n + cols - 1) / cols;
    const cell_w = w.w * 0.88 / @as(f32, @floatFromInt(cols));
    const cell_h = w.h * 0.84 / @as(f32, @floatFromInt(rows));
    const sc = @min(cell_w / w.w, cell_h / w.h) * 0.9;
    const r = i / cols;
    const c = i % cols;
    // The last row is centred.
    const in_row = if (r == rows - 1) n - r * cols else cols;
    const row_w = @as(f32, @floatFromInt(in_row)) * cell_w;
    const x0 = w.x + (w.w - row_w) / 2 + cell_w / 2;
    const y0 = w.y + (w.h - @as(f32, @floatFromInt(rows)) * cell_h) / 2 + cell_h / 2;
    return .{ x0 + @as(f32, @floatFromInt(c)) * cell_w, y0 + @as(f32, @floatFromInt(r)) * cell_h, 0, sc, 0, 0, 0 };
}

/// A hand: along an arc at the foot of the window, rotation in proportion to the offset.
fn fanPose(i: usize, n: usize, w: dvui.Rect.Physical) Pose {
    const nf: f32 = @floatFromInt(n);
    const t = if (n <= 1) 0 else (@as(f32, @floatFromInt(i)) / (nf - 1)) * 2 - 1;
    const sc = 0.42;
    return .{ w.x + w.w / 2 + t * @min(w.w * 0.42, nf * 55), w.y + w.h * 0.62 + t * t * w.h * 0.08, t * 0.32, sc, 0, 0, 0 };
}

fn openPose(i: usize, w: dvui.Rect.Physical) Pose {
    return switch (s.layout) {
        .grid => gridPose(i, s.n, w),
        .fan => fanPose(i, s.n, w),
    };
}

const stagger_ns: i128 = 30 * std.time.ns_per_ms;

fn arm(now: i128, closing: bool) void {
    const w = winRect();
    for (0..s.n) |i| {
        const c = &s.cards[i];
        const k: i128 = @intCast(if (closing) s.n - 1 - i else i);
        c.pending = if (closing) stackPose(i, w) else openPose(i, w);
        c.arm_ns = now + k * stagger_ns;
    }
}

// ---- photographs ------------------------------------------------------------------------

fn photograph(doc_slot: usize, full: bool) void {
    const r = winRect();
    const sh: f32 = if (full) 1.5 else 4;
    const size: [2]u32 = .{ @intFromFloat(@max(1, r.w / sh)), @intFromFloat(@max(1, r.h / sh)) };
    const tex = core.FrameTarget.snapshot(r, size) orelse return;
    const p = &s.photos[doc_slot];
    if (p.tex) |old| {
        s.photo_bytes -= @as(usize, old.width) * old.height * 4;
        dvui.Texture.destroyLater(old);
    }
    p.tex = tex;
    p.hires = full;
    s.photo_bytes += @as(usize, tex.width) * tex.height * 4;
}

// ---- drawing ----------------------------------------------------------------------------

const Mesh = struct { pts: [(grid_n + 1) * (grid_n + 1)]dvui.Point.Physical };

fn project(pose: Pose, w: dvui.Rect.Physical, mesh: *Mesh) void {
    const cx = pose[0];
    const cy = pose[1] - pose[4] * 10;
    const sc = pose[3] * (1 + pose[4] * 0.06);
    const hw = w.w * sc / 2;
    const hh = w.h * sc / 2;
    const ay = pose[5];
    const ax = pose[6];
    const d = @max(w.w, w.h) * 1.6 * sc;
    const cr = @cos(pose[2]);
    const sr = @sin(pose[2]);
    for (0..grid_n + 1) |j| {
        for (0..grid_n + 1) |i| {
            const u = @as(f32, @floatFromInt(i)) / grid_n * 2 - 1;
            const v = @as(f32, @floatFromInt(j)) / grid_n * 2 - 1;
            var x = u * hw;
            var y = v * hh;
            var z: f32 = 0;
            // About Y by ay, then about X by ax.
            const x1 = x * @cos(ay) + z * @sin(ay);
            z = -x * @sin(ay) + z * @cos(ay);
            x = x1;
            const y1 = y * @cos(ax) - z * @sin(ax);
            z = y * @sin(ax) + z * @cos(ax);
            y = y1;
            const p = d / (d + z);
            x *= p;
            y *= p;
            mesh.pts[j * (grid_n + 1) + i] = .{ .x = cx + x * cr - y * sr, .y = cy + x * sr + y * cr };
        }
    }
}

fn drawCard(i: usize, w: dvui.Rect.Physical, front_light: f32) void {
    const c = &s.cards[i];
    const tex = (s.photos[c.doc].tex) orelse return;
    const pose = c.spring.pos;
    const lift = std.math.clamp(pose[4], 0, 1.5);

    // Height shadow: a tight contact shadow and a wide soft one, offset by the lift.
    const hw = w.w * pose[3] / 2;
    const hh = w.h * pose[3] / 2;
    const rc: dvui.Rect.Physical = .{ .x = pose[0] - hw, .y = pose[1] - hh, .w = hw * 2, .h = hh * 2 };
    var wide = rc;
    wide.y += 8 + lift * 22;
    wide.fill(.all(14), .{ .color = .{ .color = dvui.Color.black.opacity(0.28 + 0.1 * lift) }, .fade = 18 + lift * 34 });
    var contact = rc;
    contact.y += 2 + lift * 5;
    contact.fill(.all(10), .{ .color = .{ .color = dvui.Color.black.opacity(0.35) }, .fade = 5 + lift * 5 });

    var mesh: Mesh = undefined;
    project(pose, w, &mesh);
    const lifo = dvui.currentWindow().lifo();
    const nv = (grid_n + 1) * (grid_n + 1);
    var b = dvui.Triangles.Builder.init(lifo, nv, grid_n * grid_n * 6) catch return;
    defer b.deinit(lifo);
    // A face turned away from the light dims a little; the front card is lit fully.
    const shade = std.math.clamp(front_light - @abs(pose[5]) * 0.4 + pose[6] * 0.25, 0.7, 1.0);
    const cv: u8 = @intFromFloat(255 * shade);
    const col: dvui.Color.PMA = .{ .r = cv, .g = cv, .b = cv, .a = 255 };
    for (0..grid_n + 1) |j| {
        for (0..grid_n + 1) |k| {
            b.appendVertex(.{
                .pos = mesh.pts[j * (grid_n + 1) + k],
                .col = col,
                .uv = .{ @as(f32, @floatFromInt(k)) / grid_n, @as(f32, @floatFromInt(j)) / grid_n },
            });
        }
    }
    for (0..grid_n) |j| {
        for (0..grid_n) |k| {
            const a: dvui.Vertex.Index = @intCast(j * (grid_n + 1) + k);
            const bb = a + 1;
            const cc = a + grid_n + 1;
            const dd = cc + 1;
            b.appendTriangles(&.{ a, bb, dd, a, dd, cc });
        }
    }
    dvui.renderTriangles(b.build_unowned(), tex) catch {};

    if (s.sheen and lift > 0.05) {
        // A quiet highlight band sliding with the tilt: vertex alpha only, no shader.
        var sb = dvui.Triangles.Builder.init(lifo, nv, grid_n * grid_n * 6) catch return;
        defer sb.deinit(lifo);
        const pos = (pose[5] * 1.2 + pose[6] * 0.8) * 2.2;
        for (0..grid_n + 1) |j| {
            for (0..grid_n + 1) |k| {
                const u = @as(f32, @floatFromInt(k)) / grid_n;
                const v = @as(f32, @floatFromInt(j)) / grid_n;
                const dist = ((u + v) - 1) - pos;
                const band = @exp(-dist * dist * 14) * 0.22 * std.math.clamp(lift, 0, 1);
                const av: u8 = @intFromFloat(255 * band);
                sb.appendVertex(.{ .pos = mesh.pts[j * (grid_n + 1) + k], .col = .{ .r = av, .g = av, .b = av, .a = av } });
            }
        }
        for (0..grid_n) |j| {
            for (0..grid_n) |k| {
                const a: dvui.Vertex.Index = @intCast(j * (grid_n + 1) + k);
                const cc = a + grid_n + 1;
                sb.appendTriangles(&.{ a, a + 1, cc + 1, a, cc + 1, cc });
            }
        }
        dvui.renderTriangles(sb.build_unowned(), null) catch {};
    }
}

fn hitTest(p: dvui.Point.Physical, w: dvui.Rect.Physical) ?usize {
    // Frontmost first: the last drawn card is the top.
    var i: usize = s.n;
    while (i > 0) {
        i -= 1;
        const c = &s.cards[i];
        const hw = w.w * c.spring.pos[3] / 2;
        const hh = w.h * c.spring.pos[3] / 2;
        const r: dvui.Rect.Physical = .{ .x = c.spring.pos[0] - hw, .y = c.spring.pos[1] - hh, .w = hw * 2, .h = hh * 2 };
        if (r.contains(p)) return i;
    }
    return null;
}

// ---- the frame --------------------------------------------------------------------------

pub fn tick(editor: *Editor) void {
    if (!s.inited) init();
    if (!s.enabled) return;
    const win = dvui.currentWindow();
    const now = win.frame_time_ns;
    const dt_s: f32 = if (s.last_ns == 0) 0.016 else @floatCast(@as(f64, @floatFromInt(@min(now - s.last_ns, 34 * std.time.ns_per_ms))) / 1e9);
    const raw_dt_ms: f32 = if (s.last_ns == 0) 0 else @floatCast(@as(f64, @floatFromInt(now - s.last_ns)) / 1e6);
    s.last_ns = now;
    s.frame += 1;
    const w = winRect();
    s.ndocs = @max(1, editor.app.open_files.count());
    if (s.level_override) |l| editor.app.settings.motion = l;

    var toggle = false;
    var click: ?dvui.Point.Physical = null;
    if (s.auto_dir != null) {
        autoScript(now, w, &toggle, &click);
        if (s.auto_step < 8) dvui.refresh(null, @src(), null);
    }
    dumpFrames(now);
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        switch (e.evt) {
            .key => |ke| {
                if (ke.action != .down) continue;
                switch (ke.code) {
                    .f8 => {
                        toggle = true;
                        e.handle(@src(), win.data());
                    },
                    .f7 => {
                        s.sheen = !s.sheen;
                        e.handle(@src(), win.data());
                    },
                    .f6 => {
                        s.layout = if (s.layout == .grid) .fan else .grid;
                        if (s.open) arm(now, false);
                        e.handle(@src(), win.data());
                    },
                    else => {},
                }
            },
            .mouse => |me| {
                if (s.visible and s.open and me.action == .press and me.button.pointer()) {
                    click = me.p;
                    e.handle(@src(), win.data());
                }
            },
            else => {},
        }
    }

    if (toggle) {
        report();
        if (!s.open) {
            // Open: photograph the front (live) view whole, place every card on the deck, then fan out.
            const front = s.cards[0].doc;
            photograph(front, true);
            for (0..s.n) |i| {
                s.cards[i].doc = i % s.ndocs;
                if (i != 0 and s.photos[s.cards[i].doc].tex == null) photograph(s.cards[i].doc, false);
                s.cards[i].spring = .{};
                s.cards[i].spring.placed = true;
                s.cards[i].spring.pos = stackPose(i, w);
                s.cards[i].target = s.cards[i].spring.pos;
            }
            // The front card shows the live view's photograph just taken.
            if (s.n > 0) s.cards[0].doc = front;
            s.open = true;
            s.visible = true;
            s.picked = null;
            s.dim_target = 0.55;
            arm(now, false);
            s.nd = 0;
        } else {
            s.open = false;
            s.dim_target = 0;
            arm(now, true);
            s.nd = 0;
        }
        s.motion_name = if (s.open) "open" else "close";
    }

    if (!s.visible) {
        // Closed: keep the active document's photograph fresh, one at a time, slowly.
        if (s.frame % 45 == 0) {
            s.cards[0].doc = 0;
            photograph(0, false);
        }
        return;
    }

    const draw_start = win.backend.nanoTime();

    // Pick.
    if (click) |p| {
        if (hitTest(p, w)) |i| {
            report();
            s.picked = i;
            s.open = false;
            s.dim_target = 0;
            s.motion_name = "pick";
            for (0..s.n) |j| {
                const c = &s.cards[j];
                c.pending = if (j == i) .{ w.x + w.w / 2, w.y + w.h / 2, 0, 1, 0, 0, 0 } else stackPose(j + 1, w);
                c.arm_ns = now + @as(i128, @intCast(if (j == i) 0 else j)) * @divTrunc(stagger_ns, 2);
            }
            s.cards[i].spring.kick(.scale, 1.2);
            s.nd = 0;
        }
    }

    // Targets: pending poses arm on their time; hover tilt and sway ride on top while open.
    const mouse = s.auto_mouse orelse win.mouse_pt;
    const hover: ?usize = if (s.open) hitTest(mouse, w) else null;
    var moving = false;
    const play = std.math.clamp((motion.level() - 0.5) * 2, 0, 1);
    const tsec: f32 = @floatCast(@as(f64, @floatFromInt(now)) / 1e9);
    for (0..s.n) |i| {
        const c = &s.cards[i];
        if (c.pending) |pnd| if (now >= c.arm_ns) {
            c.target = pnd;
            c.pending = null;
        };
        var tgt = c.target;
        if (s.open and c.pending == null) {
            if (play > 0 and !motion.off()) tgt[2] += @sin(tsec * 1.3 + @as(f32, @floatFromInt(i)) * 1.7) * 0.018 * play;
            if (hover != null and hover.? == i) {
                const hw = w.w * tgt[3] / 2;
                const hh = w.h * tgt[3] / 2;
                const nx = std.math.clamp((mouse.x - c.spring.pos[0]) / hw, -1, 1);
                const ny = std.math.clamp((mouse.y - c.spring.pos[1]) / hh, -1, 1);
                const maxt: f32 = 0.26;
                tgt[5] = -nx * maxt;
                tgt[6] = ny * maxt;
                tgt[4] = 1;
                tgt[3] *= 1.07;
                if (s.hover_prev != i) c.spring.kick(.scale, 0.9);
            }
        }
        if (c.spring.step(tgt, dt_s, 5.5)) moving = true;
        if (c.pending != null) moving = true;
    }
    if (hover) |h| s.hover_prev = h else s.hover_prev = max_cards;
    s.dim = if (@abs(s.dim - s.dim_target) < 0.002) s.dim_target else s.dim + (s.dim_target - s.dim) * @min(1, dt_s * 9);

    // Draw: a dim over the app, then the cards back to front (the last card is the bottom).
    w.fill(.all(0), .{ .color = .{ .color = dvui.Color.black.opacity(s.dim) } });
    var i: usize = s.n;
    while (i > 0) {
        i -= 1;
        // The hovered card draws last: on top.
        if (hover != null and hover.? == i) continue;
        drawCard(i, w, 0.9);
    }
    if (hover) |h| drawCard(h, w, 1.0);

    record(raw_dt_ms, @floatCast(@as(f64, @floatFromInt(win.backend.nanoTime() - draw_start)) / 1e6));

    const keep = moving or s.open or @abs(s.dim - s.dim_target) > 0.002;
    // Always something to sway at playful while open.
    if (keep) dvui.refresh(null, @src(), null);
    if (!keep) {
        report();
        s.visible = false;
        if (s.picked) |p| {
            const doc = s.cards[p].doc;
            if (doc < editor.app.open_files.count()) editor.workbench.setActiveDocIndex(doc);
            s.cards[0].doc = doc;
            s.picked = null;
        }
    }
}

fn record(frame_ms: f32, draw_ms: f32) void {
    if (s.nd < s.dts.len) {
        s.dts[s.nd] = frame_ms;
        s.draws[s.nd] = draw_ms;
        s.nd += 1;
    }
}

fn report() void {
    if (s.nd < 3) return;
    const n = s.nd;
    var tmp: [512]f32 = undefined;
    @memcpy(tmp[0..n], s.dts[0..n]);
    std.mem.sort(f32, tmp[0..n], {}, std.sort.asc(f32));
    var sum: f32 = 0;
    for (s.dts[1..n]) |v| sum += v;
    var dsum: f32 = 0;
    var dmax: f32 = 0;
    for (s.draws[0..n]) |v| {
        dsum += v;
        dmax = @max(dmax, v);
    }
    const nf: f32 = @floatFromInt(n);
    std.log.info("CARDS {s} level={d:.2} cards={d} frames={d} frame_ms mean={d:.2} p95={d:.2} max={d:.2} | cpu_ms(tick+draw) mean={d:.3} max={d:.3} | photos={d:.2}MB sheen={}", .{
        s.motion_name,  motion.level(),                                         s.n,        n,
        sum / (nf - 1), tmp[@min(n - 1, @as(usize, @intFromFloat(nf * 0.95)))], tmp[n - 1], dsum / nf,
        dmax,           @as(f32, @floatFromInt(s.photo_bytes)) / 1048576.0,     s.sheen,
    });
    s.nd = 0;
}

// ---- the scripted run: a synthetic pointer and the toggles, so a tape needs no OS input --------

fn cardCenter(i: usize, w: dvui.Rect.Physical) dvui.Point.Physical {
    const p = openPose(i, w);
    return .{ .x = p[0], .y = p[1] };
}

fn lerpPt(a: dvui.Point.Physical, b: dvui.Point.Physical, t: f32) dvui.Point.Physical {
    const k = std.math.clamp(t, 0, 1);
    const e = k * k * (3 - 2 * k);
    return .{ .x = a.x + (b.x - a.x) * e, .y = a.y + (b.y - a.y) * e };
}

/// The script, in seconds from the first frame: open, sweep the pointer over cards (sheen on part
/// of the way), close, open again, click a card.
fn autoScript(now: i128, w: dvui.Rect.Physical, toggle: *bool, click: *?dvui.Point.Physical) void {
    if (s.auto_t0 == 0) s.auto_t0 = now;
    const t: f32 = @floatCast(@as(f64, @floatFromInt(now - s.auto_t0)) / 1e9);
    const hop = @min(s.n - 1, 1);
    const far = @min(s.n - 1, 4);
    const mid = @min(s.n - 1, 2);
    const pick = @min(s.n - 1, 3);
    if (s.auto_step == 0 and t > 1.5) {
        toggle.* = true;
        s.auto_step = 1;
    } else if (s.auto_step == 1 and t > 3.2) {
        s.auto_step = 2;
    } else if (s.auto_step == 2) {
        // Sweep: card 1, then far across, then a third.
        const k = (t - 3.2) / 1.2;
        s.auto_mouse = if (k < 1) lerpPt(.{ .x = w.w / 2, .y = w.h + 20 }, cardCenter(hop, w), k) else lerpPt(cardCenter(hop, w), cardCenter(far, w), k - 1.2);
        if (t > 5.2 and std.c.getenv("FIZZY_CARDS_NOSHEEN") == null) s.sheen = true;
        if (t > 6.6) {
            s.auto_step = 3;
            s.auto_from = s.auto_mouse.?;
        }
    } else if (s.auto_step == 3) {
        s.auto_mouse = lerpPt(s.auto_from, cardCenter(mid, w), (t - 6.6) / 0.8);
        if (t > 7.8) {
            toggle.* = true;
            s.auto_mouse = .{ .x = -1, .y = -1 };
            s.auto_step = 4;
        }
    } else if (s.auto_step == 4 and t > 10.0) {
        toggle.* = true;
        s.auto_step = 5;
    } else if (s.auto_step == 5 and t > 12.0) {
        s.auto_mouse = cardCenter(pick, w);
        s.auto_step = 6;
    } else if (s.auto_step == 6 and t > 12.8) {
        click.* = s.auto_mouse;
        s.auto_step = 7;
    } else if (s.auto_step == 7 and t > 15.5) {
        std.log.info("CARDS_AUTO done", .{});
        s.auto_step = 8;
    }
}

/// One frame of the run as raw RGBA (width, height in the file name), a frame behind the
/// screen: the copy lands before it can be read.
fn dumpFrames(now: i128) void {
    const dir = s.auto_dir orelse return;
    if (!s.auto_frames) return;
    const arena = dvui.currentWindow().arena();
    if (s.shot_pending) |tgt| {
        s.shot_pending = null;
        if (dvui.Texture.readTarget(arena, tgt)) |px| {
            var name: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&name, "{s}/f{d:0>4}_t{d}_{d}x{d}.rgba", .{ dir, s.shot_n, @divTrunc(now - s.auto_t0, std.time.ns_per_ms), tgt.width, tgt.height }) catch return;
            core.fs.write(dvui.io, path, std.mem.sliceAsBytes(px)) catch {};
            s.shot_n += 1;
        } else |_| {}
        tgt.destroyLater();
    }
    if (s.visible) {
        const r = winRect();
        s.shot_pending = core.FrameTarget.snapshotTarget(r, .{ @intFromFloat(r.w / 2), @intFromFloat(r.h / 2) });
    }
}
