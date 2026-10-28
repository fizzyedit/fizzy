//! The `dashboard.cards` service: what a team or host has for the person to look at, as cards in
//! and actions out. The dashboard plugin draws them (a carousel of the ones that need an answer)
//! and calls `act` when the person picks an action; it knows nothing of where a card came from.
//! A provider (the host app, a team layer, a plugin) registers one and owns every string.
//!
//! A card the person has answered is the provider's to drop: the next `list` leaves it out and
//! `generation` has moved. Every call is on the UI thread. Optional, like every service: with no
//! provider the dashboard says so.

pub const Api = struct {
    /// Bump whenever this struct's layout changes: `getServiceTyped` refuses a provider whose
    /// version differs rather than reinterpreting one shape as another across `dlopen`.
    pub const service_version: u32 = 1;
    pub const service_name = "dashboard.cards";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const Emphasis = enum(u8) {
        normal,
        /// The action the card is mostly asking for.
        primary,
        /// One that loses something: drawn apart from the others.
        destructive,
    };

    pub const Action = struct {
        /// What `act` is given back; unique within its card.
        id: []const u8,
        label: []const u8,
        emphasis: Emphasis = .normal,
    };

    pub const Card = struct {
        /// Stable while the card exists; `act` names the card by it.
        id: []const u8,
        title: []const u8,
        /// Who or what is asking ("Linux worker", "CI"); empty draws nothing.
        source: []const u8 = "",
        /// The full information, shown whole: no card is truncated to a summary.
        body: []const u8,
        actions: []const Action = &.{},
    };

    pub const VTable = struct {
        list: *const fn (ctx: *anyopaque) []const Card,
        act: *const fn (ctx: *anyopaque, card_id: []const u8, action_id: []const u8) void,
        generation: *const fn (ctx: *anyopaque) u32,
    };

    /// The cards that need the person, oldest first. Owned by the provider and valid until
    /// `generation` changes: a caller keeping a string past that copies it.
    pub fn list(self: Api) []const Card {
        return self.vtable.list(self.ctx);
    }

    /// The person picked `action_id` on `card_id`. The provider does what it means and drops the
    /// card when it is answered. An unknown card or action is ignored.
    pub fn act(self: Api, card_id: []const u8, action_id: []const u8) void {
        self.vtable.act(self.ctx, card_id, action_id);
    }

    /// Moves whenever `list` would answer differently. Cheap to ask every frame.
    pub fn generation(self: Api) u32 {
        return self.vtable.generation(self.ctx);
    }
};
