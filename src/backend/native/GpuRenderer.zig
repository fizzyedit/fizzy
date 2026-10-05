//! The drawing half of fizzy's native backend (`SDLBackend.zig`): dvui's triangles, textures and
//! render targets on SDL_GPU (Metal, Vulkan, D3D12), plus fragment programs of fizzy's own
//! (`SDLBackend.program_api`).
//!
//! Rebuilt from dvui's `sdl3gpu` backend, whose shaders it uses, with what that backend gets
//! wrong for fizzy put right:
//!
//! * **Passes.** Draws are recorded per destination and encoded as one render pass when the
//!   destination changes (`renderTarget`), something must see them (a read, an update or
//!   destroy of a texture they use), or the frame ends. A target keeps what was drawn into it
//!   (its pass loads); it is cleared only when created or asked (`textureClearTarget`), by the
//!   load of its next pass — or a pass of its own when something samples it first. Switching
//!   back to the window never drops its waiting draws.
//! * **The window's drawable is acquired late**: by the window's first pass, which with fizzy's
//!   `FrameTarget` is the frame's last — the CPU does not wait on the GPU for a drawable
//!   before the frame is built. Nothing is drawn when there is none (minimized, occluded).
//!   That pass clears the drawable (a fresh one holds nothing worth loading) and maps the
//!   frame by the drawable's own size.
//! * **Vertices.** Each draw keeps its own indices and a `vertex_offset` (`u16` indices
//!   overflow when one buffer holds a whole pass), and consecutive draws merge only while the
//!   offsets still fit. A pass's vertices and indices go up in one copy into a buffer that
//!   grows without losing anything already pushed: they wait on the CPU until the pass is
//!   encoded.
//! * **Uploads** (texture creation and updates, vertices) are written into transfer buffers
//!   cycled per command buffer and recorded on the frame's own command buffer, in order with
//!   its passes — never a fence wait.
//! * **Blends** (`textureBlend`, and a program's) are taken per draw when it is recorded, so
//!   a blend reset before the draws are encoded does not reach back. Each is its own
//!   pipeline: over, add, copy, and `punch` (`dst · (1 − a)`).
//! * **Scissors** are clamped to the destination; a draw clipped to nothing is dropped.
//! * **Precise targets** (`precision = .high`) are 16-bit float.
//! * **Reads** (`readPixels`, `textureReadTarget`) download through a fence: a sync, as on any
//!   backend.
//! * **Viewports.** More windows can be claimed on the device (`claimViewport`), each handed
//!   its part of the frame from a target, copied into its drawable on the frame's own command
//!   buffer (`presentInto`): one frame, one submission, whatever the number of windows.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = @import("sdl3-c");

const GpuRenderer = @This();
const log = std.log.scoped(.GpuRenderer);

const Index = dvui.Vertex.Index;
const index_element_size = if (Index == u32) c.SDL_GPU_INDEXELEMENTSIZE_32BIT else c.SDL_GPU_INDEXELEMENTSIZE_16BIT;

/// The most uniform vec4s a program may take (`program_api.uniform_cap`), as on the web.
pub const uniform_cap = 64;

/// dvui's own shaders (`src/backends/sdl3gpu`), compiled by shadercross: a vertex shader that
/// passes position, colour and uv through, and a fragment shader that multiplies the texture
/// by the colour. Programs reuse the vertex shader.
const shaders = struct {
    const spv_vertex align(8) = @embedFile("shaders/compiled/spv/default.vertex.spv").*;
    const spv_fragment align(8) = @embedFile("shaders/compiled/spv/default.fragment.spv").*;
    const msl_vertex align(8) = @embedFile("shaders/compiled/msl/default.vertex.msl").*;
    const msl_fragment align(8) = @embedFile("shaders/compiled/msl/default.fragment.msl").*;
    const dxil_vertex align(8) = @embedFile("shaders/compiled/dxil/default.vertex.dxil").*;
    const dxil_fragment align(8) = @embedFile("shaders/compiled/dxil/default.fragment.dxil").*;
};

/// How a draw lands on what is there (`dvui.Backend.TextureBlend`, plus `punch` for programs —
/// `core.gfx.programs.Blend`, whose numbering this follows).
pub const Blend = enum(u2) {
    /// Premultiplied source-over.
    over = 0,
    add = 1,
    /// Writes colour and alpha.
    copy = 2,
    /// `dst · (1 − src.a)`, colour and alpha: clears what is there by the source's coverage.
    punch = 3,
};

/// A vertex as the GPU takes it. Recorded in the destination's pixels and mapped to clip space
/// when its pass is encoded (by the drawable's size, for the window). The vertex shader reads
/// `float4` position and colour: the two-component position is widened to (x, y, 0, 1) and the
/// colour bytes normalized by the input assembler.
const Vertex = extern struct {
    x: f32,
    y: f32,
    col: [4]u8,
    u: f32,
    v: f32,
};

/// A texture or render target: what `dvui.Texture.ptr` points to.
pub const Tex = struct {
    texture: *c.SDL_GPUTexture,
    format: c.SDL_GPUTextureFormat,
    width: u32,
    height: u32,
    sampler: *c.SDL_GPUSampler,
    blend: Blend = .over,
    target: bool = false,
    /// Owes a clear, made by the load of its next pass (or a pass of its own before anything
    /// samples or reads it).
    needs_clear: bool = false,
    /// The pending pass (`pass_serial`) that last drew from or into it, so whatever must not
    /// overtake those draws — an update, a clear, a destroy — encodes them first.
    used_in: u64 = 0,
};

const Draw = struct {
    first_index: u32,
    index_count: u32,
    vertex_offset: u32,
    tex: *Tex,
    clip: ?c.SDL_Rect,
    blend: Blend,
    /// 0: dvui's own fragment shader; else a `programs` id.
    program: u32 = 0,
    extra: [2]*Tex,
    /// Offset of the program's uniforms in `uniforms`.
    uniforms: u32 = 0,
};

const Program = struct {
    shader: ?*c.SDL_GPUShader,
    textures: u32,
    uniform_vec4s: u32,
};

const Active = struct {
    id: u32,
    extra: [2]*Tex,
    data: [uniform_cap][4]f32,
    /// Where `data` sits in this pass's `uniforms`; appended by the first draw after `begin`
    /// or after a flush.
    at: ?u32 = null,
};

const PipelineKey = struct {
    program: u32,
    format: c.SDL_GPUTextureFormat,
    blend: Blend,
};

pub const NativeSource = struct {
    msl: []const u8,
    spirv: []const u8,
    dxil: []const u8,
};

pub const Options = struct {
    vsync: bool = true,
    /// Drive this window with another renderer's device (secondary OS windows).
    share_device_of: ?*GpuRenderer = null,
};

gpa: std.mem.Allocator,
device: *c.SDL_GPUDevice,
owns_device: bool,
window: *c.SDL_Window,
vsync: bool = true,

shader_format: c.SDL_GPUShaderFormat,
swapchain_format: c.SDL_GPUTextureFormat,
/// The float format of precise targets, where the device can render to and sample it.
precise_format: ?c.SDL_GPUTextureFormat,
vertex_shader: *c.SDL_GPUShader,
fragment_shader: *c.SDL_GPUShader,
/// [filter (0 nearest, 1 linear)][wrap u (0 clamp, 1 repeat)][wrap v]
samplers: [2][2][2]*c.SDL_GPUSampler,
pipelines: std.AutoHashMapUnmanaged(PipelineKey, *c.SDL_GPUGraphicsPipeline) = .empty,
programs: std.ArrayList(Program) = .empty,

/// Texture records, reused through the pool's free list.
tex_pool: std.heap.MemoryPool(Tex),
/// 1×1 white: what an untextured draw samples.
white: *Tex = undefined,

/// The command buffer being recorded: the frame's, or one that took uploads between frames.
cmd: ?*c.SDL_GPUCommandBuffer = null,
/// Bumped for every command buffer, so the rings cycle their buffers once per command buffer.
epoch: u64 = 0,
copy_pass: ?*c.SDL_GPUCopyPass = null,

swapchain: ?*c.SDL_GPUTexture = null,
swapchain_w: u32 = 0,
swapchain_h: u32 = 0,
swapchain_state: enum { none, acquired, unavailable } = .none,
/// Whether this frame's drawable has been cleared (by the window's first pass).
window_cleared: bool = false,

/// Where draws go: a render target, or null for the window.
target: ?*Tex = null,
/// The pass being recorded; bumped each time one is encoded.
pass_serial: u64 = 1,
verts: std.ArrayList(Vertex) = .empty,
indices: std.ArrayList(Index) = .empty,
draws: std.ArrayList(Draw) = .empty,
uniforms: std.ArrayList([4]f32) = .empty,

active: ?Active = null,
blend_override: ?Blend = null,

/// Texture uploads.
upload_ring: TransferRing = .{ .min_cap = 4 << 20 },
/// Vertex and index uploads: staged here, copied into `stream_buffer`.
stream_ring: TransferRing = .{ .min_cap = 1 << 20 },
stream_buffer: BufferRing = .{ .min_cap = 1 << 20 },

/// The renderers alive, by window (`forWindow`); the first is the primary.
var registry: [8]?*GpuRenderer = @splat(null);

pub fn forWindow(window: *c.SDL_Window) ?*GpuRenderer {
    for (registry) |slot| if (slot) |r| if (r.window == window) return r;
    return null;
}

pub fn primary() ?*GpuRenderer {
    for (registry) |slot| if (slot) |r| return r;
    return null;
}

/// A device for `window`'s renderer, with the validation layers (where the driver has them) in Debug
/// builds. On Windows a transparent window asks for D3D12: SDL tries Vulkan first, and a Vulkan
/// swapchain there is opaque, where D3D12's is composited with its alpha (DirectComposition). Without
/// D3D12 the window takes whatever SDL picks, and is opaque.
fn createDevice(window: *c.SDL_Window) ?*c.SDL_GPUDevice {
    const formats = c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL | c.SDL_GPU_SHADERFORMAT_MSL;
    const debug = builtin.mode == .Debug;
    if (builtin.os.tag == .windows and c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_TRANSPARENT != 0) {
        if (c.SDL_CreateGPUDevice(formats, debug, "direct3d12")) |device| return device;
        log.warn("no D3D12 device ({s}); the transparent window will be opaque", .{c.SDL_GetError()});
    }
    return c.SDL_CreateGPUDevice(formats, debug, null);
}

pub fn create(gpa: std.mem.Allocator, window: *c.SDL_Window, options: Options) !*GpuRenderer {
    const self = try gpa.create(GpuRenderer);
    errdefer gpa.destroy(self);

    const device: *c.SDL_GPUDevice = if (options.share_device_of) |other| other.device else createDevice(window) orelse {
        log.err("SDL_CreateGPUDevice failed: {s}", .{c.SDL_GetError()});
        return error.GpuDevice;
    };
    const owns_device = options.share_device_of == null;
    errdefer if (owns_device) c.SDL_DestroyGPUDevice(device);
    if (c.SDL_GetGPUDeviceDriver(device)) |name| log.info("GPU driver: {s}", .{name});

    // A transparent window is claimed as one where the driver composites the swapchain's alpha
    // (Metal, Vulkan, D3D12 through DirectComposition): fizzyedit/SDL leaves that to each driver
    // (docs/DEPENDENCIES.md).
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
        log.err("SDL_ClaimWindowForGPUDevice failed: {s}", .{c.SDL_GetError()});
        return error.GpuClaimWindow;
    }
    errdefer c.SDL_ReleaseWindowFromGPUDevice(device, window);
    prepareLayer(window);

    const formats = c.SDL_GetGPUShaderFormats(device);
    const shader_format: c.SDL_GPUShaderFormat = if (formats & c.SDL_GPU_SHADERFORMAT_MSL != 0)
        c.SDL_GPU_SHADERFORMAT_MSL
    else if (formats & c.SDL_GPU_SHADERFORMAT_SPIRV != 0)
        c.SDL_GPU_SHADERFORMAT_SPIRV
    else if (formats & c.SDL_GPU_SHADERFORMAT_DXIL != 0)
        c.SDL_GPU_SHADERFORMAT_DXIL
    else {
        log.err("no supported shader format (have 0x{x})", .{formats});
        return error.GpuShaderFormat;
    };

    const precise: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
    const precise_ok = c.SDL_GPUTextureSupportsFormat(device, precise, c.SDL_GPU_TEXTURETYPE_2D, c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET);

    self.* = .{
        .gpa = gpa,
        .device = device,
        .owns_device = owns_device,
        .window = window,
        .shader_format = shader_format,
        .swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, window),
        .precise_format = if (precise_ok) precise else null,
        .vertex_shader = undefined,
        .fragment_shader = undefined,
        .samplers = undefined,
        .tex_pool = .empty,
    };

    const vs_code: []const u8, const fs_code: []const u8 = switch (shader_format) {
        c.SDL_GPU_SHADERFORMAT_MSL => .{ &shaders.msl_vertex, &shaders.msl_fragment },
        c.SDL_GPU_SHADERFORMAT_SPIRV => .{ &shaders.spv_vertex, &shaders.spv_fragment },
        else => .{ &shaders.dxil_vertex, &shaders.dxil_fragment },
    };
    self.vertex_shader = self.makeShader(vs_code, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 0) orelse return error.GpuShader;
    errdefer c.SDL_ReleaseGPUShader(device, self.vertex_shader);
    self.fragment_shader = self.makeShader(fs_code, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 1, 0) orelse return error.GpuShader;
    errdefer c.SDL_ReleaseGPUShader(device, self.fragment_shader);

    for (0..2) |f| for (0..2) |u| for (0..2) |v| {
        const wrap = [2]c.SDL_GPUSamplerAddressMode{ c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE, c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT };
        const filter: c.SDL_GPUFilter = if (f == 1) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST;
        var info = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
        info.min_filter = filter;
        info.mag_filter = filter;
        info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
        info.address_mode_u = wrap[u];
        info.address_mode_v = wrap[v];
        info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        info.max_lod = 1000;
        self.samplers[f][u][v] = c.SDL_CreateGPUSampler(device, &info) orelse {
            log.err("SDL_CreateGPUSampler failed: {s}", .{c.SDL_GetError()});
            return error.GpuSampler;
        };
    };

    if (!options.vsync) self.setVSync(false);

    const white = try self.textureCreate(&[4]u8{ 255, 255, 255, 255 }, .{ .width = 1, .height = 1 });
    self.white = @ptrCast(@alignCast(white.ptr));

    for (&registry) |*slot| if (slot.* == null) {
        slot.* = self;
        break;
    };
    return self;
}

pub fn destroy(self: *GpuRenderer) void {
    for (&registry) |*slot| if (slot.* == self) {
        slot.* = null;
    };
    // Whatever is still recorded is dropped (nothing will present it), what was submitted is
    // waited out.
    self.resetPass();
    self.target = null;
    _ = self.submit(false);
    _ = c.SDL_WaitForGPUIdle(self.device);

    c.SDL_ReleaseGPUTexture(self.device, self.white.texture);
    var it = self.pipelines.valueIterator();
    while (it.next()) |p| c.SDL_ReleaseGPUGraphicsPipeline(self.device, p.*);
    self.pipelines.deinit(self.gpa);
    for (self.programs.items) |p| if (p.shader) |s| c.SDL_ReleaseGPUShader(self.device, s);
    self.programs.deinit(self.gpa);
    for (self.samplers) |a| for (a) |b| for (b) |s| c.SDL_ReleaseGPUSampler(self.device, s);
    c.SDL_ReleaseGPUShader(self.device, self.vertex_shader);
    c.SDL_ReleaseGPUShader(self.device, self.fragment_shader);
    self.upload_ring.deinit(self.device);
    self.stream_ring.deinit(self.device);
    self.stream_buffer.deinit(self.device);
    self.verts.deinit(self.gpa);
    self.indices.deinit(self.gpa);
    self.draws.deinit(self.gpa);
    self.uniforms.deinit(self.gpa);
    self.tex_pool.deinit(self.gpa);

    c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
    if (self.owns_device) c.SDL_DestroyGPUDevice(self.device);
    self.gpa.destroy(self);
}

/// The swapchain's CAMetalLayer as SDL's Metal renderer, the old backend, kept it: untagged
/// (SDL_GPU tags it sRGB, on claim and on every swapchain-parameter change). See
/// `macos_monitor.m`.
fn prepareLayer(window: *c.SDL_Window) void {
    if (builtin.os.tag != .macos) return;
    const nswindow = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return;
    fizzy_native_metal_layer_prepare(nswindow);
}
extern "c" fn fizzy_native_metal_layer_prepare(nswindow: *anyopaque) void;

/// Present with or without waiting for the display, from now on.
pub fn setVSync(self: *GpuRenderer, on: bool) void {
    const mode: c.SDL_GPUPresentMode = if (on)
        c.SDL_GPU_PRESENTMODE_VSYNC
    else if (c.SDL_WindowSupportsGPUPresentMode(self.device, self.window, c.SDL_GPU_PRESENTMODE_IMMEDIATE))
        c.SDL_GPU_PRESENTMODE_IMMEDIATE
    else if (c.SDL_WindowSupportsGPUPresentMode(self.device, self.window, c.SDL_GPU_PRESENTMODE_MAILBOX))
        c.SDL_GPU_PRESENTMODE_MAILBOX
    else
        c.SDL_GPU_PRESENTMODE_VSYNC;
    if (!c.SDL_SetGPUSwapchainParameters(self.device, self.window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, mode)) {
        log.err("SDL_SetGPUSwapchainParameters failed: {s}", .{c.SDL_GetError()});
        return;
    }
    prepareLayer(self.window);
    self.vsync = on;
}

fn makeShader(self: *GpuRenderer, code: []const u8, stage: c.SDL_GPUShaderStage, samplers: u32, uniform_buffers: u32) ?*c.SDL_GPUShader {
    var info = std.mem.zeroes(c.SDL_GPUShaderCreateInfo);
    info.code = code.ptr;
    info.code_size = code.len;
    info.entrypoint = if (self.shader_format == c.SDL_GPU_SHADERFORMAT_MSL) "main0" else "main";
    info.format = self.shader_format;
    info.stage = stage;
    info.num_samplers = samplers;
    info.num_uniform_buffers = uniform_buffers;
    return c.SDL_CreateGPUShader(self.device, &info) orelse {
        log.err("SDL_CreateGPUShader failed: {s}", .{c.SDL_GetError()});
        return null;
    };
}

fn pipeline(self: *GpuRenderer, program: u32, format: c.SDL_GPUTextureFormat, blend: Blend) ?*c.SDL_GPUGraphicsPipeline {
    const key: PipelineKey = .{ .program = program, .format = format, .blend = blend };
    if (self.pipelines.get(key)) |p| return p;

    const fragment = if (program == 0) self.fragment_shader else (self.programs.items[program - 1].shader orelse return null);

    var target = std.mem.zeroes(c.SDL_GPUColorTargetDescription);
    target.format = format;
    target.blend_state.color_blend_op = c.SDL_GPU_BLENDOP_ADD;
    target.blend_state.alpha_blend_op = c.SDL_GPU_BLENDOP_ADD;
    switch (blend) {
        .over, .add, .punch => {
            const src: c.SDL_GPUBlendFactor = if (blend == .punch) c.SDL_GPU_BLENDFACTOR_ZERO else c.SDL_GPU_BLENDFACTOR_ONE;
            const dst: c.SDL_GPUBlendFactor = if (blend == .add) c.SDL_GPU_BLENDFACTOR_ONE else c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
            target.blend_state.enable_blend = true;
            target.blend_state.src_color_blendfactor = src;
            target.blend_state.src_alpha_blendfactor = src;
            target.blend_state.dst_color_blendfactor = dst;
            target.blend_state.dst_alpha_blendfactor = dst;
        },
        .copy => target.blend_state.enable_blend = false,
    }

    const attributes = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = @offsetOf(Vertex, "col") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "u") },
    };
    const buffer_desc = c.SDL_GPUVertexBufferDescription{
        .slot = 0,
        .pitch = @sizeOf(Vertex),
        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
        .instance_step_rate = 0,
    };

    var info = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
    info.vertex_shader = self.vertex_shader;
    info.fragment_shader = fragment;
    info.vertex_input_state.vertex_buffer_descriptions = &buffer_desc;
    info.vertex_input_state.num_vertex_buffers = 1;
    info.vertex_input_state.vertex_attributes = &attributes;
    info.vertex_input_state.num_vertex_attributes = attributes.len;
    info.primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    info.rasterizer_state.fill_mode = c.SDL_GPU_FILLMODE_FILL;
    info.rasterizer_state.cull_mode = c.SDL_GPU_CULLMODE_NONE;
    info.target_info.color_target_descriptions = &target;
    info.target_info.num_color_targets = 1;

    const p = c.SDL_CreateGPUGraphicsPipeline(self.device, &info) orelse {
        log.err("SDL_CreateGPUGraphicsPipeline failed: {s}", .{c.SDL_GetError()});
        return null;
    };
    self.pipelines.put(self.gpa, key, p) catch {
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, p);
        return null;
    };
    return p;
}

// ---------------------------------------------------------------------------------------------
// Command buffers

fn ensureCmd(self: *GpuRenderer) !*c.SDL_GPUCommandBuffer {
    if (self.cmd) |cmd| return cmd;
    const cmd = c.SDL_AcquireGPUCommandBuffer(self.device) orelse {
        log.err("SDL_AcquireGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
        return error.GpuCommandBuffer;
    };
    self.cmd = cmd;
    self.epoch += 1;
    return cmd;
}

fn beginCopy(self: *GpuRenderer) !*c.SDL_GPUCopyPass {
    if (self.copy_pass) |p| return p;
    const cmd = try self.ensureCmd();
    const p = c.SDL_BeginGPUCopyPass(cmd) orelse {
        log.err("SDL_BeginGPUCopyPass failed: {s}", .{c.SDL_GetError()});
        return error.GpuCopyPass;
    };
    self.copy_pass = p;
    return p;
}

fn endCopy(self: *GpuRenderer) void {
    if (self.copy_pass) |p| c.SDL_EndGPUCopyPass(p);
    self.copy_pass = null;
}

/// Submit what is recorded. A drawable acquired on it is presented with it.
fn submit(self: *GpuRenderer, want_fence: bool) ?*c.SDL_GPUFence {
    self.endCopy();
    const cmd = self.cmd orelse return null;
    self.cmd = null;
    self.swapchain = null;
    self.swapchain_state = .none;
    if (want_fence) {
        return c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse {
            log.err("SDL_SubmitGPUCommandBufferAndAcquireFence failed: {s}", .{c.SDL_GetError()});
            return null;
        };
    }
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) log.err("SDL_SubmitGPUCommandBuffer failed: {s}", .{c.SDL_GetError()});
    return null;
}

/// Submit and wait for the GPU to finish it.
fn submitAndWait(self: *GpuRenderer) !void {
    const fence = self.submit(true) orelse return error.GpuSubmit;
    defer c.SDL_ReleaseGPUFence(self.device, fence);
    if (!c.SDL_WaitForGPUFences(self.device, true, &fence, 1)) return error.GpuFence;
}

// ---------------------------------------------------------------------------------------------
// Frames

pub fn beginFrame(self: *GpuRenderer) void {
    // Anything a frame that never presented left behind is dropped, not drawn into this one.
    self.resetPass();
    self.target = null;
    self.window_cleared = false;
    self.active = null;
    self.blend_override = null;
}

/// End the frame: encode what waits and submit, presenting the window. A frame that drew
/// nothing to the window presents a cleared one when `clear_if_empty`, else leaves the last.
pub fn present(self: *GpuRenderer, clear_if_empty: bool) void {
    self.flush() catch |err| log.err("present: {any}", .{err});
    if (!self.window_cleared and clear_if_empty and self.swapchain_state == .none) {
        self.target = null;
        self.windowPass() catch |err| log.err("present clear: {any}", .{err});
    }
    _ = self.submit(false);
    self.target = null;
    self.window_cleared = false;
}

fn acquireSwapchain(self: *GpuRenderer) !bool {
    switch (self.swapchain_state) {
        .acquired => return true,
        .unavailable => return false,
        .none => {},
    }
    const cmd = try self.ensureCmd();
    var tex: ?*c.SDL_GPUTexture = null;
    var w: u32 = 0;
    var h: u32 = 0;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, self.window, &tex, &w, &h)) {
        log.err("SDL_WaitAndAcquireGPUSwapchainTexture failed: {s}", .{c.SDL_GetError()});
        self.swapchain_state = .unavailable;
        return false;
    }
    // None while minimized or occluded: nothing is drawn this frame.
    if (tex == null or w == 0 or h == 0) {
        self.swapchain_state = .unavailable;
        return false;
    }
    self.swapchain = tex;
    self.swapchain_w = w;
    self.swapchain_h = h;
    self.swapchain_state = .acquired;
    return true;
}

// ---------------------------------------------------------------------------------------------
// Viewports: more windows on this renderer's device and command buffer

/// Claim `window` on this renderer's device, to present into alongside the main window (a
/// viewport, `SDLBackend.Viewport`): one renderer, one command buffer and one submission for
/// every window, so every texture and program is valid in all of them.
///
/// macOS: its swapchain waits for the display, as the main window's does. Presented without
/// display sync, a second window's pictures reached the window server at any moment, and the main
/// window's next drawable came that much later and unevenly — up to 20 ms on a ProMotion display,
/// a third of frames at 12–13 ms with a float window up; with both synced, none (measured with
/// the user's session: 30–95 frames over 10 ms in every 2 s, then 0–8). The wait moves into the
/// viewport's acquire, and the frame is paced once.
/// Elsewhere it does not wait — IMMEDIATE where the device has it, else MAILBOX — so a second
/// window never holds the main one's frame back; not yet measured there.
pub fn claimViewport(self: *GpuRenderer, window: *c.SDL_Window) !void {
    if (!c.SDL_ClaimWindowForGPUDevice(self.device, window)) {
        log.err("SDL_ClaimWindowForGPUDevice (viewport) failed: {s}", .{c.SDL_GetError()});
        return error.GpuClaimWindow;
    }
    const mode: c.SDL_GPUPresentMode = if (builtin.os.tag == .macos)
        c.SDL_GPU_PRESENTMODE_VSYNC
    else if (c.SDL_WindowSupportsGPUPresentMode(self.device, window, c.SDL_GPU_PRESENTMODE_IMMEDIATE))
        c.SDL_GPU_PRESENTMODE_IMMEDIATE
    else if (c.SDL_WindowSupportsGPUPresentMode(self.device, window, c.SDL_GPU_PRESENTMODE_MAILBOX))
        c.SDL_GPU_PRESENTMODE_MAILBOX
    else
        c.SDL_GPU_PRESENTMODE_VSYNC;
    if (!c.SDL_SetGPUSwapchainParameters(self.device, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, mode)) {
        log.err("SDL_SetGPUSwapchainParameters (viewport) failed: {s}", .{c.SDL_GetError()});
    }
    prepareLayer(window);
}

/// Give `window` back. SDL waits out what is still in flight to it.
pub fn releaseViewport(self: *GpuRenderer, window: *c.SDL_Window) void {
    c.SDL_ReleaseWindowFromGPUDevice(self.device, window);
}

/// Copy `target` into `window`'s next drawable — a viewport's part of the frame, drawn there
/// already — presented with this frame's submission (`present`). Transparent wherever the target
/// is. Never waits: a drawable not ready (minimized, occluded, or its last frame still in flight)
/// skips this frame for that window. True when there was one.
pub fn presentInto(self: *GpuRenderer, window: *c.SDL_Window, target: dvui.TextureTarget) bool {
    const tex: *Tex = @ptrCast(@alignCast(target.ptr));
    const cmd = self.ensureCmd() catch return false;
    self.endCopy();
    // A target nothing drew into still owes its clear.
    if (tex.needs_clear) self.clearPass(tex) catch return false;
    var swap: ?*c.SDL_GPUTexture = null;
    var w: u32 = 0;
    var h: u32 = 0;
    if (!c.SDL_AcquireGPUSwapchainTexture(cmd, window, &swap, &w, &h)) {
        log.err("SDL_AcquireGPUSwapchainTexture (viewport) failed: {s}", .{c.SDL_GetError()});
        return false;
    }
    const dest = swap orelse return false;
    // The window and its part of the frame are the same size but for a resize in flight; the
    // overlap is copied as it is, never scaled.
    const bw = @min(w, tex.width);
    const bh = @min(h, tex.height);
    if (bw == 0 or bh == 0) return false;
    var info = std.mem.zeroes(c.SDL_GPUBlitInfo);
    info.source.texture = tex.texture;
    info.source.w = bw;
    info.source.h = bh;
    info.destination.texture = dest;
    info.destination.w = bw;
    info.destination.h = bh;
    info.load_op = c.SDL_GPU_LOADOP_CLEAR;
    info.clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    info.filter = c.SDL_GPU_FILTER_NEAREST;
    c.SDL_BlitGPUTexture(cmd, &info);
    return true;
}

// ---------------------------------------------------------------------------------------------
// Recording

pub fn draw(self: *GpuRenderer, texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const Index, maybe_clipr: ?dvui.Rect.Physical) !void {
    if (idx.len == 0 or vtx.len == 0) return;
    const tex: *Tex = if (texture) |t| @ptrCast(@alignCast(t.ptr)) else self.white;

    var clip: ?c.SDL_Rect = null;
    if (maybe_clipr) |r| {
        const rect: c.SDL_Rect = .{ .x = @trunc(r.x), .y = @trunc(r.y), .w = @trunc(r.w), .h = @trunc(r.h) };
        if (rect.w <= 0 or rect.h <= 0) return;
        if (self.target) |t| {
            // Clipped to nothing on this target: dropped here. The window's size is known only
            // when its pass is encoded (`flush` clamps again).
            if (rect.x >= @as(c_int, @intCast(t.width)) or rect.y >= @as(c_int, @intCast(t.height)) or rect.x + rect.w <= 0 or rect.y + rect.h <= 0) return;
        }
        clip = rect;
    }

    const blend: Blend = self.blend_override orelse (if (texture != null) tex.blend else .over);
    var program: u32 = 0;
    var extra: [2]*Tex = .{ self.white, self.white };
    var uniforms_at: u32 = 0;
    if (self.active) |*a| {
        program = a.id;
        extra = a.extra;
        const n = self.programs.items[a.id - 1].uniform_vec4s;
        if (n > 0) {
            if (a.at == null) {
                a.at = @intCast(self.uniforms.items.len);
                try self.uniforms.appendSlice(self.gpa, a.data[0..n]);
            }
            uniforms_at = a.at.?;
        }
    }

    const base: u32 = @intCast(self.verts.items.len);
    try self.verts.ensureUnusedCapacity(self.gpa, vtx.len);
    for (vtx) |v| self.verts.appendAssumeCapacity(.{
        .x = v.pos.x,
        .y = v.pos.y,
        .col = .{ v.col.r, v.col.g, v.col.b, v.col.a },
        .u = v.uv[0],
        .v = v.uv[1],
    });

    try self.indices.ensureUnusedCapacity(self.gpa, idx.len);
    const first: u32 = @intCast(self.indices.items.len);

    // Merge with the draw before when nothing differs and its vertex offset still reaches
    // these vertices through the index type.
    if (self.draws.items.len > 0) {
        const prev = &self.draws.items[self.draws.items.len - 1];
        const delta = base - prev.vertex_offset;
        if (prev.tex == tex and prev.blend == blend and prev.program == program and
            prev.extra[0] == extra[0] and prev.extra[1] == extra[1] and prev.uniforms == uniforms_at and
            clipEql(prev.clip, clip) and
            @as(u64, delta) + vtx.len - 1 <= std.math.maxInt(Index) and
            prev.first_index + prev.index_count == first)
        {
            for (idx) |i| self.indices.appendAssumeCapacity(@intCast(@as(u32, i) + delta));
            prev.index_count += @intCast(idx.len);
            self.markUsed(tex, extra);
            return;
        }
    }

    self.indices.appendSliceAssumeCapacity(idx);
    try self.draws.append(self.gpa, .{
        .first_index = first,
        .index_count = @intCast(idx.len),
        .vertex_offset = base,
        .tex = tex,
        .clip = clip,
        .blend = blend,
        .program = program,
        .extra = extra,
        .uniforms = uniforms_at,
    });
    self.markUsed(tex, extra);
}

fn markUsed(self: *GpuRenderer, tex: *Tex, extra: [2]*Tex) void {
    tex.used_in = self.pass_serial;
    extra[0].used_in = self.pass_serial;
    extra[1].used_in = self.pass_serial;
    if (self.target) |t| t.used_in = self.pass_serial;
}

fn clipEql(a: ?c.SDL_Rect, b: ?c.SDL_Rect) bool {
    if (a == null and b == null) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return x.x == y.x and x.y == y.y and x.w == y.w and x.h == y.h;
}

pub fn renderTarget(self: *GpuRenderer, texture: ?dvui.TextureTarget) !void {
    const next: ?*Tex = if (texture) |t| @ptrCast(@alignCast(t.ptr)) else null;
    if (next == self.target) return;
    try self.flush();
    self.target = next;
}

fn resetPass(self: *GpuRenderer) void {
    self.verts.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();
    self.draws.clearRetainingCapacity();
    self.uniforms.clearRetainingCapacity();
    self.pass_serial += 1;
    if (self.active) |*a| a.at = null;
}

/// Encode the pending pass: what was recorded for the current destination, or only its
/// owed clear.
fn flush(self: *GpuRenderer) !void {
    defer self.resetPass();
    if (self.target) |t| {
        if (self.draws.items.len == 0 and !t.needs_clear) return;
    } else if (self.draws.items.len == 0) return;

    if (self.target) |t| {
        try self.encodePass(t.texture, t.width, t.height, t.format, if (t.needs_clear) c.SDL_GPU_LOADOP_CLEAR else c.SDL_GPU_LOADOP_LOAD);
        t.needs_clear = false;
    } else try self.windowPass();
}

fn windowPass(self: *GpuRenderer) !void {
    // Textures sampled by these draws that still owe their clear get it first: its own pass,
    // before the drawable is waited for.
    try self.clearSampled();
    if (!try self.acquireSwapchain()) return;
    const load: c.SDL_GPULoadOp = if (self.window_cleared) c.SDL_GPU_LOADOP_LOAD else c.SDL_GPU_LOADOP_CLEAR;
    self.window_cleared = true;
    try self.encodePass(self.swapchain.?, self.swapchain_w, self.swapchain_h, self.swapchain_format, load);
}

fn clearSampled(self: *GpuRenderer) !void {
    for (self.draws.items) |d| {
        for ([3]*Tex{ d.tex, d.extra[0], d.extra[1] }) |s| {
            if (s.needs_clear and s != self.target) try self.clearPass(s);
        }
    }
}

/// A pass that only clears `tex`.
fn clearPass(self: *GpuRenderer, tex: *Tex) !void {
    self.endCopy();
    const cmd = try self.ensureCmd();
    var ct = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
    ct.texture = tex.texture;
    ct.load_op = c.SDL_GPU_LOADOP_CLEAR;
    ct.store_op = c.SDL_GPU_STOREOP_STORE;
    const pass = c.SDL_BeginGPURenderPass(cmd, &ct, 1, null) orelse {
        log.err("SDL_BeginGPURenderPass (clear) failed: {s}", .{c.SDL_GetError()});
        return error.GpuRenderPass;
    };
    c.SDL_EndGPURenderPass(pass);
    tex.needs_clear = false;
}

fn encodePass(self: *GpuRenderer, dest: *c.SDL_GPUTexture, dw: u32, dh: u32, format: c.SDL_GPUTextureFormat, load: c.SDL_GPULoadOp) !void {
    if (self.target != null) try self.clearSampled();
    // Before the rings are asked for room: they cycle per command buffer (`epoch`).
    const cmd = try self.ensureCmd();

    // Vertices (mapped to clip space by this destination's size) and indices, in one copy.
    var vbind: c.SDL_GPUBufferBinding = undefined;
    var ibind: c.SDL_GPUBufferBinding = undefined;
    if (self.draws.items.len > 0) {
        const vbytes: u32 = @intCast(self.verts.items.len * @sizeOf(Vertex));
        const ioff: u32 = std.mem.alignForward(u32, vbytes, 16);
        const total: u32 = ioff + @as(u32, @intCast(self.indices.items.len * @sizeOf(Index)));

        const staged = try self.stream_ring.reserve(self.device, self.epoch, total, 16);
        const out: [*]Vertex = @ptrCast(@alignCast(staged.ptr));
        const sx = 2.0 / @as(f32, @floatFromInt(dw));
        const sy = 2.0 / @as(f32, @floatFromInt(dh));
        for (self.verts.items, 0..) |v, i| {
            out[i] = .{ .x = v.x * sx - 1.0, .y = 1.0 - v.y * sy, .col = v.col, .u = v.u, .v = v.v };
        }
        @memcpy(staged.ptr[ioff..total], std.mem.sliceAsBytes(self.indices.items));
        self.stream_ring.unmap(self.device);

        const dst = try self.stream_buffer.reserve(self.device, self.epoch, total, 16);
        const copy = try self.beginCopy();
        c.SDL_UploadToGPUBuffer(
            copy,
            &.{ .transfer_buffer = staged.tb, .offset = staged.offset },
            &.{ .buffer = dst.buf, .offset = dst.offset, .size = total },
            dst.cycle,
        );
        vbind = .{ .buffer = dst.buf, .offset = dst.offset };
        ibind = .{ .buffer = dst.buf, .offset = dst.offset + ioff };
    }
    self.endCopy();

    var ct = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
    ct.texture = dest;
    ct.load_op = load;
    ct.store_op = c.SDL_GPU_STOREOP_STORE;
    const pass = c.SDL_BeginGPURenderPass(cmd, &ct, 1, null) orelse {
        log.err("SDL_BeginGPURenderPass failed: {s}", .{c.SDL_GetError()});
        return error.GpuRenderPass;
    };
    defer c.SDL_EndGPURenderPass(pass);
    if (self.draws.items.len == 0) return;

    c.SDL_BindGPUVertexBuffers(pass, 0, &vbind, 1);
    c.SDL_BindGPUIndexBuffer(pass, &ibind, index_element_size);

    const full: c.SDL_Rect = .{ .x = 0, .y = 0, .w = @intCast(dw), .h = @intCast(dh) };
    var bound: ?*c.SDL_GPUGraphicsPipeline = null;
    var scissor: ?c.SDL_Rect = null;
    var pushed: ?u32 = null;
    var last_samplers: [3]?*Tex = .{ null, null, null };
    var last_n: u32 = 0;
    for (self.draws.items) |d| {
        var r = full;
        if (d.clip) |cr| {
            const x0 = @max(cr.x, 0);
            const y0 = @max(cr.y, 0);
            const x1 = @min(cr.x + cr.w, full.w);
            const y1 = @min(cr.y + cr.h, full.h);
            if (x1 <= x0 or y1 <= y0) continue;
            r = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
        }

        const p = self.pipeline(d.program, format, d.blend) orelse continue;
        if (p != bound) {
            c.SDL_BindGPUGraphicsPipeline(pass, p);
            bound = p;
        }
        if (scissor == null or !clipEql(scissor, r)) {
            c.SDL_SetGPUScissor(pass, &r);
            scissor = r;
        }

        const prog: ?Program = if (d.program == 0) null else self.programs.items[d.program - 1];
        const n: u32 = 1 + (if (prog) |pr| pr.textures else 0);
        const set: [3]*Tex = .{ d.tex, d.extra[0], d.extra[1] };
        if (n != last_n or !std.mem.eql(?*Tex, last_samplers[0..n], &[3]?*Tex{ set[0], set[1], set[2] })) {
            var bindings: [3]c.SDL_GPUTextureSamplerBinding = undefined;
            for (0..n) |i| bindings[i] = .{ .texture = set[i].texture, .sampler = set[i].sampler };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &bindings, n);
            last_samplers = .{ set[0], set[1], set[2] };
            last_n = n;
        }
        if (prog) |pr| if (pr.uniform_vec4s > 0 and pushed != d.uniforms) {
            const data = self.uniforms.items[d.uniforms..][0..pr.uniform_vec4s];
            c.SDL_PushGPUFragmentUniformData(cmd, 0, data.ptr, @intCast(pr.uniform_vec4s * 16));
            pushed = d.uniforms;
        };

        c.SDL_DrawGPUIndexedPrimitives(pass, d.index_count, 1, d.first_index, @intCast(d.vertex_offset), 0);
    }
}

// ---------------------------------------------------------------------------------------------
// Textures

fn samplerFor(self: *GpuRenderer, interpolation: dvui.enums.TextureInterpolation, wrap_u: dvui.enums.TextureWrap, wrap_v: dvui.enums.TextureWrap) *c.SDL_GPUSampler {
    return self.samplers[@intFromBool(interpolation == .linear)][@intFromBool(wrap_u == .repeat)][@intFromBool(wrap_v == .repeat)];
}

pub fn textureCreate(self: *GpuRenderer, pixels: [*]const u8, options: dvui.Texture.CreateOptions) !dvui.Texture {
    if (!formatSupported(options.format)) {
        log.err("textureCreate: pixel format {s} not supported", .{@tagName(options.format)});
        return dvui.Backend.TextureError.NotImplemented;
    }
    if (options.width == 0 or options.height == 0) return dvui.Backend.TextureError.TextureCreate;
    var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
    info.type = c.SDL_GPU_TEXTURETYPE_2D;
    info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
    info.width = options.width;
    info.height = options.height;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    info.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
    const texture = c.SDL_CreateGPUTexture(self.device, &info) orelse {
        log.err("SDL_CreateGPUTexture failed: {s}", .{c.SDL_GetError()});
        return dvui.Backend.TextureError.TextureCreate;
    };
    errdefer c.SDL_ReleaseGPUTexture(self.device, texture);

    const tex = self.tex_pool.create(self.gpa) catch return dvui.Backend.TextureError.OutOfMemory;
    errdefer self.tex_pool.destroy(tex);
    tex.* = .{
        .texture = texture,
        .format = info.format,
        .width = options.width,
        .height = options.height,
        .sampler = self.samplerFor(options.interpolation, options.wrap_u, options.wrap_v),
    };
    try self.upload(tex, pixels, options.format, options.width, 0, 0, options.width, options.height);

    return .{ .ptr = tex, .width = options.width, .height = options.height, .format = options.format, .interpolation = options.interpolation, .wrap_u = options.wrap_u, .wrap_v = options.wrap_v };
}

/// Replace `w`×`h` texels at `x`,`y` from `pixels`, which holds the whole texture's rows
/// (pitch `texture.width` texels).
pub fn textureUpdate(self: *GpuRenderer, texture: dvui.Texture, pixels: [*]const u8, x: u32, y: u32, w: u32, h: u32) !void {
    const tex: *Tex = @ptrCast(@alignCast(texture.ptr));
    if (!formatSupported(texture.format)) return dvui.Backend.TextureError.NotImplemented;
    if (w == 0 or h == 0) return;
    if (x + w > tex.width or y + h > tex.height) return dvui.Backend.TextureError.TextureUpdate;
    // Draws already recorded from it see what it held when they were made.
    if (tex.used_in == self.pass_serial) self.flush() catch return dvui.Backend.TextureError.TextureUpdate;
    try self.upload(tex, pixels, texture.format, texture.width, x, y, w, h);
}

fn upload(self: *GpuRenderer, tex: *Tex, pixels: [*]const u8, format: dvui.enums.TexturePixelFormat, pitch_texels: u32, x: u32, y: u32, w: u32, h: u32) !void {
    const row_bytes: usize = @as(usize, w) * 4;
    const len: u32 = @intCast(row_bytes * h);
    const staged = self.upload_ring.reserve(self.device, self.uploadEpoch() catch return dvui.Backend.TextureError.TextureUpdate, len, 512) catch return dvui.Backend.TextureError.TextureUpdate;
    const src_pitch: usize = @as(usize, pitch_texels) * 4;
    for (0..h) |row| {
        const src = pixels + (@as(usize, y) + row) * src_pitch + @as(usize, x) * 4;
        convertRow(staged.ptr + row * row_bytes, src, w, format);
    }
    self.upload_ring.unmap(self.device);

    const copy = self.beginCopy() catch return dvui.Backend.TextureError.TextureUpdate;
    c.SDL_UploadToGPUTexture(
        copy,
        &.{ .transfer_buffer = staged.tb, .offset = staged.offset, .pixels_per_row = w, .rows_per_layer = h },
        &.{ .texture = tex.texture, .mip_level = 0, .layer = 0, .x = x, .y = y, .z = 0, .w = w, .h = h, .d = 1 },
        false,
    );
}

/// The command buffer uploads go on: acquired here when none is being recorded (an upload
/// between frames), so the ring cycles for it.
fn uploadEpoch(self: *GpuRenderer) !u64 {
    _ = try self.ensureCmd();
    return self.epoch;
}

pub fn textureCreateTarget(self: *GpuRenderer, options: dvui.Texture.CreateOptions) !dvui.TextureTarget {
    if (options.width == 0 or options.height == 0) return dvui.Backend.TextureError.TextureCreate;
    const format: c.SDL_GPUTextureFormat = if (options.precision == .high)
        (self.precise_format orelse c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM)
    else
        c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
    info.type = c.SDL_GPU_TEXTURETYPE_2D;
    info.format = format;
    info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
    info.width = options.width;
    info.height = options.height;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    info.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
    const texture = c.SDL_CreateGPUTexture(self.device, &info) orelse {
        log.err("SDL_CreateGPUTexture (target) failed: {s}", .{c.SDL_GetError()});
        return dvui.Backend.TextureError.TextureCreate;
    };
    errdefer c.SDL_ReleaseGPUTexture(self.device, texture);

    const tex = self.tex_pool.create(self.gpa) catch return dvui.Backend.TextureError.OutOfMemory;
    tex.* = .{
        .texture = texture,
        .format = format,
        .width = options.width,
        .height = options.height,
        .sampler = self.samplerFor(options.interpolation, .clamp, .clamp),
        .target = true,
        // Starts transparent (`Texture.Target.create`).
        .needs_clear = true,
    };
    return .{ .ptr = tex, .width = options.width, .height = options.height, .format = options.format, .interpolation = options.interpolation, .wrap_u = .clamp, .wrap_v = .clamp };
}

pub fn textureClearTarget(self: *GpuRenderer, target: dvui.TextureTarget) void {
    const tex: *Tex = @ptrCast(@alignCast(target.ptr));
    // Draws already recorded into or from it come first.
    if (tex.used_in == self.pass_serial) self.flush() catch |err| log.err("textureClearTarget: {any}", .{err});
    tex.needs_clear = true;
}

pub fn textureBlend(_: *GpuRenderer, texture: dvui.Texture, blend: dvui.Backend.TextureBlend) void {
    const tex: *Tex = @ptrCast(@alignCast(texture.ptr));
    tex.blend = switch (blend) {
        .over => .over,
        .add => .add,
        .copy => .copy,
    };
}

pub fn textureDestroy(self: *GpuRenderer, ptr: *anyopaque) void {
    const tex: *Tex = @ptrCast(@alignCast(ptr));
    if (tex.used_in == self.pass_serial) self.flush() catch |err| log.err("textureDestroy: {any}", .{err});
    if (self.target == tex) self.target = null;
    // Released once the command buffers using it are done (SDL defers it).
    c.SDL_ReleaseGPUTexture(self.device, tex.texture);
    self.tex_pool.destroy(tex);
}

pub fn readPixels(self: *GpuRenderer, rect: dvui.Rect.Physical, pixels_out: [*]u8) !void {
    self.flush() catch return dvui.Backend.TextureError.TextureRead;
    // The window's drawable is not readable (and is not acquired until the frame's end).
    const tex = self.target orelse return dvui.Backend.TextureError.TextureRead;
    if (rect.x < 0 or rect.y < 0 or rect.w < 1 or rect.h < 1) return dvui.Backend.TextureError.TextureRead;
    const x: u32 = @intFromFloat(rect.x);
    const y: u32 = @intFromFloat(rect.y);
    const w: u32 = @intFromFloat(rect.w);
    const h: u32 = @intFromFloat(rect.h);
    if (x + w > tex.width or y + h > tex.height) return dvui.Backend.TextureError.TextureRead;
    try self.download(tex, x, y, w, h, pixels_out);
}

pub fn textureReadTarget(self: *GpuRenderer, target: dvui.TextureTarget, pixels_out: [*]u8) !void {
    const tex: *Tex = @ptrCast(@alignCast(target.ptr));
    if (tex.used_in == self.pass_serial or self.target == tex) self.flush() catch return dvui.Backend.TextureError.TextureRead;
    try self.download(tex, 0, 0, tex.width, tex.height, pixels_out);
}

/// Copy `w`×`h` texels at `x`,`y` of `tex` into `out` as RGBA bytes: submits what is recorded
/// and waits for the GPU (a frame's drawable acquired on it would be presented with it, which
/// is why the window's is acquired last).
fn download(self: *GpuRenderer, tex: *Tex, x: u32, y: u32, w: u32, h: u32, out: [*]u8) !void {
    if (tex.needs_clear) self.clearPass(tex) catch return dvui.Backend.TextureError.TextureRead;
    const texel: u32 = if (tex.format == c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT) 8 else 4;
    const size: u32 = w * h * texel;

    var info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
    info.size = size;
    const tb = c.SDL_CreateGPUTransferBuffer(self.device, &info) orelse {
        log.err("SDL_CreateGPUTransferBuffer (download) failed: {s}", .{c.SDL_GetError()});
        return dvui.Backend.TextureError.TextureRead;
    };
    defer c.SDL_ReleaseGPUTransferBuffer(self.device, tb);

    const copy = self.beginCopy() catch return dvui.Backend.TextureError.TextureRead;
    c.SDL_DownloadFromGPUTexture(
        copy,
        &.{ .texture = tex.texture, .mip_level = 0, .layer = 0, .x = x, .y = y, .z = 0, .w = w, .h = h, .d = 1 },
        &.{ .transfer_buffer = tb, .offset = 0, .pixels_per_row = w, .rows_per_layer = h },
    );
    self.submitAndWait() catch return dvui.Backend.TextureError.TextureRead;

    const mapped = c.SDL_MapGPUTransferBuffer(self.device, tb, false) orelse return dvui.Backend.TextureError.TextureRead;
    defer c.SDL_UnmapGPUTransferBuffer(self.device, tb);
    const src: [*]const u8 = @ptrCast(mapped);
    const n: usize = @as(usize, w) * h;
    if (texel == 4) {
        @memcpy(out[0 .. n * 4], src[0 .. n * 4]);
    } else {
        const halves: [*]align(1) const f16 = @ptrCast(src);
        for (0..n * 4) |i| {
            const v: f32 = @floatCast(halves[i]);
            out[i] = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }
}

fn formatSupported(format: dvui.enums.TexturePixelFormat) bool {
    return switch (format) {
        .fourcc_yv12, .fourcc_iyuv, .fourcc_yuy2, .fourcc_uyvy, .fourcc_yvyu => false,
        else => true,
    };
}

/// Where R, G, B and A sit in a texel of `format`, as bytes in memory; A null when the format
/// has none (opaque).
fn layout(format: dvui.enums.TexturePixelFormat) struct { r: u2, g: u2, b: u2, a: ?u2 } {
    const little = builtin.cpu.arch.endian() == .little;
    // The `_8_8_8_8` formats are packed 32-bit words, named from the high byte down: in memory
    // on a little-endian machine they are the byte order reversed.
    const f: dvui.enums.TexturePixelFormat = if (!little) format else switch (format) {
        .rgba_8_8_8_8 => .abgr_32,
        .argb_8_8_8_8 => .bgra_32,
        .bgra_8_8_8_8 => .argb_32,
        .abgr_8_8_8_8 => .rgba_32,
        .rgbx_8_8_8_8 => .xbgr_32,
        .xrgb_8_8_8_8 => .bgrx_32,
        .bgrx_8_8_8_8 => .xrgb_32,
        .xbgr_8_8_8_8 => .rgbx_32,
        else => format,
    };
    return switch (f) {
        .argb_32, .argb_8_8_8_8 => .{ .r = 1, .g = 2, .b = 3, .a = 0 },
        .bgra_32, .bgra_8_8_8_8 => .{ .r = 2, .g = 1, .b = 0, .a = 3 },
        .abgr_32, .abgr_8_8_8_8 => .{ .r = 3, .g = 2, .b = 1, .a = 0 },
        .rgbx_32, .rgbx_8_8_8_8 => .{ .r = 0, .g = 1, .b = 2, .a = null },
        .xrgb_32, .xrgb_8_8_8_8 => .{ .r = 1, .g = 2, .b = 3, .a = null },
        .bgrx_32, .bgrx_8_8_8_8 => .{ .r = 2, .g = 1, .b = 0, .a = null },
        .xbgr_32, .xbgr_8_8_8_8 => .{ .r = 3, .g = 2, .b = 1, .a = null },
        else => .{ .r = 0, .g = 1, .b = 2, .a = 3 },
    };
}

/// `n` texels of `format` at `src` as RGBA bytes at `dst`.
fn convertRow(dst: [*]u8, src: [*]const u8, n: u32, format: dvui.enums.TexturePixelFormat) void {
    const l = layout(format);
    if (l.r == 0 and l.g == 1 and l.b == 2 and l.a != null and l.a.? == 3) {
        @memcpy(dst[0 .. @as(usize, n) * 4], src[0 .. @as(usize, n) * 4]);
        return;
    }
    for (0..n) |i| {
        const s = src[i * 4 ..][0..4];
        const d = dst[i * 4 ..][0..4];
        d[0] = s[l.r];
        d[1] = s[l.g];
        d[2] = s[l.b];
        d[3] = if (l.a) |a| s[a] else 255;
    }
}

// ---------------------------------------------------------------------------------------------
// Programs (`SDLBackend.program_api`)

pub fn programCreate(self: *GpuRenderer, source: NativeSource, textures: u32, uniform_vec4s: u32) u32 {
    if (textures > 2 or uniform_vec4s > uniform_cap) return 0;
    const code = switch (self.shader_format) {
        c.SDL_GPU_SHADERFORMAT_MSL => source.msl,
        c.SDL_GPU_SHADERFORMAT_SPIRV => source.spirv,
        else => source.dxil,
    };
    if (code.len == 0) return 0;
    const shader = self.makeShader(code, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 1 + textures, if (uniform_vec4s > 0) 1 else 0) orelse return 0;
    self.programs.append(self.gpa, .{ .shader = shader, .textures = textures, .uniform_vec4s = uniform_vec4s }) catch {
        c.SDL_ReleaseGPUShader(self.device, shader);
        return 0;
    };
    return @intCast(self.programs.items.len);
}

pub fn programStatus(self: *GpuRenderer, id: u32) u8 {
    if (id == 0 or id > self.programs.items.len) return 0;
    return if (self.programs.items[id - 1].shader != null) 2 else 0;
}

pub fn programBegin(self: *GpuRenderer, id: u32, textures: []const ?*anyopaque, uniforms: []const [4]f32) bool {
    if (self.programStatus(id) != 2) return false;
    if (textures.len > 2 or uniforms.len > uniform_cap) return false;
    const prog = self.programs.items[id - 1];
    var a: Active = .{ .id = id, .extra = .{ self.white, self.white }, .data = @splat(@splat(0)) };
    for (textures, 0..) |t, i| {
        if (t) |p| a.extra[i] = @ptrCast(@alignCast(p));
    }
    const n = @min(uniforms.len, prog.uniform_vec4s);
    @memcpy(a.data[0..n], uniforms[0..n]);
    self.active = a;
    return true;
}

pub fn programBlend(self: *GpuRenderer, mode: u8) void {
    self.blend_override = @enumFromInt(@as(u2, @truncate(mode)));
}

pub fn programEnd(self: *GpuRenderer) void {
    self.active = null;
    self.blend_override = null;
}

// ---------------------------------------------------------------------------------------------
// Rings

/// An upload transfer buffer filled front to back over one command buffer. Its first map for
/// a command buffer cycles it, so a previous one still in flight keeps the bytes it reads; a
/// fill past the end cycles too (the copies already recorded keep theirs); one bigger than the
/// buffer grows it.
const TransferRing = struct {
    tb: ?*c.SDL_GPUTransferBuffer = null,
    cap: u32 = 0,
    off: u32 = 0,
    epoch: u64 = 0,
    min_cap: u32,

    const Slot = struct { tb: *c.SDL_GPUTransferBuffer, offset: u32, ptr: [*]u8 };

    fn reserve(self: *TransferRing, device: *c.SDL_GPUDevice, epoch: u64, len: u32, alignment: u32) !Slot {
        var at = std.mem.alignForward(u32, self.off, alignment);
        var cycle = false;
        if (self.epoch != epoch) {
            self.epoch = epoch;
            at = 0;
            cycle = true;
        }
        if (self.tb == null or len > self.cap) {
            if (self.tb) |old| c.SDL_ReleaseGPUTransferBuffer(device, old);
            self.tb = null;
            var cap = @max(self.min_cap, self.cap);
            while (cap < len) cap *= 2;
            var info = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
            info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
            info.size = cap;
            self.tb = c.SDL_CreateGPUTransferBuffer(device, &info) orelse {
                log.err("SDL_CreateGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
                self.cap = 0;
                return error.GpuTransferBuffer;
            };
            self.cap = cap;
            at = 0;
            cycle = false;
        } else if (at + len > self.cap) {
            at = 0;
            cycle = true;
        }
        const base = c.SDL_MapGPUTransferBuffer(device, self.tb.?, cycle) orelse {
            log.err("SDL_MapGPUTransferBuffer failed: {s}", .{c.SDL_GetError()});
            return error.GpuMap;
        };
        self.off = at + len;
        return .{ .tb = self.tb.?, .offset = at, .ptr = @as([*]u8, @ptrCast(base)) + at };
    }

    fn unmap(self: *TransferRing, device: *c.SDL_GPUDevice) void {
        c.SDL_UnmapGPUTransferBuffer(device, self.tb.?);
    }

    fn deinit(self: *TransferRing, device: *c.SDL_GPUDevice) void {
        if (self.tb) |tb| c.SDL_ReleaseGPUTransferBuffer(device, tb);
        self.* = .{ .min_cap = self.min_cap };
    }
};

/// The GPU side of the vertex/index stream, with `TransferRing`'s placement: each pass's data
/// at its own offset, cycled per command buffer and on wrapping, grown when one pass's data
/// does not fit.
const BufferRing = struct {
    buf: ?*c.SDL_GPUBuffer = null,
    cap: u32 = 0,
    off: u32 = 0,
    epoch: u64 = 0,
    min_cap: u32,

    const Slot = struct { buf: *c.SDL_GPUBuffer, offset: u32, cycle: bool };

    fn reserve(self: *BufferRing, device: *c.SDL_GPUDevice, epoch: u64, len: u32, alignment: u32) !Slot {
        var at = std.mem.alignForward(u32, self.off, alignment);
        var cycle = false;
        if (self.epoch != epoch) {
            self.epoch = epoch;
            at = 0;
            cycle = true;
        }
        if (self.buf == null or len > self.cap) {
            if (self.buf) |old| c.SDL_ReleaseGPUBuffer(device, old);
            self.buf = null;
            var cap = @max(self.min_cap, self.cap);
            while (cap < len) cap *= 2;
            var info = std.mem.zeroes(c.SDL_GPUBufferCreateInfo);
            info.usage = c.SDL_GPU_BUFFERUSAGE_VERTEX | c.SDL_GPU_BUFFERUSAGE_INDEX;
            info.size = cap;
            self.buf = c.SDL_CreateGPUBuffer(device, &info) orelse {
                log.err("SDL_CreateGPUBuffer failed: {s}", .{c.SDL_GetError()});
                self.cap = 0;
                return error.GpuBuffer;
            };
            self.cap = cap;
            at = 0;
            cycle = false;
        } else if (at + len > self.cap) {
            at = 0;
            cycle = true;
        }
        self.off = at + len;
        return .{ .buf = self.buf.?, .offset = at, .cycle = cycle };
    }

    fn deinit(self: *BufferRing, device: *c.SDL_GPUDevice) void {
        if (self.buf) |b| c.SDL_ReleaseGPUBuffer(device, b);
        self.* = .{ .min_cap = self.min_cap };
    }
};
