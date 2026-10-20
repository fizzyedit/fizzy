//! A device that draws nothing: the compile-only skeleton every implementation starts from, and
//! enough of a device to test a renderer's call sequence without a GPU. It hands out ids,
//! counts what is live and what was drawn, and refuses the misuse a real device would
//! (`Failed`): a pass opened inside a pass, a drawable acquired while a pass is open, a
//! submit with a pass open.
//!
//! Not a simulator: nothing is rendered, uploads are not kept, and a mapped transfer buffer is
//! one scratch region shared by all of them.
const std = @import("std");
const types = @import("types.zig");
const shader = @import("shader.zig");
const Device = @import("Device.zig");

const Null = @This();

next_id: u64 = 1,
live: Counts = .{},
open_copy_passes: u32 = 0,
open_render_passes: u32 = 0,
open_commands: u32 = 0,
submits: u32 = 0,
render_passes: u32 = 0,
draws: u32 = 0,
presents: u32 = 0,
/// Whether `acquireSwapchain` finds a drawable (false: the window is minimized).
drawable_available: bool = true,
window_claimed: bool = false,
swapchain_acquired: bool = false,
scratch: [64 * 1024]u8 = undefined,

pub const Counts = struct {
    textures: i32 = 0,
    buffers: i32 = 0,
    transfer_buffers: i32 = 0,
    samplers: i32 = 0,
    shaders: i32 = 0,
    pipelines: i32 = 0,
    fences: i32 = 0,

    /// Nothing left alive: what `Device.destroy` must find after the renderer released its own.
    pub fn allReleased(self: Counts) bool {
        return self.textures == 0 and self.buffers == 0 and self.transfer_buffers == 0 and
            self.samplers == 0 and self.shaders == 0 and self.pipelines == 0 and self.fences == 0;
    }
};

pub const caps: Device.Caps = .{
    .driver = "null",
    .shader_formats = shader.Formats.initMany(&.{ .spirv, .msl, .dxil }),
};

pub fn device(self: *Null) Device {
    return .{ .ctx = self, .vtable = &vtable, .caps = caps };
}

fn from(ctx: *anyopaque) *Null {
    return @ptrCast(@alignCast(ctx));
}

fn id(self: *Null, comptime H: type) H {
    defer self.next_id += 1;
    return @fromBackingInt(@intCast(self.next_id));
}

fn destroy(_: *anyopaque) void {}
fn waitIdle(_: *anyopaque) void {}

fn supportsTexture(_: *anyopaque, _: types.TextureFormat, _: types.TextureUsage) bool {
    return true;
}

fn claimWindow(ctx: *anyopaque, _: types.WindowId) types.Error!void {
    from(ctx).window_claimed = true;
}

fn releaseWindow(ctx: *anyopaque, _: types.WindowId) void {
    from(ctx).window_claimed = false;
}

fn setPresentMode(_: *anyopaque, _: types.WindowId, _: types.PresentMode) types.Error!void {}

fn supportsPresentMode(_: *anyopaque, _: types.WindowId, mode: types.PresentMode) bool {
    return mode != .mailbox;
}

fn swapchainFormat(_: *anyopaque, _: types.WindowId) types.TextureFormat {
    return .bgra8_unorm;
}

fn acquireSwapchain(ctx: *anyopaque, _: types.CommandBuffer, _: types.WindowId, _: bool) types.Error!?types.Swapchain {
    const self = from(ctx);
    if (!self.window_claimed or self.open_render_passes + self.open_copy_passes != 0) return error.Failed;
    if (!self.drawable_available) return null;
    self.swapchain_acquired = true;
    return .{ .texture = self.id(types.Texture), .width = 800, .height = 600 };
}

fn createTexture(ctx: *anyopaque, desc: types.TextureDesc) types.Error!types.Texture {
    if (desc.width == 0 or desc.height == 0) return error.Failed;
    const self = from(ctx);
    self.live.textures += 1;
    return self.id(types.Texture);
}

fn releaseTexture(ctx: *anyopaque, _: types.Texture) void {
    from(ctx).live.textures -= 1;
}

fn createBuffer(ctx: *anyopaque, _: types.BufferDesc) types.Error!types.Buffer {
    const self = from(ctx);
    self.live.buffers += 1;
    return self.id(types.Buffer);
}

fn releaseBuffer(ctx: *anyopaque, _: types.Buffer) void {
    from(ctx).live.buffers -= 1;
}

fn createTransferBuffer(ctx: *anyopaque, desc: types.TransferBufferDesc) types.Error!types.TransferBuffer {
    const self = from(ctx);
    if (desc.size > self.scratch.len) return error.OutOfMemory;
    self.live.transfer_buffers += 1;
    return self.id(types.TransferBuffer);
}

fn releaseTransferBuffer(ctx: *anyopaque, _: types.TransferBuffer) void {
    from(ctx).live.transfer_buffers -= 1;
}

fn mapTransferBuffer(ctx: *anyopaque, _: types.TransferBuffer, _: bool) types.Error![*]u8 {
    return &from(ctx).scratch;
}

fn unmapTransferBuffer(_: *anyopaque, _: types.TransferBuffer) void {}

fn createSampler(ctx: *anyopaque, _: types.SamplerDesc) types.Error!types.Sampler {
    const self = from(ctx);
    self.live.samplers += 1;
    return self.id(types.Sampler);
}

fn releaseSampler(ctx: *anyopaque, _: types.Sampler) void {
    from(ctx).live.samplers -= 1;
}

fn createShader(ctx: *anyopaque, desc: Device.ShaderDesc) types.Error!types.Shader {
    if (!caps.shader_formats.contains(desc.code.format)) return error.Unsupported;
    if (desc.code.bytes.len == 0) return error.Failed;
    const self = from(ctx);
    self.live.shaders += 1;
    return self.id(types.Shader);
}

fn releaseShader(ctx: *anyopaque, _: types.Shader) void {
    from(ctx).live.shaders -= 1;
}

fn createPipeline(ctx: *anyopaque, _: Device.PipelineDesc) types.Error!types.Pipeline {
    const self = from(ctx);
    self.live.pipelines += 1;
    return self.id(types.Pipeline);
}

fn releasePipeline(ctx: *anyopaque, _: types.Pipeline) void {
    from(ctx).live.pipelines -= 1;
}

fn acquireCommandBuffer(ctx: *anyopaque) types.Error!types.CommandBuffer {
    const self = from(ctx);
    self.open_commands += 1;
    return self.id(types.CommandBuffer);
}

fn endCommands(self: *Null) types.Error!void {
    if (self.open_commands == 0 or self.open_render_passes + self.open_copy_passes != 0) return error.Failed;
    self.open_commands -= 1;
    self.submits += 1;
    if (self.swapchain_acquired) self.presents += 1;
    self.swapchain_acquired = false;
}

fn submit(ctx: *anyopaque, _: types.CommandBuffer) types.Error!void {
    try endCommands(from(ctx));
}

fn submitWithFence(ctx: *anyopaque, _: types.CommandBuffer) types.Error!types.Fence {
    const self = from(ctx);
    try endCommands(self);
    self.live.fences += 1;
    return self.id(types.Fence);
}

fn waitFence(_: *anyopaque, _: types.Fence) types.Error!void {}

fn releaseFence(ctx: *anyopaque, _: types.Fence) void {
    from(ctx).live.fences -= 1;
}

fn beginCopyPass(ctx: *anyopaque, _: types.CommandBuffer) types.Error!types.CopyPass {
    const self = from(ctx);
    if (self.open_render_passes + self.open_copy_passes != 0) return error.Failed;
    self.open_copy_passes += 1;
    return self.id(types.CopyPass);
}

fn endCopyPass(ctx: *anyopaque, _: types.CopyPass) void {
    from(ctx).open_copy_passes -= 1;
}

fn uploadToBuffer(_: *anyopaque, _: types.CopyPass, _: types.TransferLocation, _: types.BufferRegion, _: bool) void {}
fn uploadToTexture(_: *anyopaque, _: types.CopyPass, _: types.TextureTransfer, _: types.TextureRegion) void {}
fn downloadFromTexture(_: *anyopaque, _: types.CopyPass, _: types.TextureRegion, _: types.TextureTransfer) void {}
fn blit(_: *anyopaque, _: types.CommandBuffer, _: types.Blit) void {}

fn beginRenderPass(ctx: *anyopaque, _: types.CommandBuffer, _: types.ColorTarget) types.Error!types.RenderPass {
    const self = from(ctx);
    if (self.open_render_passes + self.open_copy_passes != 0) return error.Failed;
    self.open_render_passes += 1;
    self.render_passes += 1;
    return self.id(types.RenderPass);
}

fn endRenderPass(ctx: *anyopaque, _: types.RenderPass) void {
    from(ctx).open_render_passes -= 1;
}

fn bindPipeline(_: *anyopaque, _: types.RenderPass, _: types.Pipeline) void {}
fn bindVertexBuffer(_: *anyopaque, _: types.RenderPass, _: types.BufferBinding) void {}
fn bindIndexBuffer(_: *anyopaque, _: types.RenderPass, _: types.BufferBinding, _: types.IndexSize) void {}
fn setScissor(_: *anyopaque, _: types.RenderPass, _: types.Rect) void {}
fn bindFragmentSamplers(_: *anyopaque, _: types.RenderPass, _: []const types.SamplerBinding) void {}
fn pushFragmentUniforms(_: *anyopaque, _: types.RenderPass, _: u32, _: []const u8) void {}

fn drawIndexed(ctx: *anyopaque, _: types.RenderPass, _: types.DrawIndexed) void {
    from(ctx).draws += 1;
}

const vtable: Device.VTable = .{
    .destroy = destroy,
    .wait_idle = waitIdle,
    .supports_texture = supportsTexture,
    .claim_window = claimWindow,
    .release_window = releaseWindow,
    .set_present_mode = setPresentMode,
    .supports_present_mode = supportsPresentMode,
    .swapchain_format = swapchainFormat,
    .acquire_swapchain = acquireSwapchain,
    .create_texture = createTexture,
    .release_texture = releaseTexture,
    .create_buffer = createBuffer,
    .release_buffer = releaseBuffer,
    .create_transfer_buffer = createTransferBuffer,
    .release_transfer_buffer = releaseTransferBuffer,
    .map_transfer_buffer = mapTransferBuffer,
    .unmap_transfer_buffer = unmapTransferBuffer,
    .create_sampler = createSampler,
    .release_sampler = releaseSampler,
    .create_shader = createShader,
    .release_shader = releaseShader,
    .create_pipeline = createPipeline,
    .release_pipeline = releasePipeline,
    .acquire_command_buffer = acquireCommandBuffer,
    .submit = submit,
    .submit_with_fence = submitWithFence,
    .wait_fence = waitFence,
    .release_fence = releaseFence,
    .begin_copy_pass = beginCopyPass,
    .end_copy_pass = endCopyPass,
    .upload_to_buffer = uploadToBuffer,
    .upload_to_texture = uploadToTexture,
    .download_from_texture = downloadFromTexture,
    .blit = blit,
    .begin_render_pass = beginRenderPass,
    .end_render_pass = endRenderPass,
    .bind_pipeline = bindPipeline,
    .bind_vertex_buffer = bindVertexBuffer,
    .bind_index_buffer = bindIndexBuffer,
    .set_scissor = setScissor,
    .bind_fragment_samplers = bindFragmentSamplers,
    .push_fragment_uniforms = pushFragmentUniforms,
    .draw_indexed = drawIndexed,
};

// A frame in the order `GpuRenderer` records one: setup, a texture upload, a vertex upload, the
// window's pass with a program draw, present. Each call here is one `GpuRenderer` makes today, and
// the order follows `claimViewport` and `setVSync` (setup), `encodePass` (uploads, then the
// drawable, then the pass), `present` (submit) and `readPixels` (download, fence); `README.md`'s
// audit table maps each call to its lines.
test "a GpuRenderer frame runs through the interface" {
    var null_device: Null = .{};
    const dev = null_device.device();
    const window: types.WindowId = 1;

    try dev.claimWindow(window);
    try std.testing.expect(dev.supportsPresentMode(window, .immediate));
    try dev.setPresentMode(window, .immediate);
    const swap_format = dev.swapchainFormat(window);

    // Shaders are picked by format from what ships, created, and built into a pipeline.
    const set: shader.Set = .{ .spirv = "spv", .msl = "msl", .dxil = "dxil" };
    const vs_code = shader.resolve(set, dev.caps.shader_formats, &shader.default_preference, .vertex, null).?;
    const vs = try dev.createShader(.{ .code = vs_code, .stage = .vertex });
    const fs_code = shader.resolve(set, dev.caps.shader_formats, &shader.default_preference, .fragment, null).?;
    const fs = try dev.createShader(.{ .code = fs_code, .stage = .fragment, .num_samplers = 1 });
    const sampler = try dev.createSampler(.{ .filter = .linear, .address_u = .clamp_to_edge, .address_v = .clamp_to_edge });
    const pipeline = try dev.createPipeline(.{
        .vertex_shader = vs,
        .fragment_shader = fs,
        .vertex_pitch = 20,
        .attributes = &.{
            .{ .location = 0, .format = .float2, .offset = 0 },
            .{ .location = 1, .format = .ubyte4_norm, .offset = 8 },
            .{ .location = 2, .format = .float2, .offset = 12 },
        },
        .color_format = swap_format,
        .blend = .{ .enabled = true, .src_color = .one, .dst_color = .one_minus_src_alpha, .src_alpha = .one, .dst_alpha = .one_minus_src_alpha },
    });
    const white = try dev.createTexture(.{ .width = 1, .height = 1, .format = .rgba8_unorm, .usage = .{ .sampler = true } });

    // The frame: uploads on a copy pass, then the drawable (no pass open), then the pass.
    const cmd = try dev.acquireCommandBuffer();
    const staging = try dev.createTransferBuffer(.{ .direction = .upload, .size = 4096 });
    const bytes = try dev.mapTransferBuffer(staging, false);
    @memset(bytes[0..4], 255);
    dev.unmapTransferBuffer(staging);
    const vbuf = try dev.createBuffer(.{ .usage = .{ .vertex = true, .index = true }, .size = 4096 });
    const copy = try dev.beginCopyPass(cmd);
    dev.uploadToTexture(copy, .{ .buffer = staging, .offset = 0, .pixels_per_row = 1, .rows_per_layer = 1 }, .{ .texture = white, .x = 0, .y = 0, .w = 1, .h = 1 });
    dev.uploadToBuffer(copy, .{ .buffer = staging, .offset = 0 }, .{ .buffer = vbuf, .offset = 0, .size = 64 }, false);
    try std.testing.expectError(error.Failed, dev.acquireSwapchain(cmd, window, true));
    dev.endCopyPass(copy);

    const swap = (try dev.acquireSwapchain(cmd, window, true)).?;
    const pass = try dev.beginRenderPass(cmd, .{ .texture = swap.texture, .load_op = .clear });
    dev.bindPipeline(pass, pipeline);
    dev.bindVertexBuffer(pass, .{ .buffer = vbuf, .offset = 0 });
    dev.bindIndexBuffer(pass, .{ .buffer = vbuf, .offset = 32 }, .u16);
    dev.setScissor(pass, .{ .x = 0, .y = 0, .w = @intCast(swap.width), .h = @intCast(swap.height) });
    dev.bindFragmentSamplers(pass, &.{.{ .texture = white, .sampler = sampler }});
    dev.pushFragmentUniforms(pass, 0, &std.mem.zeroes([16]u8));
    dev.drawIndexed(pass, .{ .index_count = 6 });
    dev.endRenderPass(pass);
    try dev.submit(cmd);

    try std.testing.expectEqual(@as(u32, 1), null_device.draws);
    try std.testing.expectEqual(@as(u32, 1), null_device.presents);
    try std.testing.expectError(error.Failed, dev.submit(cmd));

    // A read: download, submit with a fence, wait.
    const cmd2 = try dev.acquireCommandBuffer();
    const down = try dev.createTransferBuffer(.{ .direction = .download, .size = 4 });
    const copy2 = try dev.beginCopyPass(cmd2);
    dev.downloadFromTexture(copy2, .{ .texture = white, .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .buffer = down, .offset = 0, .pixels_per_row = 1, .rows_per_layer = 1 });
    dev.endCopyPass(copy2);
    const fence = try dev.submitWithFence(cmd2);
    try dev.waitFence(fence);
    dev.releaseFence(fence);
    dev.releaseTransferBuffer(down);
    try std.testing.expectEqual(@as(u32, 1), null_device.presents);

    dev.releaseTexture(white);
    dev.releasePipeline(pipeline);
    dev.releaseSampler(sampler);
    dev.releaseShader(vs);
    dev.releaseShader(fs);
    dev.releaseBuffer(vbuf);
    dev.releaseTransferBuffer(staging);
    dev.releaseWindow(window);
    try std.testing.expect(null_device.live.allReleased());
    dev.destroy();
}

test "no drawable: minimized windows draw nothing and present nothing" {
    var null_device: Null = .{ .drawable_available = false };
    const dev = null_device.device();
    try dev.claimWindow(1);
    const cmd = try dev.acquireCommandBuffer();
    try std.testing.expect((try dev.acquireSwapchain(cmd, 1, true)) == null);
    try dev.submit(cmd);
    try std.testing.expectEqual(@as(u32, 0), null_device.presents);
}

test "a device refuses a shader format it lacks" {
    var null_device: Null = .{};
    const dev = null_device.device();
    const code: shader.Code = .{ .format = .dxbc, .bytes = "x", .entry = "main" };
    try std.testing.expectError(error.Unsupported, dev.createShader(.{ .code = code, .stage = .fragment }));
}
