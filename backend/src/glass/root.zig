//! Fizzy's in-app glass: the frame drawn into a target so what is under a surface can be read back
//! (`FrameTarget`), the frosted and blurred backdrops made from it (`BlurBackdrop`), the liquid
//! glass laid over them (`LiquidField`, `liquid_glass`, `liquid_blob`, its fragment program through
//! `programs`), and the motion setting they move by (`motion`).
//!
//! The backend's, so a plain dvui app on fizzy's backend can be made of the same glass as fizzy's
//! own surfaces (a floating window in the window's material); fizzy's `core` re-exports every name
//! here under the one it always had (`core.FrameTarget`, `core.widgets.BlurBackdrop`, …), and
//! plugins see no change. It depends on dvui and the glass's look (`glass_look`) only; its profiler
//! scopes go to the app's profiler through `prof`.
pub const FrameTarget = @import("FrameTarget.zig");
pub const BlurBackdrop = @import("BlurBackdrop.zig");
pub const LiquidField = @import("LiquidField.zig");
pub const liquid_glass = @import("liquid_glass.zig");
pub const liquid_blob = @import("liquid_blob.zig");
pub const programs = @import("programs.zig");
pub const motion = @import("motion.zig");
pub const FrameClock = @import("FrameClock.zig");
pub const MotionClock = @import("MotionClock.zig");
pub const input_time = @import("input_time.zig");
pub const prof = @import("prof.zig");

// The glass's own test root (`build/app.zig`, on dvui's testing backend): the frost's capture
// sizes and the blobs' smooth union.
test {
    _ = BlurBackdrop;
    _ = liquid_blob;
    _ = MotionClock;
    _ = input_time;
}
