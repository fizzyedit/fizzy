//! Custom GPU programs: a fragment shader of your own, drawn where dvui would draw triangles —
//! for UI effects, and for games that use fizzy as their shell and dvui as their UI.
//!
//! dvui draws everything with one fixed shader — a texture times a colour. Some pictures cannot be
//! made from that however many passes it takes: glass whose shapes run together (`LiquidField`)
//! needs a distance worked out at every pixel, and a game needs its own shaders. A backend that
//! can compile programs says so here; anything else draws through one with `draw`/`drawRect`.
//!
//! **Using one** (any widget, any plugin):
//!
//! ```zig
//! var plasma: core.programs.Program = .fromGlsl(@embedFile("plasma.glsl"), .{ .uniform_vec4s = 1 });
//!
//! fn draw(rect: dvui.Rect.Physical) void {
//!     const t: f32 = @floatCast(@as(f64, @floatFromInt(dvui.frameTimeNS())) / 1e9);
//!     if (!core.programs.drawRect(&plasma, rect, .{ .uniforms = &.{.{ t, rect.w, rect.h, 0 }} })) {
//!         rect.fill(.{}, .{ .color = .{ .color = .black } }); // no programs here: a fallback
//!     }
//!     dvui.refresh(null, @src(), null); // animating: keep frames coming
//! }
//! ```
//!
//! `drawRect` lays a quad over `rect` whose uv runs 0…1 across it; `draw` takes your own
//! triangles. Either goes where the frame is when it is made — in a floating window it is queued
//! with that window's other drawing and replays in its place — and returns false, drawing
//! nothing, where there are no programs (dvui's own backends, an old WebGL without high-precision
//! fragment shaders) or yours is still compiling: draw something else.
//!
//! **Cost.** A program draw is a draw: a switch of program, its uniforms set from the frame's
//! data, and your triangles in the frame's one vertex stream — no buffer of its own, nothing read
//! back. Do the work per pixel, not per vertex: a quad and a loop in the shader is the cheap way
//! to draw many shapes (`LiquidField` draws a drop and its bubbles as one quad). Keep uniforms
//! few (they are vec4s, at most `Hooks.max_uniform_vec4s`) and programs few per frame.
//!
//! **Where it comes from.** The backend is the app's (`src/backend/WebBackend.zig` on the web): it
//! declares `program_api`, and the host publishes it each frame (`publishHost`) into the shared
//! dvui window, where every image's copy of this file finds it — a plugin dylib's or web side
//! module's included, since they run in the host's process and call its functions directly. A
//! backend without it (dvui's own, the plugin proxy before the host publishes) has none, and
//! callers draw some other way.
//!
//! **When.** A program draw is a draw: it goes where the frame is when it is made. Glass reads what
//! is under it, so it is made inside a `dvui.deferRender` job, when its layer replays — the same
//! as a frost.
//!
//! **The vertices.** A program sees dvui's vertex — position, colour (0…1, premultiplied), and
//! uv — exactly as passed; `renderTriangles` moves only the positions (by the render target's
//! offset), so the colour and uv are free to carry what the program wants.
//!
//! **Writing one (the web).** A fragment shader in GLSL ES, without a `#version` line, against
//! the backend's prelude, which makes the one source build as ES 3.00 and ES 1.00:
//! `VARYING` for an input, `TEX(sampler, uv)` to sample, `FRAG_COLOR` for the output, and
//! `MAX_VEC4` for the length of its uniforms, `uniform vec4 uData[MAX_VEC4]`. Inputs are
//! `vColor` and `vTextureCoord`; samplers are `uSampler` (unit 0, the draw's own texture),
//! `uTex1` and `uTex2` (the extra textures `begin` binds).
const std = @import("std");
const dvui = @import("dvui");

const log = std.log.scoped(.programs);

/// Bumped whenever `Hooks` changes shape, so an image built against another layout finds none.
pub const abi_version: u32 = 1;

/// How the draws between `begin` and `end` land on what is there.
pub const Blend = enum(u8) {
    /// Premultiplied source-over, dvui's own.
    over = 0,
    /// Adds.
    add = 1,
    /// Writes, colour and alpha.
    copy = 2,
    /// Clears what is there by the source's alpha: `dst · (1 − a)`. Followed by an `add` of the
    /// same coverage, it writes `src · a + dst · (1 − a)` for colour *and* alpha — a picture that
    /// replaces what it covers, with an anti-aliased edge that no single blend can make.
    punch = 3,
};

pub const Status = enum(u8) { failed = 0, compiling = 1, ready = 2 };

/// A program's source for every backend that might compile it: each takes the one it can.
pub const Source = extern struct {
    /// GLSL ES fragment shader, without its `#version` (see the file comment): the web.
    glsl: ?[*]const u8 = null,
    glsl_len: usize = 0,
    /// The same compiled for SDL_GPU (the native backend): Metal source (entry point `main0`),
    /// SPIR-V, DXIL. Built from one HLSL source by shadercross.
    msl: ?[*]const u8 = null,
    msl_len: usize = 0,
    spirv: ?[*]const u8 = null,
    spirv_len: usize = 0,
    dxil: ?[*]const u8 = null,
    dxil_len: usize = 0,
    /// Extra textures it reads beyond the draw's own (units 1 and up), at most 2.
    textures: u32 = 0,
    /// Length of its `uData`, in vec4s.
    uniform_vec4s: u32 = 0,
};

/// What a backend that can draw programs offers. Every function is the host's, called from any
/// image in its process.
pub const Hooks = extern struct {
    abi: u32 = abi_version,
    /// The most uniform vec4s a program may have.
    max_uniform_vec4s: u32 = 0,
    /// Compile `source`: an id, or 0 where the backend cannot. Compiling may take frames
    /// (`status`).
    create: *const fn (source: *const Source) callconv(.c) u32,
    status: *const fn (program: u32) callconv(.c) u8,
    /// Draw through `program` from here until `end`: `textures` (`n_textures` of them, opaque
    /// dvui texture pointers) at units 1…, `uniforms` (`n_uniforms` vec4s) as its `uData`. False,
    /// and nothing changes, when it is not ready.
    begin: *const fn (program: u32, textures: [*]const ?*anyopaque, n_textures: u32, uniforms: [*]const [4]f32, n_uniforms: u32) callconv(.c) bool,
    /// How the following draws blend (`Blend`), over each texture's own, until `end`.
    blend: *const fn (mode: u8) callconv(.c) void,
    end: *const fn () callconv(.c) void,
};

const publish_id: dvui.Id = @enumFromInt(0x6669_7a7a_7072_6f67); // "fizzprog"
const publish_key = "_programs";

/// Host only, once a frame: publish this backend's programs, if it has any.
pub fn publishHost() void {
    if (dvui.current_window == null) return;
    if (!@hasDecl(dvui.backend, "program_api")) return;
    const api = dvui.backend.program_api;
    dvui.dataSet(null, publish_id, publish_key, Hooks{
        .max_uniform_vec4s = api.max_uniform_vec4s(),
        .create = &Host.create,
        .status = &api.status,
        .begin = &api.begin,
        .blend = &api.blend,
        .end = &api.end,
    });
}

/// The host's side of `Hooks.create`: the backend takes the source a piece at a time, so its
/// file needs nothing of this one.
const Host = struct {
    fn create(source: *const Source) callconv(.c) u32 {
        if (!@hasDecl(dvui.backend, "program_api")) return 0;
        const api = dvui.backend.program_api;
        if (@hasDecl(api, "createNative")) {
            const empty: [*]const u8 = "";
            return api.createNative(
                source.msl orelse empty,
                source.msl_len,
                source.spirv orelse empty,
                source.spirv_len,
                source.dxil orelse empty,
                source.dxil_len,
                source.textures,
                source.uniform_vec4s,
            );
        }
        const glsl = source.glsl orelse return 0;
        return api.create(glsl, source.glsl_len, source.textures, source.uniform_vec4s);
    }
};

/// This frame's programs, or null where the backend has none.
pub fn hooks() ?Hooks {
    if (dvui.current_window == null) return null;
    const h = dvui.dataGet(null, publish_id, publish_key, Hooks) orelse return null;
    if (h.abi != abi_version) return null;
    return h;
}

/// A program as an app declares it, compiled on first use and kept: `ready` hands back its id
/// once the backend has it. One per program per image; a plugin's copy compiles its own.
pub const Program = struct {
    source: Source,
    id: u32 = 0,
    state: enum { unasked, asked, failed } = .unasked,
    logged: bool = false,

    pub const Shape = struct {
        /// Length of its `uData`, in vec4s.
        uniform_vec4s: u32 = 0,
        /// Extra textures it reads (`uTex1`, `uTex2`).
        textures: u32 = 0,
    };

    /// A program from GLSL ES source (see the file comment): the web's. A native backend takes
    /// the same program as Metal, SPIR-V or DXIL (`from`).
    pub fn fromGlsl(comptime glsl: []const u8, shape: Shape) Program {
        return from(.{ .glsl = glsl }, shape);
    }

    /// The one program in each form a backend might compile: GLSL ES for the web (against the
    /// prelude), and for the native backend Metal source (entry point `main0`), SPIR-V or DXIL —
    /// each backend takes the form it can and draws nothing where it has none. Native programs
    /// take the default vertex shader's colour and uv, the draw's own texture at 0 and the extra
    /// ones at 1 and 2, and the uniforms as `constant float4 *data [[buffer(0)]]` (see
    /// `src/backend/native/shaders/program_example.fragment.hlsl`).
    pub fn from(comptime sources: Sources, shape: Shape) Program {
        var src: Source = .{ .textures = shape.textures, .uniform_vec4s = shape.uniform_vec4s };
        if (sources.glsl) |t| {
            src.glsl = t.ptr;
            src.glsl_len = t.len;
        }
        if (sources.msl) |t| {
            src.msl = t.ptr;
            src.msl_len = t.len;
        }
        if (sources.spirv) |t| {
            src.spirv = t.ptr;
            src.spirv_len = t.len;
        }
        if (sources.dxil) |t| {
            src.dxil = t.ptr;
            src.dxil_len = t.len;
        }
        return .{ .source = src };
    }

    pub const Sources = struct {
        glsl: ?[]const u8 = null,
        msl: ?[]const u8 = null,
        spirv: ?[]const u8 = null,
        dxil: ?[]const u8 = null,
    };

    /// The program's id, ready to draw with — compiling it the first time — or null while it
    /// compiles, where it failed, or where there are no programs.
    pub fn ready(self: *Program, h: Hooks) ?u32 {
        switch (self.state) {
            .failed => return null,
            .unasked => {
                if (self.source.uniform_vec4s > h.max_uniform_vec4s) {
                    self.state = .failed;
                    return null;
                }
                self.id = h.create(&self.source);
                self.state = if (self.id == 0) .failed else .asked;
                if (self.id == 0) return null;
            },
            .asked => {},
        }
        return switch (@as(Status, @enumFromInt(h.status(self.id)))) {
            .ready => blk: {
                if (!self.logged) {
                    self.logged = true;
                    log.info("program {d} ready", .{self.id});
                }
                break :blk self.id;
            },
            .compiling => blk: {
                // Keep frames coming until it is there.
                dvui.refresh(null, @src(), null);
                break :blk null;
            },
            .failed => blk: {
                self.state = .failed;
                log.warn("program {d} failed to build; drawing without it", .{self.id});
                break :blk null;
            },
        };
    }
};

/// The texture handle `begin` takes.
pub fn handle(tex: ?dvui.Texture) ?*anyopaque {
    const t = tex orelse return null;
    return @ptrCast(t.ptr);
}

// ── Drawing ─────────────────────────────────────────────────────────────────────────────────────

/// What a draw through a program reads besides its triangles.
pub const DrawOptions = struct {
    /// Its `uData`: as many vec4s as it declared, at most.
    uniforms: []const [4]f32 = &.{},
    /// What it reads at units 1 and 2 (`uTex1`, `uTex2`).
    textures: []const ?dvui.Texture = &.{},
    blend: Blend = .over,
};

/// Draw `triangles` through `program`, `tex` at unit 0 (`uSampler`), in order with everything
/// drawn around it. False, having drawn nothing, where there are no programs or `program` is not
/// ready yet: draw a fallback.
pub fn draw(program: *Program, triangles: dvui.Triangles, tex: ?dvui.Texture, opts: DrawOptions) bool {
    const h = hooks() orelse return false;
    const id = program.ready(h) orelse return false;
    if (opts.uniforms.len > h.max_uniform_vec4s or opts.textures.len > 2) return false;
    const arena = dvui.currentWindow().arena();
    const job = arena.create(Job) catch return false;
    job.* = .{
        .program = id,
        // Its own copy: replayed later, and `renderTriangles` moves positions in place.
        .triangles = triangles.dupe(arena) catch return false,
        .tex = tex,
        .uniforms = arena.dupe([4]f32, opts.uniforms) catch return false,
        .blend = opts.blend,
    };
    for (opts.textures, 0..) |t, i| job.textures[i] = handle(t);
    job.n_textures = @intCast(opts.textures.len);
    // Where the frame is being recorded for later (a floating window's commands), this queues
    // it among them; where it is drawn as it goes, it draws now.
    dvui.deferRender(job, Job.run);
    return true;
}

/// How `drawRect` lays its quad down.
pub const RectOptions = struct {
    uniforms: []const [4]f32 = &.{},
    textures: []const ?dvui.Texture = &.{},
    blend: Blend = .over,
    /// What the quad carries at unit 0.
    tex: ?dvui.Texture = null,
    /// The uv across the quad, top left to bottom right.
    uv: dvui.Rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    /// Every corner's colour (`vColor`), premultiplied by the program's own reading.
    color: dvui.Color = .white,
};

/// `draw` a quad over `rect` (physical pixels, window coordinates): its uv running across it per
/// `opts.uv`, every vertex `opts.color`.
pub fn drawRect(program: *Program, rect: dvui.Rect.Physical, opts: RectOptions) bool {
    const arena = dvui.currentWindow().arena();
    var b = dvui.Triangles.Builder.init(arena, 4, 6) catch return false;
    defer b.deinit(arena);
    const col = dvui.Color.PMA.fromColor(opts.color);
    const u = opts.uv;
    b.appendVertex(.{ .pos = rect.topLeft(), .col = col, .uv = .{ u.x, u.y } });
    b.appendVertex(.{ .pos = rect.topRight(), .col = col, .uv = .{ u.x + u.w, u.y } });
    b.appendVertex(.{ .pos = rect.bottomRight(), .col = col, .uv = .{ u.x + u.w, u.y + u.h } });
    b.appendVertex(.{ .pos = rect.bottomLeft(), .col = col, .uv = .{ u.x, u.y + u.h } });
    b.appendTriangles(&.{ 0, 1, 2, 0, 2, 3 });
    return draw(program, b.build_unowned(), opts.tex, .{ .uniforms = opts.uniforms, .textures = opts.textures, .blend = opts.blend });
}

/// A `draw` waiting for its place in the frame.
const Job = struct {
    program: u32,
    triangles: dvui.Triangles,
    tex: ?dvui.Texture,
    uniforms: []const [4]f32,
    textures: [2]?*anyopaque = .{ null, null },
    n_textures: u32 = 0,
    blend: Blend,

    fn run(ctx: ?*anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(ctx orelse return));
        const h = hooks() orelse return;
        if (!h.begin(self.program, &self.textures, self.n_textures, self.uniforms.ptr, @intCast(self.uniforms.len))) return;
        defer h.end();
        h.blend(@intFromEnum(self.blend));
        dvui.renderTriangles(self.triangles, self.tex) catch {};
    }
};
