//! The drop targets over a place while something is dragged: one in the middle and one along
//! each edge. The place under the pointer shows all five at once, the one under the pointer lit;
//! moving to another place, the old set clears as the new one comes in over it.
//!
//! **One geometry, one look, for every drag.** A view dragged between places and a tab dragged
//! between panes read the pointer against the same five rects (`rects`, `at`) and draw the same
//! zones (`draw`), so a drop means the same thing wherever it lands and looks the same getting
//! there.
//!
//! **The look is liquid glass.** A zone is a pane of the dialogs' own frost over what is under
//! it — the app's one surface rounding, a gap around each, a faint icon saying what it does —
//! drawn as a mesh over one blur of the place, so the glass can bend what it shows: a lens band
//! at its rim, and ripples running through it as it arrives and as it lights under the pointer.
//! An edge zone grows in from its edge and the middle from its centre, on a bounce, as its frost
//! comes in; leaving, the same backwards and quicker. What is underneath is the caller's: this
//! only draws the glass over it.
//!
//! **Every point of a place is some zone.** The gaps between the rects are there to be seen, not
//! to be dead space: a point in one resolves to the nearest zone, so a drop never does nothing
//! just because it fell between two targets.
const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("../dialogs.zig");
const widgets = @import("../widgets.zig");
const BlurBackdrop = @import("BlurBackdrop.zig");
const icons = @import("icons");
const icon_tex = @import("../gfx/icon.zig");

pub const Side = enum { left, right, top, bottom };

pub const Zone = union(enum) {
    /// Into the place itself: a trade for a place that shows one view, a new tab for one that
    /// shows several.
    center,
    /// A split on that edge.
    edge: Side,

    pub fn eql(a: Zone, b: Zone) bool {
        return switch (a) {
            .center => b == .center,
            .edge => |s| b == .edge and b.edge == s,
        };
    }
};

/// The five targets of one place, in physical pixels.
pub const Rects = struct {
    center: dvui.Rect.Physical,
    left: dvui.Rect.Physical,
    right: dvui.Rect.Physical,
    top: dvui.Rect.Physical,
    bottom: dvui.Rect.Physical,

    pub fn of(self: Rects, z: Zone) dvui.Rect.Physical {
        return switch (z) {
            .center => self.center,
            .edge => |s| switch (s) {
                .left => self.left,
                .right => self.right,
                .top => self.top,
                .bottom => self.bottom,
            },
        };
    }
};

/// Every zone, in the order they are drawn and stored.
pub const all = [_]Zone{ .center, .{ .edge = .left }, .{ .edge = .right }, .{ .edge = .top }, .{ .edge = .bottom } };

/// Points. The gap around and between zones — the middle's from the bands too, so all five read
/// as one set — and an edge band's thickness, capped as a fraction of the place so a small place
/// keeps a middle.
pub const gap: f32 = 8;
pub const band: f32 = 64;
pub const band_fraction: f32 = 0.22;

/// Where the five zones sit over `bounds`. The side bands run the full height; the top and
/// bottom bands fit between them; the middle stands back from all four.
pub fn rects(bounds: dvui.Rect.Physical, scale: f32) Rects {
    const g = gap * scale;
    const inner = inset(bounds, g, g);
    const tx = @min(band * scale, inner.w * band_fraction);
    const ty = @min(band * scale, inner.h * band_fraction);
    const left: dvui.Rect.Physical = .{ .x = inner.x, .y = inner.y, .w = tx, .h = inner.h };
    const right: dvui.Rect.Physical = .{ .x = inner.x + inner.w - tx, .y = inner.y, .w = tx, .h = inner.h };
    const span_x = inner.x + tx + g;
    const span_w = @max(0, inner.w - 2 * (tx + g));
    const top: dvui.Rect.Physical = .{ .x = span_x, .y = inner.y, .w = span_w, .h = ty };
    const bottom: dvui.Rect.Physical = .{ .x = span_x, .y = inner.y + inner.h - ty, .w = span_w, .h = ty };
    return .{
        // What is left between the bands, one gap back from each.
        .center = inset(inner, tx + g, ty + g),
        .left = left,
        .right = right,
        .top = top,
        .bottom = bottom,
    };
}

/// The zone a point reads as: the one containing it, else the nearest — the gaps belong to
/// whichever target is closest.
pub fn at(r: Rects, p: dvui.Point.Physical) Zone {
    var best: Zone = .center;
    var best_d: f32 = std.math.floatMax(f32);
    for (all) |z| {
        const d = distance(r.of(z), p);
        if (d < best_d) {
            best = z;
            best_d = d;
        }
    }
    return best;
}

fn distance(r: dvui.Rect.Physical, p: dvui.Point.Physical) f32 {
    const dx = @max(@max(r.x - p.x, 0), p.x - (r.x + r.w));
    const dy = @max(@max(r.y - p.y, 0), p.y - (r.y + r.h));
    return dx * dx + dy * dy;
}

fn inset(r: dvui.Rect.Physical, dx: f32, dy: f32) dvui.Rect.Physical {
    return .{ .x = r.x + dx, .y = r.y + dy, .w = @max(0, r.w - 2 * dx), .h = @max(0, r.h - 2 * dy) };
}

/// How long the zones take to come in and to go, in milliseconds. In is the longer: it carries
/// the bounce, and the place arrived at is watched turning into glass. Out gets out of the way of
/// the place arrived at, and of what a drop is doing.
pub const appear_ms: f32 = 340;
pub const vanish_ms: f32 = 170;
/// A time constant: how quickly a zone lights or dims under the pointer, most of the way in
/// about three of these.
pub const light_ms: f32 = 55;

const State = struct {
    /// 0…1, linear in time; shaped when read (`grow`, `frost`).
    shown: f32 = 0,
    /// 0…1: how lit — the zone under the pointer.
    lit: [all.len]f32 = @splat(0),
    /// When the zones last began to come in: their arrival ripple runs from here.
    born_ns: i128 = 0,
    /// The ripple a zone gives when it lights, from where the pointer was.
    pulse_ns: [all.len]i128 = @splat(0),
    pulse_at: [all.len]dvui.Point.Physical = @splat(.{}),
    last_ns: i128 = 0,
};

/// What dropping in the middle does, for its icon: trade places with the one view a place shows,
/// add to the several it shows, join it with the place beside it into one — or nothing, the
/// middle of the place a view was lifted from, which is bare glass.
pub const Center = enum { replace, add, join, none };

/// How one place's zones are drawn this frame.
pub const Look = struct {
    /// The zone under the pointer, which lights.
    hovered: ?Zone = null,
    /// False sends them all away — the pointer left the place, or the drag ended — until
    /// `showing` says they are gone.
    target: bool = true,
    /// The middle's icon.
    center: Center = .replace,
};

/// White added over a lit zone's glass, on top of the dialogs' own lift.
const lit_lift: f32 = 0.10;
/// Points: an icon's size.
const icon_size: f32 = 18;

/// Draw the zones over `r`, keyed by `id` (the place's).
///
/// Call every frame the pointer is over the place, and after while `showing`, after what the
/// zones cover has drawn. Gone, a place forgets its zones, so the next arrival comes in anew.
pub fn draw(id: dvui.Id, r: Rects, scale: f32, look: Look) void {
    const st = dvui.dataGetPtrDefault(null, id, "_drop_zones", State, .{});
    const now = dvui.currentWindow().frame_time_ns;
    // A gap of more than a few frames is a new visit: start from nothing.
    if (st.last_ns == 0 or now - st.last_ns > 200 * std.time.ns_per_ms) st.* = .{ .last_ns = now };
    const dt_ms: f32 = @as(f32, @floatFromInt(now - st.last_ns)) / std.time.ns_per_ms;
    st.last_ns = now;

    const want_shown: f32 = if (look.target) 1 else 0;
    if (st.shown == 0 and want_shown > 0) st.born_ns = now;
    st.shown = step(st.shown, want_shown, dt_ms, if (want_shown > st.shown) appear_ms else vanish_ms);
    var moving = st.shown != want_shown;
    const mouse = dvui.currentWindow().mouse_pt;
    for (all, 0..) |z, i| {
        const want_lit: f32 = if (look.target) (if (look.hovered) |h| (if (h.eql(z)) 1 else 0) else 0) else 0;
        // Lighting under the pointer is a touch on the glass: it ripples from there.
        if (want_lit == 1 and st.lit[i] < 0.5 and now - st.pulse_ns[i] > 120 * std.time.ns_per_ms) {
            st.pulse_ns[i] = now;
            st.pulse_at[i] = mouse;
        }
        st.lit[i] = approach(st.lit[i], want_lit, dt_ms, light_ms);
        if (st.lit[i] != want_lit) moving = true;
    }

    const g = frost(st.shown);
    if (g > 0.01) {
        const e = grow(st.shown);
        var panes: [all.len]Pane = undefined;
        for (all, 0..) |z, i| {
            const full = r.of(z);
            panes[i] = .{
                .r = entering(full, z, e),
                .lit = st.lit[i],
                .waves = .{
                    .{ .origin = arrivalOrigin(full, z), .start_ns = st.born_ns },
                    .{ .origin = st.pulse_at[i], .start_ns = st.pulse_ns[i] },
                },
            };
            if (panes[i].waves[0].live(now) or panes[i].waves[1].live(now)) moving = true;
        }
        glass(id, &panes, g, scale);
        for (all, 0..) |z, i| {
            if (z == .center and look.center == .none) continue;
            drawIcon(panes[i].r, iconFor(z, look.center), g, st.lit[i], scale);
        }
    }

    if (moving) {
        dvui.refresh(null, @src(), id);
    } else if (!look.target) {
        forget(id);
    }
}

/// The join over two places a drop would make one: a single lit pane of the same glass across
/// both, where each showed its own zones — the place the drop leaves, shown before it is made.
/// `rect` is the two places together; null while no join is aimed at, and the pane goes over the
/// last place it covered. Draw after every place has drawn (it lies over their zones as they go),
/// keyed by one `id` for the whole window.
pub fn drawJoin(id: dvui.Id, rect: ?dvui.Rect.Physical, scale: f32) void {
    const JoinState = struct { shown: f32 = 0, last_ns: i128 = 0, born_ns: i128 = 0, rect: dvui.Rect.Physical = .{} };
    const st = dvui.dataGetPtr(null, id, "_drop_join", JoinState) orelse blk: {
        if (rect == null) return;
        break :blk dvui.dataGetPtrDefault(null, id, "_drop_join", JoinState, .{});
    };
    const now = dvui.currentWindow().frame_time_ns;
    if (st.last_ns == 0 or now - st.last_ns > 200 * std.time.ns_per_ms) st.* = .{ .last_ns = now };
    const dt_ms: f32 = @as(f32, @floatFromInt(now - st.last_ns)) / std.time.ns_per_ms;
    st.last_ns = now;
    if (rect) |rr| st.rect = inset(rr, gap * scale, gap * scale);
    const want: f32 = if (rect != null) 1 else 0;
    if (st.shown == 0 and want > 0) st.born_ns = now;
    st.shown = step(st.shown, want, dt_ms, if (want > st.shown) appear_ms else vanish_ms);
    var moving = st.shown != want;
    const g = frost(st.shown);
    if (g > 0.01 and st.rect.w >= 1 and st.rect.h >= 1) {
        const pane: Pane = .{
            .r = entering(st.rect, .center, 0.85 + 0.15 * grow(st.shown)),
            .lit = 1,
            .waves = .{ .{ .origin = st.rect.center(), .start_ns = st.born_ns }, .{} },
        };
        if (pane.waves[0].live(now)) moving = true;
        glass(id, &.{pane}, g, scale);
        drawIcon(pane.r, .{ .name = "drop_zone_join", .tvg = icons.tvg.lucide.@"squares-unite" }, g, 1, scale);
    }
    if (moving) {
        dvui.refresh(null, @src(), id);
    } else if (rect == null) {
        dvui.dataRemove(null, id, "_drop_join");
    }
}

// ── Coming and going ────────────────────────────────────────────────────────────────────────────

/// How big a zone is at progress `t`: out-back, so it overshoots a little and settles — the
/// bounce. Read backwards on the way out, the same curve swells a touch and then goes.
pub fn grow(t: f32) f32 {
    const u = std.math.clamp(t, 0, 1);
    const c1: f32 = 1.70158;
    const c3 = c1 + 1;
    const v = u - 1;
    return @max(0, 1 + c3 * v * v * v + c1 * v * v);
}

/// How much frost a zone has at progress `t`: ahead of its size, so the glass is glass before
/// it has finished arriving.
fn frost(t: f32) f32 {
    const u = std.math.clamp(t, 0, 1);
    const v = 1 - u;
    return 1 - v * v * v;
}

/// A zone at size `e`: an edge band grown out of its own edge — its outer side fixed, its depth
/// scaled, its length nearly whole — and the middle from its centre.
fn entering(r: dvui.Rect.Physical, z: Zone, e: f32) dvui.Rect.Physical {
    const along = 0.8 + 0.2 * @min(e, 1);
    return switch (z) {
        .center => scaleAbout(r, e, e),
        .edge => |side| switch (side) {
            .left => .{ .x = r.x, .y = r.y + r.h * (1 - along) / 2, .w = r.w * e, .h = r.h * along },
            .right => .{ .x = r.x + r.w - r.w * e, .y = r.y + r.h * (1 - along) / 2, .w = r.w * e, .h = r.h * along },
            .top => .{ .x = r.x + r.w * (1 - along) / 2, .y = r.y, .w = r.w * along, .h = r.h * e },
            .bottom => .{ .x = r.x + r.w * (1 - along) / 2, .y = r.y + r.h - r.h * e, .w = r.w * along, .h = r.h * e },
        },
    };
}

/// Where a zone's arrival ripple starts: the edge it grows out of, or the middle's centre.
fn arrivalOrigin(r: dvui.Rect.Physical, z: Zone) dvui.Point.Physical {
    return switch (z) {
        .center => r.center(),
        .edge => |side| switch (side) {
            .left => .{ .x = r.x, .y = r.y + r.h / 2 },
            .right => .{ .x = r.x + r.w, .y = r.y + r.h / 2 },
            .top => .{ .x = r.x + r.w / 2, .y = r.y },
            .bottom => .{ .x = r.x + r.w / 2, .y = r.y + r.h },
        },
    };
}

fn scaleAbout(r: dvui.Rect.Physical, kx: f32, ky: f32) dvui.Rect.Physical {
    const w = r.w * kx;
    const h = r.h * ky;
    return .{ .x = r.x + (r.w - w) / 2, .y = r.y + (r.h - h) / 2, .w = w, .h = h };
}

// ── The glass ───────────────────────────────────────────────────────────────────────────────────

/// One pane of glass to lay down: where, how lit, and the ripples running through it.
const Pane = struct {
    r: dvui.Rect.Physical,
    lit: f32 = 0,
    waves: [2]Wave = .{ .{}, .{} },
};

/// A ripple through the glass: a ring running out from `origin`, a couple of crests deep, dying
/// away. Like the sprite shelf's water it moves what the glass shows, not the glass: a crest bends
/// the blur under it outward along the ring, so the frost wobbles as the wave goes by.
const Wave = struct {
    origin: dvui.Point.Physical = .{},
    /// Zero: no wave.
    start_ns: i128 = 0,

    /// Points: the distance between crests, and how far the glass bends at the first.
    const wavelength: f32 = 34;
    const depth: f32 = 5;
    /// Points per millisecond the ring runs out at, and how quickly it dies away.
    const speed: f32 = 0.85;
    const decay_ms: f32 = 240;
    const life_ms: f32 = 900;

    fn age(self: Wave, now: i128) f32 {
        return @as(f32, @floatFromInt(now - self.start_ns)) / std.time.ns_per_ms;
    }

    fn live(self: Wave, now: i128) bool {
        if (self.start_ns == 0) return false;
        const t = self.age(now);
        return t >= 0 and t < life_ms;
    }

    /// How far, in physical pixels and along the ring, the glass at `p` is bent right now.
    fn bend(self: Wave, p: dvui.Point.Physical, now: i128, scale: f32) dvui.Point.Physical {
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
        const a = depth * scale * @exp(-t / decay_ms) * crest;
        return .{ .x = dx / d * a, .y = dy / d * a };
    }
};

/// Points: how wide the lens band at a pane's rim is, and how far in it reaches for what it shows
/// at the very edge — the pane magnifies what is under its border, the way a thick glass edge does.
const lens_band: f32 = 16;
const lens_reach: f32 = 9;

/// The frost under `panes` at strength `g`: one read of the frame and one blur for all of them,
/// laid down as a bent mesh each, tinted and lifted like the dialogs' glass, the lit ones
/// brighter. With the blur off it is the dialogs' fill, as much of it as `g`.
fn glass(id: dvui.Id, panes: []const Pane, g: f32, scale: f32) void {
    // Finalized, as a widget's options would be: an unresolved corner draws square whatever
    // radius it names.
    const theme = dvui.themeGet();
    const corners_nat = dialogs.surface_corners.finalize(&theme);
    const base = widgets.menuFrost() orelse {
        const corners = corners_nat.scale(scale, dvui.CornerRect.Physical);
        const fill = dialogs.dialogFill();
        for (panes) |pane| {
            if (pane.r.w < 1 or pane.r.h < 1) continue;
            const c = fill.lerp(.white, lit_lift * pane.lit);
            pane.r.fill(corners, .{ .color = .{ .color = c.opacity(@as(f32, @floatFromInt(c.a)) / 255 * g) }, .fade = 1.0 });
        }
        return;
    };
    const job = dvui.dataGetPtrDefault(null, id, "_drop_zones_job", LayerJob, .{});
    job.* = .{
        .backdrop = job.backdrop,
        .corners = corners_nat,
        .radius = corners_nat.tl.radius() * scale,
        .scale = scale,
        .now = dvui.currentWindow().frame_time_ns,
        .strength = g,
    };
    for (panes) |pane| {
        if (pane.r.w < 1 or pane.r.h < 1) continue;
        job.panes[job.count] = pane;
        job.count += 1;
    }
    if (job.count == 0) return;
    // The layer covers the panes it serves and nothing else, so what it reads back and blurs is
    // only what the glass will show.
    var bounds = job.panes[0].r;
    for (job.panes[1..job.count]) |pane| bounds = bounds.unionWith(pane.r);
    job.pane = scaled(base, g);
    job.bounds = bounds;
    const backdrop = dvui.dataGetPtrDefault(null, id, "_drop_zones_frost", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "_drop_zones_frost", &BlurBackdrop.releaseTexture);
    backdrop.mode = .readback;
    backdrop.radius_px = job.pane.radius;
    backdrop.detail = job.pane.detail;
    // Re-read every frame: what is under the zones moves for the whole of a drag.
    backdrop.init(dvui.windowRectScale().rectFromPhysical(bounds), .{ bounds, job.now, job.pane.radius });
    job.backdrop = backdrop;
    dvui.deferRender(job, LayerJob.draw);
}

/// `base` at strength `g`: its blur, tint and lift all scaled together, so a weaker frost is the
/// same glass, thinner.
fn scaled(base: BlurBackdrop.Pane, g: f32) BlurBackdrop.Pane {
    var pane = base;
    pane.radius = base.radius * g;
    pane.mix = base.mix * g;
    pane.lift = base.lift * g;
    return pane;
}

/// The shared layer, drawn at replay once everything under the panes is on the frame: read and
/// blur `bounds` once, then lay each pane's bent slice of it down with the dialogs' tint and
/// lift, and a thin bright rim.
const LayerJob = struct {
    backdrop: ?*BlurBackdrop = null,
    pane: BlurBackdrop.Pane = .{},
    bounds: dvui.Rect.Physical = .{},
    corners: dvui.CornerRect = .{},
    /// Physical pixels: the panes' corner radius.
    radius: f32 = 0,
    scale: f32 = 1,
    now: i128 = 0,
    strength: f32 = 1,
    panes: [all.len]Pane = undefined,
    count: usize = 0,

    fn draw(ctx: ?*anyopaque) void {
        const self: *LayerJob = @ptrCast(@alignCast(ctx orelse return));
        const backdrop = self.backdrop orelse return;
        backdrop.deinit();
        const tex = backdrop.small orelse return;
        if (self.bounds.w < 1 or self.bounds.h < 1) return;
        const mix = std.math.clamp(self.pane.mix, 0, 1);
        // As `frostPane` composes it: the frost at `1 - mix` of itself, then the tint and the
        // lift added over it.
        const frost_mod: dvui.Color = if (self.pane.tint != null) dvui.Color.white.opacity(1 - mix) else .white;
        for (self.panes[0..self.count]) |pane| {
            self.drawMesh(tex, pane, frost_mod);
            if (self.pane.tint) |tint| BlurBackdrop.addTint(pane.r, self.corners, self.scale, tint, mix);
            const lift = std.math.clamp(self.pane.lift + lit_lift * pane.lit * self.strength, 0, 1);
            BlurBackdrop.addTint(pane.r, self.corners, self.scale, .white, lift);
            self.drawRim(pane);
        }
    }

    /// The pane as rings of vertices from its rim in to its centre, each sampling the blur a
    /// little off where it sits: the lens band near the rim, and whatever ripple is passing.
    fn drawMesh(self: *const LayerJob, tex: dvui.Texture, pane: Pane, mod: dvui.Color) void {
        const r = pane.r;
        const half = @min(r.w, r.h) / 2;
        if (half < 1) return;
        const s = self.scale;
        // Insets of each ring from the rim, in physical pixels: close together through the lens
        // band, then spread out to the middle so a ripple has vertices to move.
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

        // One ring's worth of points: each corner an arc, each straight side cut into steps so
        // a ripple along it has somewhere to show.
        const arc_steps = 6;
        const step_px = 22 * s;
        const side_x: usize = @intFromFloat(@max(1, @ceil(@max(0, r.w - 2 * self.radius) / step_px)));
        const side_y: usize = @intFromFloat(@max(1, @ceil(@max(0, r.h - 2 * self.radius) / step_px)));
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

        // The fringe: the rim pushed out half a pixel, clear, so the edge is smooth.
        ringPoints(ring_pts, r, self.radius, -0.5 * s, arc_steps, side_x, side_y);
        for (ring_pts) |p| b.appendVertex(.{ .pos = p, .col = clear, .uv = self.uvAt(p, 0, pane) });
        for (insets) |d| {
            ringPoints(ring_pts, r, self.radius, d, arc_steps, side_x, side_y);
            for (ring_pts) |p| b.appendVertex(.{ .pos = p, .col = col, .uv = self.uvAt(p, d, pane) });
        }
        const c = r.center();
        b.appendVertex(.{ .pos = c, .col = col, .uv = self.uvAt(c, half, pane) });

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
        const tris = b.build_unowned();
        dvui.renderTriangles(tris, tex) catch {};
    }

    /// Where in the blur the glass at `p` shows: the point itself, reached in toward the middle
    /// through the lens band (`inset_px` from the rim), and moved by any ripple going by.
    fn uvAt(self: *const LayerJob, p: dvui.Point.Physical, inset_px: f32, pane: Pane) @Vector(2, f32) {
        const s = self.scale;
        var q = p;
        const band_px = lens_band * s;
        if (inset_px < band_px) {
            const k = 1 - inset_px / band_px;
            const reach = lens_reach * s * k * k;
            const c = pane.r.center();
            const dx = c.x - p.x;
            const dy = c.y - p.y;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > 0.5) {
                q.x += dx / d * reach;
                q.y += dy / d * reach;
            }
        }
        for (pane.waves) |w| {
            const off = w.bend(p, self.now, s);
            q.x -= off.x;
            q.y -= off.y;
        }
        const bd = self.bounds;
        return .{
            std.math.clamp((q.x - bd.x) / bd.w, 0, 1),
            std.math.clamp((q.y - bd.y) / bd.h, 0, 1),
        };
    }

    /// A hairline of light around the pane's edge, brighter lit — where a thick glass catches it.
    fn drawRim(self: *const LayerJob, pane: Pane) void {
        const s = self.scale;
        const a = self.strength * (0.10 + 0.14 * pane.lit);
        if (a <= 0.01) return;
        var path: dvui.Path.Builder = .init(dvui.currentWindow().arena());
        defer path.deinit();
        path.addRect(pane.r.insetAll(0.5 * s), self.corners.scale(s, dvui.CornerRect.Physical));
        path.build().stroke(.{ .color = .{ .color = dvui.Color.white.opacity(a) }, .thickness = @max(1, s), .closed = true });
    }
};

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

/// A zone's icon, over its glass (queued after it, so drawn after it). Faint until lit, and in
/// only once the glass is mostly there; blended toward the glass rather than made translucent,
/// so a glyph's crossing strokes never show.
fn drawIcon(zr: dvui.Rect.Physical, glyph: Glyph, g: f32, lit: f32, scale: f32) void {
    const side = icon_size * scale;
    if (zr.w < side * 1.5 or zr.h < side * 1.5) return;
    const arrive = std.math.clamp((g - 0.45) / 0.55, 0, 1);
    if (arrive <= 0.01) return;
    const theme = dvui.themeGet();
    const ink = theme.color(.window, .text);
    const glass_c = dialogs.dialogFill().opacity(1);
    const color = glass_c.lerp(ink, arrive * (0.35 + 0.65 * lit));
    const at_r: dvui.Rect.Physical = .{ .x = zr.x + (zr.w - side) / 2, .y = zr.y + (zr.h - side) / 2, .w = side, .h = side };
    icon_tex.render(glyph.name, glyph.tvg, .{ .r = at_r, .s = scale }, .{}, .{
        .stroke_color = .{ .color = color },
        .fill_color = .transparent,
    });
}

const Glyph = struct { name: []const u8, tvg: []const u8 };

/// What each zone's icon shows: a pane opening on that side, or the middle's trade, add or join.
fn iconFor(z: Zone, center: Center) Glyph {
    return switch (z) {
        .center => switch (center) {
            .replace => .{ .name = "drop_zone_replace", .tvg = icons.tvg.lucide.replace },
            .add => .{ .name = "drop_zone_add", .tvg = icons.tvg.lucide.@"square-plus" },
            .join, .none => .{ .name = "drop_zone_join", .tvg = icons.tvg.lucide.@"squares-unite" },
        },
        .edge => |side| switch (side) {
            .left => .{ .name = "drop_zone_left", .tvg = icons.tvg.lucide.@"panel-left" },
            .right => .{ .name = "drop_zone_right", .tvg = icons.tvg.lucide.@"panel-right" },
            .top => .{ .name = "drop_zone_top", .tvg = icons.tvg.lucide.@"panel-top" },
            .bottom => .{ .name = "drop_zone_bottom", .tvg = icons.tvg.lucide.@"panel-bottom" },
        },
    };
}

/// `v` moved toward `target` at a constant rate: all the way in `dur_ms`.
fn step(v: f32, target: f32, dt_ms: f32, dur_ms: f32) f32 {
    if (dt_ms <= 0) return v;
    const d = dt_ms / dur_ms;
    return if (target > v) @min(target, v + d) else @max(target, v - d);
}

/// Whether `id`'s zones are still on screen: shown, or going.
pub fn showing(id: dvui.Id) bool {
    const st = dvui.dataGetPtr(null, id, "_drop_zones", State) orelse return false;
    return st.shown > 0;
}

/// Drop `id`'s zones outright: the next time its place is the target they come in from nothing.
pub fn forget(id: dvui.Id) void {
    dvui.dataRemove(null, id, "_drop_zones");
}

/// `v` eased toward `target` over `dt_ms`, with time constant `tau_ms`.
fn approach(v: f32, target: f32, dt_ms: f32, tau_ms: f32) f32 {
    if (dt_ms <= 0) return v;
    const k = 1 - @exp(-dt_ms / tau_ms);
    const next = v + (target - v) * k;
    return if (@abs(next - target) < 0.002) target else next;
}
