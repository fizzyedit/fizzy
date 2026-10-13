// `liquid_glass.glsl` in Metal, for fizzy's native backend (`backend/`): the same
// program line for line — change it, `liquid_glass.fragment.hlsl` and `LiquidField.sample`
// together. To the interface the native backend's programs take: entry point `main0`, the
// default vertex shader's outputs as inputs, the draw's own texture (the frost) at 0, the sharp
// picture at 1, the uniforms as buffer 0.

#include <metal_stdlib>
using namespace metal;

#define G 7
#define MAX_SHAPES 16

struct main0_in
{
    float4 color [[user(locn0)]];
    float2 uv [[user(locn1)]];
};

struct main0_out
{
    float4 color [[color(0)]];
};

static float sdRoundBox(float2 p, float2 b, float4 r, thread float2 &g)
{
    float rr = p.x > 0.0 ? (p.y > 0.0 ? r.z : r.y) : (p.y > 0.0 ? r.w : r.x);
    float2 q = abs(p) - b + rr;
    float2 s = float2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
    if (q.x > 0.0 && q.y > 0.0) {
        g = normalize(q) * s;
    } else if (q.x > q.y) {
        g = float2(s.x, 0.0);
    } else {
        g = float2(0.0, s.y);
    }
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rr;
}

static float softBox(float2 p, float4 s, float k, thread float2 &o)
{
    float4 d = float4(p.x - s.x + s.z, s.x + s.z - p.x, p.y - s.y + s.w, s.y + s.w - p.y);
    float m = min(min(d.x, d.y), min(d.z, d.w));
    float4 w = exp((m - d) / k);
    float sum = w.x + w.y + w.z + w.w;
    o = float2(w.y - w.x, w.w - w.z) / sum;
    return k * log(sum) - m;
}

static float smin(float a, float b, float k, thread float &m)
{
    float h = max(k - abs(a - b), 0.0) / k;
    m = h * h * 0.5;
    if (b < a) m = 1.0 - m;
    return min(a, b) - h * h * k * 0.25;
}

static float noise(float2 p)
{
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

fragment main0_out main0(
    main0_in in [[stage_in]],
    float4 frag [[position]],
    texture2d<float> Frost [[texture(0)]], sampler FrostSampler [[sampler(0)]],
    texture2d<float> Sharp [[texture(1)]], sampler SharpSampler [[sampler(1)]],
    constant float4 *uData [[buffer(0)]])
{
    main0_out out = {};
    int first = int(in.color.g * 255.0 + 0.5);
    int count = int(in.color.b * 255.0 + 0.5);
    float2 p = in.uv;
    float4 g0 = uData[0];
    float4 g1 = uData[1];
    float4 g2 = uData[2];
    float4 g3 = uData[3];
    float4 g4 = uData[4];
    float4 g5 = uData[5]; // dither; the lens: its band's share of the shape, its bend, its shade
    float4 g6 = uData[6]; // opaque window; the lens: dispersion, a drop's diagonal light (0: a window's hairline), the band's cap
    bool inward = g5.y > 0.0;

    float d1 = 1e9; float d2 = 1e9; float4 m1 = float4(0.0); float4 m2 = float4(0.0);
    float h1 = 1e9; float h2 = 1e9;
    float f1 = 1e9; float f2 = 1e9; float2 o1 = float2(0.0); float2 o2 = float2(0.0);
    for (int i = first; i < first + count && i < MAX_SHAPES; i++) {
        float4 s0 = uData[G + 3 * i];
        float4 s1 = uData[G + 3 * i + 1];
        float4 s2 = uData[G + 3 * i + 2];
        float2 g;
        float d = sdRoundBox(p - s0.xy, s0.zw, min(s1, float4(min(s0.z, s0.w))), g);
        float hs = min(s0.z, s0.w);
        if (d < d1) { d2 = d1; m2 = m1; h2 = h1; d1 = d; m1 = s2; h1 = hs; } else if (d < d2) { d2 = d; m2 = s2; h2 = hs; }
        float2 o;
        float f = d;
        if (s2.w < 0.5) {
            f = softBox(p, s0, g1.y, o);
        } else {
            o = g;
        }
        if (f < f1) { f2 = f1; o2 = o1; f1 = f; o1 = o; } else if (f < f2) { f2 = f; o2 = o; }
    }
    float k = max(g1.x, 0.0001);
    float wm; float wf;
    float D = smin(d1, d2, k, wm);
    float F = smin(f1, f2, k, wf);
    float cov = clamp(0.5 - D, 0.0, 1.0);
    if (cov <= 0.0) discard_fragment();
    if (in.color.r < 0.5) {
        out.color = float4(0.0, 0.0, 0.0, cov);
        return out;
    }

    float4 mat = mix(m1, m2, wm);
    float2 outv = mix(o1, o2, wf);
    float soft = max(0.0, -F);
    float steepR = exp(-soft / g1.z);
    float steepL = exp(-soft / g1.w);
    float b = clamp(mat.x, 0.0, 1.0);
    float lens = mat.y;

    float t = 0.0;
    float disp = 0.0;
    float2 uv;
    if (inward) {
        float W = max(min(g5.y * mix(h1, h2, wm), g6.w), 1.0);
        t = clamp(1.0 - soft / W, 0.0, 1.0);
        disp = g5.z * W * lens * t * t;
        uv = clamp((p - outv * disp - g0.xy) * g0.zw, 0.0, 1.0);
    } else {
        uv = clamp((p + outv * (g2.x * lens * steepR) - g0.xy) * g0.zw, 0.0, 1.0);
    }
    float4 frost = Frost.sample(FrostSampler, uv);
    float4 sharp = g4.w > 0.5 ? Sharp.sample(SharpSampler, uv) : frost;
    // The colour fringe: red and blue from either side, each un-premultiplied by its own alpha and
    // put back at the middle's. By the middle's alone, at the edge of a clear part of the window
    // the two alphas differ widely, and the fringe came out as red and blue specks.
    if (inward && g6.y > 0.0 && disp > 0.5) {
        float2 du = outv * (disp * 0.04 * g6.y) * g0.zw;
        float2 uvr = clamp(uv + du, 0.0, 1.0);
        float2 uvb = clamp(uv - du, 0.0, 1.0);
        float4 frost_r = Frost.sample(FrostSampler, uvr);
        frost.r = frost_r.r / max(frost_r.a, 1e-4) * frost.a;
        float4 frost_b = Frost.sample(FrostSampler, uvb);
        frost.b = frost_b.b / max(frost_b.a, 1e-4) * frost.a;
        if (g4.w > 0.5) {
            float4 sharp_r = Sharp.sample(SharpSampler, uvr);
            sharp.r = sharp_r.r / max(sharp_r.a, 1e-4) * sharp.a;
            float4 sharp_b = Sharp.sample(SharpSampler, uvb);
            sharp.b = sharp_b.b / max(sharp_b.a, 1e-4) * sharp.a;
        } else {
            sharp.r = frost.r;
            sharp.b = frost.b;
        }
    }
    // Worked out over an opaque picture of what the glass covers, then made exactly as
    // see-through as that is (`under`): over a translucent window (vibrancy, Acrylic) the
    // desktop's material shows through the glass as much as through the window round it. Laid
    // over the translucent picture as it was, the rim — where the clear glass lies over the
    // frost — came out more opaque than the face, and the material lit the face and not the rim.
    // Opaque where the window is (`LiquidField.publishOpaqueWindow`): its alpha is only its shape.
    float under = uData[6].x > 0.5 ? 1.0 : frost.a;
    frost = float4(frost.rgb / max(frost.a, 1e-4), 1.0);
    sharp = float4(sharp.rgb / max(sharp.a, 1e-4), 1.0);

    float mixv = g4.z > 0.5 ? g4.x : 0.0;
    // Apple's lens: the window's colour fades out across the band, as an OS window's does
    // (`glass_look.window`, its feather: strong most of the way, gone at the edge), so the edge stays
    // the lens bending what is behind it — unless the colour is near whole, when it covers the edge
    // too (`glass_look.shine_start`, 0.8 to 1).
    if (inward) mixv *= 1.0 - t * t * (1.0 - smoothstep(0.8, 1.0, mixv));
    float4 c = mix(sharp, frost, b) * (1.0 - mixv);
    float a = clamp(g2.y * lens * (inward ? t : steepR * steepR) * (1.0 - mixv), 0.0, 1.0);
    c = sharp * a + c * (1.0 - sharp.a * a);
    c += g3 * mixv;
    // A translucent tint lies over the frost, not over what is behind the window: the glass is
    // opaque here, and `under` alone says how much of the desktop's material shows through it.
    c += frost * (1.0 - c.a);
    // The way the edge faces, against a light from the top left.
    float facing = dot(outv, float2(-0.70710678, -0.70710678));
    float toward = max(facing, 0.0);
    float away = max(-facing, 0.0);
    // Apple's lens has two edges, measured beside the OS's (`g6.z`, `glass_look.InApp.diagonal`):
    // - a drop's (> 0): lit along the diagonal the light runs, top left and bottom right, about
    //   three pixels in and only near the diagonal; darkened across the other, top right and
    //   bottom left; nothing at the sides square to the light;
    // - a window's (0): a dark hairline at the very edge and a bright one, two pixels, just inside
    //   it, the same on every side (the OS window's own border, as Liquid Glass windows have).
    // Nothing across the band in either. Shade is the glass's own, not the picture's: a dark layer
    // over it, as whole where the picture is see-through as where it is not. `px` is a point, in
    // pixels (the rim line's width is 0.8 of one, `LiquidField.rim_line_width`).
    float px = g2.z * 1.25;
    float af = abs(facing);
    bool diagonal = inward && g6.z > 0.0;
    float edge_dark = diagonal ? g6.z * (1.0 - smoothstep(0.2, 0.7, af)) * exp(-max(0.0, -D) / (2.0 * px))
                               : 0.85 * (1.0 - smoothstep(0.0, 0.5 * px, -D));
    float shade = inward ? max(g5.w * t * t, edge_dark) : 0.0;
    float4 o = float4(c.rgb * (under * (1.0 - shade)), under * (1.0 - shade) + shade);
    float spec = inward ? (diagonal ? g6.z * smoothstep(0.75, 1.0, af) : 0.25)
                        : 0.45 * (toward * sqrt(toward) + 0.75 * away * sqrt(away)) + 0.06;
    float line = diagonal ? exp(-max(0.0, -D) / px)
             : inward ? smoothstep(0.25 * px, 0.5 * px, -D) * (1.0 - smoothstep(1.2 * px, 1.6 * px, -D))
                        : exp(-max(0.0, -D) / g2.z);
    float lit = line * spec + (inward ? 0.0 : 0.04 * steepL * toward);
    float lift = (g4.z > 0.5 ? g4.y : 0.0) + mat.z;
    // The glass's own light, added whole. Scaled with the picture, it went wherever the picture
    // was see-through — over the explorer, which is the window's OS glass — and the glass all but
    // vanished there, rim and all, where Liquid Glass keeps its bright rim over anything.
    o.rgb += float3(clamp(lift + lens * g2.w * lit, 0.0, 1.0));
    o = clamp(o, 0.0, 1.0);
    // Light over a see-through picture carries its own alpha: brighter than its alpha, a pixel is
    // no colour premultiplied, and the frost captured from this frame next (`rgb / a`) blew it up
    // into bright specks wherever the window is clear — over the explorer. Opaque, alpha is 1.
    o.a = max(o.a, max(o.r, max(o.g, o.b)));
    o.rgb += (noise(frag.xy) - 0.5) * g5.x * o.a;
    out.color = clamp(o, 0.0, 1.0) * cov;
    return out;
}
