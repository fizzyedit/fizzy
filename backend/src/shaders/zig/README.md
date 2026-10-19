# Programs in Zig (a spike)

Two of fizzy's programs, written in Zig and compiled by Zig 0.17's self-hosted SPIR-V backend
(`zig build zig-shaders`; `zig build zig-shaders-cross` adds Metal and GLSL ES through
`spirv-cross`). Nothing draws them yet: fizzy's programs are still the HLSL ones beside
`../`, compiled by `scripts/compile-shaders.sh`.

- `program_example.zig` is `program_example.fragment.hlsl`.
- `liquid_glass.zig` is `../../glass/shaders/liquid_glass.fragment.hlsl`, line for line.
- `gpu.zig` is the program interface (the inputs, textures, uniforms and output that
  `SDLBackend.program_api` documents) and what Zig lacks as a shading language.

## What was checked (macOS, Metal, 2026-10-19)

- Both pass `spirv-val --target-env vulkan1.0`. Through `spirv-cross --msl` they keep fizzy's
  bindings (`[[buffer(0)]]`, `[[texture(0/1)]]`, `[[user(locn0/1)]]`, entry `main0`), and
  through `--hlsl --shader-model 51` its registers (`b0, space3`, `t0/s0, space2`).
- Drawn in a sandbox fizzy beside their HLSL twins, through `core.programs`: the example is
  pixel for pixel the same; the glass matches to within 2/255 on 95% of its pixels and 3/255 on
  99%, the rest where the frost under the two differed.

## What Zig lacked, and the workarounds in `gpu.zig`

- **Indexing an array in a uniform block is miscompiled** (`block.data[i]`): the element's
  pointer gets the array's type and the module fails `spirv-val`. Copying the block out first
  needs SPIR-V 1.4 (`OpCopyLogical`) and copies every vec4 at every pixel. `Uniforms(n).data(i)`
  writes the access chain in inline SPIR-V instead.
- **An `@extern` made by a runtime-callable function crashes the compiler** (SIGTRAP); the
  textures are declared as constants.
- **A `"c"` (constant) operand to inline SPIR-V came out as id 0** in a non-inline function.
- **No `discard`**: `OpKill` in inline SPIR-V, in a `noinline fn … noreturn` with a label after
  it. Inlined, what Zig emits next depends on `-fstrip` and broke the block structure.
- **No `SampleLevel`**: `std.spirv` has only implicit-level sampling; `sampleLevel` is inline
  SPIR-V.
- **No swizzles, no scalar × vector, no `lerp`/`dot`/`length`/`normalize`/`smoothstep`/`frac`**:
  helpers, and `s0[2]` for `s0.z`, `Vec2{ s0[0], s0[1] }` for `s0.xy`. A vector index must be
  comptime-known.
- `callconv(.spirv_fragment)` must be `.{ .spirv_fragment = .{} }`, and the sampler address
  space is `.constant` (UniformConstant). `spirv32-vulkan` gives a Logical module;
  `spirv64-vulkan` asks for 64-bit pointers (`PhysicalStorageBuffer64`, `Int64`).
- Zig scalarizes vector arithmetic and inlines nothing: the glass is 52 KB of SPIR-V (41 KB
  stripped) against the HLSL's 19.5 KB, and its MSL 47 KB against 21 KB. `spirv-opt -O` brings
  it to 18.5 KB.

Loops, `if`/`else` chains, out-parameters (`*Vec2`), structs in uniform blocks (field access,
not arrays), `@exp`/`@log`/`@sqrt`/`@abs`/`@min`/`@max`/`@floor` (to GLSL.std.450) all worked.
