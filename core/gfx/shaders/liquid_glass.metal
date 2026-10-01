// `liquid_glass.glsl` in Metal, for fizzy's native backend (`src/backend/native`): the same
// program line for line — change both together, and `LiquidField.sample` with them. To the
// interface the native backend's programs take: entry point `main0`, the default vertex shader's
// outputs as inputs, the draw's own texture (the frost) at 0, the sharp picture at 1, the
// uniforms as buffer 0.

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
    float4 g5 = uData[5];

    float d1 = 1e9; float d2 = 1e9; float4 m1 = float4(0.0); float4 m2 = float4(0.0);
    float f1 = 1e9; float f2 = 1e9; float2 o1 = float2(0.0); float2 o2 = float2(0.0);
    for (int i = first; i < first + count && i < MAX_SHAPES; i++) {
        float4 s0 = uData[G + 3 * i];
        float4 s1 = uData[G + 3 * i + 1];
        float4 s2 = uData[G + 3 * i + 2];
        float2 g;
        float d = sdRoundBox(p - s0.xy, s0.zw, min(s1, float4(min(s0.z, s0.w))), g);
        if (d < d1) { d2 = d1; m2 = m1; d1 = d; m1 = s2; } else if (d < d2) { d2 = d; m2 = s2; }
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

    float2 uv = clamp((p + outv * (g2.x * lens * steepR) - g0.xy) * g0.zw, 0.0, 1.0);
    float4 frost = Frost.sample(FrostSampler, uv);
    float4 sharp = g4.w > 0.5 ? Sharp.sample(SharpSampler, uv) : frost;

    float mixv = g4.z > 0.5 ? g4.x * b : 0.0;
    float4 c = mix(sharp, frost, b) * (1.0 - mixv);
    float a = clamp(g2.y * lens * steepR * steepR * (1.0 - mixv), 0.0, 1.0);
    c = sharp * a + c * (1.0 - sharp.a * a);
    c += g3 * mixv;
    float facing = dot(outv, float2(-0.70710678, -0.70710678));
    float toward = max(facing, 0.0);
    float away = max(-facing, 0.0);
    float spec = 0.45 * (toward * sqrt(toward) + 0.75 * away * sqrt(away)) + 0.06;
    float line = exp(-max(0.0, -D) / g2.z);
    float lit = line * spec + 0.04 * steepL * toward;
    float lift = (g4.z > 0.5 ? g4.y * b : 0.0) + mat.z;
    c += float4(clamp(lift + lens * g2.w * lit, 0.0, 1.0));
    c = clamp(c, 0.0, 1.0);
    c.rgb += (noise(frag.xy) - 0.5) * g5.x * c.a;
    out.color = clamp(c, 0.0, 1.0) * cov;
    return out;
}
