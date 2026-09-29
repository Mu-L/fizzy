//! Frosted glass shaped like a drop of water.
//!
//! A frost is a blurred picture of what is under a pane. Laid down as a flat textured rect it is
//! a sheet of paper; laid down as a mesh whose texture coordinates follow the shape of a drop, it
//! is glass. A drop is flat across the middle and curves down to its rim, so near the rim it
//! **refracts**: it shows what lies a little further in, magnified out toward the edge, most at
//! the edge and fading softly inward. It also catches **light** from the top left there, and a
//! dimmer reflection on the far side (`drawLift`, in one pass with the pane's lift).
//!
//! **One smooth field, not a bevel.** Both come from a soft distance to the pane's edges — the
//! four sides blended, not the nearest one taken — whose gradient turns smoothly round a corner.
//! A bevel of rings, each bent along its own normal, folded along every corner's diagonal like a
//! mitred frame; a band with a fixed profile drew a line where it met the face. The field has no
//! crease anywhere, so neither does the glass.
//!
//! The rim is also **clearer** than the face: the picture before the blur shows through it,
//! bent the same way, strongest at the very edge and fading into the frost with the drop's
//! steepness. (Through a bevel's creases the same picture drew streaks; through a smooth field it
//! is only magnified.)
//!
//! How much of it is the caller's (`Look`): the app scales it by `core.motion.liquid` and the
//! user's dialog refraction, so the glass is flat when motion is off.
const std = @import("std");
const dvui = @import("dvui");

/// Points: how far in, at the very rim, the drop reaches for what it shows (times
/// `Look.refraction`); how far in its curve fades by a factor of e; and how softly its sides blend
/// into each other round a corner.
pub const refraction: f32 = 18;
pub const falloff: f32 = 15;
pub const softness: f32 = 10;
/// How much of the unblurred picture the rim shows at its very edge, 0…1: glass is clearer
/// where it is thin and steep, frosted across its face.
pub const clarity: f32 = 0.55;
/// Points: how far in the mesh keeps rings, beyond which the drop is flat and a fan will do.
const band: f32 = 44;

/// A pane's corner radii in physical pixels, in the order its rings run: top-left, bottom-left,
/// bottom-right, top-right. Per corner, so a pane can be square where it meets another and
/// round where it does not (a drop zone splitting from a solid pane).
pub const Radii = [4]f32;

pub fn uniform(radius: f32) Radii {
    return @splat(radius);
}

/// How one pane of glass looks.
pub const Look = struct {
    /// 0…1: the drop's refraction and light.
    lens: f32 = 1,
    /// How far the drop refracts, times `refraction`: the user's dialog refraction setting,
    /// 0 (none) to 2.
    refraction: f32 = 1,
    /// The same picture before it was blurred, covering the same bounds, when there is one
    /// (`BlurBackdrop.sharpTexture`): what the clearer rim shows (`clarity`).
    sharp: ?dvui.Texture = null,
    /// Switches `tex` between blending over what is under it (true) and its own blend (false)
    /// — `BlurBackdrop.blendOver`. A frost *replaces* what it covers, which is right across its
    /// face and wrong at its edge: the edge's one-pixel fade has to blend onto what is behind,
    /// or it cuts a notch out of it and the curve shows its pixels. Null draws the edge in the
    /// texture's own blend.
    blend_over: ?*const fn (tex: dvui.Texture, over: bool) void = null,
};

/// How much of the glass's edge a frost of blur `radius` has: none on an unblurred pane, all of
/// it by `full_at_blur`. A drop is thick glass; a barely-frosted pane is a thin sheet, and
/// switching the whole rim on at the first step of blur made it pop.
pub fn blurRamp(radius: f32) f32 {
    return std.math.clamp(radius / full_at_blur, 0, 1);
}
pub const full_at_blur: f32 = 20;

/// Whether `look` bends anything at all — when it does not, a flat textured rect is the same
/// picture for a fraction of the work.
pub fn bends(look: Look) bool {
    return look.lens > 0.001;
}

/// Where the rings of a pane sit, as fractions of `band`: closer together at the rim, where the
/// bend changes fastest. Few enough that a pane stays cheap — every vertex is copied to the GPU
/// each frame, for every pane on screen — and enough that the bend between them reads as a curve.
const ring_steps = [_]f32{ 0, 0.05, 0.12, 0.21, 0.33, 0.48, 0.66, 1.0 };
/// Segments in a corner's arc: enough that a corner reads as a curve, not a polygon.
const arc_steps = 8;

/// Physical pixels: the edge fades from solid to clear across one pixel, half inside the outline
/// and half outside — dvui's own anti-aliasing of a rounded fill (`Path.fillConvexTriangles`,
/// `fade = 1`), so glass has the same smooth edge every other rounded surface has, at any scale.
const aa_in: f32 = 0.5;
const aa_out: f32 = 0.5;

/// The drop at a point: which way is out (a smooth blend of the sides' normals, shorter near a
/// corner where two share it), and how steep it is there (1 at the rim, fading inward).
pub const Field = struct {
    out: dvui.Point.Physical,
    steep: f32,
};

/// The drop's field at `p` in pane `r`: a soft minimum of the distances to its four sides —
/// `-k·ln Σ e^(-dᵢ/k)` — so the corners are round and the gradient never turns sharply.
pub fn fieldAt(p: dvui.Point.Physical, r: dvui.Rect.Physical, scale: f32) Field {
    const k = softness * scale;
    const d = [4]f32{ p.x - r.x, r.x + r.w - p.x, p.y - r.y, r.y + r.h - p.y };
    const m = @min(@min(d[0], d[1]), @min(d[2], d[3]));
    var w: [4]f32 = undefined;
    var sum: f32 = 0;
    for (d, 0..) |di, i| {
        // Relative to the nearest side, so the exponentials never underflow deep inside.
        w[i] = @exp(-(di - m) / k);
        sum += w[i];
    }
    const soft = m - k * @log(sum);
    return .{
        .out = .{ .x = (w[1] - w[0]) / sum, .y = (w[3] - w[2]) / sum },
        .steep = @exp(-@max(0, soft) / (falloff * scale)),
    };
}

/// Lay `tex` — a picture of `tex_bounds` — down over `r` with corner radii `radii`, every vertex
/// coloured `mod` (the frost half of a frost/tint mix), bent through the drop per `look`. Rings
/// of vertices through its curve and a fan over the flat middle: a pane is its corners' arcs times
/// a handful of rings, whatever its size.
pub fn drawPane(tex: dvui.Texture, tex_bounds: dvui.Rect.Physical, r: dvui.Rect.Physical, radii: Radii, scale: f32, mod: dvui.Color, look: Look) void {
    const half = @min(r.w, r.h) / 2;
    if (half < 1 or tex_bounds.w < 1 or tex_bounds.h < 1) return;
    const band_px = @min(band * scale, half * 0.9);
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    const col = dvui.Color.PMA.fromColor(mod);
    const clear = dvui.Color.PMA.fromColor(.transparent);
    const pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const reach_px = refraction * scale * look.lens * look.refraction;

    // The face: the rings through the curve, from half a pixel inside the outline, and a fan
    // over the flat middle — in the texture's own blend.
    {
        const rings = ring_steps.len;
        const vtx_count = per_ring * rings + 1;
        var b = dvui.Triangles.Builder.init(arena, vtx_count, per_ring * 6 * (rings - 1) + per_ring * 3) catch return;
        defer b.deinit(arena);
        for (ring_steps) |x| {
            ringPoints(pts, null, r, radii, @max(aa_in, band_px * x), arc_steps, 1, 1);
            for (pts) |p| b.appendVertex(.{ .pos = p, .col = col, .uv = seen(p, r, scale, reach_px, tex_bounds) });
        }
        const c = r.center();
        b.appendVertex(.{ .pos = c, .col = col, .uv = seen(c, r, scale, reach_px, tex_bounds) });
        appendRingStrips(&b, per_ring, rings);
        appendFan(&b, per_ring, rings - 1, vtx_count - 1);
        dvui.renderTriangles(b.build_unowned(), tex) catch {};
    }

    // The edge: solid half a pixel inside the outline to clear half a pixel outside it
    // (`aa_in`, `aa_out`, as dvui fades a rounded fill), blended over what is behind.
    {
        var b = dvui.Triangles.Builder.init(arena, per_ring * 2, per_ring * 6) catch return;
        defer b.deinit(arena);
        ringPoints(pts, null, r, radii, -aa_out, arc_steps, 1, 1);
        for (pts) |p| b.appendVertex(.{ .pos = p, .col = clear, .uv = seen(p, r, scale, reach_px, tex_bounds) });
        ringPoints(pts, null, r, radii, aa_in, arc_steps, 1, 1);
        for (pts) |p| b.appendVertex(.{ .pos = p, .col = col, .uv = seen(p, r, scale, reach_px, tex_bounds) });
        appendRingStrips(&b, per_ring, 2);
        if (look.blend_over) |set| set(tex, true);
        dvui.renderTriangles(b.build_unowned(), tex) catch {};
        if (look.blend_over) |set| set(tex, false);
    }

    if (look.sharp) |sharp| drawClear(sharp, tex_bounds, r, radii, scale, mod, look, band_px);
}

/// The rim's clearer glass: the unblurred picture over the frost, bent the same way, as much of
/// it as `clarity` times the drop's steepness — sharpest at the very edge, gone where the face
/// is flat. Drawn at the frost's weight (`mod`), so it takes the pane's tint and lift afterwards
/// like the frost does.
fn drawClear(sharp: dvui.Texture, tex_bounds: dvui.Rect.Physical, r: dvui.Rect.Physical, radii: Radii, scale: f32, mod: dvui.Color, look: Look, band_px: f32) void {
    // With the refraction setting, up to as designed: a flat edge is a clear one no more.
    const amount = clarity * look.lens * @min(1, look.refraction) * @as(f32, @floatFromInt(mod.a)) / 255;
    if (amount <= 0.01) return;
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    const rings = ring_steps.len;
    var b = dvui.Triangles.Builder.init(arena, per_ring * (rings + 1), per_ring * 6 * rings) catch return;
    defer b.deinit(arena);
    const pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const clear = dvui.Color.PMA.fromColor(.transparent);
    const reach_px = refraction * scale * look.lens * look.refraction;
    ringPoints(pts, null, r, radii, -aa_out, arc_steps, 1, 1);
    for (pts) |p| b.appendVertex(.{ .pos = p, .col = clear, .uv = seen(p, r, scale, reach_px, tex_bounds) });
    for (ring_steps) |x| {
        ringPoints(pts, null, r, radii, @max(aa_in, band_px * x), arc_steps, 1, 1);
        for (pts) |p| {
            const steep = fieldAt(p, r, scale).steep;
            // Squared, so the clear glass hugs the edge and the face stays frosted.
            const col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(amount * steep * steep));
            b.appendVertex(.{ .pos = p, .col = col, .uv = seen(p, r, scale, reach_px, tex_bounds) });
        }
    }
    appendRingStrips(&b, per_ring, rings + 1);
    dvui.renderTriangles(b.build_unowned(), sharp) catch {};
}

/// Where the glass at `p` shows: further in, against the drop's outward direction, by as much of
/// `reach_px` as the drop is steep there.
fn seen(p: dvui.Point.Physical, r: dvui.Rect.Physical, scale: f32, reach_px: f32, bd: dvui.Rect.Physical) @Vector(2, f32) {
    const f = fieldAt(p, r, scale);
    const reach = reach_px * f.steep;
    const q: dvui.Point.Physical = .{ .x = p.x - f.out.x * reach, .y = p.y - f.out.y * reach };
    return .{
        std.math.clamp((q.x - bd.x) / bd.w, 0, 1),
        std.math.clamp((q.y - bd.y) / bd.h, 0, 1),
    };
}

/// The white a pane of glass adds over its tint — its `lift`, the whole pane — and the light its
/// rim catches on top: brightest where it faces the top left, a dimmer reflection on the side
/// facing away, `amount` of it. One pass for both. `light` is a white texture that adds
/// (`BlurBackdrop.additiveWhite`); draw this after the tint, so it stays white.
pub fn drawLift(light: dvui.Texture, r: dvui.Rect.Physical, radii: Radii, scale: f32, lift: f32, amount: f32) void {
    if (lift <= 0.002 and amount <= 0.01) return;
    const half = @min(r.w, r.h) / 2;
    if (half < 1) return;
    const band_px = @min(band * scale, half * 0.9);
    const per_ring = 4 * (arc_steps + 1);
    const arena = dvui.currentWindow().arena();
    const rings = ring_steps.len;
    const vtx_count = per_ring * (rings + 1) + 1;
    var b = dvui.Triangles.Builder.init(arena, vtx_count, per_ring * 6 * rings + per_ring * 3) catch return;
    defer b.deinit(arena);
    const pts = arena.alloc(dvui.Point.Physical, per_ring) catch return;
    const clear = dvui.Color.PMA.fromColor(.transparent);
    ringPoints(pts, null, r, radii, -aa_out, arc_steps, 1, 1);
    for (pts) |p| b.appendVertex(.{ .pos = p, .col = clear, .uv = .{ 0.5, 0.5 } });
    // Up and to the left, as a window's light usually is.
    const lx: f32 = -0.45;
    const ly: f32 = -0.89;
    for (ring_steps) |x| {
        ringPoints(pts, null, r, radii, @max(aa_in, band_px * x), arc_steps, 1, 1);
        for (pts) |p| {
            const f = fieldAt(p, r, scale);
            const facing = f.out.x * lx + f.out.y * ly;
            const lit = 0.20 * @max(0, facing) + 0.07 * @max(0, -facing);
            const col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(std.math.clamp(lift + amount * f.steep * lit, 0, 1)));
            b.appendVertex(.{ .pos = p, .col = col, .uv = .{ 0.5, 0.5 } });
        }
    }
    b.appendVertex(.{ .pos = r.center(), .col = dvui.Color.PMA.fromColor(dvui.Color.white.opacity(std.math.clamp(lift, 0, 1))), .uv = .{ 0.5, 0.5 } });
    appendRingStrips(&b, per_ring, rings + 1);
    appendFan(&b, per_ring, rings, vtx_count - 1);
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

/// A fan from the vertex at `center` to the innermost ring, ring number `ring` counting the
/// fringe as ring 0.
fn appendFan(b: *dvui.Triangles.Builder, per_ring: usize, ring: usize, center: usize) void {
    const n: dvui.Vertex.Index = @intCast(per_ring);
    const last: dvui.Vertex.Index = @intCast(ring * per_ring);
    const c: dvui.Vertex.Index = @intCast(center);
    var i: dvui.Vertex.Index = 0;
    while (i < n) : (i += 1) b.appendTriangles(&.{ c, last + i, last + (i + 1) % n });
}

/// The points of one ring: `r` pushed in by `d` (out, when negative) with corner radii `radii` —
/// the ring's own, so every ring of a pane keeps its corners round — from the top-left corner
/// down the left side, along the bottom, up the right and back along the top: the order dvui's
/// own paths run (`Path.Builder.addRect`). `normals`, when given, gets each point's outward unit
/// normal: straight out from its corner's centre on an arc, square to its side on a side.
pub fn ringPoints(out: []dvui.Point.Physical, normals: ?[]dvui.Point.Physical, r: dvui.Rect.Physical, radii: Radii, d: f32, comptime steps_per_arc: usize, side_x: usize, side_y: usize) void {
    const x0 = r.x + d;
    const y0 = r.y + d;
    const x1 = r.x + r.w - d;
    const y1 = r.y + r.h - d;
    const max_rad = @max(0.01, @min(x1 - x0, y1 - y0) / 2);
    var rad: [4]f32 = undefined;
    for (radii, 0..) |v, i| rad[i] = std.math.clamp(v, 0.01, max_rad);
    const pi = std.math.pi;
    var n: usize = 0;
    const Corner = struct { cx: f32, cy: f32, a0: f32, a1: f32, rad: f32 };
    const corners = [_]Corner{
        .{ .cx = x0 + rad[0], .cy = y0 + rad[0], .a0 = 1.5 * pi, .a1 = pi, .rad = rad[0] },
        .{ .cx = x0 + rad[1], .cy = y1 - rad[1], .a0 = pi, .a1 = 0.5 * pi, .rad = rad[1] },
        .{ .cx = x1 - rad[2], .cy = y1 - rad[2], .a0 = 0.5 * pi, .a1 = 0, .rad = rad[2] },
        .{ .cx = x1 - rad[3], .cy = y0 + rad[3], .a0 = 2 * pi, .a1 = 1.5 * pi, .rad = rad[3] },
    };
    // The outward normal of the straight run after each corner: left, bottom, right, top.
    const side_normals = [_]dvui.Point.Physical{ .{ .x = -1 }, .{ .y = 1 }, .{ .x = 1 }, .{ .y = -1 } };
    for (corners, 0..) |c, ci| {
        var k: usize = 0;
        while (k <= steps_per_arc) : (k += 1) {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps_per_arc));
            const a = c.a0 + (c.a1 - c.a0) * t;
            out[n] = .{ .x = c.cx + c.rad * @cos(a), .y = c.cy + c.rad * @sin(a) };
            if (normals) |ns| ns[n] = .{ .x = @cos(a), .y = @sin(a) };
            n += 1;
        }
        // The straight run to the next corner, cut into steps.
        const next = corners[(ci + 1) % corners.len];
        const from = out[n - 1];
        const to: dvui.Point.Physical = .{ .x = next.cx + next.rad * @cos(next.a0), .y = next.cy + next.rad * @sin(next.a0) };
        const steps = if (ci % 2 == 0) side_y else side_x;
        var k2: usize = 1;
        while (k2 < steps) : (k2 += 1) {
            const t = @as(f32, @floatFromInt(k2)) / @as(f32, @floatFromInt(steps));
            out[n] = .{ .x = from.x + (to.x - from.x) * t, .y = from.y + (to.y - from.y) * t };
            if (normals) |ns| ns[n] = side_normals[ci];
            n += 1;
        }
    }
    std.debug.assert(n == out.len);
}
