//! `core.work` — long-running work written once, run on a thread or from the frame.
//!
//! A `Task` is a state machine: `step` does a bounded amount of work and says whether more
//! remains, whether it is waiting on something (bytes from a mount that have not landed),
//! or whether it is done. Nothing in it blocks. That shape is what makes one implementation
//! run everywhere:
//!
//! - **`.thread`** — a worker calls `step` back to back until `done`, parking while the task
//!   is `waiting` until `notify` wakes it. For work whose completions arrive inside the call
//!   (the local disk through `core.LocalFs`), this is exactly a blocking loop on a thread, at
//!   that speed.
//! - **`.pump`** — the host calls `pump` once a frame with a time budget; `step` runs until
//!   the budget is spent or it is waiting. The web build, which has no threads, runs every
//!   task this way; native runs a task this way when its completions are delivered by the
//!   frame pump anyway (a mount's transport), so the task's state is only ever touched from
//!   one thread. The caller picks; see `Runner.start`.
//!
//! Why not `std.Io.async`: on a single-threaded `Io` it runs the function inline to
//! completion, and there is no stackful `Io` for wasm — so a task that must not stall the
//! frame has to yield by returning, which is what `step` is. On native `Runner` puts a task
//! on a `std.Thread` for the same reason the transport does: the work is a loop the thread
//! owns, not an operation the `Io` awaits.
//!
//! The clock is the caller's (`Runner.init` takes `now`): the host's boot clock natively,
//! the frame's high-resolution timer on the web, a counter in tests.
const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const Status = enum {
    /// More to do; call again.
    more,
    /// Nothing can be done until something arrives (`Runner.notify`, or the next frame's
    /// completions).
    waiting,
    /// Finished; `step` is not called again.
    done,
};

pub const Task = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Work until `deadline_ns` (in the runner's clock; `maxInt` for "as long as it
        /// takes") or until nothing is ready, then say which.
        step: *const fn (ctx: *anyopaque, deadline_ns: i64) Status,
        /// The runner is stopping before `done`: release what `step` was holding.
        cancel: *const fn (ctx: *anyopaque) void,
    };

    pub fn step(self: Task, deadline_ns: i64) Status {
        return self.vtable.step(self.ctx, deadline_ns);
    }
    pub fn cancel(self: Task) void {
        self.vtable.cancel(self.ctx);
    }
};

pub const Mode = enum {
    /// On a worker thread. Native only, for a task whose completions arrive inside `step`.
    thread,
    /// From `pump`, on the caller's thread, within a budget per call.
    pump,
};

/// Runs one task at a time.
pub const Runner = struct {
    gpa: std.mem.Allocator,
    /// For the worker's mutex and condition (`.thread` mode only; the web build never locks).
    io: std.Io,
    now: *const fn () i64,
    /// Called from the worker when the task made progress, so the host can repaint. Optional.
    wake: ?*const fn () void,

    task: ?Task = null,
    mode: Mode = .pump,
    thread: if (is_wasm) void else ?std.Thread = if (is_wasm) {} else null,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    /// Set by `notify`, cleared by the worker when it resumes.
    notified: bool = false,
    quit: bool = false,
    finished: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, now: *const fn () i64, wake: ?*const fn () void) Runner {
        return .{ .gpa = gpa, .io = io, .now = now, .wake = wake };
    }

    /// Start `task`. `.thread` on wasm is an error: the caller decides per target and per
    /// source of completions, and this refuses the one combination that cannot work.
    pub fn start(self: *Runner, task: Task, mode: Mode) error{ Busy, Unsupported, ThreadFailed }!void {
        if (self.task != null) return error.Busy;
        if (mode == .thread and is_wasm) return error.Unsupported;
        self.task = task;
        self.mode = mode;
        self.quit = false;
        self.notified = false;
        self.finished.store(false, .release);
        if (mode == .thread and !is_wasm) {
            self.thread = std.Thread.spawn(.{}, worker, .{self}) catch {
                self.task = null;
                return error.ThreadFailed;
            };
        }
    }

    pub fn running(self: *const Runner) bool {
        return self.task != null and !self.finished.load(.acquire);
    }

    /// Wake a `.thread` task that reported `waiting` (something it asked for has arrived,
    /// or there is new work for it). Harmless for `.pump`, which is stepped every frame.
    pub fn notify(self: *Runner) void {
        if (is_wasm) return;
        self.mutex.lockUncancelable(self.io);
        self.notified = true;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
    }

    /// `.pump` mode: step the task for up to `budget_ns`. Call once per frame, from the
    /// thread that delivers its completions. Returns true while the task is alive, so the
    /// caller knows to keep the frames coming.
    pub fn pump(self: *Runner, budget_ns: i64) bool {
        const task = self.task orelse return false;
        if (self.mode != .pump) return self.running();
        if (self.finished.load(.acquire)) return false;
        const deadline = self.now() + budget_ns;
        while (true) {
            switch (task.step(deadline)) {
                .more => if (self.now() >= deadline) return true,
                .waiting => return true,
                .done => {
                    self.finished.store(true, .release);
                    return false;
                },
            }
        }
    }

    /// Stop whatever is running: a `.thread` task is cancelled and joined, a `.pump` task
    /// cancelled in place. Idempotent.
    pub fn stop(self: *Runner) void {
        const task = self.task orelse return;
        if (self.mode == .thread and !is_wasm) {
            self.mutex.lockUncancelable(self.io);
            self.quit = true;
            self.mutex.unlock(self.io);
            self.cond.signal(self.io);
            if (self.thread) |t| t.join();
            self.thread = null;
        }
        if (!self.finished.load(.acquire)) task.cancel();
        self.task = null;
    }

    /// Forget a task that has finished, so the next `start` is allowed. True if it had.
    pub fn reap(self: *Runner) bool {
        if (self.task == null or !self.finished.load(.acquire)) return false;
        if (!is_wasm) {
            if (self.thread) |t| t.join();
            self.thread = null;
        }
        self.task = null;
        return true;
    }

    fn worker(self: *Runner) void {
        const task = self.task.?;
        const io = self.io;
        while (true) {
            self.mutex.lockUncancelable(io);
            const quit = self.quit;
            self.mutex.unlock(io);
            if (quit) return;
            switch (task.step(std.math.maxInt(i64))) {
                .more => {},
                .waiting => {
                    self.mutex.lockUncancelable(io);
                    while (!self.notified and !self.quit) self.cond.waitUncancelable(io, &self.mutex);
                    self.notified = false;
                    self.mutex.unlock(io);
                },
                .done => {
                    self.finished.store(true, .release);
                    if (self.wake) |w| w();
                    return;
                },
            }
        }
    }
};

// ---- tests -----------------------------------------------------------------------------------

/// A task that counts to `goal`, one unit per call, and goes `waiting` at `wait_at` until
/// notified — the same code in both modes.
const Counter = struct {
    n: u32 = 0,
    goal: u32,
    wait_at: ?u32 = null,
    /// Set by the test after `waiting`, standing in for "the bytes arrived".
    released: bool = false,
    cancelled: bool = false,

    fn step(ctx: *anyopaque, _: i64) Status {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        if (self.wait_at) |w| {
            if (self.n == w and !self.released) return .waiting;
        }
        self.n += 1;
        return if (self.n >= self.goal) .done else .more;
    }
    fn cancel(ctx: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.cancelled = true;
    }
    const vtable: Task.VTable = .{ .step = step, .cancel = cancel };
    fn task(self: *Counter) Task {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

var test_clock: i64 = 0;
fn testNow() i64 {
    test_clock += 1;
    return test_clock;
}

test "pump mode: a budget bounds each call, the task finishes across calls" {
    var c: Counter = .{ .goal = 10 };
    var r = Runner.init(std.testing.allocator, std.testing.io, testNow, null);
    try r.start(c.task(), .pump);
    // A budget of 4 clock ticks: each `step` costs no ticks itself, but `pump` reads the
    // clock once per `.more`, so about four units land per call.
    var calls: usize = 0;
    while (r.pump(4)) calls += 1;
    try std.testing.expectEqual(@as(u32, 10), c.n);
    try std.testing.expect(calls >= 2);
    try std.testing.expect(r.reap());
    try std.testing.expect(!c.cancelled);
}

test "pump mode: waiting returns to the caller; the next pump resumes" {
    var c: Counter = .{ .goal = 5, .wait_at = 2 };
    var r = Runner.init(std.testing.allocator, std.testing.io, testNow, null);
    try r.start(c.task(), .pump);
    try std.testing.expect(r.pump(100));
    try std.testing.expectEqual(@as(u32, 2), c.n);
    try std.testing.expect(r.pump(100)); // still waiting
    try std.testing.expectEqual(@as(u32, 2), c.n);
    c.released = true;
    try std.testing.expect(!r.pump(100));
    try std.testing.expectEqual(@as(u32, 5), c.n);
}

test "thread mode: the same task runs to completion on a worker, parking while waiting" {
    if (is_wasm) return error.SkipZigTest;
    var c: Counter = .{ .goal = 1000, .wait_at = 500 };
    var r = Runner.init(std.testing.allocator, std.testing.io, testNow, null);
    try r.start(c.task(), .thread);
    // Let it reach the wait, release, wake it.
    var spins: usize = 0;
    while (@atomicLoad(u32, &c.n, .acquire) < 500 and spins < 100_000) : (spins += 1) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u32, 500), @atomicLoad(u32, &c.n, .acquire));
    @atomicStore(bool, &c.released, true, .release);
    r.notify();
    spins = 0;
    while (r.running() and spins < 100_000) : (spins += 1) std.Thread.yield() catch {};
    try std.testing.expect(r.reap());
    try std.testing.expectEqual(@as(u32, 1000), c.n);
    try std.testing.expect(!c.cancelled);
}

test "stop cancels a task that was waiting" {
    if (is_wasm) return error.SkipZigTest;
    var c: Counter = .{ .goal = 10, .wait_at = 3 };
    var r = Runner.init(std.testing.allocator, std.testing.io, testNow, null);
    try r.start(c.task(), .thread);
    var spins: usize = 0;
    while (@atomicLoad(u32, &c.n, .acquire) < 3 and spins < 100_000) : (spins += 1) std.Thread.yield() catch {};
    r.stop();
    try std.testing.expect(c.cancelled);
    try std.testing.expect(!r.running());
    try r.start(c.task(), .pump); // a stopped runner takes a new task
    r.stop();
}
