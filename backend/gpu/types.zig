//! The plain types of the GPU device interface: handles, formats and the descriptions a `Device`
//! is asked to make things from. Std-only, so it compiles for every target.
//!
//! Each description is the narrowest one fizzy's renderer needs (`README.md` lists the calls
//! behind them); a field is added when a renderer needs it, not because a GPU API has it.
const std = @import("std");

/// Why a device call failed. A caller can act on each: `OutOfMemory` frees something and tries
/// again, `Unsupported` takes another path (a format, a present mode), `Failed` logs and gives
/// the frame up. Detail goes to the log, not the error.
pub const Error = error{ OutOfMemory, Unsupported, Failed };

/// An opaque id a device hands out. Zero is never a live object. The device checks a handle
/// against its own tables, so a stale or foreign one is `Failed` and not a crash.
pub fn Handle(comptime tag: []const u8) type {
    _ = tag;
    return enum(u64) { none = 0, _ };
}

pub const Texture = Handle("texture");
pub const Buffer = Handle("buffer");
pub const TransferBuffer = Handle("transfer_buffer");
pub const Sampler = Handle("sampler");
pub const Shader = Handle("shader");
pub const Pipeline = Handle("pipeline");
pub const Fence = Handle("fence");
pub const CommandBuffer = Handle("command_buffer");
pub const CopyPass = Handle("copy_pass");
pub const RenderPass = Handle("render_pass");

/// A window the device presents into: `winsys.Window.id`. The device maps it to the native
/// surface itself; this package does not import `winsys`, so a device can be built without it.
pub const WindowId = u64;

pub const TextureFormat = enum {
    rgba8_unorm,
    bgra8_unorm,
    /// Precise render targets (`Device.supportsTexture` says whether the device has them).
    rgba16_float,

    pub fn bytesPerTexel(self: TextureFormat) u32 {
        return switch (self) {
            .rgba8_unorm, .bgra8_unorm => 4,
            .rgba16_float => 8,
        };
    }
};

pub const TextureUsage = packed struct(u8) {
    sampler: bool = false,
    color_target: bool = false,
    _: u6 = 0,
};

/// A 2D texture of one level and one layer, single-sampled.
pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    usage: TextureUsage,
};

pub const Filter = enum { nearest, linear };
pub const AddressMode = enum { clamp_to_edge, repeat };

/// Minification and magnification share `filter`; mips are not used.
pub const SamplerDesc = struct {
    filter: Filter,
    address_u: AddressMode,
    address_v: AddressMode,
};

pub const BufferUsage = packed struct(u8) {
    vertex: bool = false,
    index: bool = false,
    _: u6 = 0,
};

pub const BufferDesc = struct {
    usage: BufferUsage,
    size: u32,
};

pub const TransferDirection = enum { upload, download };

/// CPU-visible memory a copy pass moves to or from the GPU.
pub const TransferBufferDesc = struct {
    direction: TransferDirection,
    size: u32,
};

pub const ShaderStage = enum { vertex, fragment };

pub const VertexFormat = enum { float2, ubyte4_norm };

pub const VertexAttribute = struct {
    location: u32,
    format: VertexFormat,
    offset: u32,
};

pub const BlendFactor = enum { zero, one, src_alpha, one_minus_src_alpha, dst_alpha, one_minus_dst_alpha };

/// Colour and alpha are combined by addition: the only operation fizzy's blends use.
pub const BlendState = struct {
    enabled: bool = false,
    src_color: BlendFactor = .one,
    dst_color: BlendFactor = .zero,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .zero,
};

pub const IndexSize = enum { u16, u32 };

pub const LoadOp = enum { load, clear };

pub const PresentMode = enum { vsync, immediate, mailbox };

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Where a transfer buffer's bytes start.
pub const TransferLocation = struct {
    buffer: TransferBuffer,
    offset: u32,
};

/// Rows of `pixels_per_row` texels from `offset`, `rows_per_layer` of them: the layout of a
/// texture region in a transfer buffer, in texels so it needs no format.
pub const TextureTransfer = struct {
    buffer: TransferBuffer,
    offset: u32,
    pixels_per_row: u32,
    rows_per_layer: u32,
};

pub const BufferRegion = struct {
    buffer: Buffer,
    offset: u32,
    size: u32,
};

pub const TextureRegion = struct {
    texture: Texture,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const BufferBinding = struct {
    buffer: Buffer,
    offset: u32,
};

pub const SamplerBinding = struct {
    texture: Texture,
    sampler: Sampler,
};

/// One colour target, stored when the pass ends. There is no depth, stencil or multisampling.
pub const ColorTarget = struct {
    texture: Texture,
    load_op: LoadOp,
    clear_color: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const DrawIndexed = struct {
    index_count: u32,
    first_index: u32 = 0,
    /// Added to each index before it reads a vertex (indices may be 16-bit while a pass's
    /// vertices outgrow 65536).
    vertex_offset: i32 = 0,
    instance_count: u32 = 1,
};

/// A copy of one texture's top-left region into another outside any pass, scaled with nearest
/// filtering when the sizes differ. The destination is cleared to transparent first, so what the
/// source does not cover stays transparent (`presentInto` is the one caller).
pub const Blit = struct {
    source: Texture,
    source_w: u32,
    source_h: u32,
    destination: Texture,
    dest_x: u32,
    dest_y: u32,
    dest_w: u32,
    dest_h: u32,
};

/// A window's drawable for this frame, valid until the command buffer it was acquired on is
/// submitted, which presents it.
pub const Swapchain = struct {
    texture: Texture,
    width: u32,
    height: u32,
};
