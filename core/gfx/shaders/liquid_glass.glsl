// Liquid glass (`core/gfx/LiquidField.zig`): rounded boxes run together by a smooth minimum,
// frosted and refracting, in one pass at every pixel. Written against the program prelude
// (`core/gfx/programs.zig`): VARYING, TEX, FRAG_COLOR, MAX_VEC4.
//
// Mirrors `LiquidField.sample` line for line, as `liquid_glass.metal` and
// `liquid_glass.fragment.hlsl` (compiled to SPIR-V and DXIL) mirror it; change them all together.
//
// Each quad's vertex colour says what it draws: r the pass (0 punches the glass's coverage out
// of what is there, 1 adds the glass), g and b the first of its shapes and how many.

#define G 7
#define MAX_SHAPES 16

VARYING vec4 vColor;
VARYING vec2 vTextureCoord;

uniform sampler2D uSampler; // the frost
uniform sampler2D uTex1;    // the picture before the blur
uniform vec4 uData[MAX_VEC4];

// Signed distance to a box of half-size `b` at the origin, its corners rounded `r`
// (top-left, top-right, bottom-right, bottom-left; y down), and which way is out.
float sdRoundBox(vec2 p, vec2 b, vec4 r, out vec2 g) {
    float rr = p.x > 0.0 ? (p.y > 0.0 ? r.z : r.y) : (p.y > 0.0 ? r.w : r.x);
    vec2 q = abs(p) - b + rr;
    vec2 s = vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
    if (q.x > 0.0 && q.y > 0.0) {
        g = normalize(q) * s;
    } else if (q.x > q.y) {
        g = vec2(s.x, 0.0);
    } else {
        g = vec2(0.0, s.y);
    }
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rr;
}

// `liquid_glass.fieldAt`: a soft minimum of the distances to the box's four sides, so the way
// out turns smoothly round a corner and never folds along a diagonal. Negative inside.
float softBox(vec2 p, vec4 s, float k, out vec2 o) {
    vec4 d = vec4(p.x - s.x + s.z, s.x + s.z - p.x, p.y - s.y + s.w, s.y + s.w - p.y);
    float m = min(min(d.x, d.y), min(d.z, d.w));
    vec4 w = exp((m - d) / k);
    float sum = w.x + w.y + w.z + w.w;
    o = vec2(w.y - w.x, w.w - w.z) / sum;
    return k * log(sum) - m;
}

// iq's quadratic smooth minimum, and how much of `b` is in it.
float smin(float a, float b, float k, out float m) {
    float h = max(k - abs(a - b), 0.0) / k;
    m = h * h * 0.5;
    if (b < a) m = 1.0 - m;
    return min(a, b) - h * h * k * 0.25;
}

float noise(vec2 p) {
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
    int first = int(vColor.g * 255.0 + 0.5);
    int count = int(vColor.b * 255.0 + 0.5);
    vec2 p = vTextureCoord;
    vec4 g0 = uData[0]; // the frost: where it starts, and 1 / its size
    vec4 g1 = uData[1]; // merge k, softness, refraction depth, light depth
    vec4 g2 = uData[2]; // reach, clarity, rim line width, light
    vec4 g3 = uData[3]; // tint, premultiplied
    vec4 g4 = uData[4]; // mix, lift, has tint, has sharp
    vec4 g5 = uData[5]; // dither; the lens: its band's share of the shape, its bend, its shade
    vec4 g6 = uData[6]; // opaque window; the lens: dispersion, a drop's diagonal light (0: a window's hairline), the band's cap
    // Apple's lens (`glass_look.inApp`): the picture pulled inward from a band near the rim,
    // magnified and, past a bend of 1, folded there. Off, the earlier glass: pulled from outside.
    bool inward = g5.y > 0.0;

    // The two nearest shapes, for the outline and for the way out.
    float d1 = 1e9; float d2 = 1e9; vec4 m1 = vec4(0.0); vec4 m2 = vec4(0.0);
    float h1 = 1e9; float h2 = 1e9;
    float f1 = 1e9; float f2 = 1e9; vec2 o1 = vec2(0.0); vec2 o2 = vec2(0.0);
    for (int i = 0; i < MAX_SHAPES; i++) {
        if (i < first) continue;
        if (i >= first + count) break;
        vec4 s0 = uData[G + 3 * i];
        vec4 s1 = uData[G + 3 * i + 1];
        vec4 s2 = uData[G + 3 * i + 2];
        vec2 g;
        float d = sdRoundBox(p - s0.xy, s0.zw, min(s1, vec4(min(s0.z, s0.w))), g);
        float hs = min(s0.z, s0.w);
        if (d < d1) { d2 = d1; m2 = m1; h2 = h1; d1 = d; m1 = s2; h1 = hs; } else if (d < d2) { d2 = d; m2 = s2; h2 = hs; }
        vec2 o;
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
    if (cov <= 0.0) discard;
    if (vColor.r < 0.5) {
        FRAG_COLOR = vec4(0.0, 0.0, 0.0, cov);
        return;
    }

    vec4 mat = mix(m1, m2, wm); // blur, lens, light, field
    vec2 outv = mix(o1, o2, wf);
    float soft = max(0.0, -F);
    float steepR = exp(-soft / g1.z);
    float steepL = exp(-soft / g1.w);
    float b = clamp(mat.x, 0.0, 1.0);
    float lens = mat.y;

    // What the glass shows here. Apple's lens: from further in, within the band near the rim — `t`
    // 1 at the edge, 0 a band in — by `bend` bands at the edge, falling off as t², so the picture
    // magnifies toward the rim and folds where the slope passes 1. The earlier glass: further out
    // along the way out, as steep as it is (`seen`).
    float t = 0.0;
    float disp = 0.0;
    vec2 uv;
    if (inward) {
        float W = max(min(g5.y * mix(h1, h2, wm), g6.w), 1.0);
        t = clamp(1.0 - soft / W, 0.0, 1.0);
        disp = g5.z * W * lens * t * t;
        uv = clamp((p - outv * disp - g0.xy) * g0.zw, 0.0, 1.0);
    } else {
        uv = clamp((p + outv * (g2.x * lens * steepR) - g0.xy) * g0.zw, 0.0, 1.0);
    }
    vec4 frost = TEX(uSampler, uv);
    vec4 sharp = g4.w > 0.5 ? TEX(uTex1, uv) : frost;
    // A little colour fringe where the band bends hardest: red from a touch less far in, blue a
    // touch further.
    // The colour fringe: red and blue from either side, each un-premultiplied by its own alpha and
    // put back at the middle's. By the middle's alone, at the edge of a clear part of the window
    // the two alphas differ widely, and the fringe came out as red and blue specks.
    if (inward && g6.y > 0.0 && disp > 0.5) {
        vec2 du = outv * (disp * 0.04 * g6.y) * g0.zw;
        vec2 uvr = clamp(uv + du, 0.0, 1.0);
        vec2 uvb = clamp(uv - du, 0.0, 1.0);
        vec4 frost_r = TEX(uSampler, uvr);
        frost.r = frost_r.r / max(frost_r.a, 1e-4) * frost.a;
        vec4 frost_b = TEX(uSampler, uvb);
        frost.b = frost_b.b / max(frost_b.a, 1e-4) * frost.a;
        if (g4.w > 0.5) {
            vec4 sharp_r = TEX(uTex1, uvr);
            sharp.r = sharp_r.r / max(sharp_r.a, 1e-4) * sharp.a;
            vec4 sharp_b = TEX(uTex1, uvb);
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
    frost = vec4(frost.rgb / max(frost.a, 1e-4), 1.0);
    sharp = vec4(sharp.rgb / max(sharp.a, 1e-4), 1.0);

    // The frost at its share of a frost / tint mix, the blur coming in from sharp. The window's
    // colour comes in whatever the blur: the opacity is the colour, under clear glass too.
    float mixv = g4.z > 0.5 ? g4.x : 0.0;
    // Apple's lens: the window's colour fades out across the band, as an OS window's does
    // (`glass_look.window`, its feather: strong most of the way, gone at the edge), so the edge stays
    // the lens bending what is behind it — unless the colour is near whole, when it covers the edge
    // too (`glass_look.shine_start`, 0.8 to 1).
    if (inward) mixv *= 1.0 - t * t * (1.0 - smoothstep(0.8, 1.0, mixv));
    vec4 c = mix(sharp, frost, b) * (1.0 - mixv);
    // The rim's clearer glass over it (`drawClear`): for Apple's lens, the band, so the rim stays
    // clear glass while the middle frosts.
    float a = clamp(g2.y * lens * (inward ? t : steepR * steepR) * (1.0 - mixv), 0.0, 1.0);
    c = sharp * a + c * (1.0 - sharp.a * a);
    // The tint (`addTint`).
    c += g3 * mixv;
    // A translucent tint lies over the frost, not over what is behind the window: the glass is
    // opaque here, and `under` alone says how much of the desktop's material shows through it.
    c += frost * (1.0 - c.a);
    // The way the edge faces, against a light from the top left.
    float facing = dot(outv, vec2(-0.70710678, -0.70710678));
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
    vec4 o = vec4(c.rgb * (under * (1.0 - shade)), under * (1.0 - shade) + shade);
    // The lift and the rim's light (`drawLift`), brightest facing the top left.
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
    o.rgb += vec3(clamp(lift + lens * g2.w * lit, 0.0, 1.0));
    o = clamp(o, 0.0, 1.0);
    // Light over a see-through picture carries its own alpha: brighter than its alpha, a pixel is
    // no colour premultiplied, and the frost captured from this frame next (`rgb / a`) blew it up
    // into bright specks wherever the window is clear — over the explorer. Opaque, alpha is 1.
    o.a = max(o.a, max(o.r, max(o.g, o.b)));
    o.rgb += (noise(gl_FragCoord.xy) - 0.5) * g5.x * o.a;
    FRAG_COLOR = clamp(o, 0.0, 1.0) * cov;
}
