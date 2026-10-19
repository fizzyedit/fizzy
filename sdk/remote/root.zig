//! `remote` — the remote-view protocol: how a host application shows a view of a running fizzy.
//!
//! std-only: no dvui, no sockets, no fizzy. The transport is the caller's (a byte stream through
//! `Endpoint`, or `Message` values passed straight across for an in-process editor), so fizzy's
//! server and every adapter, through the C API (`fizzy_remote.h`), share one definition.
//! `README.md` has the encoding.
//!
//!   * `message` — the messages and the types in them.
//!   * `codec` — frames, and a `Message` to bytes and back.
//!   * `FrameReader` — cuts a byte stream into frames, in whatever chunks it arrives.
//!   * `Connection` — the rules of the conversation, with no bytes in it.
//!   * `Endpoint` — a `Connection` with the bytes around it, and a loopback `pump` for tests.
pub const message = @import("message.zig");
pub const codec = @import("codec.zig");
pub const FrameReader = @import("FrameReader.zig");
pub const Connection = @import("Connection.zig");
pub const Endpoint = @import("Endpoint.zig");

pub const Message = message.Message;

test {
    _ = message;
    _ = codec;
    _ = FrameReader;
    _ = Connection;
    _ = Endpoint;
    _ = @import("tests.zig");
}
