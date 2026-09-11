//! How a watcher thread wakes a sleeping application.
//!
//! Every watcher here runs its own thread and has the same need: it has buffered something, and
//! the UI thread may be parked in the event loop with nothing to draw. Waking it is a single call
//! into the *application's* backend — `window.backend.refresh()` for fizzy — which is the one
//! thing in this directory that cannot be answered without knowing whose window it is.
//!
//! So the application answers it once, at startup, and the watchers stop caring. A single
//! function pointer rather than a field threaded through three constructors: there is one event
//! loop per process, waking it is idempotent, and a watcher that wakes nothing (because the app
//! never set this) degrades to "the change is picked up on the next frame something else causes"
//! rather than failing.
//!
//! Safe to call from any thread — that is the whole point of it. See `Editor.fizzyRefresh`'s doc
//! comment for how that was verified: one call reliably wakes the blocked loop for exactly one
//! frame.
var hook: ?*const fn () void = null;

/// Called once by the application, before any watcher starts.
pub fn setHook(f: *const fn () void) void {
    hook = f;
}

/// Wake the UI thread, if the application said how. A no-op otherwise.
pub fn now() void {
    if (hook) |f| f();
}
