//! Remote image fetching for markdown previews.
//!
//! `![alt](https://…)` and `<img src="https://…">` are the normal way READMEs carry their
//! screenshots and badges, so a preview that only reads local files renders most real-world
//! markdown with holes in it. Each distinct URL is fetched once on a worker thread (the render
//! path must never block on the network) into a process-wide cache; the worker wakes the UI with
//! `dvui.refresh` when it lands, so the image appears without needing an unrelated input event.
//!
//! Same ownership shape as fizzy's own `store_icon.zig`: entries are heap-allocated so a worker's
//! pointer stays valid across map growth, and each worker writes only its own entry's bytes
//! before flipping `status` with release ordering.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

/// Whether this build can fetch at all. Remote images need an HTTP client and a
/// worker thread; the wasm build has neither — `dvui.io` is the failing vtable
/// there and the module is single-threaded — so a remote image resolves to
/// `.failed` and the preview draws its placeholder, exactly as it does natively
/// when a fetch fails. Wiring the browser's `fetch` into a real `std.Io` is the
/// seam that turns this back on; it is the same one the plugin store's catalog
/// fetch is waiting for, so both light up together.
pub const fetch_supported = builtin.target.cpu.arch != .wasm32;

pub const Status = enum(u8) { fetching, ready, failed };

/// Per-image cap. Matches `render_ast.max_image_bytes` — a README image past this is a mistake.
const max_bytes: usize = 16 * 1024 * 1024;
/// Bound on how many distinct remote URLs one session will ever fetch. A pathological document
/// can't turn the preview into an unbounded download queue.
const max_entries: usize = 256;
/// Bound on fetches in flight at once, so a README with 40 badges doesn't spawn 40 threads.
const max_in_flight: usize = 6;

const Entry = struct {
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.fetching)),
    /// Fetched bytes (`gpa`-owned). Written by the worker before the release-store of `ready`.
    bytes: ?[]u8 = null,
    thread: ?std.Thread = null,
    url: []u8,

    fn statusValue(self: *Entry) Status {
        return @enumFromInt(self.status.load(.acquire));
    }
};

var entries: std.StringHashMapUnmanaged(*Entry) = .empty;
/// Captured from the first `request` — every entry is allocated and freed with it.
var gpa: ?std.mem.Allocator = null;

/// Counted rather than tracked in a counter the workers would have to decrement: the map is
/// small and bounded by `max_entries`, and a UI-thread-only walk keeps this state single-owner.
fn inFlight() usize {
    var n: usize = 0;
    var it = entries.valueIterator();
    while (it.next()) |e| {
        if (e.*.statusValue() == .fetching) n += 1;
    }
    return n;
}

/// True for a URL this module handles (everything else is a local path).
pub fn isRemote(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
}

pub const Result = union(enum) {
    /// Fetch in progress — the caller should draw a placeholder and try again next frame.
    pending,
    /// Cached bytes, valid until `deinit`.
    ready: []const u8,
    failed,
};

/// Look up `url`, starting a fetch on first sight. UI thread only.
pub fn request(allocator: std.mem.Allocator, url: []const u8) Result {
    if (comptime !fetch_supported) return .failed;
    if (gpa == null) gpa = allocator;
    const a = gpa.?;

    if (entries.get(url)) |entry| {
        return switch (entry.statusValue()) {
            .fetching => .pending,
            .failed => .failed,
            .ready => if (entry.bytes) |b| .{ .ready = b } else .failed,
        };
    }

    if (entries.count() >= max_entries or inFlight() >= max_in_flight) return .pending;

    const url_owned = a.dupe(u8, url) catch return .failed;
    const entry = a.create(Entry) catch {
        a.free(url_owned);
        return .failed;
    };
    entry.* = .{ .url = url_owned };
    // Keyed by the entry's own copy of the URL, so the map never borrows caller memory.
    entries.put(a, url_owned, entry) catch {
        a.free(url_owned);
        a.destroy(entry);
        return .failed;
    };

    const io = dvui.io;
    const win = dvui.currentWindow();
    entry.thread = std.Thread.spawn(.{}, worker, .{ entry, io, win }) catch {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return .failed;
    };
    return .pending;
}

/// Join every worker and free the cache. Called from the plugin's `deinit` — a dylib must not be
/// unloaded with its own threads still running.
pub fn deinit() void {
    if (comptime !fetch_supported) return;
    const a = gpa orelse {
        entries = .empty;
        return;
    };
    var it = entries.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr.*;
        if (entry.thread) |t| t.join();
        if (entry.bytes) |b| a.free(b);
        a.free(entry.url);
        a.destroy(entry);
    }
    entries.deinit(a);
    entries = .empty;
    gpa = null;
}

fn worker(entry: *Entry, io: std.Io, win: *dvui.Window) void {
    defer dvui.refresh(win, @src(), null);
    const a = gpa orelse {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    };

    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(a);
    defer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = entry.url },
        .response_writer = &body.writer,
    }) catch {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    };
    if (result.status != .ok or body.written().len == 0 or body.written().len > max_bytes) {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    }

    const owned = a.dupe(u8, body.written()) catch {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    };
    entry.bytes = owned;
    entry.status.store(@intFromEnum(Status.ready), .release);
}
