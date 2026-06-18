//! Shared 1D water surface along the cover-flow waterline (slot space).
//!
//! The field is anchored to the sprite shelf: one band of `cols_per_slot`
//! columns per cover-flow slot, centred on the focused card. Cards inject
//! disturbances at their slot; one wave step per frame lets ripples travel
//! along the shelf and wobble neighbouring reflections — including the static
//! centre card, which never moves but still sits "in the water".
//!
//! It is a signed height field h(x) along the waterline; rendering uses |h| so
//! ripples always crest above the baseline while physics stays symmetric for
//! both scroll directions. ~600 cells, O(n) per frame.

const std = @import("std");

/// Columns of surface resolution per cover-flow slot. Higher = smaller, finer
/// ripples (more waves per card). Scale-invariant: a slot's screen width scales
/// with the sprite, so the ripple wavelength in pixels tracks the zoom.
pub const cols_per_slot: usize = 56;
/// Samples per card width for reflection meshes (`cols_per_slot` + 1 endpoints).
pub const reflection_surface_cols: usize = cols_per_slot + 1;
/// Slots the field spans (2 * max_window + 1; see sprites.zig `max_window` = 12).
pub const max_slots: usize = 25;
/// Buffer slot index of the focused card: slot offset `d` maps to `field_center + d`.
pub const field_center: usize = max_slots / 2; // 12
pub const grid_n: usize = cols_per_slot * max_slots;

/// Field-column coordinate of the centre of the slot at offset `d` from focus.
pub fn slotCenterCol(d: i64) f32 {
    const slot = @as(f32, @floatFromInt(field_center)) + @as(f32, @floatFromInt(d));
    return slot * @as(f32, @floatFromInt(cols_per_slot)) + @as(f32, @floatFromInt(cols_per_slot)) * 0.5;
}

/// Field-column coordinate of the left edge of the slot at offset `d`.
pub fn slotLeftCol(d: i64) f32 {
    const slot = @as(f32, @floatFromInt(field_center)) + @as(f32, @floatFromInt(d));
    return slot * @as(f32, @floatFromInt(cols_per_slot));
}

/// Field-column coordinate for a continuous slot offset (for sampling the
/// waterline between cards). `d_cont` is the fractional offset from the focus.
pub fn colForOffset(d_cont: f32) f32 {
    return (@as(f32, @floatFromInt(field_center)) + d_cont) * @as(f32, @floatFromInt(cols_per_slot)) +
        @as(f32, @floatFromInt(cols_per_slot)) * 0.5;
}

const max_height: f32 = 1.85;
const max_vel: f32 = 10.5;

pub const WaterSurface = struct {
    height: [grid_n]f32 = .{0} ** grid_n,
    vel: [grid_n]f32 = .{0} ** grid_n,

    /// Re-anchor the field when the focused slot shifts by `slots` (so in-flight
    /// ripples keep travelling with the shelf). `new[i] = old[i + slots*cols]`.
    pub fn reanchor(self: *WaterSurface, slots: i64) void {
        if (slots == 0) return;
        const span: i64 = @intCast(grid_n);
        const shift = slots * @as(i64, @intCast(cols_per_slot));
        if (shift <= -span or shift >= span) {
            @memset(&self.height, 0);
            @memset(&self.vel, 0);
            return;
        }
        var tmp_h: [grid_n]f32 = undefined;
        var tmp_v: [grid_n]f32 = undefined;
        var i: usize = 0;
        while (i < grid_n) : (i += 1) {
            const src = @as(i64, @intCast(i)) + shift;
            if (src < 0 or src >= span) {
                tmp_h[i] = 0;
                tmp_v[i] = 0;
            } else {
                tmp_h[i] = self.height[@intCast(src)];
                tmp_v[i] = self.vel[@intCast(src)];
            }
        }
        self.height = tmp_h;
        self.vel = tmp_v;
    }

    /// Propagation stiffness (higher = faster, tighter ripples). Wave speed is
    /// `sqrt(wave_c)` cells/s; at 56 cells/card a ripple crosses in ~0.09 s.
    const wave_c: f32 = 11500.0;

    /// Velocity diffusion (kinematic viscosity, cells²/s). Surface-tension analogue:
    /// damps short-wavelength modes ∝ wavenumber², so grid-scale jitter decays fast
    /// while smooth long swells — which carry the refraction — are barely touched.
    /// Stable while `visc·dt ≤ 0.5`; sub-step `dt ≤ 0.0047 s` keeps margin to spare.
    const visc: f32 = 32.0;

    /// One wave-equation step: `vel += c²·∇²h·dt`, then integrate and damp.
    /// Sub-stepped so the explicit scheme stays stable (CFL) even at high `wave_c`
    /// and slow frames, decoupling ripple speed from the frame rate.
    pub fn step(self: *WaterSurface, dt_in: f32) void {
        const dt_total = std.math.clamp(dt_in, 0.0, 1.0 / 30.0);
        if (dt_total <= 0) return;

        const c = @sqrt(wave_c);
        const max_sub_dt = 0.5 / c; // CFL margin (c·dt/dx ≤ 0.5)
        const nsub = @max(1, @as(usize, @intFromFloat(@ceil(dt_total / max_sub_dt))));
        const dt = dt_total / @as(f32, @floatFromInt(nsub));
        // Lighter velocity damping so ripples keep oscillating (wake-like) for a
        // couple seconds after the last stir instead of snapping flat; height damps
        // slower still so peaks stay tight. Energy gate stops the refresh by ~3 s.
        const vel_damp = @exp(-2.8 * dt);
        const h_damp = @exp(-1.5 * dt);
        const n: f32 = @floatFromInt(grid_n);

        var sub: usize = 0;
        while (sub < nsub) : (sub += 1) {
            var i: usize = 1;
            while (i < grid_n - 1) : (i += 1) {
                const lap = self.height[i - 1] + self.height[i + 1] - 2.0 * self.height[i];
                self.vel[i] += lap * wave_c * dt;
            }
            // Reflective ends so ripples bounce instead of vanishing at the buffer edge.
            self.vel[0] += (self.height[1] - self.height[0]) * wave_c * dt;
            self.vel[grid_n - 1] += (self.height[grid_n - 2] - self.height[grid_n - 1]) * wave_c * dt;

            // Viscosity: diffuse velocity using a snapshot (Jacobi), so short, jittery
            // ripples smear out while smooth swells pass through. Computed from the
            // pre-diffusion velocities so left/right neighbours stay consistent.
            if (visc > 0) {
                var lap_v: [grid_n]f32 = undefined;
                lap_v[0] = self.vel[1] - self.vel[0];
                lap_v[grid_n - 1] = self.vel[grid_n - 2] - self.vel[grid_n - 1];
                var k: usize = 1;
                while (k < grid_n - 1) : (k += 1) {
                    lap_v[k] = self.vel[k - 1] + self.vel[k + 1] - 2.0 * self.vel[k];
                }
                for (&self.vel, lap_v) |*v, l| v.* += visc * l * dt;
            }

            var h_sum: f32 = 0;
            var v_sum: f32 = 0;
            for (&self.height, &self.vel) |*h, *v| {
                h.* += v.* * dt;
                v.* *= vel_damp;
                h.* *= h_damp;
                h.* = std.math.clamp(h.*, -max_height, max_height);
                v.* = std.math.clamp(v.*, -max_vel, max_vel);
                h_sum += h.*;
                v_sum += v.*;
            }

            // Remove the DC component so a sustained stir ripples around the rest
            // line instead of dragging the whole surface up or down.
            const h_mean = h_sum / n;
            const v_mean = v_sum / n;
            for (&self.height, &self.vel) |*h, *v| {
                h.* -= h_mean;
                v.* -= v_mean;
            }
        }
    }

    /// Disturb the surface around field column `col`: a Gaussian height bump plus
    /// a velocity impulse (a downward "drop" rebounds into travelling ripples).
    pub fn inject(self: *WaterSurface, col: f32, radius_cols: f32, height_strength: f32, vel_strength: f32) void {
        if (@abs(height_strength) < 0.0001 and @abs(vel_strength) < 0.0001) return;
        const r = @max(radius_cols, 0.4);
        const r2 = r * r;
        const c = std.math.clamp(col, 0, @as(f32, @floatFromInt(grid_n - 1)));
        const lo = @max(0, @as(i64, @intFromFloat(@floor(c - r * 3.0))));
        const hi = @min(@as(i64, @intCast(grid_n - 1)), @as(i64, @intFromFloat(@ceil(c + r * 3.0))));
        var i = lo;
        while (i <= hi) : (i += 1) {
            const dx = @as(f32, @floatFromInt(i)) - c;
            const fall = @exp(-(dx * dx) / r2);
            self.height[@intCast(i)] += height_strength * fall;
            self.vel[@intCast(i)] += vel_strength * fall;
        }
    }

    /// Signed surface height at field column `col` (linear interpolation).
    pub fn heightAt(self: *const WaterSurface, col: f32) f32 {
        const c = std.math.clamp(col, 0, @as(f32, @floatFromInt(grid_n - 1)));
        const idx0: usize = @intFromFloat(@floor(c));
        const idx1 = @min(idx0 + 1, grid_n - 1);
        const t = c - @as(f32, @floatFromInt(idx0));
        return std.math.lerp(self.height[idx0], self.height[idx1], t);
    }

    /// Compresses broad swells so crests read steeper at the same peak height.
    const visual_height_gamma: f32 = 1.12;

    fn sharpenVisualHeight(h: f32) f32 {
        if (h <= 0) return 0;
        return std.math.pow(f32, h, visual_height_gamma);
    }

    /// Visual height for drawing: |h| so crests always sit above the baseline.
    /// Left scroll drives mostly negative h in simulation; right scroll positive —
    /// taking the magnitude mirrors the look without clamping either to zero.
    pub fn visualHeightAt(self: *const WaterSurface, col: f32) f32 {
        return sharpenVisualHeight(@abs(self.heightAt(col)));
    }

    /// Slope of the sharpened visual surface — keeps horizontal refraction aligned
    /// with the displayed ripple direction in both scroll orientations.
    pub fn visualSlopeAt(self: *const WaterSurface, col: f32) f32 {
        const c = std.math.clamp(col, 0.45, @as(f32, @floatFromInt(grid_n - 1)) - 0.45);
        return (self.visualHeightAt(c + 0.45) - self.visualHeightAt(c - 0.45)) * 0.98;
    }

    /// Signed slope of the simulation field (internal / energy).
    pub fn slopeAt(self: *const WaterSurface, col: f32) f32 {
        const c = std.math.clamp(col, 1, @as(f32, @floatFromInt(grid_n - 2)));
        const idx0: usize = @intFromFloat(@floor(c));
        const t = c - @as(f32, @floatFromInt(idx0));
        const s0 = self.height[idx0 + 1] - self.height[idx0 - 1];
        const s1 = self.height[@min(idx0 + 2, grid_n - 1)] - self.height[idx0];
        return std.math.lerp(s0, s1, t) * 0.5;
    }

    /// Mean per-cell disturbance — used to stop refreshing once the water settles.
    /// Normalised by cell count so the settle threshold is grid-size independent.
    pub fn energy(self: *const WaterSurface) f32 {
        var e: f32 = 0;
        for (self.height, self.vel) |h, v| e += @abs(h) + @abs(v) * 0.1;
        return e / @as(f32, @floatFromInt(grid_n));
    }
};
