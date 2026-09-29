//! Frosted glass that bends what it shows.
//!
//! A frost is a blurred picture of what is under a pane. Laid down as a flat textured rect it
//! is a sheet of paper; laid down as a mesh whose texture coordinates are pulled around, it is
//! glass: a **lens** at the rim, where the pane reaches in for what it shows at its very edge so
//! the border magnifies the way a thick edge does, and **ripples** running through it, which
//! bend the blur along a ring the way the sprite shelf's water bends its reflections. A thin
//! **rim** of light finishes the edge.
//!
//! How much of each is the caller's (`Look`): the app scales the lens by `core.motion.liquid`
//! and the ripples by `core.motion.playful`, so the glass is flat when motion is off and
//! only ripples when it is playful.
const std = @import("std");
const dvui = @import("dvui");

/// A ripple through the glass: a ring running out from `origin`, a couple of crests deep, dying
/// away. It moves what the glass shows, not the glass: a crest bends the blur under it outward
/// along the ring, so the frost wobbles as the wave goes by.
pub const Wave = struct {
    origin: dvui.Point.Physical = .{},
    /// Frame time the ring left `origin`. Zero: no wave.
    start_ns: i128 = 0,
    /// 0…1: how far it bends, of the most it can.
    amount: f32 = 1,

    /// Points: the distance between crests, and how far the glass bends at the first.
    pub const wavelength: f32 = 34;
    pub const depth: f32 = 5;
    /// Points per millisecond the ring runs out at, how quickly it dies away, and when it is gone.
    pub const speed: f32 = 0.85;
    pub const decay_ms: f32 = 240;
    pub const life_ms: f32 = 900;

    fn age(self: Wave, now: i128) f32 {
        return @as(f32, @floatFromInt(now - self.start_ns)) / std.time.ns_per_ms;
    }

    /// Still running at `now` — the caller keeps frames coming while any wave is.
    pub fn live(self: Wave, now: i128) bool {
        if (self.start_ns == 0 or self.amount <= 0.001) return false;
        const t = self.age(now);
        return t >= 0 and t < life_ms;
    }

    /// How far, in physical pixels and along the ring, the glass at `p` is bent at `now`.
    pub fn bend(self: Wave, p: dvui.Point.Physical, now: i128, scale: f32) dvui.Point.Physical {
        if (!self.live(now)) return .{};
        const t = self.age(now);
        const dx = p.x - self.origin.x;
        const dy = p.y - self.origin.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d < 0.5) return .{};
        const lambda = wavelength * scale;
        const behind = speed * scale * t - d;
        if (behind < 0) return .{};
        const crest = @sin(behind / lambda * std.math.tau) * @exp(-behind / lambda);
        const a = depth * scale * self.amount * @exp(-t / decay_ms) * crest;
        return .{ .x = dx / d * a, .y = dy / d * a };
    }
};

/// Points: how wide the lens band at a pane's rim is, and how far in it reaches for what it
/// shows at the very edge.
pub const lens_band: f32 = 16;
pub const lens_reach: f32 = 9;

/// How one pane of glass bends.
pub const Look = struct {
    /// 0…1: the lens at the rim.
    lens: f32 = 1,
    /// The ripples running through it.
    waves: []const Wave = &.{},
    /// Frame time the waves are read at.
    now: i128 = 0,
};

/// Whether `look` bends anything at all — when it does not, a flat textured rect is the same
/// picture for a fraction of the work.
pub fn bends(look: Look) bool {
    if (look.lens > 0.001) return true;
    for (look.waves) |w| if (w.live(look.now)) return true;
    return false;
}

/// Lay `tex` — a picture of `tex_bounds` — down over `r` with rounded corners of `radius_px`,
/// bent per `look`, every vertex coloured `mod` (the frost half of a frost/tint mix). Drawn as
/// rings of vertices from the rim in to the centre: close together through the lens band, then
/// spread out so a ripple has vertices to move.
pub fn drawPane(tex: dvui.Texture, tex_bounds: dvui.Rect.Physical, r: dvui.Rect.Physical, radius_px: f32, scale: f32, mod: dvui.Color, look: Look) void {
    const half = @min(r.w, r.h) / 2;
    if (half < 1 or tex_bounds.w < 1 or tex_bounds.h < 1) return;
    const s = scale;
    var insets_buf: [16]f32 = undefined;
    var rings: usize = 0;
    for ([_]f32{ 0, 1.5, 4, 8, 13 }) |d| {
        const px = d * s;
        if (px < half * 0.95) {
            insets_buf[rings] = px;
            rings += 1;
        }
    }
    for ([_]f32{ 0.25, 0.45, 0.65, 0.82, 0.95 }) |f| {
        const px = half * f;
        if (px > insets_buf[rings - 1] + 2 * s) {
            insets_buf[rings] = px;
            rings += 1;
        }
    }
    const insets = insets_buf[0..rings];

    // One ring's worth of points: each corner an arc, each straight side cut into steps so a
    // ripple along it has somewhere to show.
    const arc_steps = 6;
    const step_px = 22 * s;
    const side_x: usize = @intFromFloat(@max(1, @ceil(@max(0, r.w - 2 * radius_px) / step_px)));
    const side_y: usize = @intFromFloat(@max(1, @ceil(@max(0, r.h - 2 * radius_px) / step_px)));
    const per_ring = 4 * (arc_steps + 1) + 2 * (side_x - 1) + 2 * (side_y - 1);

    const arena = dvui.currentWindow().arena();
    // Rings, the anti-aliasing fringe outside the rim, and the centre.
    const vtx_count = per_ring * (rings + 1) + 1;
    const idx_count = per_ring * 6 * rings + per_ring * 3;
    var b = dvui.Triangles.Builder.init(arena, vtx_count, idx_count) catch return;
    defer b.deinit(arena);

    const col = dvui.Color.PMA.fromColor(mod);
    const clear = dvui.Color.PMA.fromColor(.transparent);
    const ring_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const ctx: Sampler = .{ .bounds = tex_bounds, .rect = r, .scale = s, .look = look };

    // The fringe: the rim pushed out half a pixel, clear, so the edge is smooth.
    ringPoints(ring_pts, r, radius_px, -0.5 * s, arc_steps, side_x, side_y);
    for (ring_pts) |p| b.appendVertex(.{ .pos = p, .col = clear, .uv = ctx.uvAt(p, 0) });
    for (insets) |d| {
        ringPoints(ring_pts, r, radius_px, d, arc_steps, side_x, side_y);
        for (ring_pts) |p| b.appendVertex(.{ .pos = p, .col = col, .uv = ctx.uvAt(p, d) });
    }
    const c = r.center();
    b.appendVertex(.{ .pos = c, .col = col, .uv = ctx.uvAt(c, half) });

    // Quads between neighbouring rings, the fringe included, then a fan to the centre, all
    // wound the way dvui winds a path's fill.
    const n: u32 = @intCast(per_ring);
    var k: u32 = 0;
    while (k < rings) : (k += 1) {
        const outer = k * n;
        const inner = (k + 1) * n;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const j = (i + 1) % n;
            b.appendTriangles(&.{
                @intCast(outer + i), @intCast(outer + j), @intCast(inner + i),
                @intCast(outer + j), @intCast(inner + j), @intCast(inner + i),
            });
        }
    }
    const last = rings * n;
    const center_idx: u32 = @intCast(vtx_count - 1);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        b.appendTriangles(&.{ @intCast(center_idx), @intCast(last + i), @intCast(last + (i + 1) % n) });
    }
    dvui.renderTriangles(b.build_unowned(), tex) catch {};
}

/// Where in the texture the glass at a point shows.
const Sampler = struct {
    bounds: dvui.Rect.Physical,
    rect: dvui.Rect.Physical,
    scale: f32,
    look: Look,

    /// The point itself, reached in toward the middle through the lens band (`inset_px` from
    /// the rim), and moved by any ripple going by.
    fn uvAt(self: Sampler, p: dvui.Point.Physical, inset_px: f32) @Vector(2, f32) {
        const s = self.scale;
        var q = p;
        const band_px = lens_band * s;
        if (self.look.lens > 0.001 and inset_px < band_px) {
            const k = 1 - inset_px / band_px;
            const reach = lens_reach * s * self.look.lens * k * k;
            const c = self.rect.center();
            const dx = c.x - p.x;
            const dy = c.y - p.y;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > 0.5) {
                q.x += dx / d * reach;
                q.y += dy / d * reach;
            }
        }
        for (self.look.waves) |w| {
            const off = w.bend(p, self.look.now, s);
            q.x -= off.x;
            q.y -= off.y;
        }
        const bd = self.bounds;
        return .{
            std.math.clamp((q.x - bd.x) / bd.w, 0, 1),
            std.math.clamp((q.y - bd.y) / bd.h, 0, 1),
        };
    }
};

/// A hairline of light around a pane's edge, `alpha` of white — where a thick glass catches it.
pub fn drawRim(r: dvui.Rect.Physical, corners: dvui.CornerRect, scale: f32, alpha: f32) void {
    if (alpha <= 0.01) return;
    var path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
    defer path.deinit();
    path.addRect(r.insetAll(0.5 * scale), corners.scale(scale, dvui.CornerRect.Physical));
    path.build().stroke(.{ .color = .{ .color = dvui.Color.white.opacity(alpha) }, .thickness = @max(1, scale), .closed = true });
}

/// The points of one ring: `r`'s rounded outline pushed in by `d` (out, when negative), from the
/// top-left corner down the left side, along the bottom, up the right and back along the top —
/// the order dvui's own paths run (`Path.Builder.addRect`).
pub fn ringPoints(out: []dvui.Point.Physical, r: dvui.Rect.Physical, radius: f32, d: f32, comptime arc_steps: usize, side_x: usize, side_y: usize) void {
    const x0 = r.x + d;
    const y0 = r.y + d;
    const x1 = r.x + r.w - d;
    const y1 = r.y + r.h - d;
    const rad = std.math.clamp(radius - d, 0.01, @max(0.01, @min(x1 - x0, y1 - y0) / 2));
    const pi = std.math.pi;
    var n: usize = 0;
    const Corner = struct { cx: f32, cy: f32, a0: f32, a1: f32 };
    const corners = [_]Corner{
        .{ .cx = x0 + rad, .cy = y0 + rad, .a0 = 1.5 * pi, .a1 = pi },
        .{ .cx = x0 + rad, .cy = y1 - rad, .a0 = pi, .a1 = 0.5 * pi },
        .{ .cx = x1 - rad, .cy = y1 - rad, .a0 = 0.5 * pi, .a1 = 0 },
        .{ .cx = x1 - rad, .cy = y0 + rad, .a0 = 2 * pi, .a1 = 1.5 * pi },
    };
    for (corners, 0..) |c, ci| {
        var k: usize = 0;
        while (k <= arc_steps) : (k += 1) {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(arc_steps));
            const a = c.a0 + (c.a1 - c.a0) * t;
            out[n] = .{ .x = c.cx + rad * @cos(a), .y = c.cy + rad * @sin(a) };
            n += 1;
        }
        // The straight run to the next corner, cut into steps.
        const next = corners[(ci + 1) % corners.len];
        const from = out[n - 1];
        const to: dvui.Point.Physical = .{ .x = next.cx + rad * @cos(next.a0), .y = next.cy + rad * @sin(next.a0) };
        const steps = if (ci % 2 == 0) side_y else side_x;
        var k2: usize = 1;
        while (k2 < steps) : (k2 += 1) {
            const t = @as(f32, @floatFromInt(k2)) / @as(f32, @floatFromInt(steps));
            out[n] = .{ .x = from.x + (to.x - from.x) * t, .y = from.y + (to.y - from.y) * t };
            n += 1;
        }
    }
    std.debug.assert(n == out.len);
}
