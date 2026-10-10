//! The `plugins` service: what each plugin's loading did, as the app saw it. Whether a plugin is
//! loaded, how many times it has been (a generation that counts every load: startup, a reload of
//! a rebuilt binary, an update, re-enabling), why the last attempt failed when it did, and how
//! long the last load took.
//!
//! Consumers: anything that waits on a plugin's rebuild (an agent's build loop watches the
//! generation move), a plugin author's status line, the store's page for a plugin, a
//! development overlay. A reload that fails leaves the running build in place: `state` stays
//! `loaded`, the generation stays put, and `why` says what went wrong.
const std = @import("std");

pub const Api = struct {
    pub const service_version: u32 = 1;
    pub const service_name = "plugins";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const State = enum(u8) {
        /// No build of this id is running: never loaded, unloaded, or disabled.
        not_loaded,
        loaded,
        /// It failed to load and nothing of it runs (`why` says what).
        failed,
    };

    pub const Status = struct {
        state: State,
        /// How many times this id has loaded in this run of the app. A reload moves it; a failed
        /// reload does not.
        generation: u32 = 0,
        /// How many loads or reloads of this id have failed in this run. A caller waiting on a
        /// reload sees it move when the reload fails, as `generation` moves when it lands.
        failures: u32 = 0,
        /// Why the last load or reload of this id failed, empty when it did not. Valid until the
        /// next call.
        why: []const u8 = "",
        /// The last successful load: opening the binary (off the UI thread, for a reload), and
        /// swapping it in on the UI thread. Zero when not measured (a startup load).
        opened_ms: f32 = 0,
        swapped_ms: f32 = 0,
    };

    pub const VTable = struct {
        status: *const fn (ctx: *anyopaque, id: []const u8) Status,
    };

    pub fn status(self: Api, id: []const u8) Status {
        return self.vtable.status(self.ctx, id);
    }
};
