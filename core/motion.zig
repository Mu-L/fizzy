//! How things move: one user setting, `level`, that every animation in the app — and in any
//! plugin that asks — reads to decide its character.
//!
//! The setting is a gradient, not a switch:
//!
//!   * **0, off** — nothing animates. dvui's own animations end the frame they start
//!     (`dvui.reduce_motion`), and everything drawn here should jump straight to where it is
//!     going (`off`). A system asking for reduced motion puts the app here whatever the setting.
//!   * **up to 0.5, minimal** — plain motion: linear, constant speed, nothing overshoots.
//!   * **0.5 to 1, playful** — things carry on past where they are going and settle back, more
//!     the further up: at 1 about 12% past. Frosted glass has a refracting edge from minimal on
//!     (`liquid`).
//!
//! **Every level arrives on time.** Whatever the level, a motion reaches its target at the
//! duration it was given (divided by the speed setting). An overshoot is not squeezed into that
//! time — a curve that arrives early to leave room for its swing reads as faster, and the slider
//! was changing speed where it should only change character — it is added after it:
//! `duration` stretches every animation by the share the swing takes at this level (`stretch`),
//! the curves arrive at the old end of it, and fades hold still for the rest. So the slider
//! changes how a motion ends, never how long it takes to get there; how long is the **speed**
//! setting's, a window from half as fast to twice as fast which never stops motion outright —
//! that is off's job.
//!
//! **Ask by intent, not by curve.** A call site says what the motion *is* — something arriving
//! (`enter`), leaving (`exit`), moving to a new place (`settle`), or fading (`fade`) — and gets the
//! curve the level gives that. They are plain `fn (f32) f32`, the shape `dvui.animation` takes, so
//! they drop in wherever a `dvui.easing` function went; they read the level when evaluated.
//! Effects that are not curves ask for an amount: `liquid`, for how much frosted glass's bevel
//! refracts and catches the light.
//!
//! **One value everywhere.** The host publishes the level into the shared dvui window each frame
//! (`publish`); a plugin dylib's copy of this file reads it from there, the way it reads the
//! dialog style. A plugin that wants its motion to match the app's calls these and nothing else.
const std = @import("std");
const dvui = @import("dvui");

/// The level when nothing has been published: minimal, the app's own character.
pub const default_level: f32 = 0.5;
/// The speed setting's middle: durations as written.
pub const default_speed: f32 = 0.5;
/// How much faster the fastest speed is than as written, and the slowest slower.
pub const speed_range: f32 = 2;

const publish_id: dvui.Id = @enumFromInt(0x6669_7a7a_6d6f_7469); // "fizzmoti"
const publish_key = "_motion";

/// What the host publishes each frame.
const Published = struct {
    level: f32 = default_level,
    /// How many times faster than written: `1 / speed_range` to `speed_range`.
    rate: f32 = 1,
};

/// Host only, once a frame before anything animates: this frame's level and speed, where every
/// image's copy of this file finds them, and dvui's own animations told whether to run at all.
/// `level` and `speed` are the settings, each 0 to 1. A system that asks for reduced motion gets
/// off, whatever the setting says.
pub fn publish(level_setting: f32, speed_setting: f32, system_prefers_reduced: bool) void {
    const v: f32 = if (system_prefers_reduced) 0 else std.math.clamp(level_setting, 0, 1);
    dvui.dataSet(null, publish_id, publish_key, Published{ .level = v, .rate = rateFor(speed_setting) });
    apply();
}

/// The speed setting (0 slow, 0.5 as written, 1 fast) as a rate: evenly spaced in doublings, so
/// the middle of the slider is the middle of how it feels.
pub fn rateFor(speed_setting: f32) f32 {
    const s = std.math.clamp(speed_setting, 0, 1);
    return std.math.pow(f32, speed_range, (s - 0.5) * 2);
}

fn published() Published {
    if (dvui.current_window == null) return .{};
    return dvui.dataGet(null, publish_id, publish_key, Published) orelse .{};
}

/// Bring this image's copy of dvui in line with the published level — the host's in `publish`,
/// a plugin's when the host hands it the window (`sdk.dvui_context.inject`).
pub fn apply() void {
    dvui.reduce_motion = off();
}

/// 0 (off) to 1 (playful). Minimal, 0.5, outside a window or before anything was published.
pub fn level() f32 {
    return published().level;
}

/// How many times faster than written motion runs (the speed setting): 0.5 to 2, never 0.
pub fn rate() f32 {
    return published().rate;
}

/// Nothing moves: jump to where it is going.
pub fn off() bool {
    return level() <= 0.001;
}

/// How much frosted glass's bevelled edge refracts, clears and catches the light
/// (`core.liquid_glass`): none at off, rising to all of it by minimal, and no more past it.
pub fn liquid() f32 {
    return std.math.clamp(level() * 2, 0, 1);
}

/// A duration in microseconds as the user wants it: at their speed, stretched to leave room after
/// the arrival for this level's overshoot (`stretch`), and a single microsecond (done at once)
/// when motion is off. Pass every duration an animation runs for through this, paired with one of
/// the curves below — they arrive at the unstretched duration.
pub fn duration(us: i32) i32 {
    if (off()) return 1;
    return @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(us)) * stretch() / rate())));
}

/// The same in milliseconds, for animations stepped by hand: 0 when off.
pub fn durationMs(ms: f32) f32 {
    return if (off()) 0 else ms * stretch() / rate();
}

/// How much longer than its arrival an animation runs at this level, for the overshoot to swing
/// and settle in: 1 up to minimal, rising to 1 / (1 - `swing_max`) at playful.
pub fn stretch() f32 {
    return 1 / arrivalAt(level());
}

/// The share of an animation its overshoot takes at playful.
pub const swing_max: f32 = 0.4;

/// When, as a share of an animation at level `lv` (stretched by `stretch`), its curves arrive.
pub fn arrivalAt(lv: f32) f32 {
    return 1 - swing_max * std.math.clamp((lv - 0.5) * 2, 0, 1);
}

// ── Curves by intent ────────────────────────────────────────────────────────────────────────────

/// Something arriving — opening, appearing, growing into place: at constant speed to its target,
/// then, above minimal, carrying on past it and settling back.
pub fn enter(t: f32) f32 {
    return enterAt(level(), t);
}

/// Something leaving — closing, shrinking away. `enter` run backwards: above minimal it draws
/// back first, then leaves at constant speed, taking exactly its duration to go.
pub fn exit(t: f32) f32 {
    return 1 - enterAt(level(), 1 - t);
}

/// Something moving to a new place or size — a slide, a resize, a reorder. The same motion as
/// `enter`: every kind of motion arrives on the same clock.
pub fn settle(t: f32) f32 {
    return settleAt(level(), t);
}

/// Opacity: linear, arriving when everything else does and holding while an overshoot swings.
/// Never past 1 — a fade has nowhere to overshoot to.
pub fn fade(t: f32) f32 {
    return clamp01(t / arrivalAt(level()));
}

/// `enter` at a given level, for a call site (or a test) that has its own. Linear to the target
/// at the arrival share, then a swing that leaves with the approach's own speed — so there is no
/// kink as it passes — rises, and comes back to rest exactly at the end.
pub fn enterAt(lv: f32, t: f32) f32 {
    const u = clamp01(t);
    if (u >= 1) return 1;
    const a = arrivalAt(lv);
    if (u <= a) return u / a;
    const swing = 1 - a;
    const x = (u - a) / swing;
    // y = 1 + B·sin(πx)·(1 − x): leaves 1 with slope B·π/swing, which is the approach's 1/a, and
    // lands back on 1 at rest.
    const b = swing / (std.math.pi * a);
    return 1 + b * @sin(std.math.pi * x) * (1 - x);
}

/// `settle` at a given level.
pub fn settleAt(lv: f32, t: f32) f32 {
    return enterAt(lv, t);
}

fn lerp(a: f32, b: f32, k: f32) f32 {
    return a + (b - a) * k;
}

fn clamp01(t: f32) f32 {
    return std.math.clamp(t, 0, 1);
}
