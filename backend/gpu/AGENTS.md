# backend/gpu: the GPU device interface

Std-only: a `Device` (`{ctx, vtable}`), its plain types, shader formats and a `Null` skeleton.
Read `README.md` first; what implements it is a plan in fizzyedit/plans.

- **No SDL, no dvui, no `winsys` import.** A file here compiles for every target and builds into a
  test with no GPU. A window is a `WindowId` (`winsys.Window.id`); the implementation maps it.
- **Clean room.** This surface comes from fizzy's own use (`GpuRenderer`) and SDL_GPU's public
  documentation and behaviour. Do not open SDL's or another library's GPU source while changing it
  (`docs/PITFALLS.md`, "clean-room hygiene").
- **Add a field when the renderer needs it,** not because a GPU API has it. Every call in the
  vtable is one `GpuRenderer` makes today.
- **A new implementation passes `Null`'s frame test** (`Null.zig`, "a GpuRenderer frame runs
  through the interface") before it draws anything, and registers its own tests in `build.zig`'s
  `unit_tests` only if they are std-only.
