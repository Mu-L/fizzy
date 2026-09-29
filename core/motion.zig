//! How things move: one user setting, `level`, that every animation in the app — and in any
//! plugin that asks — reads to decide its character.
//!
//! The setting is a gradient, not a switch:
//!
//!   * **0, off** — nothing animates. dvui's own animations end the frame they start
//!     (`dvui.reduce_motion`), and everything drawn here should jump straight to where it is
//!     going (`off`). A system asking for reduced motion puts the app here whatever the setting.
//!   * **just above 0** — motion, but plain: linear, constant speed, nothing overshoots, nothing
//!     ripples.
//!   * **0.5, minimal** — the app's clean character: things arriving overshoot a touch and
//!     settle, things leaving draw back before they go, moves decelerate. Frosted glass bends
//!     what it shows at its edges, the way a thick pane does. Nothing wobbles.
//!   * **1, playful** — springier arrivals that jiggle before they settle, glass that ripples
//!     as it appears and as it is touched.
//!
//! Between those points everything is a blend, so the slider is a slider.
//!
//! **Ask by intent, not by curve.** A call site says what the motion *is* — something arriving
//! (`enter`), leaving (`exit`), moving to a new place (`settle`), or fading (`fade`) — and gets the
//! curve the level gives that. They are plain `fn (f32) f32`, the shape `dvui.animation` takes, so
//! they drop in wherever a `dvui.easing` function went; they read the level when evaluated.
//! Effects that are not curves ask for an amount: `playful` for ripples and jiggle, `liquid`
//! for the glass's refraction.
//!
//! **One value everywhere.** The host publishes the level into the shared dvui window each frame
//! (`publish`); a plugin dylib's copy of this file reads it from there, the way it reads the
//! dialog style. A plugin that wants its motion to match the app's calls these and nothing else.
const std = @import("std");
const dvui = @import("dvui");

/// The level when nothing has been published: minimal, the app's own character.
pub const default_level: f32 = 0.5;

const publish_id: dvui.Id = @enumFromInt(0x6669_7a7a_6d6f_7469); // "fizzmoti"
const publish_key = "_motion_level";

/// Host only, once a frame before anything animates: this frame's level, where every image's
/// `level()` finds it, and dvui's own animations told whether to run at all. A system that asks
/// for reduced motion gets off, whatever the setting says.
pub fn publish(setting: f32, system_prefers_reduced: bool) void {
    const v: f32 = if (system_prefers_reduced) 0 else std.math.clamp(setting, 0, 1);
    dvui.dataSet(null, publish_id, publish_key, v);
    apply();
}

/// Bring this image's copy of dvui in line with the published level — the host's in `publish`,
/// a plugin's when the host hands it the window (`sdk.dvui_context.inject`).
pub fn apply() void {
    dvui.reduce_motion = off();
}

/// 0 (off) to 1 (playful). Minimal, 0.5, outside a window or before anything was published.
pub fn level() f32 {
    if (dvui.current_window == null) return default_level;
    return dvui.dataGet(null, publish_id, publish_key, f32) orelse default_level;
}

/// Nothing moves: jump to where it is going.
pub fn off() bool {
    return level() <= 0.001;
}

/// How much of the playful end is on: 0 up to minimal, rising to 1 at playful. Ripples, jiggle,
/// anything that is there to delight rather than to explain, scales by this.
pub fn playful() f32 {
    return std.math.clamp((level() - 0.5) * 2, 0, 1);
}

/// How much frosted glass bends what it shows — the refraction at its edges: none at off,
/// rising to all of it by minimal, and no more past it (playful adds ripples, not a thicker
/// lens).
pub fn liquid() f32 {
    return std.math.clamp(level() * 2, 0, 1);
}

/// A duration in microseconds, at this level: nothing at off, a little longer at playful so a
/// spring has room to settle.
pub fn duration(us: i32) i32 {
    if (off()) return 0;
    const k = 1 + 0.2 * playful();
    return @intFromFloat(@as(f32, @floatFromInt(us)) * k);
}

/// The same in milliseconds, for animations stepped by hand.
pub fn durationMs(ms: f32) f32 {
    if (off()) return 0;
    return ms * (1 + 0.2 * playful());
}

// ── Curves by intent ────────────────────────────────────────────────────────────────────────────

/// Something arriving — opening, appearing, growing into place. Linear at the plain end, a clean
/// overshoot at minimal, a spring that jiggles once at playful.
pub fn enter(t: f32) f32 {
    return enterAt(level(), t);
}

/// Something leaving — closing, shrinking away. `enter` run backwards: at minimal it draws back
/// a touch before it goes.
pub fn exit(t: f32) f32 {
    return 1 - enterAt(level(), 1 - t);
}

/// Something moving to a new place or size — a slide, a resize, a reorder. Linear at the plain
/// end, a clean deceleration at minimal, a small overshoot at playful.
pub fn settle(t: f32) f32 {
    return settleAt(level(), t);
}

/// Opacity. Never overshoots at any level: linear at the plain end, eased out from minimal on.
pub fn fade(t: f32) f32 {
    const u = clamp01(t);
    return lerp(u, outCubic(u), std.math.clamp(level() * 2, 0, 1));
}

/// `enter` at a given level, for a call site (or a test) that has its own.
pub fn enterAt(lv: f32, t: f32) f32 {
    const u = clamp01(t);
    if (u >= 1) return 1;
    if (lv <= 0.5) return lerp(u, outBack(u, 1.70158), lv * 2);
    return lerp(outBack(u, 1.70158), spring(u), (lv - 0.5) * 2);
}

/// `settle` at a given level.
pub fn settleAt(lv: f32, t: f32) f32 {
    const u = clamp01(t);
    if (u >= 1) return 1;
    if (lv <= 0.5) return lerp(u, outCubic(u), lv * 2);
    return lerp(outCubic(u), outBack(u, 1.2), (lv - 0.5) * 2);
}

fn outBack(t: f32, c1: f32) f32 {
    const c3 = c1 + 1;
    const v = t - 1;
    return 1 + c3 * v * v * v + c1 * v * v;
}

fn outCubic(t: f32) f32 {
    const v = 1 - t;
    return 1 - v * v * v;
}

/// A damped spring that lands exactly on 1 at t = 1: about 15% over, then a small dip under,
/// then home — the jiggle.
fn spring(t: f32) f32 {
    return 1 - @exp(-3.5 * t) * @cos(2.5 * std.math.pi * t) * (1 - t);
}

fn lerp(a: f32, b: f32, k: f32) f32 {
    return a + (b - a) * k;
}

fn clamp01(t: f32) f32 {
    return std.math.clamp(t, 0, 1);
}
