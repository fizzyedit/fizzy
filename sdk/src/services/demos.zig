//! The `demos` service: the demos the app can play, and playing one. A demo opens on a keyframe
//! and plays the real app, setting the person's session aside while it plays and giving it back
//! when it ends (`docs/AUTOMATION.md`). Not a live tape, which plays on whatever is open: that is
//! the `automation` service.
//!
//! The app's own demos are listed here (fizzy's tour), with every demo a plugin registers
//! (`Host.registerDemo`) and, on the web, the guides hosted beside the page. A guides browser lists
//! them and plays the one a person picks; an agent can play one by name.
//!
//! Every call is on the UI thread. Optional, like every service: an app with no demo player
//! registers none.

pub const Api = struct {
    /// Bump whenever this struct's layout changes: `getServiceTyped` refuses a provider whose
    /// version differs rather than reinterpreting one shape as another across `dlopen`.
    pub const service_version: u32 = 1;
    pub const service_name = "demos";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const Origin = enum(u8) {
        /// Built into the app.
        bundled,
        /// Registered by a plugin (`Host.registerDemo`).
        plugin,
        /// Hosted beside the web page, fetched when it is played.
        hosted,
    };

    pub const Chapter = struct {
        /// Where it begins, in demo milliseconds.
        at: u32,
        title: []const u8,
    };

    pub const Info = struct {
        name: []const u8,
        title: []const u8,
        /// How long it plays, start to end, in demo milliseconds.
        ms: u32,
        chapters: []const Chapter,
        origin: Origin,
    };

    pub const Play = enum(u8) {
        /// Playing from the next frame.
        started,
        /// No demo of that name.
        unknown,
        /// Something else is driving the app (a live tape): try again once it is done.
        busy,
        /// Never answered: a demo plays on a stage of its own, the person's work, saved or not,
        /// set aside untouched. Kept so a plugin switching on it still builds; it goes at the
        /// next SDK release that moves the boundary for another reason.
        unsaved,
    };

    pub const VTable = struct {
        list: *const fn (ctx: *anyopaque) []const Info,
        play: *const fn (ctx: *anyopaque, name: []const u8, at_ms: u32) Play,
        current: *const fn (ctx: *anyopaque) ?[]const u8,
        generation: *const fn (ctx: *anyopaque) u32,
    };

    /// Every demo the app can play, its own first. Owned by the app and valid until `generation`
    /// changes: a caller keeping a name or a title past that copies it.
    pub fn list(self: Api) []const Info {
        return self.vtable.list(self.ctx);
    }

    /// Play the demo named `name` from `at_ms` (0: from the start; a chapter's `at` starts at that
    /// chapter). A demo already playing is replaced.
    pub fn play(self: Api, name: []const u8, at_ms: u32) Play {
        return self.vtable.play(self.ctx, name, at_ms);
    }

    /// The name of the demo loaded now (playing, paused or at its end), or null. Owned by the
    /// app, valid for the frame.
    pub fn current(self: Api) ?[]const u8 {
        return self.vtable.current(self.ctx);
    }

    /// Moves whenever `list` would answer differently: a plugin's demos came or went, or the
    /// hosted guides arrived. Cheap to ask every frame.
    pub fn generation(self: Api) u32 {
        return self.vtable.generation(self.ctx);
    }
};
