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
    pub const wavelength: f32 = 72;
    pub const depth: f32 = 6;
    /// Points per millisecond the ring runs out at, how quickly it dies away, and when it is
    /// gone. Slow enough to be watched crossing a pane: a ripple over in a blink reads as a
    /// flicker, not as water.
    pub const speed: f32 = 0.32;
    pub const decay_ms: f32 = 700;
    pub const life_ms: f32 = 2200;
    /// How much a trough darkens the glass under it, of its own colour — the ring is seen by its
    /// shading as much as by how it bends a blur that has little in it to bend.
    pub const shade: f32 = 0.10;
    /// Points in from the rim a ripple reaches: it moves the edge of the glass, like the lip of
    /// a drop, and leaves the middle still — a ring through the middle of a blur has nothing to
    /// bend but the mesh, and shows its triangles.
    pub const band: f32 = 28;

    fn age(self: Wave, now: i128) f32 {
        return @as(f32, @floatFromInt(now - self.start_ns)) / std.time.ns_per_ms;
    }

    /// Still running at `now` — the caller keeps frames coming while any wave is.
    pub fn live(self: Wave, now: i128) bool {
        if (self.start_ns == 0 or self.amount <= 0.001) return false;
        const t = self.age(now);
        return t >= 0 and t < life_ms;
    }

    /// The surface at `p`, at `now`: -1 (a trough) to 1 (a crest), already damped, and 0 where
    /// the ring has not reached yet or has long passed.
    pub fn height(self: Wave, p: dvui.Point.Physical, now: i128, scale: f32) f32 {
        if (!self.live(now)) return 0;
        const t = self.age(now);
        const dx = p.x - self.origin.x;
        const dy = p.y - self.origin.y;
        const d = @sqrt(dx * dx + dy * dy);
        const lambda = wavelength * scale;
        const behind = speed * scale * t - d;
        if (behind < 0) return 0;
        // A soft packet a wavelength or so long, not a sharp front: rises, swings once, settles.
        const x = behind / lambda;
        const crest = @sin(x * std.math.tau) * @exp(-(x - 0.6) * (x - 0.6) / 0.5);
        return self.amount * @exp(-t / decay_ms) * crest;
    }

    /// How far, in physical pixels and along the ring, the glass at `p` is bent at `now`.
    pub fn bend(self: Wave, p: dvui.Point.Physical, now: i128, scale: f32) dvui.Point.Physical {
        const h = self.height(p, now, scale);
        if (h == 0) return .{};
        const dx = p.x - self.origin.x;
        const dy = p.y - self.origin.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d < 0.5) return .{};
        const a = depth * scale * h;
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
    /// Whether the waves bend what the glass shows here, or only shade it. False when they
    /// already bent the picture before it was blurred (`Warp`) — the better place for it.
    waves_bend: bool = true,
    /// The same picture before it was blurred, covering the same bounds, when there is one
    /// (`BlurBackdrop.sharpTexture`). The rim shows it, refracted: see `edge_band`.
    sharp: ?dvui.Texture = null,
};

/// Points: how far in from the rim the sharp picture shows through, how strongly it shows at the
/// rim, and how far in the rim reaches for it. Refraction you can see: a lens bending a blur
/// bends nothing much — there is little in a blur to bend — but the edge of a thick glass shows
/// what is behind it clearly and pulled out of place, and the middle frosted.
pub const edge_band: f32 = 18;
pub const edge_clarity: f32 = 0.7;
pub const edge_reach: f32 = 16;

/// Ripples bent into a picture *before* it is blurred: the blur then softens the bend the way
/// water softens what is seen through it, where bending the finished blur shows every triangle
/// of the mesh doing it. Only near the rims of `panes` — a ripple moves the lip of the glass
/// and leaves its middle still. `BlurBackdrop` applies it while copying the frame into the
/// picture it blurs.
pub const Warp = struct {
    pub const max_waves = 12;
    pub const max_panes = 6;
    waves: [max_waves]Wave = undefined,
    wave_count: usize = 0,
    panes: [max_panes]dvui.Rect.Physical = undefined,
    pane_count: usize = 0,
    now: i128 = 0,
    scale: f32 = 1,

    pub fn addWave(self: *Warp, w: Wave) void {
        if (self.wave_count == max_waves or !w.live(self.now)) return;
        self.waves[self.wave_count] = w;
        self.wave_count += 1;
    }

    pub fn addPane(self: *Warp, r: dvui.Rect.Physical) void {
        if (self.pane_count == max_panes) return;
        self.panes[self.pane_count] = r;
        self.pane_count += 1;
    }

    /// Anything to bend: a wave still running, over some pane.
    pub fn live(self: *const Warp) bool {
        return self.wave_count > 0 and self.pane_count > 0;
    }

    /// Where the picture at `p` (window pixels) is read from.
    fn source(self: *const Warp, p: dvui.Point.Physical) dvui.Point.Physical {
        var e: f32 = 0;
        const band_px = Wave.band * self.scale;
        for (self.panes[0..self.pane_count]) |r| {
            if (!r.contains(p)) continue;
            const d = @min(@min(p.x - r.x, r.x + r.w - p.x), @min(p.y - r.y, r.y + r.h - p.y));
            const k = std.math.clamp(1 - d / band_px, 0, 1);
            e = @max(e, k * k * (3 - 2 * k));
        }
        if (e <= 0.001) return p;
        var q = p;
        for (self.waves[0..self.wave_count]) |w| {
            const off = w.bend(p, self.now, self.scale);
            q.x -= off.x * e;
            q.y -= off.y * e;
        }
        return q;
    }
};

/// Copy `rect` (window pixels) of `src` — a picture of the window whose top-left sits at
/// `src_origin` — onto `dest`, bent by `warp`. A grid fine enough for the bend to read as a
/// curve once blurred; only drawn while a wave runs.
pub fn drawWarped(src: dvui.Texture, src_origin: dvui.Point.Physical, rect: dvui.Rect.Physical, dest: dvui.Rect.Physical, warp: *const Warp) void {
    const sw: f32 = @floatFromInt(src.width);
    const sh: f32 = @floatFromInt(src.height);
    if (sw < 1 or sh < 1 or dest.w < 1 or dest.h < 1) return;
    const cell = 12.0;
    // Capped so the grid's vertices fit a 16-bit index.
    const cols: usize = @intFromFloat(std.math.clamp(@ceil(dest.w / cell), 1, 150));
    const rows: usize = @intFromFloat(std.math.clamp(@ceil(dest.h / cell), 1, 150));
    const arena = dvui.currentWindow().arena();
    var b = dvui.Triangles.Builder.init(arena, (cols + 1) * (rows + 1), cols * rows * 6) catch return;
    defer b.deinit(arena);
    const col = dvui.Color.PMA.fromColor(.white);
    for (0..rows + 1) |j| {
        const v = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(rows));
        for (0..cols + 1) |i| {
            const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(cols));
            const at: dvui.Point.Physical = .{ .x = rect.x + rect.w * u, .y = rect.y + rect.h * v };
            const q = warp.source(at);
            b.appendVertex(.{
                .pos = .{ .x = dest.x + dest.w * u, .y = dest.y + dest.h * v },
                .col = col,
                .uv = .{ (q.x - src_origin.x) / sw, (q.y - src_origin.y) / sh },
            });
        }
    }
    const Index = dvui.Vertex.Index;
    const stride: Index = @intCast(cols + 1);
    for (0..rows) |j| {
        for (0..cols) |i| {
            const a: Index = @intCast(j * (cols + 1) + i);
            // Wound as dvui winds a rect's fill: down, across, up.
            b.appendTriangles(&.{ a, a + stride, a + stride + 1, a, a + stride + 1, a + 1 });
        }
    }
    dvui.renderTriangles(b.build_unowned(), src) catch {};
}

/// Whether `look` bends anything at all — when it does not, a flat textured rect is the same
/// picture for a fraction of the work.
pub fn bends(look: Look) bool {
    if (look.lens > 0.001) return true;
    for (look.waves) |w| if (w.live(look.now)) return true;
    return false;
}

/// Lay `tex` — a picture of `tex_bounds` — down over `r` with rounded corners of `radius_px`,
/// bent per `look`, every vertex coloured `mod` (the frost half of a frost/tint mix). Drawn as
/// rings of vertices from the rim in to the centre, close together through the lens band and the
/// band a ripple moves.
///
/// **Only as many vertices as the bend needs.** The lens pushes each ring straight in along its
/// own normal, which is constant along a straight side, so at rest a pane is its corners' arcs
/// and a handful of rings round the rim — some 170 vertices. Only while a ripple runs along the
/// rim does it take two more rings and sides cut into steps. Every vertex is copied into the GPU's buffer each frame, and a mesh ten
/// times this was a quarter of a dragged frame.
pub fn drawPane(tex: dvui.Texture, tex_bounds: dvui.Rect.Physical, r: dvui.Rect.Physical, radius_px: f32, scale: f32, mod: dvui.Color, look: Look) void {
    const half = @min(r.w, r.h) / 2;
    if (half < 1 or tex_bounds.w < 1 or tex_bounds.h < 1) return;
    const s = scale;
    var rippling = false;
    for (look.waves) |w| {
        if (w.live(look.now)) rippling = true;
    }
    var insets_buf: [16]f32 = undefined;
    var rings: usize = 0;
    for ([_]f32{ 0, 1.5, 4, 8, 13 }) |d| {
        const px = d * s;
        if (px < half * 0.95) {
            insets_buf[rings] = px;
            rings += 1;
        }
    }
    if (rippling) {
        // Through the band a ripple moves, and no further: the middle stays still.
        for ([_]f32{ 19, Wave.band }) |d| {
            const px = d * s;
            if (px < half * 0.95 and px > insets_buf[rings - 1] + 2 * s) {
                insets_buf[rings] = px;
                rings += 1;
            }
        }
    }
    const insets = insets_buf[0..rings];

    // One ring's worth of points: each corner an arc; each straight side cut into steps while a
    // ripple runs along it, one segment otherwise.
    const arc_steps = 6;
    const step_px = 28 * s;
    const side_x: usize = if (!rippling) 1 else @intFromFloat(@max(1, @ceil(@max(0, r.w - 2 * radius_px) / step_px)));
    const side_y: usize = if (!rippling) 1 else @intFromFloat(@max(1, @ceil(@max(0, r.h - 2 * radius_px) / step_px)));
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
    const seen_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const ctx: Sampler = .{ .bounds = tex_bounds, .scale = s, .look = look };

    // Each ring shows what lies further in, by the lens's reach at its inset: the same ring
    // pushed in along its normal, point for point. The fringe (the rim pushed out half a pixel,
    // clear, so the edge is smooth) shows what the rim does.
    const fringe_d = -0.5 * s;
    ringPoints(ring_pts, r, radius_px, fringe_d, arc_steps, side_x, side_y);
    ringPoints(seen_pts, r, radius_px, ctx.reach(0), arc_steps, side_x, side_y);
    for (ring_pts, seen_pts) |p, q| b.appendVertex(.{ .pos = p, .col = clear, .uv = ctx.uvAt(p, q, 1) });
    for (insets) |d| {
        ringPoints(ring_pts, r, radius_px, d, arc_steps, side_x, side_y);
        ringPoints(seen_pts, r, radius_px, d + ctx.reach(d), arc_steps, side_x, side_y);
        const edge = ctx.edge(d);
        for (ring_pts, seen_pts) |p, q| b.appendVertex(.{ .pos = p, .col = ctx.shaded(col, p, edge), .uv = ctx.uvAt(p, q, edge) });
    }
    const c = r.center();
    b.appendVertex(.{ .pos = c, .col = col, .uv = ctx.uvAt(c, c, 0) });

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

    if (look.sharp) |sharp| drawEdge(sharp, tex_bounds, r, radius_px, scale, mod, look);
}

/// The rim band of `r` drawn from the unblurred picture, refracted — pulled in toward the middle
/// by `edge_reach`, most at the rim — and fading out across `edge_band`, over the frost. Drawn
/// at the frost's weight (`mod`), so it takes the same tint and lift afterwards.
fn drawEdge(sharp: dvui.Texture, tex_bounds: dvui.Rect.Physical, r: dvui.Rect.Physical, radius_px: f32, scale: f32, mod: dvui.Color, look: Look) void {
    const half = @min(r.w, r.h) / 2;
    const band_px = @min(edge_band * scale, half * 0.9);
    if (band_px < 2 or look.lens <= 0.01) return;
    const insets = [_]f32{ 0, 0.2, 0.45, 0.7, 1.0 };
    const arc_steps = 6;
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    var b = dvui.Triangles.Builder.init(arena, per_ring * insets.len, per_ring * 6 * (insets.len - 1)) catch return;
    defer b.deinit(arena);
    const ring_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const seen_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const weight: f32 = @as(f32, @floatFromInt(mod.a)) / 255;
    for (insets) |f| {
        const d = band_px * f;
        const k = 1 - f;
        const reach = edge_reach * scale * look.lens * k * k;
        ringPoints(ring_pts, r, radius_px, d, arc_steps, 1, 1);
        ringPoints(seen_pts, r, radius_px, d + reach, arc_steps, 1, 1);
        const a = edge_clarity * look.lens * weight * k * k;
        const col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(a));
        for (ring_pts, seen_pts) |p, q| b.appendVertex(.{ .pos = p, .col = col, .uv = .{
            std.math.clamp((q.x - tex_bounds.x) / tex_bounds.w, 0, 1),
            std.math.clamp((q.y - tex_bounds.y) / tex_bounds.h, 0, 1),
        } });
    }
    const n: dvui.Vertex.Index = @intCast(per_ring);
    var k: dvui.Vertex.Index = 0;
    while (k + 1 < insets.len) : (k += 1) {
        const outer = k * n;
        const inner = (k + 1) * n;
        var i: dvui.Vertex.Index = 0;
        while (i < n) : (i += 1) {
            const j = (i + 1) % n;
            b.appendTriangles(&.{ outer + i, outer + j, inner + i, outer + j, inner + j, inner + i });
        }
    }
    dvui.renderTriangles(b.build_unowned(), sharp) catch {};
}

/// Where in the texture the glass at a point shows.
const Sampler = struct {
    bounds: dvui.Rect.Physical,
    scale: f32,
    look: Look,

    /// How far in, in physical pixels, the lens reaches for what a ring `inset_px` from the rim
    /// shows: all of `lens_reach` at the rim, easing to nothing across the band.
    fn reach(self: Sampler, inset_px: f32) f32 {
        const band_px = lens_band * self.scale;
        if (self.look.lens <= 0.001 or inset_px >= band_px) return 0;
        const k = 1 - @max(0, inset_px) / band_px;
        return lens_reach * self.scale * self.look.lens * k * k;
    }

    /// How much a ripple moves the glass `inset_px` in from the rim: all of it at the rim, eased
    /// to none across `Wave.band`.
    fn edge(self: Sampler, inset_px: f32) f32 {
        const band_px = Wave.band * self.scale;
        const k = std.math.clamp(1 - inset_px / band_px, 0, 1);
        return k * k * (3 - 2 * k);
    }

    /// `col` darkened where a trough of a passing ripple is at `p`, by `edge` of it. Only
    /// darkened: the colour is premultiplied at the frost's own weight, which is already as
    /// bright as it can be.
    fn shaded(self: Sampler, col: dvui.Color.PMA, p: dvui.Point.Physical, edge_k: f32) dvui.Color.PMA {
        if (edge_k <= 0.001) return col;
        var h: f32 = 0;
        for (self.look.waves) |w| h += w.height(p, self.look.now, self.scale);
        if (h >= 0) return col;
        const k = 1 - Wave.shade * edge_k * @min(1, -h);
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(col.r)) * k),
            .g = @intFromFloat(@as(f32, @floatFromInt(col.g)) * k),
            .b = @intFromFloat(@as(f32, @floatFromInt(col.b)) * k),
            .a = col.a,
        };
    }

    /// The glass at `p` shows `seen` — `p` pushed in by the lens — moved by `edge` of any
    /// ripple going by.
    fn uvAt(self: Sampler, p: dvui.Point.Physical, seen: dvui.Point.Physical, edge_k: f32) @Vector(2, f32) {
        var q = seen;
        if (edge_k > 0.001 and self.look.waves_bend) {
            for (self.look.waves) |w| {
                const off = w.bend(p, self.look.now, self.scale);
                q.x -= off.x * edge_k;
                q.y -= off.y * edge_k;
            }
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
