//! A plugin's store page, as a document.
//!
//! The page used to be a *takeover*: one surface in the main region that swapped the whole
//! center out while a card was selected. That made selection do two jobs at once — choose what
//! the page shows, and choose what the card's own controls act on — and there was only ever one
//! page, because there was only ever one selection.
//!
//! A page is a document instead. Opening one is `openFilePath` on a path under this module's
//! mount, so everything a document already has comes for free: a tab, a split, focus, close,
//! restore, and as many open at once as the user opens. Nothing in the app knows a store page is
//! special; the tab strip is the workbench's, the markdown under the header is the bundled
//! renderer's, and this file is a document owner like any editor plugin.
//!
//! The mount is what makes that possible without a new host API: `DocumentIo` opens any path a
//! mount claims by reading its bytes, on the desktop and in the browser alike. So the page's
//! "file" is one line — the plugin's id — and everything else is looked up from the catalog at
//! draw time, where it is anyway (a plugin installs, updates, or goes away while its page is
//! open, and the page should say so without being reloaded).
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const core = @import("core");
const readme = @import("readme.zig");

const DocHandle = sdk.DocHandle;

/// The one place the page's file extension is spelled. Deliberately unlikely to collide with
/// anything a user has on disk: this is fizzy's own, and a `.md` here would fight the markdown
/// plugin for ownership of every README in the world.
pub const extension = ".fizzyplugin";

/// The mount every page lives under. A page's path is `store://<display name><extension>`, so
/// the tab shows the plugin's name — a tab strip is a row of file names, and "Google Drive" is
/// what that plugin is called.
pub const mount_prefix = "store://";

pub const plugin_id = "fizzy.store";

/// What the store gives this module so a page can draw itself without importing `PluginStore`
/// (which imports this file). One vtable, filled in at registration — the same `{ctx, vtable}`
/// seam the app uses everywhere it needs to name fizzy from underneath.
pub const PageDraw = struct {
    /// Draw the header for `plugin_id`: title, version, publisher, and the page's controls.
    /// Returns false when the store has never heard of this id, which is a page worth saying
    /// "gone" on rather than drawing blank.
    header: *const fn (plugin_id: []const u8) bool,
    /// Where this plugin's README lives: the repo URL and the path within it. Null when the
    /// store cannot say, which shows the "no README" state rather than fetching nothing.
    source: *const fn (plugin_id: []const u8) ?Source,
    /// Draw the page's tab strip with `tab` selected; returns the tab after any click. Drawn by
    /// the store because it is the store's styling, chosen per page because the tab is a
    /// property of the page you are looking at, not of the app.
    tabs: *const fn (tab: u8) u8,
    /// Draw the body of a tab that is not the README.
    otherTab: *const fn (tab: u8) void,
};

/// The README tab, by the index the store's tab strip gives it.
pub const readme_tab: u8 = 0;

pub const Source = struct {
    repo: []const u8,
    subpath: []const u8,
};

var page_draw: ?PageDraw = null;

/// One open page.
pub const Document = struct {
    id: u64,
    path: []u8,
    grouping: u64 = 0,
    /// The plugin this page is about, read from the mounted file's single line.
    plugin: []u8,
    /// Created on the first draw rather than at load: the catalog answers where a README lives,
    /// and a page can be restored from a saved layout before the catalog has been fetched.
    readme: ?readme.Readme = null,
    readme_started: bool = false,
    /// Which of the page's tabs is showing.
    tab: u8 = readme_tab,
    /// A page the user has said to keep. An unkept page is *temporary*: the next page opened
    /// takes its tab, so clicking down a list of plugins reads one after another in place
    /// instead of leaving a tab behind for every card touched.
    kept: bool = false,

    pub fn fromBytes(path: []const u8, bytes: []const u8) !Document {
        const gpa = sdk.allocator();
        const trimmed = std.mem.trim(u8, bytes, " \r\n\t");
        if (trimmed.len == 0) return error.InvalidFile;
        const plugin_copy = try gpa.dupe(u8, trimmed);
        errdefer gpa.free(plugin_copy);
        const path_copy = try gpa.dupe(u8, path);
        return .{
            .id = std.hash.Wyhash.hash(0, path),
            .path = path_copy,
            .plugin = plugin_copy,
        };
    }

    pub fn deinit(self: *Document) void {
        const gpa = sdk.allocator();
        if (self.readme) |*r| r.deinit();
        gpa.free(self.path);
        gpa.free(self.plugin);
        self.* = undefined;
    }
};

const State = struct {
    docs: std.AutoArrayHashMapUnmanaged(u64, Document) = .empty,
    /// The pages' own filesystem. Owned here; one entry per page ever opened this session.
    files: core.vfs.Mem = undefined,
    mounted: bool = false,
};

var state: State = .{};

pub var plugin: sdk.Plugin = .{
    .state = @ptrCast(&state),
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = "Plugin Store",
};

const vtable: sdk.Plugin.VTable = .{
    .fileTypes = fileTypes,
    .documentStackSize = documentStackSize,
    .documentStackAlign = documentStackAlign,
    .loadDocument = loadDocument,
    .loadDocumentFromBytes = loadDocumentFromBytes,
    .documentIdFromBuffer = documentIdFromBuffer,
    .setDocumentGroupingOnBuffer = setDocumentGroupingOnBuffer,
    .deinitDocumentBuffer = deinitDocumentBuffer,
    .registerOpenDocument = registerOpenDocument,
    .documentPtr = documentPtr,
    .documentByPath = documentByPath,
    .unregisterDocument = unregisterDocument,
    .documentGrouping = documentGrouping,
    .setDocumentGrouping = setDocumentGrouping,
    .documentPath = documentPath,
    .drawDocument = drawDocument,
    .closeDocument = closeDocument,
    .isDirty = isDirty,
    .saveDocument = saveDocument,
};

comptime {
    sdk.Plugin.assertEditorVTable(vtable);
}

/// Register the page owner and mount the filesystem its pages live on. Called by the store,
/// which is the only thing that opens one.
pub fn register(host: *sdk.Host, draw: PageDraw) !void {
    page_draw = draw;
    state.files = try core.vfs.Mem.init(host.allocator);
    try host.registerPlugin(&plugin);
    try host.mount(mount_prefix, state.files.fs());
    state.mounted = true;
}

pub fn deinit() void {
    for (state.docs.values()) |*doc| doc.deinit();
    state.docs.deinit(sdk.allocator());
    if (state.mounted) state.files.deinit();
    state.mounted = false;
}

/// Open (or focus) the store page for `plugin_id`, titled `title`. The path is the title, so a
/// page's tab reads as the plugin's name.
pub fn open(host: *sdk.Host, id: []const u8, title: []const u8, grouping: u64) !void {
    if (!state.mounted) return;
    const gpa = host.allocator;

    // The temporary page, if any, gives up its tab to this one. Collected first: closing walks
    // back into this module (`closeDocument`) and would invalidate an iterator over `docs`.
    var replacing: ?u64 = null;
    for (state.docs.values()) |*doc| {
        if (doc.kept) continue;
        if (std.mem.eql(u8, doc.plugin, id)) return focus(host, doc.*); // already the open one
        replacing = doc.id;
        break;
    }

    const file = try std.fmt.allocPrint(gpa, "{s}{s}", .{ sanitized(title), extension });
    defer gpa.free(file);
    try state.files.put(file, id);

    const path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ mount_prefix, file });
    defer gpa.free(path);
    _ = try host.openFile(.{ .path = path, .grouping = grouping, .mode = .preview });

    // After the open, not before: a failed open should not have cost the user the page they
    // were reading. The close is a no-op for a page the user kept.
    if (replacing) |old| host.closeDocById(old) catch |err| {
        dvui.log.warn("store page: could not close the temporary page: {t}", .{err});
    };
}

/// Bring an already-open page to the front.
fn focus(host: *sdk.Host, doc: Document) !void {
    _ = try host.openFile(.{ .path = doc.path, .grouping = doc.grouping });
}

/// A title as a filename: a page is addressed by its path, and a path with a separator in it is
/// a different directory. Plugin display names are free text, so this is not hypothetical.
fn sanitized(title: []const u8) []const u8 {
    // In place is impossible (the caller owns the string), and an allocation here would need
    // freeing by every caller — so reject rather than rewrite, and fall back to something that
    // is always a valid file name. A display name with a slash in it is the rare case.
    for (title) |c| {
        if (c == '/' or c == '\\' or c == 0) return "Plugin";
    }
    return title;
}

// ---- the document vtable ---------------------------------------------------------------------

fn fileTypes(_: *anyopaque) []const []const u8 {
    return &.{extension};
}

fn documentStackSize(_: *anyopaque) usize {
    return @sizeOf(Document);
}
fn documentStackAlign(_: *anyopaque) usize {
    return @alignOf(Document);
}
fn loadDocument(_: *anyopaque, path: []const u8, out_doc: *anyopaque) anyerror!void {
    // Never reached in practice — every page lives on the mount, so `DocumentIo` reads the bytes
    // and calls `loadDocumentFromBytes`. Kept because the vtable requires it and because a page
    // path could be restored from a layout after the mount is gone.
    _ = path;
    _ = out_doc;
    return error.Unsupported;
}
fn loadDocumentFromBytes(_: *anyopaque, path: []const u8, bytes: []const u8, out_doc: *anyopaque) anyerror!void {
    try sdk.document.loadBytesInto(Document, path, bytes, docBuf(out_doc));
}
fn documentIdFromBuffer(_: *anyopaque, doc: *anyopaque) u64 {
    return docBuf(doc).id;
}
fn setDocumentGroupingOnBuffer(_: *anyopaque, doc: *anyopaque, grouping: u64) void {
    docBuf(doc).grouping = grouping;
}
fn deinitDocumentBuffer(_: *anyopaque, doc: *anyopaque) void {
    docBuf(doc).deinit();
}

fn registerOpenDocument(_: *anyopaque, file: *anyopaque) anyerror!*anyopaque {
    const doc = docBuf(file);
    try state.docs.put(sdk.allocator(), doc.id, doc.*);
    return state.docs.getPtr(doc.id).?;
}
fn documentPtr(_: *anyopaque, id: u64) ?*anyopaque {
    return state.docs.getPtr(id);
}
fn documentByPath(_: *anyopaque, path: []const u8) ?*anyopaque {
    for (state.docs.values()) |*doc| {
        if (std.mem.eql(u8, doc.path, path)) return doc;
    }
    return null;
}
fn unregisterDocument(_: *anyopaque, id: u64) void {
    _ = state.docs.swapRemove(id);
}
fn documentGrouping(_: *anyopaque, handle: DocHandle) u64 {
    return (docFrom(handle) orelse return 0).grouping;
}
fn setDocumentGrouping(_: *anyopaque, handle: DocHandle, grouping: u64) void {
    (docFrom(handle) orelse return).grouping = grouping;
}
fn documentPath(_: *anyopaque, handle: DocHandle) []const u8 {
    return (docFrom(handle) orelse return "").path;
}

/// Never: a page is a view of the store, not an edit of anything.
fn isDirty(_: *anyopaque, _: DocHandle) bool {
    return false;
}
fn saveDocument(_: *anyopaque, _: DocHandle) anyerror!void {}

fn closeDocument(_: *anyopaque, handle: DocHandle) void {
    const doc = docFrom(handle) orelse return;
    doc.deinit();
    _ = state.docs.swapRemove(handle.id);
}

fn drawDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return;

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
    defer page.deinit();

    const draw = page_draw orelse return;
    // The header answers "is this plugin still a thing the store knows about" — a page can
    // outlive the plugin it is about (uninstalled, or a registry that no longer lists it).
    if (!draw.header(doc.plugin)) {
        dvui.labelNoFmt(@src(), "The store no longer has this plugin.", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.7) },
        });
        return;
    }

    doc.tab = draw.tabs(doc.tab);
    if (doc.tab != readme_tab) {
        draw.otherTab(doc.tab);
        return;
    }

    if (doc.readme == null and !doc.readme_started) {
        if (draw.source(doc.plugin)) |src| {
            doc.readme = readme.Readme.init(doc.plugin, src.repo, src.subpath);
            if (doc.readme) |*r| r.start();
            doc.readme_started = true;
        }
    }
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(16) });
    defer body.deinit();
    if (doc.readme) |*r| r.draw() else placeholderText("No README for this plugin.");
}

fn placeholderText(text: []const u8) void {
    dvui.labelNoFmt(@src(), text, .{}, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.7) },
    });
}

/// Whether `id`'s page is open at all.
pub fn isOpen(id: []const u8) bool {
    for (state.docs.values()) |*doc| {
        if (std.mem.eql(u8, doc.plugin, id)) return true;
    }
    return false;
}

/// Whether `id`'s page is open and kept — the store asks so its flyout can offer Keep or say it
/// already is.
pub fn isKept(id: []const u8) bool {
    for (state.docs.values()) |*doc| {
        if (std.mem.eql(u8, doc.plugin, id)) return doc.kept;
    }
    return false;
}

/// Keep `id`'s page: it stops being the one the next page replaces. There is no unkeep — a tab
/// the user asked to hold onto is closed by closing it, like any other.
pub fn keep(id: []const u8) void {
    for (state.docs.values()) |*doc| {
        if (std.mem.eql(u8, doc.plugin, id)) doc.kept = true;
    }
}

fn docBuf(ptr: *anyopaque) *Document {
    return @ptrCast(@alignCast(ptr));
}

/// The handle carries the pointer this module returned from `registerOpenDocument`, so trust it
/// — but only after checking the id is one of ours, since a handle for another owner's document
/// would otherwise be reinterpreted as a page.
fn docFrom(handle: DocHandle) ?*Document {
    return state.docs.getPtr(handle.id);
}
