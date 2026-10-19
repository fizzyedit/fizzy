//! `program_example.fragment.hlsl`, in Zig: tints the draw's own texture by `data[0]`, then mixes
//! in the extra texture at slot 1, tiled `data[1].x` times, by `data[1].y`.
const gpu = @import("gpu.zig");
const U = gpu.Uniforms(2);

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    const d0 = U.data(0);
    const d1 = U.data(1);
    const base = gpu.sample(gpu.texture0, gpu.uv.*) * gpu.color.* * d0;
    const extra = gpu.sample(gpu.texture1, gpu.uv.* * gpu.splat2(d1[0]));
    gpu.out.* = gpu.lerp(base, extra, d1[1]);
}
