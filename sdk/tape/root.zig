//! `tape` — demos and recordings of a dvui app as data, and the engine that replays them exactly.
//!
//! std-only: no dvui, no window, no app. What a tape aims at is named (an anchor), what its keys
//! spell is the app's to say (`Tape.Check`), and how its input reaches widgets is the app's sink
//! (`Sequencer.Sink`) — so the same tapes play in any dvui app, and a plugin can write a demo of
//! itself with `Script`. The dvui half (the player, the overlay) lives with the app.
//!
//!   * `Tape` — the data: keyframes, input ops, captions, chapters. Round-trips through ZON
//!     (`Tape.parse`, `Tape.write`) and the binary form (`binary`); `Tape.load` reads either.
//!   * `binary` — the binary form: a bounds check and a copy to load, not a parse.
//!   * `Sequencer` — plays a tape a frame at a time, deterministically.
//!   * `Script` — writes a tape the way a person would act it out.
pub const Tape = @import("Tape.zig");
pub const Sequencer = @import("Sequencer.zig");
pub const Script = @import("Script.zig");
pub const binary = @import("binary.zig");

test {
    _ = Tape;
    _ = Sequencer;
    _ = Script;
    _ = binary;
}
