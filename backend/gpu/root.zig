//! gpu: the device interface fizzy's renderer draws through, std-only.
//!
//! Pure data and a vtable, like `winsys`: no SDL, no dvui, nothing that allocates on its own.
//! `README.md` is the audit of what `GpuRenderer` asks of SDL_GPU, the decisions, and what is
//! left out; the renderers that implement `Device` are a plan of their own (fizzyedit/plans).
//!
//! Nothing outside this directory uses it yet: moving `GpuRenderer` onto it is the first step
//! of that plan, once the interface has been read against the SDL_GPU adapter.
pub const Device = @import("Device.zig");
pub const Null = @import("Null.zig");
pub const types = @import("types.zig");
pub const shader = @import("shader.zig");

test {
    _ = Device;
    _ = Null;
    _ = shader;
}
