//! Custom GPU programs: a fragment shader of the app's own, drawn where dvui would draw triangles.
//!
//! dvui draws everything with one fixed shader — a texture times a colour. Some pictures cannot be
//! made from that however many passes it takes: glass whose shapes run together (`LiquidField`)
//! needs a distance worked out at every pixel, and a game drawn under the UI needs its own
//! shaders. A backend that can compile programs says so here, and draws are sent through one by
//! bracketing ordinary `dvui.renderTriangles` calls with `begin` and `end`.
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
            .ready => self.id,
            .compiling => blk: {
                // Keep frames coming until it is there.
                dvui.refresh(null, @src(), null);
                break :blk null;
            },
            .failed => blk: {
                self.state = .failed;
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
