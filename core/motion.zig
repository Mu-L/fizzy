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
//!   * **0.5, minimal** — the app's clean character: things arriving slide in with a smooth,
//!     slight bounce, things leaving draw back a touch before they go, moves decelerate. Frosted
//!     glass bends what it shows at its edges, the way a thick pane does. Nothing wobbles.
//!   * **1, playful** — very smooth and fluid: arrivals start from rest and glide in on a soft
//!     spring, and glass ripples as it appears and as it is touched.
//!
//! Between those points everything is a blend, so the slider is a slider — of *character*, not
//! speed. **Speed** is its own setting: a window from half as fast to twice as fast, which every
//! duration passes through (`duration`) and which never stops motion outright — that is off's job.
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

/// A duration in microseconds as the user wants it: at their speed, and a single microsecond
/// (done at once) when motion is off. The level changes how a motion is shaped, never how long
/// it takes; the speed is what changes that. Pass every duration an animation runs for through
/// this.
pub fn duration(us: i32) i32 {
    if (off()) return 1;
    return @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(us)) / rate())));
}

/// The same in milliseconds, for animations stepped by hand: 0 when off.
pub fn durationMs(ms: f32) f32 {
    return if (off()) 0 else ms / rate();
}

// ── Curves by intent ────────────────────────────────────────────────────────────────────────────

/// Something arriving — opening, appearing, growing into place. Linear at the plain end, a smooth
/// slight bounce at minimal, a soft spring from rest at playful.
pub fn enter(t: f32) f32 {
    return enterAt(level(), t);
}

/// Something leaving — closing, shrinking away. `enter` run backwards: at minimal it draws back
/// a touch before it goes.
pub fn exit(t: f32) f32 {
    return 1 - enterAt(level(), 1 - t);
}

/// Something moving to a new place or size — a slide, a resize, a reorder. Linear at the plain
/// end, a clean deceleration at minimal, a soft spring with the barest overshoot at playful.
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
    if (lv <= 0.5) return lerp(u, outBack(u, minimal_back), lv * 2);
    return lerp(outBack(u, minimal_back), spring(u, 0.65), (lv - 0.5) * 2);
}

/// `settle` at a given level.
pub fn settleAt(lv: f32, t: f32) f32 {
    const u = clamp01(t);
    if (u >= 1) return 1;
    if (lv <= 0.5) return lerp(u, outCubic(u), lv * 2);
    return lerp(outCubic(u), spring(u, 0.75), (lv - 0.5) * 2);
}

/// Minimal's arrival: an out-back this strong overshoots by about 5% — a bounce you see, not
/// one you notice.
const minimal_back: f32 = 1.2;

fn outBack(t: f32, c1: f32) f32 {
    const c3 = c1 + 1;
    const v = t - 1;
    return 1 + c3 * v * v * v + c1 * v * v;
}

fn outCubic(t: f32) f32 {
    const v = 1 - t;
    return 1 - v * v * v;
}

/// A damped spring let go from rest, with damping ratio `zeta`: it starts slowly — no jump at
/// the first frame, which is what reads as fluid — swings a little past 1 (about 7% at 0.65, 3%
/// at 0.75) and settles, landing exactly on 1 at t = 1.
fn spring(t: f32, zeta: f32) f32 {
    // Stiff enough to have settled by the end: the envelope is down to e^-4.5 at t = 1.
    const omega = 4.5 / zeta;
    const wd = omega * @sqrt(1 - zeta * zeta);
    const x = struct {
        fn at(u: f32, z: f32, w: f32, d: f32) f32 {
            return 1 - @exp(-z * w * u) * (@cos(d * u) + (z * w / d) * @sin(d * u));
        }
    }.at;
    // What is left of the swing at t = 1 is spread over the run, so it lands exactly.
    return x(t, zeta, omega, wd) + t * (1 - x(1, zeta, omega, wd));
}

fn lerp(a: f32, b: f32, k: f32) f32 {
    return a + (b - a) * k;
}

fn clamp01(t: f32) f32 {
    return std.math.clamp(t, 0, 1);
}
