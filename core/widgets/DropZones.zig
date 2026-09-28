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

/// How long a zone takes to fade in or out, and to light or dim, as a time constant: most of
/// the way there in about three of these.
pub const appear_ms: f32 = 70;
pub const light_ms: f32 = 55;

const State = struct {
    shown: [all.len]f32 = @splat(0),
    /// 0…1: how lit — the zone under the pointer.
    lit: [all.len]f32 = @splat(0),
    last_ns: i128 = 0,
};

/// What dropping in the middle does, for its icon: trade places with the one view a place shows,
/// or join the several it shows.
pub const Center = enum { replace, add };

/// White added over a lit zone's glass, on top of the dialogs' own lift.
const lit_lift: f32 = 0.10;
/// Points: an icon's size.
const icon_size: f32 = 18;

/// Draw the zones over `r`, keyed by `id` (the place's). `hovered` is the zone under the pointer,
/// which lights; `target` false fades them all out — the place can no longer be dropped on (the
/// drag ended) — until `showing` says they are gone. `center` picks the middle's icon.
///
/// **The glass is the dialogs' own** — `core.dialogs`' frost: its radius, tint, mix and lift, a
/// live blur of whatever is under each zone — with a faint icon saying what the zone does: a
/// pane opening on that edge, or the middle's trade or join. Fading in grows the blur and tint
/// from nothing; never the opacity: a frost *replaces* what it covers (a see-through window's
/// content would otherwise show through it), so thinner glass is less blur, not a fainter pane.
/// The zone under the pointer lights — lifted brighter, its icon at full strength.
///
/// **One capture per place.** The zones at the same strength are cut from one frosted layer over
/// the place: one read of the frame and one blur, not five. Only a zone lighting or dimming takes
/// a pane of its own, which is one or two at a time. With the blur off it is the dialogs' fill,
/// faded the same way.
///
/// Call every frame the place can be dropped on, and after while `showing`, after what the zones
/// cover has drawn. Faded out, a place forgets its zones, so the next time they fade in anew.
pub fn draw(id: dvui.Id, r: Rects, hovered: ?Zone, scale: f32, target: bool, center: Center) void {
    const st = dvui.dataGetPtrDefault(null, id, "_drop_zones", State, .{});
    const now = dvui.currentWindow().frame_time_ns;
    // A gap of more than a few frames is a new visit: start from nothing.
    if (st.last_ns == 0 or now - st.last_ns > 200 * std.time.ns_per_ms) st.* = .{ .last_ns = now };
    const dt_ms: f32 = @as(f32, @floatFromInt(now - st.last_ns)) / std.time.ns_per_ms;
    st.last_ns = now;

    // Finalized, as a widget's options would be: an unresolved corner draws square whatever
    // radius it names.
    const theme = dvui.themeGet();
    const corners_nat = dialogs.surface_corners.finalize(&theme);
    const corners = corners_nat.scale(scale, dvui.CornerRect.Physical);
    const frost = widgets.menuFrost();

    const want_shown: f32 = if (target) 1 else 0;
    var moving = false;
    var strength: [all.len]f32 = undefined;
    for (all, 0..) |z, i| {
        st.shown[i] = approach(st.shown[i], want_shown, dt_ms, appear_ms);
        const want_lit: f32 = if (target) (if (hovered) |h| (if (h.eql(z)) 1 else 0) else 0) else 0;
        st.lit[i] = approach(st.lit[i], want_lit, dt_ms, light_ms);
        if (@abs(st.shown[i] - want_shown) > 0.002 or @abs(st.lit[i] - want_lit) > 0.002) moving = true;
        strength[i] = easeOut(st.shown[i]);
    }

    if (frost) |base| {
        const job = dvui.dataGetPtrDefault(null, id, "_drop_zones_job", LayerJob, .{});
        job.* = .{ .backdrop = job.backdrop, .corners = corners_nat, .scale = scale };
        var layer: f32 = 0;
        for (all, 0..) |z, i| {
            const g = strength[i];
            if (g <= 0.01) continue;
            const zr = r.of(z);
            if (zr.w < 1 or zr.h < 1) continue;
            if (st.lit[i] <= 0.002) {
                // Unlit: one of the layer's slices. They all share a strength (`shown` moves
                // together), so the first one says what the layer is.
                layer = g;
                job.zones[job.count] = zr;
                job.count += 1;
            } else {
                var pane = scaled(base, g);
                pane.lift = std.math.clamp(pane.lift + lit_lift * st.lit[i], 0, 1);
                BlurBackdrop.frostPane(dvui.Id.extendId(id, @src(), i), zr, corners_nat, scale, pane);
            }
        }
        if (job.count > 0 and layer > 0.01) {
            // The layer covers the zones it serves and nothing else, so what it reads back and
            // blurs is only what the glass will show.
            var bounds = job.zones[0];
            for (job.zones[1..job.count]) |zr| bounds = bounds.unionWith(zr);
            job.pane = scaled(base, layer);
            job.bounds = bounds;
            const backdrop = dvui.dataGetPtrDefault(null, id, "_drop_zones_frost", BlurBackdrop, .{});
            dvui.dataSetDeinitFunction(null, id, "_drop_zones_frost", &BlurBackdrop.releaseTexture);
            backdrop.mode = .readback;
            backdrop.radius_px = job.pane.radius;
            backdrop.detail = job.pane.detail;
            // Re-read every frame: what is under the zones moves for the whole of a drag.
            backdrop.init(dvui.windowRectScale().rectFromPhysical(bounds), .{ bounds, now, job.pane.radius });
            job.backdrop = backdrop;
            dvui.deferRender(job, LayerJob.draw);
        }
    } else {
        const fill = dialogs.dialogFill();
        for (all, 0..) |z, i| {
            const g = strength[i];
            if (g <= 0.01) continue;
            const zr = r.of(z);
            if (zr.w < 1 or zr.h < 1) continue;
            const c = fill.lerp(.white, lit_lift * st.lit[i]);
            zr.fill(corners, .{ .color = .{ .color = c.opacity(@as(f32, @floatFromInt(c.a)) / 255 * g) }, .fade = 1.0 });
        }
    }

    // The icons, over the glass (queued after it, so drawn after it). Faint until lit; blended
    // toward the glass rather than made translucent, so a glyph's crossing strokes never show.
    const ink = theme.color(.window, .text);
    const glass = dialogs.dialogFill().opacity(1);
    for (all, 0..) |z, i| {
        const g = strength[i];
        if (g <= 0.01) continue;
        const zr = r.of(z);
        const side = icon_size * scale;
        if (zr.w < side * 1.5 or zr.h < side * 1.5) continue;
        const strength_ink = g * (0.35 + 0.65 * st.lit[i]);
        const color = glass.lerp(ink, strength_ink);
        const at_r: dvui.Rect.Physical = .{ .x = zr.x + (zr.w - side) / 2, .y = zr.y + (zr.h - side) / 2, .w = side, .h = side };
        const glyph = iconFor(z, center);
        icon_tex.render(glyph.name, glyph.tvg, .{ .r = at_r, .s = scale }, .{}, .{
            .stroke_color = .{ .color = color },
            .fill_color = .transparent,
        });
    }

    if (moving) {
        dvui.refresh(null, @src(), id);
    } else if (!target) {
        forget(id);
    }
}

const Glyph = struct { name: []const u8, tvg: []const u8 };

/// What each zone's icon shows: a pane opening on that side, or the middle's trade or join.
fn iconFor(z: Zone, center: Center) Glyph {
    return switch (z) {
        .center => switch (center) {
            .replace => .{ .name = "drop_zone_replace", .tvg = icons.tvg.lucide.replace },
            .add => .{ .name = "drop_zone_add", .tvg = icons.tvg.lucide.@"square-plus" },
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

fn easeOut(t: f32) f32 {
    const u = std.math.clamp(t, 0, 1);
    return 1 - (1 - u) * (1 - u);
}

/// Whether `id`'s zones are still on screen: shown, or fading out.
pub fn showing(id: dvui.Id) bool {
    const st = dvui.dataGetPtr(null, id, "_drop_zones", State) orelse return false;
    for (st.shown) |v| if (v > 0.002) return true;
    return false;
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
