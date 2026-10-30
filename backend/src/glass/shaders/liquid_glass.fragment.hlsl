// Liquid glass (`core/gfx/LiquidField.zig`): rounded boxes run together by a smooth minimum,
// frosted and refracting, in one pass at every pixel.
//
// The one source of the program: written here, in HLSL, and generated from it for every backend
// by `scripts/compile-shaders.sh` — SPIR-V (Vulkan) and DXIL (D3D12) for fizzy's native backend,
// Metal for it on macOS, GLSL ES 3.00 for the web — into `compiled/`, which CI checks against this
// (`.github/workflows/shaders.yml`). Never edit those by hand: change this, and commit what CI
// compiles. `LiquidField.sample` mirrors the field on the CPU, line for line; change it with this.
//
// Each quad's vertex colour says what it draws: r the pass (0 punches the glass's coverage out
// of what is there, 1 adds the glass), g and b the first of its shapes and how many.
//
// To the interface the native backend's programs take (`program_example.fragment.hlsl`): the
// default vertex shader's outputs as inputs, the draw's own texture (the frost) at slot 0, the
// sharp picture at 1, the uniforms as one array. On the web the same, by the names
// `core.gfx.programs` gives them (the generator renames them).

#define G 11
#define MAX_SHAPES 16
// How far past its place's outline the outside of the place begins, in pixels: far enough that no
// sliver of it shows inside, near enough that a shape at the outline still runs into it.
#define EDGE_GAP 1.0

// No SV_POSITION: D3D12 links a pixel shader's inputs to the vertex shader's outputs by register,
// and the default vertex shader's third output (the instance) sits where a pixel position read
// here would land — the pipeline is refused. The noise below takes `uv` instead, which is the
// same window pixel (`LiquidField.quads`).
struct PSInput
{
    float4 color : COLOR;
    float2 uv : TEXCOORD0;
};

Texture2D<float4> Frost : register(t0, space2);
SamplerState FrostSampler : register(s0, space2);
Texture2D<float4> Sharp : register(t1, space2);
SamplerState SharpSampler : register(s1, space2);

cbuffer Uniforms : register(b0, space3)
{
    float4 uData[G + 3 * MAX_SHAPES];
};

// Signed distance to a box of half-size `b` at the origin, its corners rounded `r`
// (top-left, top-right, bottom-right, bottom-left; y down), and which way is out.
float sdRoundBox(float2 p, float2 b, float4 r, out float2 g)
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

// `liquid_glass.fieldAt`: a soft minimum of the distances to the box's four sides, so the way
// out turns smoothly round a corner and never folds along a diagonal. Negative inside.
float softBox(float2 p, float4 s, float k, out float2 o)
{
    float4 d = float4(p.x - s.x + s.z, s.x + s.z - p.x, p.y - s.y + s.w, s.y + s.w - p.y);
    float m = min(min(d.x, d.y), min(d.z, d.w));
    float4 w = exp((m - d) / k);
    float sum = w.x + w.y + w.z + w.w;
    o = float2(w.y - w.x, w.w - w.z) / sum;
    return k * log(sum) - m;
}

// iq's quadratic smooth minimum, and how much of `b` is in it.
float smin(float a, float b, float k, out float m)
{
    float h = max(k - abs(a - b), 0.0) / k;
    m = h * h * 0.5;
    if (b < a) m = 1.0 - m;
    return min(a, b) - h * h * k * 0.25;
}

// Rounded intersection (hg_sdf fOpIntersectionRound); it stays within both operands.
float intersectRound(float a, float b, float r)
{
    if (r == 0.0) return max(a, b);
    return min(-r, max(a, b)) + length(max(float2(r + a, r + b), 0.0));
}

float panelDistance(float2 p, float soft, out float2 g)
{
    float4 box = uData[G + 3 * (MAX_SHAPES - 1)];
    float4 rad = min(uData[G + 3 * (MAX_SHAPES - 1) + 1], (float4)min(box.z, box.w));
    int count = int(uData[G + 3 * (MAX_SHAPES - 1) + 2].z);
    float d = soft > 0.0 ? softBox(p, box, soft, g) : sdRoundBox(p - box.xy, box.zw, rad, g);
    for (int i = 0; i < count && i < 4; i++) {
        float4 seam = uData[G + 3 * (MAX_SHAPES - 2 - i)];
        float4 params = uData[G + 3 * (MAX_SHAPES - 2 - i) + 1];
        if (params.x == 0.0) continue;
        float open = clamp(params.x / params.y, 0.0, 1.0);
        float along = seam.x < 0.5 ? p.y : p.x;
        float v = (seam.x < 0.5 ? p.x : p.y) - seam.y;
        float h = params.x / 2.0;
        float len = seam.w - seam.z;
        float advance = smoothstep(0.0, 0.6, open);
        float tip;
        float direction;
        if (params.w > 2.5) {
            float u = along - (seam.z + seam.w) / 2.0;
            tip = max(len / 2.0 * (1.0 - advance) - abs(u), 0.0);
            direction = u < 0.0 ? 1.0 : -1.0;
        } else {
            float u = params.w < 1.5 ? along - seam.z : seam.w - along;
            tip = max(u - (len - h) * advance, 0.0);
            direction = params.w < 1.5 ? 1.0 : -1.0;
        }
        float lenSlot = length(float2(v, tip));
        float slot = lenSlot - h;
        float2 slotOut = float2(0.0, 0.0);
        if (lenSlot > 0.0) {
            slotOut = float2(-v, -tip * direction) / lenSlot;
            if (seam.x > 0.5) slotOut = slotOut.yx;
        }
        float radius = params.z * open;
        float2 weights = max(float2(radius + d, radius - slot), 0.0);
        float norm = length(weights);
        if (radius > 0.0 && norm > 0.0) g = (weights.x * g + weights.y * slotOut) / norm;
        else if (-slot > d) g = slotOut;
        d = intersectRound(d, -slot, radius);
    }
    return d;
}

// A soft step in at `a`, then a fall over `w`: the lit edge's line and glow along the inside of
// the outline (`x` the depth inside it).
float band(float x, float a, float w)
{
    return smoothstep(a - 0.5, a + 0.5, x) * exp(-max(0.0, x - a) / max(w, 1e-3));
}

// How far the light runs on from the place of the box (centre and half size `s0`, corner radii
// `rad`) that faces `L`, the unit vector toward the light: 1 there, falling in a smoothstep to 0 at
// `ext` pixels, over the last `ramp` of them (at least one pixel, so a hard cut is still anti-aliased).
// The place is the point of the outline whose normal is `L`: on the corner's arc, or, where `L` is
// square to an axis, on the side facing it at p's own place along it. The chord stands for the
// distance along the outline (at a radius of 50 it is short by 1 pixel).
float alongEnd(float2 p, float4 s0, float4 rad, float2 L, float ext, float ramp)
{
    float2 q = float2(L.x < 0.0 ? -1.0 : 1.0, L.y < 0.0 ? -1.0 : 1.0);
    float r = q.x < 0.0 ? (q.y < 0.0 ? rad.x : rad.w) : (q.y < 0.0 ? rad.y : rad.z);
    float2 inner = max(s0.zw - r, 0.0);
    float2 P = s0.xy + q * inner + r * L;
    if (abs(L.x) < 1e-3) P.x = clamp(p.x, s0.x - inner.x, s0.x + inner.x) + r * L.x;
    if (abs(L.y) < 1e-3) P.y = clamp(p.y, s0.y - inner.y, s0.y + inner.y) + r * L.y;
    return 1.0 - smoothstep(max(ext - max(ramp, 1.0), 0.0), ext, length(p - P));
}

float noise(float2 p)
{
    return frac(52.9829189 * frac(dot(p, float2(0.06711056, 0.00583715))));
}

float4 main(PSInput input) : SV_Target0
{
    int first = int(input.color.g * 255.0 + 0.5);
    int count = int(input.color.b * 255.0 + 0.5);
    float2 p = input.uv;
    float4 g0 = uData[0];
    float4 g1 = uData[1];
    float4 g2 = uData[2];
    float4 g3 = uData[3];
    float4 g4 = uData[4];
    float4 g5 = uData[5]; // dither; the lens: its band's share of the shape, its bend, its shade
    float4 g7 = uData[7]; // the look's curves (`glass_look.Look`): the wash at the shape's top and at its bottom, the sweep, the luminance ceiling (1: off)
    float4 g8 = uData[8]; // how dark the window's hairline edge is; the lit edge's line width, glow width, and the length of its falloff ramp
    float4 g9 = uData[9]; // the light: the unit vector toward it, its height, the far side's share
    float4 g10 = uData[10]; // the lit edge: line, glow, shade, and how far the light runs along the outline (0: the lit edge is off, the drop's edge reads only the light)
    float4 g6 = uData[6]; // opaque window (+1); the lens: dispersion, a drop's diagonal light (0: a window's hairline), the band's cap
    // Apple's lens (`glass_look.inApp`): the picture pulled inward from a band near the rim,
    // magnified and, past a bend of 1, folded there. Off, the earlier glass: pulled from outside.
    bool inward = g5.y > 0.0;

    // The two nearest shapes, for the outline and for the way out.
    float d1 = 1e9; float d2 = 1e9; float4 m1 = float4(0.0, 0.0, 0.0, 0.0); float4 m2 = float4(0.0, 0.0, 0.0, 0.0);
    float h1 = 1e9; float h2 = 1e9;
    // Each nearest shape's vertical extent: its centre and half height, for the wash and the sweep.
    float2 y1 = float2(0.0, 1.0); float2 y2 = float2(0.0, 1.0);
    float f1 = 1e9; float f2 = 1e9; float2 o1 = float2(0.0, 0.0); float2 o2 = float2(0.0, 0.0);
    // Each nearest shape's reach of light from its lit place and from the far one (`alongEnd`).
    float2 al1 = float2(0.0, 0.0); float2 al2 = float2(0.0, 0.0);
    for (int i = first; i < first + count && i < MAX_SHAPES; i++) {
        float4 s0 = uData[G + 3 * i];
        float4 s1 = uData[G + 3 * i + 1];
        float4 s2 = uData[G + 3 * i + 2];
        bool panel = s2.w < -0.5 || s2.w > 3.5;
        if (panel) {
            s0 = uData[G + 3 * (MAX_SHAPES - 1)];
            s1 = uData[G + 3 * (MAX_SHAPES - 1) + 1];
            s2 = uData[G + 3 * (MAX_SHAPES - 1) + 2];
            s2.z = 0.0;
        }
        float2 g;
        float4 rad = min(s1, (float4)min(s0.z, s0.w));
        float d = sdRoundBox(p - s0.xy, s0.zw, rad, g);
        if (panel) d = panelDistance(p, 0.0, g);
        float hs = min(s0.z, s0.w);
        float2 al = float2(0.0, 0.0);
        if (g10.w > 0.0) al = float2(alongEnd(p, s0, rad, g9.xy, g10.w, g8.w), alongEnd(p, s0, rad, -g9.xy, g10.w, g8.w));
        if (d < d1) { d2 = d1; m2 = m1; h2 = h1; y2 = y1; al2 = al1; d1 = d; m1 = s2; h1 = hs; y1 = s0.yw; al1 = al; } else if (d < d2) { d2 = d; m2 = s2; h2 = hs; y2 = s0.yw; al2 = al; }
        float2 o;
        float f = d;
        if (s2.w < 0.5) {
            f = softBox(p, s0, g1.y, o);
        } else {
            o = g;
        }
        if (panel) {
            f = panelDistance(p, g1.y, o);
        }
        if (f < f1) { f2 = f1; o2 = o1; f1 = f; o1 = o; } else if (f < f2) { f2 = f; o2 = o; }
    }
    // The place the glass belongs to (`LiquidField.edge`), in the last slot, flagged 2. Its outside
    // is one more shape: a shape near the outline runs into it, a neck that joins it to the edge.
    // Its outline cuts the glass's coverage, so none of it crosses; the rim and the bend come from
    // the joined shape, so there is no rim along the cut, as if the glass carried on past it.
    // Flagged 3, cut (`LiquidField.Edge.cut`): not joined, and the cut is an edge of the glass's
    // own, its rim and bend along it.
    float inPlace = -1e9;
    float2 placeOut = float2(0.0, 0.0);
    float4 e0 = uData[G + 3 * (MAX_SHAPES - 1)];
    float4 e2 = uData[G + 3 * (MAX_SHAPES - 1) + 2];
    bool cutEdge = e2.w > 2.5 && e2.w < 3.5;
    if (e2.w > 1.5 && e2.w < 3.5) {
        float4 e1 = uData[G + 3 * (MAX_SHAPES - 1) + 1];
        float2 ge;
        inPlace = sdRoundBox(p - e0.xy, e0.zw, min(e1, (float4)min(e0.z, e0.w)), ge);
        placeOut = ge;
    }
    if (e2.w > 1.5 && e2.w < 3.5 && !cutEdge) {
        float2 ge = placeOut;
        float d = EDGE_GAP - inPlace;
        float hs = h1;
        if (d < d1) { d2 = d1; m2 = m1; h2 = h1; y2 = y1; al2 = al1; d1 = d; m1 = e2; h1 = hs; y1 = e0.yw; al1 = float2(0.0, 0.0); } else if (d < d2) { d2 = d; m2 = e2; h2 = hs; y2 = e0.yw; al2 = float2(0.0, 0.0); }
        float2 o = -ge;
        if (d < f1) { f2 = f1; o2 = o1; f1 = d; o1 = o; } else if (d < f2) { f2 = d; o2 = o; }
    }
    float k = max(g1.x, 0.0001);
    float wm; float wf;
    float D = smin(d1, d2, k, wm);
    float F = smin(f1, f2, k, wf);
    // Cut: the glass's outline, and so its rim line, runs along the place's where that is nearer.
    if (cutEdge) D = max(D, inPlace);
    float cov = clamp(0.5 - max(D, inPlace), 0.0, 1.0);
    if (cov <= 0.0) discard;
    if (input.color.r < 0.5) return float4(0.0, 0.0, 0.0, cov);

    float4 mat = lerp(m1, m2, wm);
    float2 outv = lerp(o1, o2, wf);
    // Cut: where the place's outline is nearer than the shapes' own, the glass's edge is the cut.
    if (cutEdge && inPlace > F) { F = inPlace; outv = placeOut; }
    // The light's reach along the outline, blended as the shapes are; none where the way out
    // folds in (a neck), which is no outline.
    float2 along = lerp(al1, al2, wm) * min(length(outv), 1.0);
    float soft = max(0.0, -F);
    float steepR = exp(-soft / g1.z);
    float steepL = exp(-soft / g1.w);
    float b = clamp(mat.x, 0.0, 1.0);
    float lens = mat.y;

    // Level 0 explicitly: the frost has no mips, and an implicit level after `discard` is a
    // derivative in divergent control flow, which Metal and GLSL let pass and HLSL does not.
// What the glass shows here. Apple's lens: from further in, within the band near the rim — `t`
// 1 at the edge, 0 a band in — by `bend` bands at the edge, falling off as t², so the picture
// magnifies toward the rim and folds where the slope passes 1. The earlier glass: further out
// along the way out, as steep as it is (`seen`).
    float t = 0.0;
    float disp = 0.0;
    float2 uv;
    if (inward) {
        float W = max(min(g5.y * lerp(h1, h2, wm), g6.w), 1.0);
        t = clamp(1.0 - soft / W, 0.0, 1.0);
        disp = g5.z * W * lens * t * t;
        uv = clamp((p - outv * disp - g0.xy) * g0.zw, 0.0, 1.0);
    } else {
        uv = clamp((p + outv * (g2.x * lens * steepR) - g0.xy) * g0.zw, 0.0, 1.0);
    }
    float4 frost = Frost.SampleLevel(FrostSampler, uv, 0.0);
    float4 sharp = g4.w > 0.5 ? Sharp.SampleLevel(SharpSampler, uv, 0.0) : frost;
    // The colour fringe: red and blue from either side, each un-premultiplied by its own alpha and
    // put back at the middle's. By the middle's alone, at the edge of a clear part of the window
    // the two alphas differ widely, and the fringe came out as red and blue specks.
    if (inward && g6.y > 0.0 && disp > 0.5) {
        float2 du = outv * (disp * 0.04 * g6.y) * g0.zw;
        float2 uvr = clamp(uv + du, 0.0, 1.0);
        float2 uvb = clamp(uv - du, 0.0, 1.0);
        float4 frost_r = Frost.SampleLevel(FrostSampler, uvr, 0.0);
        frost.r = frost_r.r / max(frost_r.a, 1e-4) * frost.a;
        float4 frost_b = Frost.SampleLevel(FrostSampler, uvb, 0.0);
        frost.b = frost_b.b / max(frost_b.a, 1e-4) * frost.a;
        if (g4.w > 0.5) {
            float4 sharp_r = Sharp.SampleLevel(SharpSampler, uvr, 0.0);
            sharp.r = sharp_r.r / max(sharp_r.a, 1e-4) * sharp.a;
            float4 sharp_b = Sharp.SampleLevel(SharpSampler, uvb, 0.0);
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
    // Glass that is the window's own material (`LiquidField.window`, its mix 2): the window's colour,
    // the tint, in place of what is behind it, as see-through as that colour is, so the desktop's
    // material shows through it as it does through the window round a card.
    bool window = g4.x > 1.5;
    float under = window ? g3.a : (fmod(uData[6].x, 2.0) > 0.5 ? 1.0 : frost.a);
    frost = float4(frost.rgb / max(frost.a, 1e-4), 1.0);
    sharp = float4(sharp.rgb / max(sharp.a, 1e-4), 1.0);

// The frost at its share of a frost / tint mix, the blur coming in from sharp. The window's
// colour comes in whatever the blur: the opacity is the colour, under clear glass too.
    float mixv = window ? 1.0 : (g4.z > 0.5 ? g4.x : 0.0);
    // Apple's lens: the window's colour fades out across the band, as an OS window's does
    // (`glass_look.window`, its feather: strong most of the way, gone at the edge), so the edge stays
    // the lens bending what is behind it — unless the colour is near whole, when it covers the edge
    // too (`glass_look.shine_start`, 0.8 to 1).
    if (inward && !window) mixv *= 1.0 - t * t * (1.0 - smoothstep(0.8, 1.0, mixv));
    float4 c = lerp(sharp, frost, b) * (1.0 - mixv);
// The rim's clearer glass over it (`drawClear`): for Apple's lens, the band, so the rim stays
// clear glass while the middle frosts.
    float a = clamp(g2.y * lens * (inward ? t : steepR * steepR) * (1.0 - mixv), 0.0, 1.0);
    c = sharp * a + c * (1.0 - sharp.a * a);
// The tint (`addTint`).
    c += g3 * mixv;
    // A translucent tint lies over the frost, not over what is behind the window: the glass is
    // opaque here, and `under` alone says how much of the desktop's material shows through it.
    if (window) {
        c = float4(g3.rgb / max(g3.a, 1e-4), 1.0);
    } else {
        c += frost * (1.0 - c.a);
        // The ceiling (`Look.ceiling`, 1: off): what is brighter than it is soft-clipped, from 0.6 of
        // it, before any wash, so text over a bright backdrop keeps its contrast and the dark keeps
        // its depth.
        if (g7.w < 1.0) {
            float lum = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
            float knee = 0.6 * g7.w;
            float room = max(g7.w - knee, 1e-4);
            float capped = lum <= knee ? lum : knee + room * (1.0 - exp(-(lum - knee) / room));
            c.rgb *= capped / max(lum, 1e-4);
        }
    }
    // The way the edge faces, against the look's light (`glass_look.Look.light_angle`, the top left
    // by default; `LiquidField.light_across` turns it a quarter): on every look, a window's
    // hairline as much as a drop's diagonal.
    float2 lightDir = g9.xy;
    float dg = g6.z;
    float facing = dot(outv, lightDir);
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
    bool diagonal = inward && dg > 0.0;
    // The lit edge (`g10.x`, below) is the one rim where it is on: neither of these draws.
    bool litEdge = g10.x > 0.0;
    float edge_dark = litEdge ? 0.0 : diagonal ? dg * (1.0 - smoothstep(0.2, 0.7, af)) * exp(-max(0.0, -D) / (2.0 * px))
                               : g8.x * (1.0 - smoothstep(0.0, 0.5 * px, -D));
    // As much as the edge has formed (`lens`), as its bend, clearing and light are: glass that is
    // barely a lens yet — a drop sunk into its place's edge — draws no dark line round itself.
    float shade = inward ? max(g5.w * t * t, edge_dark) * min(lens, 1.0) : 0.0;
    float4 o = float4(c.rgb * (under * (1.0 - shade)), under * (1.0 - shade) + shade);
// The lift and the rim's light (`drawLift`), brightest facing the top left.
    // A drop's light: where the edge faces the light, and on along the outline as far as the look's
    // `rim_extent` carries it from its lit corners (a straight side under a diagonal light faces it
    // at 0.707, below the start, so it is dark by design).
    float spec = inward ? (diagonal ? dg * max(smoothstep(0.75, 1.0, af), max(along.x, along.y)) : 0.25)
                        : 0.45 * (toward * sqrt(toward) + 0.75 * away * sqrt(away)) + 0.06;
    float line_ = diagonal ? exp(-max(0.0, -D) / px)
             : inward ? smoothstep(0.25 * px, 0.5 * px, -D) * (1.0 - smoothstep(1.2 * px, 1.6 * px, -D))
                        : exp(-max(0.0, -D) / g2.z);
    float lit = litEdge ? 0.0 : line_ * spec + (inward ? 0.0 : 0.04 * steepL * toward);
    // Down the shape (`v`, 0 at its top): the wash falls from `wash_top` to `wash_bottom`, and the
    // sweep, a specular band over the top ~38%, is strongest at the top edge.
    float2 ys = lerp(y1, y2, wm);
    float v = clamp((p.y - (ys.x - ys.y)) / max(2.0 * ys.y, 1e-4), 0.0, 1.0);
    float wash = g7.x + (g7.y - g7.x) * v + g7.z * (1.0 - smoothstep(0.0, 0.38, v));
    float lift = (g4.z > 0.5 ? g4.y + wash : 0.0) + mat.z;
    // The glass's own light, added whole. Scaled with the picture, it went wherever the picture
    // was see-through — over the explorer, which is the window's OS glass — and the glass all but
    // vanished there, rim and all, where Liquid Glass keeps its bright rim over anything.
    o.rgb += (float3)clamp(lift + lens * g2.w * lit, 0.0, 1.0);
    // The lit edge (`LiquidField.sample` mirrors it): a sharp line at the outline and a glow inside
    // it on the sides toward the light, `rim_back` of it on the far sides, a dark band on the sides
    // square to it. The line also runs on along the outline from the lit places (`along`). As much
    // as the edge has formed (`lens`), as the old edge is. The picture is `cov` over all of it,
    // below.
    if (litEdge) {
        float2 n2 = dot(outv, outv) > 1e-8 ? normalize(outv) : float2(0.0, 0.0);
        float f = dot(n2, g9.xy);
        float pw = lerp(8.0, 1.0, g9.z);
        float litE = pow(max(f, 0.0), pw) + g9.w * pow(max(-f, 0.0), pw);
        float edgeOn = min(lens, 1.0);
        float rimLine = g10.x * max(litE, max(along.x, g9.w * along.y)) * band(-D, 0.0, g8.y) * edgeOn;
        float glow = g10.y * litE * band(-D, g8.y, g8.z) * edgeOn;
        float shadeE = g10.z * (1.0 - abs(f)) * band(-D, 0.0, 2.0 * px) * edgeOn;
        o.rgb = o.rgb * (1.0 - shadeE) + (rimLine + glow);
    }
    o = clamp(o, 0.0, 1.0);
    // Light over a see-through picture carries its own alpha: brighter than its alpha, a pixel is
    // no colour premultiplied, and the frost captured from this frame next (`rgb / a`) blew it up
    // into bright specks wherever the window is clear — over the explorer. Opaque, alpha is 1.
    o.a = max(o.a, max(o.r, max(o.g, o.b)));
    o.rgb += (noise(p) - 0.5) * g5.x * o.a;
    return clamp(o, 0.0, 1.0) * cov;
}
