//! The remote-view messages: what a host (Blender, Unreal, ...) and a running fizzy say to each
//! other about a view (plans/EMBEDDED_EDITOR_PLAN.md, "The protocol").
//!
//! Every payload is a plain struct of the types `codec.zig` can carry: fixed-width integers,
//! floats, bools, enums, packed flag structs, optionals, byte strings and slices of structs.
//! **Fields append.** A new field goes last and carries a default, so a peer that predates it
//! sends the message without it and decodes as the default; never reorder, retype or remove one.
//! The ids in `Type` are the wire's and never change or get reused.

/// One view of a connection, chosen by the host. Many per connection; 0 is never a view.
pub const ViewId = u32;

pub const min_version: u16 = 1;
pub const max_version: u16 = 1;

/// A message's wire id. Non-exhaustive: a newer peer's id decodes as an unknown number.
pub const Type = enum(u16) {
    hello = 1,
    bye = 2,
    create_view = 10,
    view_created = 11,
    close_view = 12,
    view_closed = 13,
    resize = 14,
    pointer_motion = 20,
    pointer_button = 21,
    wheel = 22,
    touch = 23,
    key = 24,
    text_input = 25,
    ime_composition = 26,
    focus = 27,
    clipboard_reply = 28,
    cursor = 40,
    ime_rect = 41,
    text_input_active = 42,
    clipboard_request = 43,
    wants_keys = 44,
    open_url = 45,
    drag_begin = 46,
    frame_request = 60,
    frame = 61,
    frame_ready = 62,
    _,

    /// A peer that does not know a *required* type must refuse the stream; one that does not
    /// know an optional type skips it by its length. Sent in the frame header.
    pub fn required(t: Type) bool {
        return switch (t) {
            .hello,
            .bye,
            .create_view,
            .view_created,
            .close_view,
            .view_closed,
            .resize,
            .frame_request,
            .frame,
            => true,
            else => false,
        };
    }

    /// Which side may send it.
    pub fn sender(t: Type) Sender {
        return switch (t) {
            .hello, .bye => .either,
            .view_created,
            .view_closed,
            .cursor,
            .ime_rect,
            .text_input_active,
            .clipboard_request,
            .wants_keys,
            .open_url,
            .drag_begin,
            .frame,
            .frame_ready,
            => .editor,
            else => .host,
        };
    }
};

pub const Sender = enum { host, editor, either };

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// Keyboard modifiers, as the host reports them.
pub const Mods = packed struct(u16) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _: u10 = 0,
};

/// The render tiers (plan, "Three render tiers"), as bits for what is offered and wanted and as
/// numbers for what a view uses.
pub const Tiers = packed struct(u8) {
    native_surface: bool = false,
    shared_texture: bool = false,
    draw_list: bool = false,
    _: u5 = 0,

    pub fn both(a: Tiers, b: Tiers) Tiers {
        return @bitCast(@as(u8, @bitCast(a)) & @as(u8, @bitCast(b)));
    }

    pub fn has(t: Tiers, tier: Tier) bool {
        return switch (tier) {
            .native_surface => t.native_surface,
            .shared_texture => t.shared_texture,
            .draw_list => t.draw_list,
            _ => false,
        };
    }
};

pub const Tier = enum(u8) { native_surface = 1, shared_texture = 2, draw_list = 3, _ };

pub const Mode = enum(u8) {
    /// Not said yet: what an adapter sends. Fizzy answers `shared` or `standalone`.
    unspecified = 0,
    shared = 1,
    standalone = 2,
    _,
};

/// The first message each way. The highest version both support is used; none in common closes
/// with `bye` (`Negotiation`).
pub const Hello = struct {
    version_min: u16 = min_version,
    version_max: u16 = max_version,
    /// The app the peer is: fizzy's bundle id, or the adapter's name.
    app_id: []const u8 = "",
    /// The peer's own version, to show ("update the add-on").
    app_version: []const u8 = "",
    tiers_offered: Tiers = .{},
    tiers_wanted: Tiers = .{},
    /// Feature bits. None are defined yet; a bit both sides set is on.
    features: u64 = 0,
    mode: Mode = .unspecified,
};

pub const CloseReason = enum(u8) {
    normal = 0,
    /// The receiver spoke an older protocol than the sender's oldest: the receiver updates.
    your_side_too_old = 1,
    /// The receiver spoke a newer protocol than the sender's newest: the sender is the old one.
    your_side_too_new = 2,
    protocol_error = 3,
    shutdown = 4,
    _,
};

pub const Bye = struct { reason: CloseReason = .normal, text: []const u8 = "" };

pub const ViewKind = enum(u8) {
    /// The whole editor.
    editor = 0,
    /// A named region of it (`target` is the region's name).
    region = 1,
    /// One document (`target` is its path).
    document = 2,
    _,
};

pub const CreateView = struct {
    view: ViewId,
    kind: ViewKind = .editor,
    target: []const u8 = "",
    /// Physical pixels.
    width: u32,
    height: u32,
    scale: f32 = 1,
    tier: Tier = .draw_list,
    /// Tier 1: the host's native handle (an NSView, a window id), 0 otherwise.
    native_handle: u64 = 0,
};

pub const ViewCreated = struct { view: ViewId, tier: Tier, width: u32, height: u32 };

pub const CloseView = struct { view: ViewId };

pub const ViewClosedReason = enum(u8) {
    /// The host closed it.
    closed = 0,
    /// The editor closed it (the document went away, fizzy is quitting).
    editor_closed = 1,
    /// Creating it failed (`text` says why).
    create_failed = 2,
    unsupported_tier = 3,
    _,
};

pub const ViewClosed = struct { view: ViewId, reason: ViewClosedReason = .closed, text: []const u8 = "" };

pub const Resize = struct {
    view: ViewId,
    /// Physical pixels.
    width: u32,
    height: u32,
    /// The host's backing scale (Retina 2x): sent, never inferred.
    scale: f32 = 1,
    /// Where the view sits in the host's window, when known.
    rect: ?Rect = null,
};

pub const PointerKind = enum(u8) { mouse = 0, touch = 1, pen = 2, _ };

pub const PointerMotion = struct { view: ViewId, x: f32, y: f32, mods: Mods = .{} };

pub const PointerButton = struct {
    view: ViewId,
    /// 0 left, 1 middle, 2 right, 3 and up are extras.
    button: u8,
    pressed: bool,
    x: f32,
    y: f32,
    mods: Mods = .{},
};

pub const Wheel = struct { view: ViewId, dx: f32, dy: f32, mods: Mods = .{} };

pub const TouchPhase = enum(u8) { down = 0, move = 1, up = 2, cancel = 3, _ };

pub const Touch = struct {
    view: ViewId,
    /// Which finger or pen.
    id: u32,
    phase: TouchPhase,
    kind: PointerKind = .touch,
    x: f32,
    y: f32,
    pressure: f32 = 1,
};

pub const Key = struct {
    view: ViewId,
    down: bool,
    repeat: bool = false,
    /// The host's own key code.
    host_code: u32,
    /// A layout-independent code (the physical key), 0 when the host has none.
    code: u32 = 0,
    mods: Mods = .{},
};

pub const TextInput = struct { view: ViewId, text: []const u8 };

/// IME composition: the marked text and its selection (byte offsets into `text`). Empty text
/// ends the composition.
pub const ImeComposition = struct { view: ViewId, text: []const u8, sel_start: u32 = 0, sel_len: u32 = 0 };

pub const Focus = struct { view: ViewId, focused: bool };

pub const ClipboardReply = struct {
    view: ViewId,
    /// The `request` of the `ClipboardRequest` this answers.
    request: u32,
    found: bool = true,
    text: []const u8 = "",
};

pub const CursorShape = enum(u8) {
    arrow = 0,
    ibeam = 1,
    crosshair = 2,
    hand = 3,
    resize_ew = 4,
    resize_ns = 5,
    resize_nwse = 6,
    resize_nesw = 7,
    move = 8,
    wait = 9,
    not_allowed = 10,
    hidden = 11,
    _,
};

pub const Cursor = struct { view: ViewId, shape: CursorShape };

/// Where the caret is, so the host places its IME candidate window.
pub const ImeRect = struct { view: ViewId, rect: Rect };

pub const TextInputActive = struct { view: ViewId, active: bool };

pub const ClipboardOp = enum(u8) { read = 0, write = 1, _ };

/// `read` is answered by a `ClipboardReply` with the same `request`; `write` carries `text` and
/// needs no answer.
pub const ClipboardRequest = struct { view: ViewId, request: u32, op: ClipboardOp, text: []const u8 = "" };

/// Does the view take the chord the host just sent, or does the host keep it?
pub const WantsKeys = struct { view: ViewId, wants: bool };

pub const OpenUrl = struct { view: ViewId, url: []const u8 };

/// A drag leaving the view (plan step 11): its type and bytes.
pub const DragBegin = struct { view: ViewId, mime: []const u8, data: []const u8 };

/// Ask for a frame. `seq` rises with each request of a view, from 1; the answer carries the
/// `seq` of the newest request it answers, and fizzy may skip older ones.
pub const FrameRequest = struct { view: ViewId, seq: u64, deadline_us: u64 = 0 };

pub const Vertex = struct { x: f32, y: f32, u: f32, v: f32, rgba: u32 };

pub const DrawCmd = struct {
    /// 0 draws untextured.
    texture: u32,
    clip: ?Rect = null,
    /// Into `DrawList.indices`, and what to add to each index to reach `DrawList.vertices`.
    index_offset: u32,
    index_count: u32,
    vertex_offset: u32 = 0,
};

pub const DrawList = struct {
    vertices: []const Vertex = &.{},
    indices: []const u32 = &.{},
    cmds: []const DrawCmd = &.{},
};

pub const TextureOp = enum(u8) {
    /// A new texture of width x height; `pixels` is all of it (RGBA8, premultiplied).
    create = 0,
    /// Replace the rect at x, y of width x height.
    update = 1,
    destroy = 2,
    _,
};

pub const TextureUpdate = struct {
    id: u32,
    op: TextureOp,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pixels: []const u8 = "",
};

/// The answer to a `FrameRequest`. Tier 3 carries `textures` and `draw`; tier 2 a `fence` and the
/// texture `slot`; tier 1 only `damage`, since the layer is live.
pub const Frame = struct {
    view: ViewId,
    seq: u64,
    tier: Tier,
    width: u32 = 0,
    height: u32 = 0,
    textures: []const TextureUpdate = &.{},
    draw: DrawList = .{},
    fence: u64 = 0,
    slot: u32 = 0,
    damage: []const Rect = &.{},
};

/// A view changed without being asked (animation, a load): the host redraws and asks.
pub const FrameReady = struct { view: ViewId };

pub const Message = union(Type) {
    hello: Hello,
    bye: Bye,
    create_view: CreateView,
    view_created: ViewCreated,
    close_view: CloseView,
    view_closed: ViewClosed,
    resize: Resize,
    pointer_motion: PointerMotion,
    pointer_button: PointerButton,
    wheel: Wheel,
    touch: Touch,
    key: Key,
    text_input: TextInput,
    ime_composition: ImeComposition,
    focus: Focus,
    clipboard_reply: ClipboardReply,
    cursor: Cursor,
    ime_rect: ImeRect,
    text_input_active: TextInputActive,
    clipboard_request: ClipboardRequest,
    wants_keys: WantsKeys,
    open_url: OpenUrl,
    drag_begin: DragBegin,
    frame_request: FrameRequest,
    frame: Frame,
    frame_ready: FrameReady,

    pub fn tag(m: Message) Type {
        return m;
    }

    /// The view a message is about; null for `hello` and `bye`.
    pub fn view(m: Message) ?ViewId {
        switch (m) {
            inline else => |p| {
                if (@hasField(@TypeOf(p), "view")) return p.view;
                return null;
            },
        }
    }
};

/// What two hellos' version ranges come to.
pub const Negotiation = union(enum) {
    /// The version to speak.
    version: u16,
    /// The peer's newest is older than our oldest: the peer updates.
    peer_too_old,
    /// The peer's oldest is newer than our newest: we update.
    peer_too_new,
};

pub fn negotiate(local: Hello, peer: Hello) Negotiation {
    if (peer.version_max < local.version_min) return .peer_too_old;
    if (peer.version_min > local.version_max) return .peer_too_new;
    return .{ .version = @min(local.version_max, peer.version_max) };
}

pub const Role = enum { host, editor };

/// What to tell the person when `who` has to update: the host's side is an adapter, the editor's
/// side is fizzy.
pub fn updateAdvice(who: Role) []const u8 {
    return switch (who) {
        .host => "update the fizzy add-on in your app",
        .editor => "update fizzy",
    };
}
