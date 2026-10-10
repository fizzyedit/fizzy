//! The `automation` service: play a live tape on the app as it is, ask whether the app has
//! settled, and read what is on screen as text.
//!
//! A **live tape** is input — clicks aimed at named widgets, keys, text, commands with arguments
//! — played on whatever the person has open, a step at a time, each once the last has landed. It
//! is the other kind of tape from a demo, which opens on a keyframe and sets the person's session
//! aside (`docs/AUTOMATION.md`; `plans/AGENTS_PLAN.md`, "Driving a live tape"). A plugin builds one
//! with the SDK's `tape` module (`tape.Script`, with `check.live = true`) and hands it over as
//! bytes, ZON (`Tape.write`) or binary (`tape.binary.encode`): the tape's layout never crosses the
//! boundary, only its encoding.
//!
//! Consumers: a plugin's tests, a macro, a scripted tutorial — anything that drives the app the
//! way a person does, through the same widgets and commands. Widgets name themselves for a tape
//! while one plays (`core.anchor`); a plugin wanting those names for itself asks with
//! `core.anchor.want()`, not through here.
//!
//! **What is on screen** (`snapshot`, `snapshotText`): every visible widget a person acts on or a
//! tape aims at, a line each, as ZON — its role, its name, its tag, its rect and what it sits in
//! (`replay.Snapshot`). The names a person reads, so a caller can find "the Close Tab button" and
//! aim a tape at its tag, or at its rect, without a picture.
//!
//! **One tape at a time.** A tape is refused (`busy`) while another plays or a demo is loaded. A
//! person's click, key, scroll or typed text stops it (`interrupted`), and a wait in the tape that
//! never holds stops it too (`timed_out`): a tape that has lost its place is stopped and reported,
//! never carried on blind.
//!
//! **Tickets, not callbacks.** `play` returns a number the caller later asks `outcome` about —
//! typically from its own `beginFrame`. A callback would be a function pointer into the caller's
//! image, which a hot reload of that plugin leaves dangling while the tape is still playing; a
//! number cannot dangle. The same goes for `settled`, which is cheap to ask every frame.
//!
//! Every call is on the UI thread. A plugin with work arriving on a thread of its own queues it
//! and plays from `beginFrame`, waking the app with `host.refresh()`.
//!
//! Optional, like every service: an app with nothing to play tapes on registers none.

pub const Api = struct {
    /// Bump whenever this struct's layout changes: `getServiceTyped` refuses a provider whose
    /// version differs rather than reinterpreting one shape as another across `dlopen`.
    pub const service_version: u32 = 2;
    pub const service_name = "automation";

    ctx: *anyopaque,
    vtable: *const VTable,

    /// Names one `play`, for `outcome` and `stop`. Never reused within a run of the app.
    pub const Ticket = enum(u32) { _ };

    pub const Play = union(enum) {
        /// Playing from the next frame.
        started: Ticket,
        /// Something else is driving the app: another tape, or a demo. Try again once it is done.
        busy,
        /// Not a tape, or not a live one (a demo's, opening on a keyframe). Why, in words — static
        /// text the app owns, so it can be kept.
        invalid: []const u8,
    };

    /// Op indexes count every op in the tape, from 0, so a caller can say which step a tape
    /// stopped before.
    pub const Outcome = union(enum) {
        /// Still going.
        playing,
        /// Every op was applied.
        finished,
        /// A person's input stopped it, before this op.
        interrupted: u32,
        /// The wait at this op gave up: what it waited for never came.
        timed_out: u32,
        /// `stop` stopped it, before this op.
        stopped: u32,
        /// No such ticket, or one too long ago for the app still to remember.
        unknown,
    };

    pub const VTable = struct {
        play: *const fn (ctx: *anyopaque, bytes: []const u8) Play,
        stop: *const fn (ctx: *anyopaque, ticket: Ticket) void,
        outcome: *const fn (ctx: *anyopaque, ticket: Ticket) Outcome,
        settled: *const fn (ctx: *anyopaque) bool,
        snapshot: *const fn (ctx: *anyopaque) SnapshotTicket,
        snapshotText: *const fn (ctx: *anyopaque, ticket: SnapshotTicket) ?[]const u8,
    };

    /// Names one `snapshot`. Never reused within a run of the app.
    pub const SnapshotTicket = enum(u32) { _ };

    /// Play the tape in `bytes`, ZON or binary. The bytes are read before this returns; the
    /// caller keeps them.
    pub fn play(self: Api, bytes: []const u8) Play {
        return self.vtable.play(self.ctx, bytes);
    }

    /// Stop the tape `ticket` names where it is. Nothing when that tape is not the one playing:
    /// a caller can stop its own tape, never someone else's.
    pub fn stop(self: Api, ticket: Ticket) void {
        self.vtable.stop(self.ctx, ticket);
    }

    /// How the tape `ticket` names ended, or that it is still playing.
    pub fn outcome(self: Api, ticket: Ticket) Outcome {
        return self.vtable.outcome(self.ctx, ticket);
    }

    /// Nothing is in flight: no tape or demo playing, nothing the app was asked to load still
    /// loading, and, as of the end of the last frame, nothing asked for another frame and nothing
    /// animating. A caller acts once a load has landed by asking this each frame from
    /// `beginFrame`. It need not ask for frames itself, and should not: its own refresh would
    /// keep the app from ever going quiet. The app runs one more frame after going quiet when
    /// someone was told "not yet", so the answer is seen.
    pub fn settled(self: Api) bool {
        return self.vtable.settled(self.ctx);
    }

    /// Ask what is on screen. It is taken over the next frame (the app wakes for it); asking
    /// again before then returns the same ticket.
    pub fn snapshot(self: Api) SnapshotTicket {
        return self.vtable.snapshot(self.ctx);
    }

    /// The snapshot `ticket` names, as ZON, once it has been taken: null before, and null again
    /// once a later one has been. The app's memory, valid until the next is taken: copy it.
    pub fn snapshotText(self: Api, ticket: SnapshotTicket) ?[]const u8 {
        return self.vtable.snapshotText(self.ctx, ticket);
    }
};
