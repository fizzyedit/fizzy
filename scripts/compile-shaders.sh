#!/usr/bin/env bash
# Compile every HLSL shader that has compiled forms committed beside it, into OUT (same layout):
#
#   X.hlsl  →  compiled/spv/X.spv     SPIR-V   (Vulkan)          shadercross
#              compiled/dxil/X.dxil   DXIL     (D3D12)           shadercross
#              compiled/msl/X.msl     Metal    (SDL_GPU, macOS)  shadercross
#              compiled/glsl/X.glsl   GLSL ES 3.00 (WebGL2)      spirv-cross, from the SPIR-V
#
# Only the forms that exist in the repository are made: a shader opts into one by committing it
# (an empty file to begin with). The HLSL is the one source; the rest are generated and checked
# (`.github/workflows/shaders.yml`), never edited by hand.
#
# The GLSL is complete source, for the web backend's programs (`core.gfx.programs`): its inputs
# are named as the web's vertex shader writes them (`vColor`, `vTextureCoord`), its samplers by
# unit (`uSampler` 0, `uTex1` 1), its uniforms `uData`, the names `web/web.js` binds.
#
# Needs `shadercross` and `spirv-cross` on PATH. Exits non-zero if any shader does not compile.
set -euo pipefail
OUT=${1:?usage: compile-shaders.sh OUT}
# Absolute: each shader compiles from its own directory (its `#include`s are relative).
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
failed=0
while IFS= read -r hlsl; do
  dir=$(dirname "$hlsl"); name=$(basename "$hlsl" .hlsl)
  for form in spv dxil msl glsl; do
    [ -f "$dir/compiled/$form/$name.$form" ] || continue
    dest="$OUT/$dir/compiled/$form/$name.$form"
    mkdir -p "$(dirname "$dest")"
    case $form in
      spv | dxil | msl)
        if ! (cd "$dir" && shadercross "$name.hlsl" -o "$dest"); then
          echo "::error file=$hlsl::$hlsl does not compile to $form"; failed=1
        fi ;;
      glsl)
        spv="$OUT/$dir/compiled/spv/$name.spv"
        [ -f "$spv" ] || (cd "$dir" && shadercross "$name.hlsl" -o "$spv.tmp" && mv "$spv.tmp" "$spv")
        # NaN checks relaxed: HLSL's `min` and `max` came out wrapped in `isnan` tests, a cost the
        # web's frame pays at every pixel for nothing the program relies on.
        if ! spirv-cross "$spv" --es --version 300 --flatten-ubo --relax-nan-checks \
            --rename-interface-variable in 0 vColor \
            --rename-interface-variable in 1 vTextureCoord \
            --output "$dest.raw"; then
          echo "::error file=$hlsl::$hlsl does not cross-compile to GLSL"; failed=1; continue
        fi
        # The names the web binds: the samplers by unit (spirv-cross names a texture and sampler it
        # combines after both), the uniforms `uData` (it names a flattened block for its type). And
        # floats high precision by default, as the web's own programs are: a program reads pixel
        # positions.
        sed -E \
          -e 's/\bSPIRV_Cross_CombinedFrostFrostSampler\b/uSampler/g' \
          -e 's/\bSPIRV_Cross_CombinedSharpSharpSampler\b/uTex1/g' \
          -e 's/\btype_Uniforms\b/uData/g' \
          -e 's/^precision mediump float;$/precision highp float;/' \
          "$dest.raw" > "$dest"
        rm "$dest.raw" ;;
    esac
  done
done < <(git ls-files '*.hlsl')
exit $failed
