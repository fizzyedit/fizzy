//! `glass/shaders/liquid_glass.fragment.hlsl`, ported line for line to Zig — a spike, to see what
//! a real program needs that Zig's SPIR-V backend has or lacks (`README.md`). The HLSL stays the
//! one fizzy draws; read it for what each step means.
const gpu = @import("gpu.zig");
const Vec2 = gpu.Vec2;
const Vec4 = gpu.Vec4;
const splat2 = gpu.splat2;
const splat4 = gpu.splat4;

const G = 7;
const max_shapes = 16;
const U = gpu.Uniforms(G + 3 * max_shapes);

fn sdRoundBox(p: Vec2, b: Vec2, r: Vec4, g: *Vec2) f32 {
    const rr = if (p[0] > 0) (if (p[1] > 0) r[2] else r[1]) else (if (p[1] > 0) r[3] else r[0]);
    const q = @abs(p) - b + splat2(rr);
    const s: Vec2 = .{ if (p[0] < 0) -1.0 else 1.0, if (p[1] < 0) -1.0 else 1.0 };
    if (q[0] > 0 and q[1] > 0) {
        g.* = gpu.normalize(q) * s;
    } else if (q[0] > q[1]) {
        g.* = .{ s[0], 0 };
    } else {
        g.* = .{ 0, s[1] };
    }
    return @min(@max(q[0], q[1]), 0) + gpu.length(@max(q, splat2(0))) - rr;
}

fn softBox(p: Vec2, s: Vec4, k: f32, o: *Vec2) f32 {
    const d: Vec4 = .{ p[0] - s[0] + s[2], s[0] + s[2] - p[0], p[1] - s[1] + s[3], s[1] + s[3] - p[1] };
    const m = @min(@min(d[0], d[1]), @min(d[2], d[3]));
    const w = @exp((splat4(m) - d) / splat4(k));
    const sum = w[0] + w[1] + w[2] + w[3];
    o.* = Vec2{ w[1] - w[0], w[3] - w[2] } / splat2(sum);
    return k * @log(sum) - m;
}

fn smin(a: f32, b: f32, k: f32, m: *f32) f32 {
    const h = @max(k - @abs(a - b), 0) / k;
    m.* = h * h * 0.5;
    if (b < a) m.* = 1 - m.*;
    return @min(a, b) - h * h * k * 0.25;
}

fn noise(p: Vec2) f32 {
    return gpu.frac(52.9829189 * gpu.frac(gpu.dot(p, Vec2{ 0.06711056, 0.00583715 })));
}

/// Un-premultiplies `x`'s channel `c` by its own alpha and puts it back at `a`.
fn rebase(x: Vec4, comptime c: u32, a: f32) f32 {
    return x[c] / @max(x[3], 1e-4) * a;
}

fn opaqueOf(x: Vec4) Vec4 {
    const a = @max(x[3], 1e-4);
    return .{ x[0] / a, x[1] / a, x[2] / a, 1 };
}

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    const color = gpu.color.*;
    const first: u32 = @intFromFloat(color[1] * 255.0 + 0.5);
    const count: u32 = @intFromFloat(color[2] * 255.0 + 0.5);
    const p = gpu.uv.*;
    const g0 = U.data(0);
    const g1 = U.data(1);
    const g2 = U.data(2);
    const g3 = U.data(3);
    const g4 = U.data(4);
    const g5 = U.data(5);
    const g6 = U.data(6);
    const inward = g5[1] > 0;

    var d1: f32 = 1e9;
    var d2: f32 = 1e9;
    var m1 = splat4(0);
    var m2 = splat4(0);
    var h1: f32 = 1e9;
    var h2: f32 = 1e9;
    var f1: f32 = 1e9;
    var f2: f32 = 1e9;
    var o1 = splat2(0);
    var o2 = splat2(0);
    var i = first;
    while (i < first + count and i < max_shapes) : (i += 1) {
        const s0 = U.data(G + 3 * i);
        const s1 = U.data(G + 3 * i + 1);
        const s2 = U.data(G + 3 * i + 2);
        var g: Vec2 = undefined;
        const d = sdRoundBox(p - Vec2{ s0[0], s0[1] }, .{ s0[2], s0[3] }, @min(s1, splat4(@min(s0[2], s0[3]))), &g);
        const hs = @min(s0[2], s0[3]);
        if (d < d1) {
            d2 = d1;
            m2 = m1;
            h2 = h1;
            d1 = d;
            m1 = s2;
            h1 = hs;
        } else if (d < d2) {
            d2 = d;
            m2 = s2;
            h2 = hs;
        }
        var o: Vec2 = undefined;
        var f = d;
        if (s2[3] < 0.5) {
            f = softBox(p, s0, g1[1], &o);
        } else {
            o = g;
        }
        if (f < f1) {
            f2 = f1;
            o2 = o1;
            f1 = f;
            o1 = o;
        } else if (f < f2) {
            f2 = f;
            o2 = o;
        }
    }
    const k = @max(g1[0], 0.0001);
    var wm: f32 = undefined;
    var wf: f32 = undefined;
    const D = smin(d1, d2, k, &wm);
    const F = smin(f1, f2, k, &wf);
    const cov = gpu.clamp(0.5 - D, 0, 1);
    if (cov <= 0) {
        gpu.discard();
    }
    if (color[0] < 0.5) {
        gpu.out.* = .{ 0, 0, 0, cov };
        return;
    }

    const mat = gpu.lerp(m1, m2, wm);
    const outv = gpu.lerp(o1, o2, wf);
    const soft = @max(0, -F);
    const steepR = @exp(-soft / g1[2]);
    const steepL = @exp(-soft / g1[3]);
    const b = gpu.clamp(mat[0], 0, 1);
    const lens = mat[1];

    var t: f32 = 0;
    var disp: f32 = 0;
    var uv: Vec2 = undefined;
    const origin: Vec2 = .{ g0[0], g0[1] };
    const scale: Vec2 = .{ g0[2], g0[3] };
    if (inward) {
        const W = @max(@min(g5[1] * gpu.lerp(h1, h2, wm), g6[3]), 1);
        t = gpu.clamp(1 - soft / W, 0, 1);
        disp = g5[2] * W * lens * t * t;
        uv = gpu.clamp01((p - outv * splat2(disp) - origin) * scale);
    } else {
        uv = gpu.clamp01((p + outv * splat2(g2[0] * lens * steepR) - origin) * scale);
    }
    var frost = gpu.sampleLevel(gpu.texture0, uv, 0);
    var sharp = if (g4[3] > 0.5) gpu.sampleLevel(gpu.texture1, uv, 0) else frost;
    if (inward and g6[1] > 0 and disp > 0.5) {
        const du = outv * splat2(disp * 0.04 * g6[1]) * scale;
        const uvr = gpu.clamp01(uv + du);
        const uvb = gpu.clamp01(uv - du);
        frost[0] = rebase(gpu.sampleLevel(gpu.texture0, uvr, 0), 0, frost[3]);
        frost[2] = rebase(gpu.sampleLevel(gpu.texture0, uvb, 0), 2, frost[3]);
        if (g4[3] > 0.5) {
            sharp[0] = rebase(gpu.sampleLevel(gpu.texture1, uvr, 0), 0, sharp[3]);
            sharp[2] = rebase(gpu.sampleLevel(gpu.texture1, uvb, 0), 2, sharp[3]);
        } else {
            sharp[0] = frost[0];
            sharp[2] = frost[2];
        }
    }
    const under = if (g6[0] > 0.5) 1 else frost[3];
    frost = opaqueOf(frost);
    sharp = opaqueOf(sharp);

    var mixv = if (g4[2] > 0.5) g4[0] else 0;
    if (inward) mixv *= 1 - t * t * (1 - gpu.smoothstep(0.8, 1, mixv));
    var c = gpu.lerp(sharp, frost, b) * splat4(1 - mixv);
    const a = gpu.clamp(g2[1] * lens * (if (inward) t else steepR * steepR) * (1 - mixv), 0, 1);
    c = sharp * splat4(a) + c * splat4(1 - sharp[3] * a);
    c += g3 * splat4(mixv);
    c += frost * splat4(1 - c[3]);

    const facing = gpu.dot(outv, Vec2{ -0.70710678, -0.70710678 });
    const toward = @max(facing, 0);
    const away = @max(-facing, 0);
    const px = g2[2] * 1.25;
    const af = @abs(facing);
    const diagonal = inward and g6[2] > 0;
    const edge_dark = if (diagonal)
        g6[2] * (1 - gpu.smoothstep(0.2, 0.7, af)) * @exp(-@max(0, -D) / (2 * px))
    else
        0.85 * (1 - gpu.smoothstep(0, 0.5 * px, -D));
    const shade = if (inward) @max(g5[3] * t * t, edge_dark) else 0;
    const lit_by = under * (1 - shade);
    var o: Vec4 = .{ c[0] * lit_by, c[1] * lit_by, c[2] * lit_by, lit_by + shade };

    const spec = if (inward)
        (if (diagonal) g6[2] * gpu.smoothstep(0.75, 1, af) else 0.25)
    else
        0.45 * (toward * @sqrt(toward) + 0.75 * away * @sqrt(away)) + 0.06;
    const line = if (diagonal)
        @exp(-@max(0, -D) / px)
    else if (inward)
        gpu.smoothstep(0.25 * px, 0.5 * px, -D) * (1 - gpu.smoothstep(1.2 * px, 1.6 * px, -D))
    else
        @exp(-@max(0, -D) / g2[2]);
    const lit = line * spec + (if (inward) 0 else 0.04 * steepL * toward);
    const lift = (if (g4[2] > 0.5) g4[1] else 0) + mat[2];
    const light = gpu.clamp(lift + lens * g2[3] * lit, 0, 1);
    o += Vec4{ light, light, light, 0 };
    o = gpu.clamp01(o);
    o[3] = @max(o[3], @max(o[0], @max(o[1], o[2])));
    const grain = (noise(p) - 0.5) * g5[0] * o[3];
    o += Vec4{ grain, grain, grain, 0 };
    gpu.out.* = gpu.clamp01(o) * splat4(cov);
}
