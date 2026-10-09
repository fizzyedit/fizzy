// An example program for fizzy's native backend (`SDLBackend.program_api`): the binding
// conventions a program follows, in HLSL — the source shadercross compiles to the three
// formats `createNative` takes (`shadercross program_example.fragment.hlsl -o ….{msl,spv,dxil}`).
// `compiled/msl/program_example.fragment.msl` is its Metal form, written by hand to the same
// interface.
//
// It tints the draw's own texture by the colour in `data[0]`, then mixes in the extra
// texture at slot 1, tiled `data[1].x` times, by `data[1].y`.

// The default vertex shader's outputs (dvui's `shared.hlsl`): position, then the vertex
// colour (premultiplied, 0…1) and uv. SPIR-V locations 0 and 1; MSL user(locn0), user(locn1).
// Read the colour and uv only: D3D12 links these to the vertex shader's outputs by register, and
// an SV_POSITION read here lands on the instance output's — the pipeline is refused.
struct PSInput
{
    float4 position : SV_POSITION;
    float4 color : COLOR;
    float2 uv : TEXCOORD0;
};

// Slot 0 is the draw's own texture (white when it has none); slots 1 and 2 are `begin`'s.
Texture2D<float4> Texture0 : register(t0, space2);
SamplerState Sampler0 : register(s0, space2);
Texture2D<float4> Texture1 : register(t1, space2);
SamplerState Sampler1 : register(s1, space2);

// `begin`'s uniforms: `uniform_vec4s` of them, as one array.
cbuffer Uniforms : register(b0, space3)
{
    float4 data[2];
};

float4 main(PSInput input) : SV_Target0
{
    float4 base = Texture0.Sample(Sampler0, input.uv) * input.color * data[0];
    float4 extra = Texture1.Sample(Sampler1, input.uv * data[1].x);
    return lerp(base, extra, data[1].y);
}
