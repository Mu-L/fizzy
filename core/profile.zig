//! The frame profiler: how long every part of a frame takes — fizzy's own phases, each plugin's
//! hooks, the surfaces plugins draw, and whatever sections a plugin marks inside its own code —
//! averaged over the last half second and shown in the profiler window (`Profiler` in the app).
//!
//! Everything a plugin does is called from fizzy, so the host times it at the call
//! (`sdk.Plugin`'s hook methods, `Layout`'s surface draws, `Host`'s callbacks) with no help from
//! the plugin. Inside a hook, a plugin marks its own sections to see where the hook's time goes:
//!
//!     const s = core.profile.section("transform");
//!     defer s.end();
//!
//! A section is nested under whatever scope is open, and belongs to the same owner — so a
//! plugin's sections land under its own hook without it naming itself.
//!
//! Each image (the host, every plugin dylib) compiles its own copy of this file. There is one
//! profiler, the host's: it publishes a pointer to itself in the shared dvui window each frame
//! (`hostFrameBegin`), and a plugin's `section` records into that. `abi` guards the layout — a
//! plugin built against a different one records nothing rather than into the wrong fields.
//!
//! Costs nothing while the window is closed (`enabled` off): a scope is then one branch.
const std = @import("std");
const dvui = @import("dvui");
const perf = @import("gfx/perf.zig");

/// Bumped whenever `Profiler`'s layout changes.
pub const abi: u32 = 2;

pub const max_entries = 1024;
const max_depth = 48;
const names_capacity = 64 * 1024;
const map_capacity = 2048; // a power of two, over twice `max_entries`
const none: u16 = std.math.maxInt(u16);

/// How many frames the history keeps (`historyFrame`), for the profiler window's graph.
pub const history_len = 240;

/// How long the published averages cover.
pub const window_ns: i128 = 500 * std.time.ns_per_ms;

pub const Entry = struct {
    owner: []const u8,
    name: []const u8,
    parent: u16,
    depth: u8,
    key: u64,

    // This frame.
    frame_ns: u64 = 0,
    frame_child_ns: u64 = 0,
    frame_calls: u32 = 0,

    // This window.
    win_ns: u64 = 0,
    win_child_ns: u64 = 0,
    win_calls: u64 = 0,
    win_max_ns: u64 = 0,

    // Published: per frame, over the last window.
    avg_ns: f64 = 0,
    avg_self_ns: f64 = 0,
    avg_calls: f64 = 0,
    max_ns: u64 = 0,
};

pub const FrameStats = struct {
    /// Between the starts of consecutive frames — what the frame rate is.
    interval_ns: f64 = 0,
    /// Inside fizzy's frame (`hostFrameBegin` … `hostFrameEnd`): the work the profiler sees.
    work_ns: f64 = 0,
    /// The slowest frame's work in the window.
    worst_work_ns: u64 = 0,
    fps: f64 = 0,
    frames: u32 = 0,
};

pub const Profiler = struct {
    abi: u32 = abi,
    enabled: bool = false,
    paused: bool = false,
    /// Held still for a moment (the window's graph under the pointer): like `paused`, but the
    /// window sets it each frame it wants it.
    frozen: bool = false,

    /// The last `history_len` frames: each one's work, and each entry's time and calls in it.
    history_work: [history_len]u32 = @splat(0),
    history_ns: [history_len][max_entries]u32 = @splat(@splat(0)),
    history_calls: [history_len][max_entries]u16 = @splat(@splat(0)),
    history_head: usize = 0,
    history_filled: usize = 0,

    entries: [max_entries]Entry = undefined,
    count: u16 = 0,
    /// Open addressing over `key`; `none` is empty.
    map: [map_capacity]u16 = @splat(none),

    stack: [max_depth]u16 = undefined,
    stack_start: [max_depth]i128 = undefined,
    depth: u8 = 0,

    names: [names_capacity]u8 = undefined,
    names_len: usize = 0,

    frame_start: i128 = 0,
    prev_frame_start: i128 = 0,
    win_start: i128 = 0,
    win_frames: u32 = 0,
    win_interval_ns: u64 = 0,
    win_work_ns: u64 = 0,
    win_worst_work_ns: u64 = 0,
    stats: FrameStats = .{},

    /// Forget every entry (the window's Reset).
    pub fn reset(self: *Profiler) void {
        self.count = 0;
        self.map = @splat(none);
        self.names_len = 0;
        self.depth = 0;
        self.win_frames = 0;
        self.win_interval_ns = 0;
        self.win_work_ns = 0;
        self.win_worst_work_ns = 0;
        self.stats = .{};
        self.history_head = 0;
        self.history_filled = 0;
        self.history_work = @splat(0);
        for (&self.history_ns) |*h| h.* = @splat(0);
        for (&self.history_calls) |*h| h.* = @splat(0);
    }

    /// The frame `ago` frames back (0 the latest recorded): its work and entries' times and calls,
    /// indexed as `slice`. Null past what the history holds.
    pub fn historyFrame(self: *Profiler, ago: usize) ?struct { work_ns: u32, ns: []const u32, calls: []const u16 } {
        if (ago >= self.history_filled) return null;
        const slot = (self.history_head + history_len - 1 - ago) % history_len;
        return .{ .work_ns = self.history_work[slot], .ns = self.history_ns[slot][0..self.count], .calls = self.history_calls[slot][0..self.count] };
    }

    pub fn slice(self: *Profiler) []Entry {
        return self.entries[0..self.count];
    }

    fn keep(self: *Profiler, s: []const u8) []const u8 {
        if (self.names_len + s.len > names_capacity) return "…";
        const out = self.names[self.names_len..][0..s.len];
        @memcpy(out, s);
        self.names_len += s.len;
        return out;
    }

    fn entryFor(self: *Profiler, owner: []const u8, name: []const u8, parent: u16) ?u16 {
        var h = std.hash.Wyhash.init(parent);
        h.update(owner);
        h.update(&.{0});
        h.update(name);
        const key = h.final();
        var slot: usize = @intCast(key & (map_capacity - 1));
        while (true) : (slot = (slot + 1) & (map_capacity - 1)) {
            const idx = self.map[slot];
            if (idx == none) break;
            if (self.entries[idx].key == key) return idx;
        }
        if (self.count >= max_entries) return null;
        const idx = self.count;
        self.count += 1;
        self.entries[idx] = .{
            .owner = self.keep(owner),
            .name = self.keep(name),
            .parent = parent,
            .depth = if (parent == none) 0 else self.entries[parent].depth + 1,
            .key = key,
        };
        self.map[slot] = idx;
        return idx;
    }

    fn open(self: *Profiler, owner: []const u8, name: []const u8) ?u16 {
        if (self.depth >= max_depth) return null;
        const parent = if (self.depth == 0) none else self.stack[self.depth - 1];
        const idx = self.entryFor(owner, name, parent) orelse return null;
        self.stack[self.depth] = idx;
        self.stack_start[self.depth] = now();
        self.depth += 1;
        return idx;
    }

    fn close(self: *Profiler, idx: u16) void {
        // Unwind to it: a scope whose end was skipped (an early return past a `defer`-less end,
        // a hook that errored) must not strand everything after it under itself.
        var d = self.depth;
        while (d > 0) {
            d -= 1;
            if (self.stack[d] == idx) break;
        } else return;
        const elapsed: u64 = @intCast(@max(0, now() - self.stack_start[d]));
        self.depth = d;
        const e = &self.entries[idx];
        e.frame_ns += elapsed;
        e.frame_calls += 1;
        if (e.parent != none) self.entries[e.parent].frame_child_ns += elapsed;
    }

    fn frameBegin(self: *Profiler) void {
        const t = now();
        if (self.prev_frame_start != 0 and self.enabled and !self.paused) {
            self.win_interval_ns += @intCast(@max(0, t - self.prev_frame_start));
        }
        self.prev_frame_start = t;
        self.frame_start = t;
        self.depth = 0;
    }

    fn frameEnd(self: *Profiler) void {
        if (!self.enabled or self.paused or self.frozen) {
            // Still clear the frame's times, or a held frame's add to the next one recorded.
            for (self.slice()) |*e| {
                e.frame_ns = 0;
                e.frame_child_ns = 0;
                e.frame_calls = 0;
            }
            return;
        }
        const t = now();
        const work: u64 = @intCast(@max(0, t - self.frame_start));
        {
            const slot = self.history_head;
            self.history_work[slot] = @intCast(@min(work, std.math.maxInt(u32)));
            for (self.slice(), 0..) |e, i| {
                self.history_ns[slot][i] = @intCast(@min(e.frame_ns, std.math.maxInt(u32)));
                self.history_calls[slot][i] = @intCast(@min(e.frame_calls, std.math.maxInt(u16)));
            }
            self.history_head = (slot + 1) % history_len;
            self.history_filled = @min(self.history_filled + 1, history_len);
        }
        self.win_work_ns += work;
        self.win_worst_work_ns = @max(self.win_worst_work_ns, work);
        self.win_frames += 1;
        for (self.slice()) |*e| {
            e.win_ns += e.frame_ns;
            e.win_child_ns += e.frame_child_ns;
            e.win_calls += e.frame_calls;
            e.win_max_ns = @max(e.win_max_ns, e.frame_ns);
            e.frame_ns = 0;
            e.frame_child_ns = 0;
            e.frame_calls = 0;
        }
        if (self.win_start == 0) self.win_start = t;
        if (t - self.win_start < window_ns) return;

        const frames: f64 = @floatFromInt(@max(self.win_frames, 1));
        const span: f64 = @floatFromInt(t - self.win_start);
        self.stats = .{
            .interval_ns = @as(f64, @floatFromInt(self.win_interval_ns)) / frames,
            .work_ns = @as(f64, @floatFromInt(self.win_work_ns)) / frames,
            .worst_work_ns = self.win_worst_work_ns,
            .fps = @as(f64, @floatFromInt(self.win_frames)) / (span / std.time.ns_per_s),
            .frames = self.win_frames,
        };
        for (self.slice()) |*e| {
            e.avg_ns = @as(f64, @floatFromInt(e.win_ns)) / frames;
            e.avg_self_ns = @as(f64, @floatFromInt(e.win_ns -| e.win_child_ns)) / frames;
            e.avg_calls = @as(f64, @floatFromInt(e.win_calls)) / frames;
            e.max_ns = e.win_max_ns;
            e.win_ns = 0;
            e.win_child_ns = 0;
            e.win_calls = 0;
            e.win_max_ns = 0;
        }
        self.win_start = t;
        self.win_frames = 0;
        self.win_interval_ns = 0;
        self.win_work_ns = 0;
        self.win_worst_work_ns = 0;
    }
};

fn now() i128 {
    return perf.nanoTimestamp();
}

/// The host's profiler. Only the host image's copy is ever used as one (`hostFrameBegin`).
var host_profiler: Profiler = .{};
var is_host = false;

const publish_id: dvui.Id = @enumFromInt(0x6669_7a7a_7970_7266); // "fizzyprf"
const publish_key = "_profiler";

/// The profiler to record into: the host's own in the host, the one it published in a plugin.
/// Null when there is none, or it was built with another layout.
pub fn current() ?*Profiler {
    if (is_host) return &host_profiler;
    const addr = dvui.dataGet(null, publish_id, publish_key, usize) orelse return null;
    const p: *Profiler = @ptrFromInt(addr);
    return if (p.abi == abi) p else null;
}

/// Host only: the profiler the window shows and controls.
pub fn host() *Profiler {
    return &host_profiler;
}

/// Host only, at the start of every frame, before anything is timed: start the frame, and
/// publish the profiler to the plugins through the shared window.
pub fn hostFrameBegin() void {
    is_host = true;
    host_profiler.frameBegin();
    dvui.dataSet(null, publish_id, publish_key, @as(usize, @intFromPtr(&host_profiler)));
}

/// Host only, at the end of every frame.
pub fn hostFrameEnd() void {
    host_profiler.frameEnd();
}

/// An open scope; `end` it (deferred) where the timed code ends.
pub const Scope = struct {
    p: ?*Profiler = null,
    idx: u16 = none,

    pub fn end(self: Scope) void {
        if (self.p) |p| p.close(self.idx);
    }
};

/// Time from here to `end` as `name` under `owner` (a plugin id, or "fizzy"), nested under the
/// scope already open. What the host wraps each call into a plugin with.
pub fn begin(owner: []const u8, name: []const u8) Scope {
    const p = current() orelse return .{};
    if (!p.enabled or p.paused) return .{};
    const idx = p.open(owner, name) orelse return .{};
    return .{ .p = p, .idx = idx };
}

/// Time from here to `end` as `name`, nested under the open scope and belonging to its owner:
/// how a plugin marks the parts of a hook.
pub fn section(name: []const u8) Scope {
    const p = current() orelse return .{};
    if (!p.enabled or p.paused) return .{};
    const owner = if (p.depth > 0) p.entries[p.stack[p.depth - 1]].owner else "?";
    const idx = p.open(owner, name) orelse return .{};
    return .{ .p = p, .idx = idx };
}

test "scopes nest, and a frame's time folds into the window's averages" {
    var p: Profiler = .{ .enabled = true };
    p.frameBegin();
    const a = p.open("pixi", "draw").?;
    const b = p.open("pixi", "bubbles").?;
    p.close(b);
    p.close(a);
    try std.testing.expectEqual(@as(u16, 2), p.count);
    try std.testing.expectEqual(@as(u8, 1), p.entries[b].depth);
    try std.testing.expectEqual(a, p.entries[b].parent);
    try std.testing.expectEqual(@as(u32, 1), p.entries[a].frame_calls);
    try std.testing.expect(p.entries[a].frame_child_ns == p.entries[b].frame_ns);
    // The same path finds the same entry.
    const a2 = p.open("pixi", "draw").?;
    try std.testing.expectEqual(a, a2);
    p.close(a2);
}

test "a scope whose end was skipped does not strand the ones after it" {
    var p: Profiler = .{ .enabled = true };
    p.frameBegin();
    const a = p.open("fizzy", "frame").?;
    _ = p.open("x", "lost").?; // never closed
    p.close(a);
    try std.testing.expectEqual(@as(u8, 0), p.depth);
}
