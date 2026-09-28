//! The drop targets over a place while something is dragged onto it: one in the middle and one
//! along each edge, all drawn at once so every option the place offers is in view.
//!
//! **One geometry, one look, for every drag.** A view dragged between places and a tab dragged
//! between panes read the pointer against the same five rects (`rects`, `at`) and draw the same
//! zones (`draw`), so a drop means the same thing wherever it lands and looks the same getting
//! there.
//!
//! **The look is the preview showing through.** A zone is a pane of frosted glass cut from a
//! blurred picture of the place — no tint, the app's one surface rounding, a gap around each. It
//! fades in, blurred, when the place becomes the target; the zone under the pointer dissolves
//! sharp, showing what is under it (in a view drag, the live preview of that drop); moving off it
//! blurs it back. What is underneath is the caller's: this only draws the glass over it.
//!
//! **Every point of a place is some zone.** The gaps between the rects are there to be seen, not
//! to be dead space: a point in one resolves to the nearest zone, so a drop never does nothing
//! just because it fell between two targets.
const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("../dialogs.zig");

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

/// Points. The gap around and between zones; an edge band's thickness, capped as a fraction of
/// the place so a small place keeps a middle; and how far the middle stands back from the bands.
pub const gap: f32 = 8;
pub const band: f32 = 64;
pub const band_fraction: f32 = 0.22;
pub const center_margin: f32 = 24;

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
    // What is left between the bands, then the middle's own margin inside that — never more
    // than a sixth of it, so a small place's middle does not vanish.
    const space = inset(inner, tx + g, ty + g);
    const mx = @min(center_margin * scale, space.w / 6);
    const my = @min(center_margin * scale, space.h / 6);
    return .{
        .center = inset(space, mx, my),
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

/// A blurred picture of the place, and the rect it was taken over — what the glass is cut from.
pub const Frosted = struct {
    texture: dvui.Texture,
    rect: dvui.Rect.Physical,
};

/// How long a zone takes to fade in, and to sharpen or blur again, as a time constant: most of
/// the way there in about three of these.
pub const appear_ms: f32 = 60;
pub const sharpen_ms: f32 = 45;

const State = struct {
    shown: [all.len]f32 = @splat(0),
    sharp: [all.len]f32 = @splat(0),
    last_ns: i128 = 0,
};

/// Draw the zones over `r`, keyed by `id` (the place's). `hovered` is the zone under the pointer,
/// which sharpens; the rest stay frosted. `frost` null (the blur is off, or the picture is not
/// taken yet) draws the glass as a plain translucent fill instead. `target` false fades them all
/// out — the pointer has moved to another place — until `showing` says they are gone.
///
/// Call every frame the place is the target, and after while `showing`, after what the zones
/// reveal has drawn. Faded out, a place forgets its zones, so the next time it is the target
/// they fade in anew.
pub fn draw(id: dvui.Id, r: Rects, hovered: ?Zone, frost: ?Frosted, scale: f32, target: bool) void {
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
    var moving = false;
    for (all, 0..) |z, i| {
        st.shown[i] = approach(st.shown[i], if (target) 1 else 0, dt_ms, appear_ms);
        const want: f32 = if (hovered) |h| (if (h.eql(z)) 1 else 0) else 0;
        st.sharp[i] = approach(st.sharp[i], want, dt_ms, sharpen_ms);
        if (@abs(st.shown[i] - @as(f32, if (target) 1 else 0)) > 0.002 or @abs(st.sharp[i] - want) > 0.002) moving = true;

        const alpha = st.shown[i] * (1 - st.sharp[i]);
        if (alpha <= 0.002) continue;
        const zr = r.of(z);
        if (zr.w < 1 or zr.h < 1) continue;
        if (frost) |f| {
            if (f.rect.w < 1 or f.rect.h < 1) continue;
            // The zone's own slice of the picture, so the glass sits over what it blurs.
            const uv: dvui.Rect = .{
                .x = std.math.clamp((zr.x - f.rect.x) / f.rect.w, 0, 1),
                .y = std.math.clamp((zr.y - f.rect.y) / f.rect.h, 0, 1),
                .w = std.math.clamp(zr.w / f.rect.w, 0, 1),
                .h = std.math.clamp(zr.h / f.rect.h, 0, 1),
            };
            dvui.renderTexture(f.texture, .{ .r = zr, .s = scale }, .{
                .corners = corners_nat,
                .uv = uv,
                .colormod = dvui.Color.white.opacity(alpha),
            }) catch {};
        } else {
            zr.fill(corners, .{ .color = .{ .color = theme.color(.window, .fill).opacity(0.6 * alpha) }, .fade = 1.0 });
        }
    }
    if (moving) {
        dvui.refresh(null, @src(), id);
    } else if (!target) {
        forget(id);
    }
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
