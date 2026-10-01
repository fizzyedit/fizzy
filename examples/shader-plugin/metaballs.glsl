// Liquid metaballs orbiting the pointer: the example shader for `core.programs`. Written against
// the program prelude (`core/gfx/programs.zig`) — VARYING, TEX, FRAG_COLOR, MAX_VEC4 — so the one
// source builds for WebGL2 and WebGL1.
//
// uData[0]: time (s), width, height (physical px), scale
// uData[1]: pointer (physical px from the top left)

VARYING vec4 vColor;
VARYING vec2 vTextureCoord;
uniform vec4 uData[MAX_VEC4];

// iq's quadratic smooth minimum: shapes within k of each other run together.
float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// Signed distance to the blob (negative inside): a drop on the pointer and six orbiting it.
float blob(vec2 p, vec2 m, float t, float s) {
    float d = length(p - m) - 40.0 * s;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float a = t * (0.55 + 0.15 * fi) + fi * 1.047;
        float r = (78.0 + 26.0 * sin(t * 0.7 + fi * 2.1)) * s;
        vec2 c = m + vec2(cos(a), sin(a * 1.3)) * r;
        d = smin(d, length(p - c) - (14.0 + 5.0 * fi) * s, 36.0 * s);
    }
    return d;
}

void main() {
    vec4 g0 = uData[0];
    vec4 g1 = uData[1];
    float t = g0.x;
    float s = g0.w;
    vec2 p = vTextureCoord * g0.yz;
    vec2 m = g1.xy;

    float d = blob(p, m, t, s);
    // Which way is out, from the distance a pixel over each way.
    vec2 n = normalize(vec2(blob(p + vec2(1.0, 0.0), m, t, s) - d, blob(p + vec2(0.0, 1.0), m, t, s) - d) + 1e-6);

    vec3 bg = mix(vec3(0.06, 0.06, 0.09), vec3(0.11, 0.09, 0.15), vTextureCoord.y);
    bg += 0.02 * sin(vec3(p.x, p.y, p.x + p.y) * 0.015 / s + t);

    // Deeper colour toward the middle, a line of light round the rim facing the top left, and a
    // soft glow just outside.
    float depth = clamp(-d / (34.0 * s), 0.0, 1.0);
    vec3 col = mix(vec3(0.96, 0.58, 0.38), vec3(0.50, 0.22, 0.52), depth);
    float rim = exp(-max(-d, 0.0) / (6.0 * s));
    col += rim * 0.55 * pow(max(dot(n, vec2(-0.7071, -0.7071)), 0.0), 1.5);
    col += rim * 0.12;
    float glow = exp(-max(d, 0.0) / (18.0 * s)) * 0.18;

    float cov = clamp(0.5 - d, 0.0, 1.0);
    vec3 c = mix(bg + glow * vec3(0.96, 0.58, 0.38), col, cov);
    FRAG_COLOR = vec4(c, 1.0);
}
