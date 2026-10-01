// Liquid glass (`core/gfx/LiquidField.zig`): rounded boxes run together by a smooth minimum,
// frosted and refracting, in one pass at every pixel. Written against the program prelude
// (`core/gfx/programs.zig`): VARYING, TEX, FRAG_COLOR, MAX_VEC4.
//
// Mirrors `LiquidField.sample` line for line; change both together.
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
    vec4 g5 = uData[5]; // dither

    // The two nearest shapes, for the outline and for the way out.
    float d1 = 1e9; float d2 = 1e9; vec4 m1 = vec4(0.0); vec4 m2 = vec4(0.0);
    float f1 = 1e9; float f2 = 1e9; vec2 o1 = vec2(0.0); vec2 o2 = vec2(0.0);
    for (int i = 0; i < MAX_SHAPES; i++) {
        if (i < first) continue;
        if (i >= first + count) break;
        vec4 s0 = uData[G + 3 * i];
        vec4 s1 = uData[G + 3 * i + 1];
        vec4 s2 = uData[G + 3 * i + 2];
        vec2 g;
        float d = sdRoundBox(p - s0.xy, s0.zw, min(s1, vec4(min(s0.z, s0.w))), g);
        if (d < d1) { d2 = d1; m2 = m1; d1 = d; m1 = s2; } else if (d < d2) { d2 = d; m2 = s2; }
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

    // What the glass shows here: further out along the way out, as steep as it is (`seen`).
    vec2 uv = clamp((p + outv * (g2.x * lens * steepR) - g0.xy) * g0.zw, 0.0, 1.0);
    vec4 frost = TEX(uSampler, uv);
    vec4 sharp = g4.w > 0.5 ? TEX(uTex1, uv) : frost;

    // The frost at its share of a frost / tint mix, the blur coming in from sharp.
    float mixv = g4.z > 0.5 ? g4.x * b : 0.0;
    vec4 c = mix(sharp, frost, b) * (1.0 - mixv);
    // The rim's clearer glass over it (`drawClear`).
    float a = clamp(g2.y * lens * steepR * steepR * (1.0 - mixv), 0.0, 1.0);
    c = sharp * a + c * (1.0 - sharp.a * a);
    // The tint (`addTint`).
    c += g3 * mixv;
    // The lift and the rim's light (`drawLift`), brightest facing the top left.
    float facing = dot(outv, vec2(-0.70710678, -0.70710678));
    float toward = max(facing, 0.0);
    float away = max(-facing, 0.0);
    float spec = 0.45 * (toward * sqrt(toward) + 0.75 * away * sqrt(away)) + 0.06;
    float line = exp(-max(0.0, -D) / g2.z);
    float lit = line * spec + 0.04 * steepL * toward;
    float lift = (g4.z > 0.5 ? g4.y * b : 0.0) + mat.z;
    c += vec4(clamp(lift + lens * g2.w * lit, 0.0, 1.0));
    c = clamp(c, 0.0, 1.0);
    c.rgb += (noise(gl_FragCoord.xy) - 0.5) * g5.x * c.a;
    FRAG_COLOR = clamp(c, 0.0, 1.0) * cov;
}
