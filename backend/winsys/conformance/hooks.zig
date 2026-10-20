//! The hooks a driver may provide beyond the required ones (`root.zig`): how the outside world
//! reaches the platform. A real window system's driver implements what its harness can do (a
//! synthetic event, a helper process); a case that needs a hook the driver lacks is skipped.
//!
//! The signatures, so a driver and the cases agree:
//!
//! - `tap(*Driver, Event.Code)`: press and release a key as the focused window's user would.
//! - `imeCompose(*Driver, text, start, len)`, `imeCommit(*Driver, text)`, `imeCancel(*Driver)`:
//!   an input method's composition in the focused window; offsets in UTF-8 bytes.
//! - `copyFromOutside(*Driver, text)`: another program replaces the clipboard.
//! - `dragBegin(*Driver, Window, geometry.Point, Drop.Data)`, `dragMove(*Driver, Window,
//!   geometry.Point)`, `dragEnd(*Driver) DropOutcome`: a drag from another program over a window
//!   (physical pixels from its top left); `dragEnd` lets go and says how it ended.
//! - `plugDisplay(*Driver, scale: f32) u64` and `unplugDisplay(*Driver, id)`: a display appears
//!   or goes; `setDisplayScale(*Driver, id, scale)`: the user changes a display's scaling.
const std = @import("std");

pub const Hook = enum {
    tap,
    imeCompose,
    imeCommit,
    imeCancel,
    copyFromOutside,
    dragBegin,
    dragMove,
    dragEnd,
    plugDisplay,
    unplugDisplay,
    setDisplayScale,
};

/// How a drag ended, as the app's last `dropRespond` decided.
pub const DropOutcome = enum { accepted, rejected, outside };
