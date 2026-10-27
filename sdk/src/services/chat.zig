//! The `chat.provider` service: the conversation a chat surface shows and the one who answers it.
//! The chat plugin draws the messages and the composer and owns no conversation; whoever has one
//! (the host app, a team plugin, an agent bridge) registers a provider and the surface reads it.
//! The chat plugin registers a tiny in-memory one when nothing else has, so the surface can be
//! tried alone.
//!
//! Every call is on the UI thread. Optional, like every service: with no provider the surface
//! says so.

pub const Api = struct {
    /// Bump whenever this struct's layout changes: `getServiceTyped` refuses a provider whose
    /// version differs rather than reinterpreting one shape as another across `dlopen`.
    pub const service_version: u32 = 1;
    pub const service_name = "chat.provider";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const Role = enum(u8) {
        /// The person typing in the composer.
        user,
        /// Whoever answers.
        assistant,
        /// The conversation itself: an attachment came, a connection dropped.
        system,
    };

    pub const Message = struct {
        role: Role,
        /// Plain text; a finished ``` fence in it is drawn as a code block.
        text: []const u8,
    };

    pub const Status = enum(u8) {
        /// Send is accepted.
        ready,
        /// An answer is being produced; the surface shows it and still lets the person type.
        busy,
        /// Send would be refused: no connection.
        offline,
    };

    pub const VTable = struct {
        messages: *const fn (ctx: *anyopaque) []const Message,
        send: *const fn (ctx: *anyopaque, text: []const u8) bool,
        attach: *const fn (ctx: *anyopaque) void,
        status: *const fn (ctx: *anyopaque) Status,
    };

    /// The conversation so far, oldest first. Owned by the provider and valid until the next
    /// `send` or the end of the frame: a caller keeping a message copies it.
    pub fn messages(self: Api) []const Message {
        return self.vtable.messages(self.ctx);
    }

    /// Add `text` as the person's next message. False when the provider refused it (offline); the
    /// surface then keeps the text in the composer. `text` is only borrowed for the call.
    pub fn send(self: Api, text: []const u8) bool {
        return self.vtable.send(self.ctx, text);
    }

    /// The person asked to attach something. The provider decides what that means (a file picker
    /// of its own, a drop target) and reports the result as a message.
    pub fn attach(self: Api) void {
        self.vtable.attach(self.ctx);
    }

    pub fn status(self: Api) Status {
        return self.vtable.status(self.ctx);
    }
};
