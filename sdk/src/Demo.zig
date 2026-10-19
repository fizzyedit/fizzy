//! A demo a plugin ships: a tape that opens on a keyframe and plays the real app, as fizzy's own
//! tour does (`docs/AUTOMATION.md`). Registered with `Host.registerDemo` in `register`, it is
//! listed and played beside fizzy's bundled demos through the `demos` service
//! (`sdk.services.demos`): by a guides browser, a command (`fizzy.demo.play`), an agent.
//!
//! The tape crosses the boundary as bytes only, ZON (`Tape.write`) or binary (`tape.binary`): a
//! plugin builds it with the SDK's `tape` module (`tape.Script`, then `finish` and an encode) and
//! hands the encoding over. The host keeps its own copy of everything here, so nothing points
//! into the plugin's image once `registerDemo` returns, and drops it when the plugin goes.
const Plugin = @import("Plugin.zig");

/// Stable id: what `fizzy.demo.play` and the `demos` service name it by. Unique among every demo
/// the app has, its own included: a second of one name is refused.
name: []const u8,
/// What a person reads in a list of guides.
title: []const u8,
/// The tape, encoded. Checked when the app lists it: one that does not load as a demo (a live
/// tape, a step no plugin applies) is left out of the list, with a warning.
tape: []const u8,
owner: ?*Plugin = null,
