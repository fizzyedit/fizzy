//! The `plugins` service: what each plugin's loading did, as the app saw it. Whether a plugin is
//! loaded, how many times it has been (a generation that counts every load: startup, a reload of
//! a rebuilt binary, an update, re-enabling), why the last attempt failed when it did, and how
//! long the last load took. And who each plugin is and what it brought (`list`): its name,
//! whether it is built into the app or loaded from its own library, its version, and how many
//! surfaces, commands, services, menus and the rest it registered.
//!
//! Consumers: anything that waits on a plugin's rebuild (an agent's build loop watches the
//! generation move), a plugin author's status line, the store's page for a plugin, a
//! development overlay, the dashboard's Plugins section (plans/DASHBOARD_PLAN.md). A reload that fails leaves the running build in place: `state` stays
//! `loaded`, the generation stays put, and `why` says what went wrong.
const std = @import("std");

pub const Api = struct {
    /// 2: `list`.
    pub const service_version: u32 = 2;
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

    /// How a plugin is in the app.
    pub const Link = enum(u8) {
        /// Compiled into the app.
        bundled,
        /// Loaded from a library file of its own: a store install, or a development build.
        library,
    };

    /// How many of each thing a plugin registered with the host.
    pub const Registered = struct {
        surfaces: u32 = 0,
        commands: u32 = 0,
        services: u32 = 0,
        /// Menu items and sections, native menu items, rail items and open actions.
        menus: u32 = 0,
        settings: u32 = 0,
        file_kinds: u32 = 0,
        languages: u32 = 0,
    };

    pub const Info = struct {
        id: []const u8,
        /// The name a person sees.
        name: []const u8,
        link: Link,
        /// Its own version and the SDK it was built against, as its library says; zero for a
        /// bundled plugin, which is the app's own version.
        version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
        built_with_sdk: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
        /// Its library's path; empty for a bundled plugin.
        path: []const u8 = "",
        registered: Registered = .{},
        status: Status,
    };

    pub const VTable = struct {
        status: *const fn (ctx: *anyopaque, id: []const u8) Status,
        list: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) error{OutOfMemory}![]Info,
    };

    pub fn status(self: Api, id: []const u8) Status {
        return self.vtable.status(self.ctx, id);
    }

    /// Every plugin the app has, loaded or failed to load, in the order they registered (the
    /// failed after), allocated in `arena`. Its strings are the app's: valid until a plugin is
    /// loaded or unloaded, so read them now and copy what you keep. The app's own internal
    /// plugins (`Plugin.internal`) are left out.
    pub fn list(self: Api, arena: std.mem.Allocator) error{OutOfMemory}![]Info {
        return self.vtable.list(self.ctx, arena);
    }
};
