//! Plugin-store backend: catalog fetch (summary + this host's release shard) + verified download,
//! plus a small threaded `Catalog` that owns the latest parsed documents. Pure of dvui/globals —
//! the caller supplies `allocator`, a `std.Io`, and the host's own `abi_fingerprint` as a hex
//! string (the caller already computes this from `sdk.dylib.abi_fingerprint`; this layer stays
//! free of SDK-specific concerns). The store UI (Chunk 5) drives `Catalog` and tracks per-plugin
//! install state on top of this.
const std = @import("std");

pub const registry = @import("registry.zig");
pub const compat = @import("compat.zig");
pub const download = @import("download.zig");

pub const Summary = registry.Summary;
pub const SummaryEntry = registry.SummaryEntry;
pub const ReleaseShard = registry.ReleaseShard;
pub const ShardRelease = registry.ShardRelease;

/// Lifecycle of the catalog fetch (not a per-plugin install state — that lives in the UI).
pub const Status = enum(u8) { idle, fetching, ready, failed };

const ParsedSummary = std.json.Parsed(registry.Summary);
const ParsedShard = std.json.Parsed(registry.ReleaseShard);

/// Owns the latest parsed `summary.json` + this host's `<abi_fingerprint>/releases.json`,
/// refreshed off the UI thread by a real `std.Thread` worker. Shared state is guarded by a
/// `std.Io.Mutex` — the codebase's pattern for coordinating a `std.Thread` worker with the GUI
/// thread (see pixi's `SaveQueue`): lock with `dvui.io`, and `join` the worker on `deinit`. The
/// owner must outlive any in-flight refresh (in the app it is `Editor`-owned, app-lifetime).
///
/// Read access goes through `acquire`/`release`: hold the lock across any read of the returned
/// `Snapshot` so the worker can't free the arena underneath a reader.
///
/// The summary and the shard fail independently: a summary fetch failure is a hard catalog
/// failure (nothing to browse), but a shard fetch failure just means no install/update info is
/// available this round — the shard falls back to `registry.ReleaseShard.empty` (or whatever was
/// last fetched successfully), so the browse list still renders with every plugin showing "no
/// compatible build in store" rather than the whole tab erroring out. A fresh `abi_fingerprint`
/// generation with no shard published yet looks identical to a network hiccup from here, which is
/// the correct behavior in both cases.
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    summary_url: []const u8,
    shard_url: []const u8,
    status_value: std.atomic.Value(u8) = .init(@intFromEnum(Status.idle)),
    mutex: std.Io.Mutex = .init,
    summary: ?ParsedSummary = null,
    shard: ?ParsedShard = null,
    /// The refresh worker, as a cancelable `Io` task group rather than a bare `std.Thread`.
    ///
    /// Shutdown has to *stop* an in-flight fetch, not merely wait for it. Nothing in the fetch
    /// path sets a network timeout, so a registry host that accepts nothing and refuses nothing
    /// (blackholed route, captive portal) parks the worker in a blocking connect for as long as
    /// the OS allows — with a `std.Thread`, `deinit`'s `join` inherits that wait and the whole
    /// app hangs at quit with no diagnostics. A `std.Io.Group` is the same shape the LSP client
    /// uses (`core/lsp/Client.zig`'s `tasks`): `cancel` requests cancelation *and* awaits, and
    /// `Io.Threaded` interrupts the blocked syscall so the worker returns `error.Canceled`
    /// promptly instead of sitting on a dead socket.
    tasks: std.Io.Group = .init,

    /// `base_url` is the catalog root (e.g. `https://plugins.fizzyed.it/catalog`);
    /// `abi_fingerprint_hex` is this host's own fingerprint as `"0x..."`, matching a
    /// `catalog/<abi_fingerprint>/releases.json` path segment. Both are duped into the Catalog.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_url: []const u8, abi_fingerprint_hex: []const u8) !Catalog {
        const summary_url = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{base_url});
        errdefer allocator.free(summary_url);
        const shard_url = try std.fmt.allocPrint(allocator, "{s}/{s}/releases.json", .{ base_url, abi_fingerprint_hex });
        return .{ .allocator = allocator, .io = io, .summary_url = summary_url, .shard_url = shard_url };
    }

    pub fn deinit(self: *Catalog) void {
        // Cancels *and* awaits, so the worker is provably finished — and therefore done touching
        // `summary`/`shard` — before they're freed below. No-op when nothing is in flight.
        self.tasks.cancel(self.io);
        if (self.summary) |*p| p.deinit();
        self.summary = null;
        if (self.shard) |*p| p.deinit();
        self.shard = null;
        self.allocator.free(self.summary_url);
        self.allocator.free(self.shard_url);
    }

    pub fn status(self: *Catalog) Status {
        return @enumFromInt(self.status_value.load(.acquire));
    }

    /// Kick off a background refresh. No-op while one is already in flight. Must be called from
    /// the UI thread — `Io.Group` is explicitly not threadsafe against its own `await`/`cancel`.
    pub fn refresh(self: *Catalog) void {
        if (self.status() == .fetching) return;
        // Release the previous worker's group resources. `status() != .fetching` means it has
        // already stored its final status, so this returns as soon as that task unwinds.
        self.tasks.await(self.io) catch {};
        self.status_value.store(@intFromEnum(Status.fetching), .release);
        // `concurrent`, not `async`: this must run on its own thread, never inline on the caller's.
        self.tasks.concurrent(self.io, worker, .{self}) catch {
            self.status_value.store(@intFromEnum(Status.failed), .release);
            return;
        };
    }

    /// Runs in the task group. Every failure path — including `error.Canceled` from a shutdown
    /// mid-fetch — lands on `.failed`, which is also the right resting state for a canceled
    /// refresh: the app is on its way down, and a later `refresh` would overwrite it anyway.
    fn worker(self: *Catalog) void {
        const fresh_summary = registry.fetchSummary(self.allocator, self.io, self.summary_url) catch {
            self.status_value.store(@intFromEnum(Status.failed), .release);
            return;
        };
        // Best-effort: any failure (network, 404 for a brand-new fingerprint nobody has
        // published for yet, malformed response) just means we keep whatever shard we already
        // had (possibly none) rather than failing the whole refresh.
        const fresh_shard = registry.fetchReleaseShard(self.allocator, self.io, self.shard_url) catch null;

        self.mutex.lockUncancelable(self.io);
        if (self.summary) |*p| p.deinit(); // free the previous summary; no leak
        self.summary = fresh_summary;
        if (fresh_shard) |s| {
            if (self.shard) |*p| p.deinit();
            self.shard = s;
        }
        self.mutex.unlock(self.io);
        self.status_value.store(@intFromEnum(Status.ready), .release);
    }

    /// A joined view of the latest summary + this host's release shard, for the duration the
    /// lock is held.
    pub const Snapshot = struct {
        summary: registry.Summary,
        shard: registry.ReleaseShard,
    };

    /// Lock the catalog and return the latest snapshot (or null if the summary has never loaded
    /// successfully). The slices stay valid until the matching `release` — hold the lock across
    /// any read of them. Pair with `release`.
    pub fn acquire(self: *Catalog) ?Snapshot {
        self.mutex.lockUncancelable(self.io);
        const summary = self.summary orelse return null;
        return .{
            .summary = summary.value,
            .shard = if (self.shard) |s| s.value else registry.ReleaseShard.empty,
        };
    }

    pub fn release(self: *Catalog) void {
        self.mutex.unlock(self.io);
    }
};

test {
    // Pull the building blocks' tests into the unit-test target.
    _ = registry;
    _ = compat;
    _ = download;
}
