//! `fizzy-automation-tests`: the std-only half of `automation/` — the tape format, the sequencer
//! that plays it and the script that writes it — under `zig build test`. Rooted here rather than
//! in `automation/` because they share the keymap's chord parser, and a module cannot reach a file
//! above its root's directory.
test {
    _ = @import("automation/Tape.zig");
    _ = @import("automation/Sequencer.zig");
    _ = @import("automation/Script.zig");
}
