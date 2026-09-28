//! The drop targets over a place while something is dragged: one in the middle and one along
//! each edge. Every place the drag could land shows all five at once, so every option in the
//! window is in view; the one under the pointer lights.
//!
//! **One geometry, one look, for every drag.** A view dragged between places and a tab dragged
//! between panes read the pointer against the same five rects (`rects`, `at`) and draw the same
//! zones (`draw`), so a drop means the same thing wherever it lands and looks the same getting
//! there.
//!
//! **The look is the dialogs' glass.** A zone is a pane of the dialogs' own frosted glass over
//! what is under it — the app's one surface rounding, a gap around each, a faint icon saying what
//! it does. It fades in when the drag starts and out when it ends; the one under the pointer
//! lights. What is underneath is the caller's: this only draws the glass over it.
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

/// How long the zones take to come in and to go, in milliseconds. In is the slower of the two:
/// it is the moment the window turns into targets, and a change that large reads as a change
/// of mode only if it is watched happening. Out gets out of the way of what the drop is doing.
pub const appear_ms: f32 = 240;
pub const vanish_ms: f32 = 150;
/// A time constant: how quickly a zone lights or dims under the pointer, most of the way in
/// about three of these.
pub const light_ms: f32 = 55;
/// How far a zone stands in from its rect while it is not there yet: it grows into place as
/// it frosts over, and shrinks back as it clears.
const grow_from: f32 = 0.9;

const State = struct {
    /// 0…1, linear in time; eased when read (`strength`).
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
    /// False fades them all out — the place can no longer be dropped on (the drag ended) —
    /// until `showing` says they are gone.
    target: bool = true,
    /// The middle's icon.
    center: Center = .replace,
    /// Frame time before which the zones hold at nothing. A drag gives every place a start a
    /// little after the last, nearest first, so the targets spread out from where the view was
    /// picked up rather than all landing on the window in the same instant.
    appear_at_ns: i128 = 0,
};

/// White added over a lit zone's glass, on top of the dialogs' own lift.
const lit_lift: f32 = 0.10;
/// Points: an icon's size.
const icon_size: f32 = 18;

/// Draw the zones over `r`, keyed by `id` (the place's).
///
/// **The glass is the dialogs' own** — `core.dialogs`' frost: its radius, tint, mix and lift, a
/// live blur of whatever is under each zone — with a faint icon saying what the zone does: a
/// pane opening on that edge, or the middle's trade, add or join. The zone under the pointer
/// lights — lifted brighter, its icon at full strength.
///
/// **Coming and going.** A zone grows into its rect as its glass frosts over, eased in and out,
/// and its icon arrives once the glass is mostly there; going, the same backwards and quicker.
/// Never by opacity: a frost *replaces* what it covers (a see-through window's content would
/// otherwise show through it), so thinner glass is less blur, not a fainter pane.
///
/// **One capture per place.** The unlit zones are cut from one frosted layer over the place:
/// one read of the frame and one blur, not five. Only a zone lighting or dimming takes a pane
/// of its own, which is one or two at a time. With the blur off it is the dialogs' fill, faded
/// the same way.
///
/// Call every frame the place can be dropped on, and after while `showing`, after what the zones
/// cover has drawn. Faded out, a place forgets its zones, so the next time they come in anew.
pub fn draw(id: dvui.Id, r: Rects, scale: f32, look: Look) void {
    const st = dvui.dataGetPtrDefault(null, id, "_drop_zones", State, .{});
    const now = dvui.currentWindow().frame_time_ns;
    // A gap of more than a few frames is a new visit: start from nothing.
    if (st.last_ns == 0 or now - st.last_ns > 200 * std.time.ns_per_ms) st.* = .{ .last_ns = now };
    const dt_ms: f32 = @as(f32, @floatFromInt(now - st.last_ns)) / std.time.ns_per_ms;
    st.last_ns = now;

    const waiting = look.target and now < look.appear_at_ns;
    const want_shown: f32 = if (look.target and !waiting) 1 else 0;
    st.shown = step(st.shown, want_shown, dt_ms, if (want_shown > st.shown) appear_ms else vanish_ms);
    const g = strength(st.shown);
    var moving = st.shown != want_shown or waiting;
    for (all, 0..) |z, i| {
        const want_lit: f32 = if (look.target) (if (look.hovered) |h| (if (h.eql(z)) 1 else 0) else 0) else 0;
        st.lit[i] = approach(st.lit[i], want_lit, dt_ms, light_ms);
        if (st.lit[i] != want_lit) moving = true;
    }

    if (g > 0.01) {
        var shown_r: [all.len]dvui.Rect.Physical = undefined;
        const k = grow_from + (1 - grow_from) * g;
        for (all, 0..) |z, i| shown_r[i] = shrink(r.of(z), k);
        glass(id, &shown_r, &st.lit, g, scale);
        for (all, 0..) |z, i| {
            if (z == .center and look.center == .none) continue;
            drawIcon(shown_r[i], iconFor(z, look.center), g, st.lit[i], scale);
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
/// `rect` is the two places together; null while no join is aimed at, and the pane fades out
/// over the last place it covered. Draw after every place has drawn (it lies over their zones
/// as they step back), keyed by one `id` for the whole window.
pub fn drawJoin(id: dvui.Id, rect: ?dvui.Rect.Physical, scale: f32) void {
    const JoinState = struct { shown: f32 = 0, last_ns: i128 = 0, rect: dvui.Rect.Physical = .{} };
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
    // Quicker than the zones coming in: this answers the pointer, it is not a change of mode.
    st.shown = step(st.shown, want, dt_ms, if (want > st.shown) 160 else vanish_ms);
    const g = strength(st.shown);
    if (g > 0.01 and st.rect.w >= 1 and st.rect.h >= 1) {
        const k = 0.97 + 0.03 * g;
        const zr = shrink(st.rect, k);
        const rects_one = [_]dvui.Rect.Physical{zr};
        const lit_one = [_]f32{1};
        glass(dvui.Id.extendId(id, @src(), 0), &rects_one, &lit_one, g, scale);
        drawIcon(zr, .{ .name = "drop_zone_join", .tvg = icons.tvg.lucide.@"squares-unite" }, g, 1, scale);
    }
    if (st.shown != want) {
        dvui.refresh(null, @src(), id);
    } else if (rect == null) {
        dvui.dataRemove(null, id, "_drop_join");
    }
}

/// The frost under `zones` at strength `g`: unlit ones cut from one shared layer, lit ones a
/// pane each.
fn glass(id: dvui.Id, zones: []const dvui.Rect.Physical, lit: []const f32, g: f32, scale: f32) void {
    // Finalized, as a widget's options would be: an unresolved corner draws square whatever
    // radius it names.
    const theme = dvui.themeGet();
    const corners_nat = dialogs.surface_corners.finalize(&theme);
    const corners = corners_nat.scale(scale, dvui.CornerRect.Physical);
    const base = widgets.menuFrost() orelse {
        const fill = dialogs.dialogFill();
        for (zones, 0..) |zr, i| {
            if (zr.w < 1 or zr.h < 1) continue;
            const c = fill.lerp(.white, lit_lift * lit[i]);
            zr.fill(corners, .{ .color = .{ .color = c.opacity(@as(f32, @floatFromInt(c.a)) / 255 * g) }, .fade = 1.0 });
        }
        return;
    };
    const job = dvui.dataGetPtrDefault(null, id, "_drop_zones_job", LayerJob, .{});
    job.* = .{ .backdrop = job.backdrop, .corners = corners_nat, .scale = scale };
    for (zones, 0..) |zr, i| {
        if (zr.w < 1 or zr.h < 1) continue;
        if (lit[i] <= 0.002) {
            job.zones[job.count] = zr;
            job.count += 1;
        } else {
            var pane = scaled(base, g);
            pane.lift = std.math.clamp(pane.lift + lit_lift * lit[i], 0, 1);
            BlurBackdrop.frostPane(dvui.Id.extendId(id, @src(), i), zr, corners_nat, scale, pane);
        }
    }
    if (job.count == 0) return;
    // The layer covers the zones it serves and nothing else, so what it reads back and blurs is
    // only what the glass will show.
    var bounds = job.zones[0];
    for (job.zones[1..job.count]) |zr| bounds = bounds.unionWith(zr);
    job.pane = scaled(base, g);
    job.bounds = bounds;
    const backdrop = dvui.dataGetPtrDefault(null, id, "_drop_zones_frost", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "_drop_zones_frost", &BlurBackdrop.releaseTexture);
    backdrop.mode = .readback;
    backdrop.radius_px = job.pane.radius;
    backdrop.detail = job.pane.detail;
    // Re-read every frame: what is under the zones moves for the whole of a drag.
    backdrop.init(dvui.windowRectScale().rectFromPhysical(bounds), .{ bounds, dvui.currentWindow().frame_time_ns, job.pane.radius });
    job.backdrop = backdrop;
    dvui.deferRender(job, LayerJob.draw);
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

/// `r` scaled by `k` about its own centre.
fn shrink(r: dvui.Rect.Physical, k: f32) dvui.Rect.Physical {
    if (k >= 1) return r;
    const w = r.w * k;
    const h = r.h * k;
    return .{ .x = r.x + (r.w - w) / 2, .y = r.y + (r.h - h) / 2, .w = w, .h = h };
}

const Glyph = struct { name: []const u8, tvg: []const u8 };

/// What each zone's icon shows: a pane opening on that side, or the middle's trade or join.
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

/// `base` at strength `g`: its blur, tint and lift all scaled together, so a weaker frost is the
/// same glass, thinner.
fn scaled(base: BlurBackdrop.Pane, g: f32) BlurBackdrop.Pane {
    var pane = base;
    pane.radius = base.radius * g;
    pane.mix = base.mix * g;
    pane.lift = base.lift * g;
    return pane;
}

/// The shared layer, drawn at replay once everything under the zones is on the frame: read and
/// blur `bounds` once, then lay each zone's slice of it down with the dialogs' tint and lift.
const LayerJob = struct {
    backdrop: ?*BlurBackdrop = null,
    pane: BlurBackdrop.Pane = .{},
    bounds: dvui.Rect.Physical = .{},
    corners: dvui.CornerRect = .{},
    scale: f32 = 1,
    zones: [all.len]dvui.Rect.Physical = undefined,
    count: usize = 0,

    fn draw(ctx: ?*anyopaque) void {
        const self: *LayerJob = @ptrCast(@alignCast(ctx orelse return));
        const backdrop = self.backdrop orelse return;
        backdrop.deinit();
        const tex = backdrop.small orelse return;
        const b = self.bounds;
        if (b.w < 1 or b.h < 1) return;
        const mix = std.math.clamp(self.pane.mix, 0, 1);
        for (self.zones[0..self.count]) |zr| {
            const uv: dvui.Rect = .{ .x = (zr.x - b.x) / b.w, .y = (zr.y - b.y) / b.h, .w = zr.w / b.w, .h = zr.h / b.h };
            // As `frostPane` composes it: the frost at `1 - mix` of itself, then the tint and
            // the lift added over it.
            if (self.pane.tint != null) {
                dvui.renderTexture(tex, .{ .r = zr, .s = self.scale }, .{ .corners = self.corners, .uv = uv, .colormod = dvui.Color.white.opacity(1 - mix) }) catch {};
                BlurBackdrop.addTint(zr, self.corners, self.scale, self.pane.tint.?, mix);
                BlurBackdrop.addTint(zr, self.corners, self.scale, .white, std.math.clamp(self.pane.lift, 0, 1));
            } else {
                dvui.renderTexture(tex, .{ .r = zr, .s = self.scale }, .{ .corners = self.corners, .uv = uv }) catch {};
            }
        }
    }
};

/// How much of a zone is there at progress `t`: eased in and out, so it neither pops on at
/// the start nor snaps to rest at the end.
fn strength(t: f32) f32 {
    const u = std.math.clamp(t, 0, 1);
    return if (u < 0.5) 4 * u * u * u else 1 - std.math.pow(f32, -2 * u + 2, 3) / 2;
}

/// `v` moved toward `target` at a constant rate: all the way in `dur_ms`.
fn step(v: f32, target: f32, dt_ms: f32, dur_ms: f32) f32 {
    if (dt_ms <= 0) return v;
    const d = dt_ms / dur_ms;
    return if (target > v) @min(target, v + d) else @max(target, v - d);
}

/// Whether `id`'s zones are still on screen: shown, or fading out.
pub fn showing(id: dvui.Id) bool {
    const st = dvui.dataGetPtr(null, id, "_drop_zones", State) orelse return false;
    return st.shown > 0;
}

/// Drop `id`'s zones outright: the next time its place is the target they fade in from nothing.
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
