//! Frosted glass with a bevelled edge.
//!
//! A frost is a blurred picture of what is under a pane. Laid down as a flat textured rect it is
//! a sheet of paper; laid down as a mesh whose texture coordinates follow the shape of a glass
//! slab, it is glass. The slab here is flat across the middle and rounds off at its rim — a
//! **bevel** a few points wide that follows the pane's corners, so a rounded corner is a rounded
//! bevel. Three things make the bevel read as one:
//!
//!   * **refraction** — looking down through a sloped surface, a ray bends inward, so the bevel
//!     shows what lies further in, pulled out toward the rim. How far follows the slope of the
//!     bevel's profile (a quarter circle): most at the very edge, where the glass is steepest,
//!     and none where it has flattened out. That profile, not a fixed band, is what keeps the
//!     edge from looking like a strip laid on the frost;
//!   * **clarity** — the bevel is clearer than the frosted face, so it shows the picture before
//!     the blur (`Look.sharp`) blended in along the same profile;
//!   * **light** — the bevel catches light from the top left, and a dimmer reflection on the far
//!     side, drawn with the pane's lift in one pass after its tint (`drawLift`).
//!
//! How much of it is the caller's (`Look.lens`): the app scales it by `core.motion.liquid`, so
//! the glass is flat when motion is off.
const std = @import("std");
const dvui = @import("dvui");

/// Points: how wide the bevel is, and how far in, at the very rim, it reaches for what it shows
/// (times `Look.refraction`).
pub const bevel: f32 = 22;
pub const refraction: f32 = 16;
/// How much of the unblurred picture the bevel shows at its steepest, 0…1.
pub const clarity: f32 = 0.4;

/// How one pane of glass looks.
pub const Look = struct {
    /// 0…1: the bevel's refraction, clarity and light.
    lens: f32 = 1,
    /// How far the bevel refracts, times `refraction`: the user's dialog refraction setting,
    /// 0 (none) to 2.
    refraction: f32 = 1,
    /// The same picture before it was blurred, covering the same bounds, when there is one
    /// (`BlurBackdrop.sharpTexture`): what the clearer bevel shows.
    sharp: ?dvui.Texture = null,
};

/// Whether `look` bends anything at all — when it does not, a flat textured rect is the same
/// picture for a fraction of the work.
pub fn bends(look: Look) bool {
    return look.lens > 0.001;
}

/// Where across the bevel the rings of a pane sit, as fractions of its width: close together at
/// the rim, where the slope changes fastest. Few: every vertex is copied to the GPU each frame,
/// for every pane of glass on screen.
const bevel_steps = [_]f32{ 0, 0.05, 0.14, 0.3, 0.55, 1.0 };
/// Segments in a corner's arc. The app's corners are small; more buys nothing visible.
const arc_steps = 4;

/// The bevel's slope `x` of the way in from the rim (0 at the rim, 1 where it is flat), as a
/// fraction of the steepest it gets: a rounded profile, steepest at the rim and easing to flat
/// with no corner where it meets the face — a spike at the rim read as a line drawn on the glass,
/// not a curve in it.
pub fn slope(x: f32) f32 {
    const u = 1 - std.math.clamp(x, 0, 1);
    return u * u * (3 - 2 * u) * u;
}

/// One ring of the bevel `d` in from the rim. Every ring keeps the corner's own radius, so a
/// rounded corner is a rounded bevel all the way in rather than sharpening to a point, as a plain
/// inset outline would past its radius.
fn ring(out: []dvui.Point.Physical, r: dvui.Rect.Physical, radius_px: f32, d: f32) void {
    ringPoints(out, r, radius_px + @max(0, d), d, arc_steps, 1, 1);
}

/// Lay `tex` — a picture of `tex_bounds` — down over `r` with rounded corners of `radius_px`,
/// every vertex coloured `mod` (the frost half of a frost/tint mix), bent through the bevel per
/// `look`. Rings of vertices across the bevel and a fan over the flat middle: the bevel pushes
/// each ring straight in along its own normal, which is constant along a straight side, so a
/// pane is its corners' arcs times a handful of rings — some 120 vertices, whatever its size.
pub fn drawPane(tex: dvui.Texture, tex_bounds: dvui.Rect.Physical, r: dvui.Rect.Physical, radius_px: f32, scale: f32, mod: dvui.Color, look: Look) void {
    const half = @min(r.w, r.h) / 2;
    if (half < 1 or tex_bounds.w < 1 or tex_bounds.h < 1) return;
    const band_px = @min(bevel * scale, half * 0.9);

    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    // The fringe, the rings across the bevel, and the centre.
    const rings = bevel_steps.len;
    const vtx_count = per_ring * (rings + 1) + 1;
    const idx_count = per_ring * 6 * rings + per_ring * 3;
    var b = dvui.Triangles.Builder.init(arena, vtx_count, idx_count) catch return;
    defer b.deinit(arena);

    const col = dvui.Color.PMA.fromColor(mod);
    const clear = dvui.Color.PMA.fromColor(.transparent);
    const ring_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const seen_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const reach_px = refraction * scale * look.lens * look.refraction;

    // The fringe: the rim pushed out half a pixel, clear, so the edge is smooth. It shows what
    // the rim does.
    ring(ring_pts, r, radius_px, -0.5 * scale);
    ring(seen_pts, r, radius_px, reach_px * slope(0));
    for (ring_pts, seen_pts) |p, q| b.appendVertex(.{ .pos = p, .col = clear, .uv = uvOf(q, tex_bounds) });
    for (bevel_steps) |x| {
        const d = band_px * x;
        ring(ring_pts, r, radius_px, d);
        ring(seen_pts, r, radius_px, d + reach_px * slope(x));
        for (ring_pts, seen_pts) |p, q| b.appendVertex(.{ .pos = p, .col = col, .uv = uvOf(q, tex_bounds) });
    }
    const c = r.center();
    b.appendVertex(.{ .pos = c, .col = col, .uv = uvOf(c, tex_bounds) });
    appendRingStrips(&b, per_ring, rings + 1);
    const n: dvui.Vertex.Index = @intCast(per_ring);
    const last: dvui.Vertex.Index = @intCast(rings * per_ring);
    const center_idx: dvui.Vertex.Index = @intCast(vtx_count - 1);
    var i: dvui.Vertex.Index = 0;
    while (i < n) : (i += 1) b.appendTriangles(&.{ center_idx, last + i, last + (i + 1) % n });
    dvui.renderTriangles(b.build_unowned(), tex) catch {};

    if (look.sharp) |sharp| drawClear(sharp, tex_bounds, r, radius_px, scale, mod, look, band_px);
}

/// The bevel's clearer glass: the unblurred picture over it, refracted the same way, as much of
/// it as the bevel is steep. Drawn at the frost's weight (`mod`), so it takes the pane's tint and
/// lift afterwards like the frost does.
fn drawClear(sharp: dvui.Texture, tex_bounds: dvui.Rect.Physical, r: dvui.Rect.Physical, radius_px: f32, scale: f32, mod: dvui.Color, look: Look, band_px: f32) void {
    if (band_px < 2) return;
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    var b = dvui.Triangles.Builder.init(arena, per_ring * bevel_steps.len, per_ring * 6 * (bevel_steps.len - 1)) catch return;
    defer b.deinit(arena);
    const ring_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const seen_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const weight: f32 = @as(f32, @floatFromInt(mod.a)) / 255;
    const reach_px = refraction * scale * look.lens * look.refraction;
    for (bevel_steps) |x| {
        const d = band_px * x;
        ring(ring_pts, r, radius_px, d);
        ring(seen_pts, r, radius_px, d + reach_px * slope(x));
        // Square-rooted, so the clear glass eases in across the bevel rather than sitting in a
        // thin line at the rim where the slope is steepest.
        const a = clarity * look.lens * weight * @sqrt(slope(x));
        const col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(a));
        for (ring_pts, seen_pts) |p, q| b.appendVertex(.{ .pos = p, .col = col, .uv = uvOf(q, tex_bounds) });
    }
    appendRingStrips(&b, per_ring, bevel_steps.len);
    dvui.renderTriangles(b.build_unowned(), sharp) catch {};
}

/// The white a pane of glass adds over its tint — its `lift`, the whole pane — and the light its
/// bevel catches on top: brightest where it faces the top left and is steep, a dimmer reflection
/// on the side facing away, `amount` of it. One pass for both. `light` is a white texture that
/// adds (`BlurBackdrop.additiveWhite`); draw this after the tint, so it stays white.
pub fn drawLift(light: dvui.Texture, r: dvui.Rect.Physical, radius_px: f32, scale: f32, lift: f32, amount: f32) void {
    if (lift <= 0.002 and amount <= 0.01) return;
    const half = @min(r.w, r.h) / 2;
    if (half < 1) return;
    const band_px = @min(bevel * scale, half * 0.9);
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    const rings = bevel_steps.len;
    const vtx_count = per_ring * (rings + 1) + 1;
    var b = dvui.Triangles.Builder.init(arena, vtx_count, per_ring * 6 * rings + per_ring * 3) catch return;
    defer b.deinit(arena);
    const ring_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const inner_pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const clear = dvui.Color.PMA.fromColor(.transparent);
    // The fringe, clear, so the edge is smooth.
    ring(ring_pts, r, radius_px, -0.5 * scale);
    for (ring_pts) |p| b.appendVertex(.{ .pos = p, .col = clear, .uv = .{ 0.5, 0.5 } });
    // Up and to the left, as a window's light usually is.
    const lx: f32 = -0.45;
    const ly: f32 = -0.89;
    for (bevel_steps) |x| {
        const d = band_px * x;
        ring(ring_pts, r, radius_px, d);
        // A pixel further in along the true inset outline, whose arcs share the ring's centres,
        // so the normal at a corner points straight out from it.
        ringPoints(inner_pts, r, radius_px + d, d + scale, arc_steps, 1, 1);
        const s = std.math.pow(f32, slope(x), 0.7);
        for (ring_pts, inner_pts) |p, q| {
            // The bevel's outward normal here: from a point a pixel further in, out to this one.
            var nx = p.x - q.x;
            var ny = p.y - q.y;
            const len = @sqrt(nx * nx + ny * ny);
            if (len > 0.0001) {
                nx /= len;
                ny /= len;
            }
            const facing = nx * lx + ny * ly;
            const lit = 0.22 * @max(0, facing) + 0.08 * @max(0, -facing);
            const col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(std.math.clamp(lift + amount * s * lit, 0, 1)));
            b.appendVertex(.{ .pos = p, .col = col, .uv = .{ 0.5, 0.5 } });
        }
    }
    b.appendVertex(.{ .pos = r.center(), .col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(std.math.clamp(lift, 0, 1))), .uv = .{ 0.5, 0.5 } });
    appendRingStrips(&b, per_ring, rings + 1);
    const n: dvui.Vertex.Index = @intCast(per_ring);
    const last: dvui.Vertex.Index = @intCast(rings * per_ring);
    const center_idx: dvui.Vertex.Index = @intCast(vtx_count - 1);
    var i: dvui.Vertex.Index = 0;
    while (i < n) : (i += 1) b.appendTriangles(&.{ center_idx, last + i, last + (i + 1) % n });
    dvui.renderTriangles(b.build_unowned(), light) catch {};
}

/// Quads between `count` neighbouring rings of `per_ring` vertices each, laid down one after
/// another from the outermost, wound the way dvui winds a path's fill.
fn appendRingStrips(b: *dvui.Triangles.Builder, per_ring: usize, count: usize) void {
    const n: dvui.Vertex.Index = @intCast(per_ring);
    var k: usize = 0;
    while (k + 1 < count) : (k += 1) {
        const outer: dvui.Vertex.Index = @intCast(k * per_ring);
        const inner: dvui.Vertex.Index = @intCast((k + 1) * per_ring);
        var i: dvui.Vertex.Index = 0;
        while (i < n) : (i += 1) {
            const j = (i + 1) % n;
            b.appendTriangles(&.{ outer + i, outer + j, inner + i, outer + j, inner + j, inner + i });
        }
    }
}

fn uvOf(q: dvui.Point.Physical, bd: dvui.Rect.Physical) @Vector(2, f32) {
    return .{
        std.math.clamp((q.x - bd.x) / bd.w, 0, 1),
        std.math.clamp((q.y - bd.y) / bd.h, 0, 1),
    };
}

/// The points of one ring: `r`'s rounded outline pushed in by `d` (out, when negative), from the
/// top-left corner down the left side, along the bottom, up the right and back along the top —
/// the order dvui's own paths run (`Path.Builder.addRect`). A ring pushed in past the corner
/// radius keeps a point of a corner, as the inside of a rounded outline does.
pub fn ringPoints(out: []dvui.Point.Physical, r: dvui.Rect.Physical, radius: f32, d: f32, comptime steps_per_arc: usize, side_x: usize, side_y: usize) void {
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
        while (k <= steps_per_arc) : (k += 1) {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps_per_arc));
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
