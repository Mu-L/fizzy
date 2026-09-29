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
//! drawn through `core.liquid_glass` over one blur of the place, so each has a bevelled edge
//! that refracts, clears and catches the light. An edge zone grows in from its edge and the
//! middle from its centre, eased at the app's motion level, as its frost comes in; leaving, the
//! same backwards and quicker. What is underneath is the caller's: this
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
const motion = @import("../motion.zig");
const liquid_glass = @import("../gfx/liquid_glass.zig");

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
pub const appear_ms: f32 = 420;
pub const vanish_ms: f32 = 170;
/// A time constant: how quickly a zone lights or dims under the pointer, most of the way in
/// about three of these.
pub const light_ms: f32 = 55;

const State = struct {
    /// 0…1, linear in time; shaped when read (`grow`, `frost`).
    shown: f32 = 0,
    /// 0…1: how lit — the zone under the pointer.
    lit: [all.len]f32 = @splat(0),
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

/// How much a lit zone's glass changes, as dvui changes a hovered fill (`Theme.adjustColorForState`,
/// ±10% by `dark`): lighter over a dark theme, darker over a light one — a pale zone brightening
/// on a pale theme barely shows.
const lit_lift: f32 = 0.10;

/// The colour a lit zone's glass moves toward: white in a dark theme, black in a light one.
fn litToward() dvui.Color {
    return if (dvui.themeGet().dark) .white else .black;
}
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
    // Where the zones were is kept until they have gone (`forget`), however long between frames:
    // a drag held still asks for none, and treating the gap as a new visit replayed the entrance
    // on the next twitch of the pointer.
    if (st.last_ns == 0) st.last_ns = now;
    const dt_ms: f32 = @as(f32, @floatFromInt(now - st.last_ns)) / std.time.ns_per_ms;
    st.last_ns = now;

    const want_shown: f32 = if (look.target) 1 else 0;
    st.shown = step(st.shown, want_shown, dt_ms, motion.durationMs(if (want_shown > st.shown) appear_ms else vanish_ms));
    var moving = st.shown != want_shown;
    for (all, 0..) |z, i| {
        const want_lit: f32 = if (look.target) (if (look.hovered) |h| (if (h.eql(z)) 1 else 0) else 0) else 0;
        st.lit[i] = approach(st.lit[i], want_lit, dt_ms, motion.durationMs(light_ms));
        if (st.lit[i] != want_lit) moving = true;
    }

    const g = frost(st.shown);
    if (g > 0.01) {
        var area = r.center;
        for (all[1..]) |z| area = area.unionWith(r.of(z));
        const panes = splitting(r, area, st.shown, &st.lit, scale);
        glass(id, &panes, area, g, scale);
        for (all, 0..) |z, i| {
            if (z == .center and look.center == .none) continue;
            drawIcon(panes[i].r, iconFor(z, look.center), @min(g, panes[i].lens), st.lit[i], scale);
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
    drawSingle(id, rect, scale, .{ .inset = gap, .icon = .join });
}

/// How `drawSingle` lays its pane down.
pub const Single = struct {
    /// Points in from the rect the pane sits.
    inset: f32 = 0,
    /// What the pane's icon says; null for none (a slot too small for one).
    icon: ?Center = null,
    /// Points: the pane's corner radius; null for the app's surface rounding.
    radius: ?f32 = null,
};

/// One lit pane of the zones' glass over `rect`, coming in as it appears and going when `rect`
/// goes null — over the last rect it covered — keyed by `id`. The one target a thing offers when
/// it is not a place with edges to split: the join across two places, a chooser a view can be
/// dropped into, the slot a dragged item will land in along a chooser.
pub fn drawSingle(id: dvui.Id, rect: ?dvui.Rect.Physical, scale: f32, opts: Single) void {
    const SingleState = struct { shown: f32 = 0, last_ns: i128 = 0, rect: dvui.Rect.Physical = .{} };
    const st = dvui.dataGetPtr(null, id, "_drop_single", SingleState) orelse blk: {
        if (rect == null) return;
        break :blk dvui.dataGetPtrDefault(null, id, "_drop_single", SingleState, .{});
    };
    const now = dvui.currentWindow().frame_time_ns;
    // Kept until it has gone, however long between frames — see `draw`.
    if (st.last_ns == 0) st.last_ns = now;
    const dt_ms: f32 = @as(f32, @floatFromInt(now - st.last_ns)) / std.time.ns_per_ms;
    st.last_ns = now;
    if (rect) |rr| st.rect = inset(rr, opts.inset * scale, opts.inset * scale);
    const want: f32 = if (rect != null) 1 else 0;
    st.shown = step(st.shown, want, dt_ms, motion.durationMs(if (want > st.shown) appear_ms else vanish_ms));
    const moving = st.shown != want;
    const g = frost(st.shown);
    if (g > 0.01 and st.rect.w >= 1 and st.rect.h >= 1) {
        const k = 0.85 + 0.15 * grow(st.shown);
        const radius = if (opts.radius) |r| r * scale else surfaceRadius(scale);
        const pane: Pane = .{
            .r = scaleAbout(st.rect, k, k),
            .lit = 1,
            .radii = liquid_glass.uniform(radius),
        };
        glass(id, &.{pane}, st.rect, g, scale);
        if (opts.icon) |icon| drawIcon(pane.r, iconFor(.center, icon), g, 1, scale);
    }
    if (moving) {
        dvui.refresh(null, @src(), id);
    } else if (rect == null) {
        dvui.dataRemove(null, id, "_drop_single");
    }
}

// ── Coming and going ────────────────────────────────────────────────────────────────────────────

/// How big a zone is at progress `t`: arriving, at the app's motion level (`motion.enter`) — a
/// slight bounce at minimal, a soft spring at playful, plain at the low end. Read backwards on the
/// way out, the same curve swells a touch and then goes.
fn grow(t: f32) f32 {
    // The whole curve over the phase, approach and swing, with no hold after: the zones time
    // their own phases, and one that arrived early and sat still would leave its phase dead.
    return @max(0, motion.enterFull(t));
}

/// How much frost a zone has at progress `t`: ahead of its size, so the glass is glass before it
/// has finished arriving.
fn frost(t: f32) f32 {
    return motion.fade(t);
}

/// The zones `p` of the way in, as liquid splitting into five. They come out of the place's
/// centre as a cluster — the five tiles that exactly fill the place, each grown half a gap toward
/// its neighbours, swelling from small together — and once they have mostly filled it they part:
/// the gaps open and each piece's edge forms. Leaving runs it backwards: the pieces run together
/// and shrink away into the centre.
///
/// Every piece has the app's rounding the whole way — never square, never rounder: a piece that
/// appeared square and rounded later read as a box being cut, and one as round as its size read
/// as a blob beside its neighbours. Pieces never overlap — glass over glass would
/// double its tint where it did — so the cluster is tiles, rounded, not overlapping drops.
fn splitting(r: Rects, area: dvui.Rect.Physical, p: f32, lit: *const [all.len]f32, scale: f32) [all.len]Pane {
    const half_gap = gap * scale / 2;
    const radius = surfaceRadius(scale);
    const fill = grow(std.math.clamp(p / 0.55, 0, 1));
    const swell = drop_start + (1 - drop_start) * fill;
    const split = grow(std.math.clamp((p - 0.4) / 0.6, 0, 1));
    const settle = std.math.clamp(split, 0, 1);
    const c = area.center();
    var out: [all.len]Pane = undefined;
    for (all, 0..) |z, i| {
        const settled = r.of(z);
        const tile = tileOf(settled, z, half_gap);
        const here = lerpRect(tile, settled, split);
        // The whole set swells as one, about the place's centre.
        const swollen: dvui.Rect.Physical = .{ .x = c.x + (here.x - c.x) * swell, .y = c.y + (here.y - c.y) * swell, .w = here.w * swell, .h = here.h * swell };
        // One radius for every piece, the whole way: the app's rounding. A piece small enough
        // is as round as it can be (the radius is clamped to half its size), so the cluster still
        // comes out as droplets; a radius that grew with each piece gave the middle one corners
        // far rounder than its neighbours'. Each piece's own edge — its refraction and light —
        // forms as it comes away.
        out[i] = .{ .r = swollen, .lit = lit[i], .radii = liquid_glass.uniform(radius), .lens = settle };
    }
    return out;
}

/// How big the cluster the zones come out of starts, of the place.
const drop_start: f32 = 0.18;

/// `settled` grown half a gap toward every neighbouring zone, so the five tile the place.
fn tileOf(settled: dvui.Rect.Physical, z: Zone, h: f32) dvui.Rect.Physical {
    // How far each side grows: left, top, right, bottom.
    const grow_by: [4]f32 = switch (z) {
        .center => .{ h, h, h, h },
        .edge => |side| switch (side) {
            .left => .{ 0, 0, h, 0 },
            .right => .{ h, 0, 0, 0 },
            .top => .{ h, 0, h, h },
            .bottom => .{ h, h, h, 0 },
        },
    };
    return .{
        .x = settled.x - grow_by[0],
        .y = settled.y - grow_by[1],
        .w = settled.w + grow_by[0] + grow_by[2],
        .h = settled.h + grow_by[1] + grow_by[3],
    };
}

/// The app's surface rounding in physical pixels. Finalized, as a widget's options would be: an
/// unresolved corner draws square whatever radius it names.
fn surfaceRadius(scale: f32) f32 {
    const theme = dvui.themeGet();
    return dialogs.surfaceCorners().finalize(&theme).tl.radius() * scale;
}

/// Per-corner radii (physical, ring order) as dvui corners in natural units at `scale`.
fn cornersOf(radii: liquid_glass.Radii, scale: f32) dvui.CornerRect {
    return .{
        .tl = .round(radii[0] / scale),
        .bl = .round(radii[1] / scale),
        .br = .round(radii[2] / scale),
        .tr = .round(radii[3] / scale),
    };
}

fn lerpRect(a: dvui.Rect.Physical, b: dvui.Rect.Physical, t: f32) dvui.Rect.Physical {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t, .w = a.w + (b.w - a.w) * t, .h = a.h + (b.h - a.h) * t };
}

fn scaleAbout(r: dvui.Rect.Physical, kx: f32, ky: f32) dvui.Rect.Physical {
    const w = r.w * kx;
    const h = r.h * ky;
    return .{ .x = r.x + (r.w - w) / 2, .y = r.y + (r.h - h) / 2, .w = w, .h = h };
}

// ── The glass ───────────────────────────────────────────────────────────────────────────────────

/// One pane of glass to lay down: where, how lit, its corner radii (physical), and how much of
/// its edge — refraction and light — it has yet.
const Pane = struct {
    r: dvui.Rect.Physical,
    lit: f32 = 0,
    radii: liquid_glass.Radii,
    lens: f32 = 1,
};



/// The frost under `panes` at strength `g`: one read of `area` and one blur for all of them,
/// laid down as a bent mesh each, tinted and lifted like the dialogs' glass, the lit ones
/// brighter. With the blur off it is the dialogs' fill, as much of it as `g`.
///
/// **Read rarely.** `area` is where the panes settle, not where they are this frame, so a pane
/// growing in does not move what is read; what is under it does not change during a drag (the
/// app under one stays put), so it is read again a few times a second, and when the blur has
/// grown a step. Reading and blurring a place every frame was most of what the glass cost.
fn glass(id: dvui.Id, panes: []const Pane, area: dvui.Rect.Physical, g: f32, scale: f32) void {
    const base = widgets.menuFrost() orelse {
        const fill = dialogs.dialogFill();
        for (panes) |pane| {
            if (pane.r.w < 1 or pane.r.h < 1) continue;
            const c = fill.lerp(litToward(), lit_lift * pane.lit);
            pane.r.fill(cornersOf(pane.radii, 1).scale(1, dvui.CornerRect.Physical), .{ .color = .{ .color = c.opacity(@as(f32, @floatFromInt(c.a)) / 255 * g) }, .fade = 1.0 });
        }
        return;
    };
    const job = dvui.dataGetPtrDefault(null, id, "_drop_zones_job", LayerJob, .{});
    job.* = .{
        .backdrop = job.backdrop,
        .scale = scale,
        .now = dvui.currentWindow().frame_time_ns,
        .strength = g,
        // The edge comes in with the blur, so a barely-frosted pane has barely an edge.
        .lens = motion.liquid() * liquid_glass.blurRamp(base.radius),
    };
    for (panes) |pane| {
        if (pane.r.w < 1 or pane.r.h < 1) continue;
        job.panes[job.count] = pane;
        job.count += 1;
    }
    if (job.count == 0) return;
    // The layer covers the place the panes settle in, and as far beyond as their edges reach for
    // what lies past them (`liquid_glass.margin`): what it reads back and blurs is what the glass
    // will show.
    const bounds = area.insetAll(-liquid_glass.margin(.{ .lens = job.lens, .refraction = base.refraction }, scale));
    job.pane = scaled(base, g);
    // In steps, so a frost fading in is re-blurred a dozen times rather than every frame.
    job.pane.radius = @round(job.pane.radius / blur_step) * blur_step;
    // Too little blur for the pyramid to make a pass: its picture would be an empty target, laid
    // down as a hole to the desktop (`BlurBackdrop.min_blur`). Glass barely there is none yet.
    if (job.pane.radius < BlurBackdrop.min_blur) {
        job.count = 0;
        return;
    }
    job.bounds = bounds;
    const backdrop = dvui.dataGetPtrDefault(null, id, "_drop_zones_frost", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "_drop_zones_frost", &BlurBackdrop.releaseTexture);
    backdrop.mode = .readback;
    backdrop.radius_px = job.pane.radius;
    backdrop.detail = job.pane.detail;
    const reread = @divTrunc(job.now, reread_ms * std.time.ns_per_ms);
    backdrop.init(dvui.windowRectScale().rectFromPhysical(bounds), .{ bounds, reread, job.pane.radius });
    job.backdrop = backdrop;
    dvui.deferRender(job, LayerJob.draw);
}

/// How often the glass reads again what is under it, and the steps its blur grows in.
const reread_ms: i128 = 250;
const blur_step: f32 = 3;

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
    scale: f32 = 1,
    now: i128 = 0,
    strength: f32 = 1,
    /// 0…1: the rim's lens and its light (`motion.liquid`).
    lens: f32 = 1,
    panes: [all.len]Pane = undefined,
    count: usize = 0,

    fn draw(ctx: ?*anyopaque) void {
        const self: *LayerJob = @ptrCast(@alignCast(ctx orelse return));
        const backdrop = self.backdrop orelse return;
        // At full alpha, as every frost draws (`BlurBackdrop.FrostJob`): the glass comes in by
        // its strength, and a frost at partial alpha is a hole.
        const prev_alpha = dvui.currentWindow().alpha;
        dvui.alphaSet(1);
        defer dvui.alphaSet(prev_alpha);
        backdrop.deinit();
        const tex = backdrop.small orelse return;
        if (self.bounds.w < 1 or self.bounds.h < 1) return;
        const mix = std.math.clamp(self.pane.mix, 0, 1);
        // As `frostPane` composes it: the frost at `1 - mix` of itself, then the tint and the
        // lift added over it.
        const frost_mod: dvui.Color = if (self.pane.tint != null) dvui.Color.white.opacity(1 - mix) else .white;
        const light = BlurBackdrop.additiveLight();
        for (self.panes[0..self.count]) |pane| {
            liquid_glass.drawPane(tex, backdrop.coverage(), pane.r, pane.radii, self.scale, frost_mod, .{
                .lens = self.lens * pane.lens,
                .refraction = self.pane.refraction,
                .sharp = backdrop.sharpTexture(),
                .blend_over = &BlurBackdrop.blendOver,
            });
            if (self.pane.tint) |tint| BlurBackdrop.addTint(pane.r, cornersOf(pane.radii, self.scale), self.scale, tint, mix);
            // The lift and the rim's light, in one pass after the tint so they stay white; a lit
            // zone is brighter and catches more.
            // Lit, the glass goes the way dvui takes a hovered fill: lighter in a dark theme (more
            // lift), darker in a light one (a shade over it once the light is on).
            const dark = dvui.themeGet().dark;
            const hover = lit_lift * pane.lit * self.strength;
            const lift = std.math.clamp(self.pane.lift + (if (dark) hover else 0), 0, 1);
            if (light) |l| liquid_glass.drawLift(l, pane.r, pane.radii, self.scale, lift, self.strength * self.lens * pane.lens * @min(1, self.pane.refraction) * (1 + 0.6 * pane.lit));
            if (!dark and hover > 0.002) {
                const corners = cornersOf(pane.radii, self.scale).scale(self.scale, dvui.CornerRect.Physical);
                pane.r.fill(corners, .{ .color = .{ .color = dvui.Color.black.opacity(hover) }, .fade = 1.0 });
            }
        }
    }
};

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

/// `v` moved toward `target` at a constant rate: all the way in `dur_ms`, at once in none.
fn step(v: f32, target: f32, dt_ms: f32, dur_ms: f32) f32 {
    if (dur_ms <= 0) return target;
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
    if (tau_ms <= 0) return target;
    if (dt_ms <= 0) return v;
    const k = 1 - @exp(-dt_ms / tau_ms);
    const next = v + (target - v) * k;
    return if (@abs(next - target) < 0.002) target else next;
}
