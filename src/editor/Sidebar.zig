const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const Constants = @import("Constants.zig");
const Entry = fizzy.Entry;
const Editor = fizzy.Editor;

const SidebarView = fizzy.sdk.SidebarView;
const PluginStore = @import("app").store.Store;
const Accounts = @import("Accounts.zig");
const Layout = @import("app").layout.Layout;
const Chooser = Layout.Chooser;

pub const Sidebar = @This();

/// Fizzy built-in views pinned to the bottom of the rail (always visible). Everything else —
/// the plugin-contributed views — scrolls above them in registration (load) order.
fn isPinned(id: []const u8) bool {
    return std.mem.eql(u8, id, PluginStore.view_id) or
        std.mem.eql(u8, id, Editor.view_settings);
}

pub fn init() !Sidebar {
    return .{};
}

pub fn deinit() void {
    // TODO: Free memory
}

/// What the sidebar wants Editor.zig to do this frame. We defer the call out to Editor
/// because the sidebar runs *before* `editor.explorer.paned` is re-created for this
/// frame — dereferencing `explorer.paned` (e.g. via `peekClose`/`open`) from inside the
/// sidebar click handler would touch last frame's freed widget, which on wasm32 trips
/// "reached unreachable code".
pub const Action = enum { none, open, close };

/// `f` is the layout frame: the rail lists whatever currently *matches* the keywords its
/// region accepts, rather than every surface in `host.surfaces`. That is what
/// makes a user's keyword override actually move an icon out of (or into) this rail.
///
/// Two vertical `Layout.Chooser`s over the sidebar's place — the plugin views scrolling above,
/// fizzy's own pinned below — so the rail picks, reorders (drag an icon along it) and hands a
/// view to the view drag (drag it off) the same way every tab strip does. What is the rail's own
/// is only how an icon looks and what picking the showing one means: it opens or closes the
/// sidebar.
pub fn draw(_: Sidebar, editor: *Editor, f: *Layout, keywords: []const []const u8) !Action {
    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
        .background = false,
        .min_size_content = .{ .w = 40, .h = 100 },
    });
    defer vbox.deinit();

    const place: Layout.Region = .{ .keywords = keywords };
    var ret: Action = .none;

    // Plugin-contributed views scroll in a bounded area, in the place's order. When more icons
    // exist than fit, an edge shadow hints at the hidden ones.
    {
        var list = Chooser.init(@src(), f, place, .{
            .dir = .vertical,
            .scroll_shadows = true,
            .outer = .{ .expand = .both, .background = false },
        });
        defer list.deinit();
        for (list.views(), 0..) |view, i| {
            if (isPinned(view.id)) continue;
            drawIcon(editor, &list, view, i);
        }
        ret = pickAction(editor, &list, ret);
    }

    // Plugin store + Settings: pinned to the bottom of the rail, always visible.
    {
        var bottom = dvui.box(@src(), .{ .dir = .vertical }, .{
            .gravity_y = 1.0,
            .background = false,
        });
        defer bottom.deinit();

        // The account disc, when anything can be signed in to; then plugin-drawn items (a
        // badge, a status light); then fizzy's own two.
        if (editor.app.host.account_providers.items.len != 0) try Accounts.drawRailDisc(editor, rail_icon);
        for (editor.app.host.rail_items.items, 0..) |item, i| {
            if (item.hidden) continue;
            var slot = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .background = false, .min_size_content = .{ .h = rail_icon } });
            defer slot.deinit();
            item.draw(item.ctx, rail_icon) catch |err| dvui.log.err("rail item '{s}' failed to draw: {t}", .{ item.id, err });
        }

        var pinned = Chooser.init(@src(), f, place, .{
            .dir = .vertical,
            .scroll = false,
            .id_extra = 1,
            .outer = .{ .expand = .horizontal, .background = false },
        });
        defer pinned.deinit();
        for (pinned.views(), 0..) |view, i| {
            if (!isPinned(view.id)) continue;
            drawIcon(editor, &pinned, view, i);
        }
        ret = pickAction(editor, &pinned, ret);
    }

    return ret;
}

/// Points tall, a rail icon; its cell is twice that.
const rail_icon: f32 = 20;

/// What a pick in the rail asks of the explorer. Picking another view shows it (the chooser has
/// already selected it) and opens the sidebar; picking the one already showing toggles it.
///
/// Reported, not done: Editor.zig invokes `peekClose` / `open` after `editor.explorer.paned` has
/// been recreated for this frame. Doing the call directly here would dereference last frame's
/// freed paned widget and crash on wasm.
fn pickAction(editor: *Editor, c: *const Chooser, so_far: Action) Action {
    if (c.picked() != null) return .open;
    if (c.reselected() == null) return so_far;
    // The region, not `explorer.closed`: on a narrow window the explorer is folded away by
    // the layout without anyone having closed it, and a tap there means "show me", not
    // "hide it again".
    const explorer_visible = if (editor.regionFor(fizzy.sdk.keywords.ide.sidebar)) |r|
        !r.isClosed() and !r.isFolded()
    else
        !editor.explorer.closed;
    return if (explorer_visible) .close else .open;
}

/// One rail icon: the chooser's item, drawn as the view's glyph with the store's attention badge.
fn drawIcon(editor: *Editor, c: *Chooser, view: *Layout.Surface, index: usize) void {
    // Only the store view can carry one; nothing else in the rail has a pending-decision notion.
    const undecided_count: usize = if (std.mem.eql(u8, view.id, PluginStore.view_id))
        editor.app.undecidedPluginCount()
    else
        0;
    // Say what the dot means — a bare badge on a 20px rail icon is otherwise a riddle.
    const detail: ?[]const u8 = if (undecided_count > 0)
        std.fmt.allocPrint(dvui.currentWindow().arena(), "{d} plugin{s} ready to load", .{
            undecided_count,
            if (undecided_count == 1) "" else "s",
        }) catch null
    else
        null;

    var it = c.item(@src(), view, .{ .tooltip = true, .tooltip_detail = detail });
    defer it.deinit();

    // Register the icon as interactive in the title bar so clicks reach DVUI even when it
    // overlaps the top drag strip on Windows. Only the topmost icon(s) actually sit inside the
    // strip — anything below is registered harmlessly (no overlap with drag rect).
    if (builtin.os.tag == .windows) {
        const r = it.data().rectScale().r;
        const strip_h = (Constants.titlebar_top_buffer + Constants.titlebar_height) * dvui.windowNaturalScale();
        if (r.y < strip_h) fizzy.backend.pushTitleBarInteractiveRect(r);
    }

    Chooser.icon(view, it.selected, it.hovered(), rail_icon, index);

    // Attention badge, same idiom (and colour) as the infobar's app-update dot: a plugin build
    // is sitting in `plugins/` waiting for the user to say whether to load it, and the card that
    // offers it is inside this very view. Purely condition-driven — it disappears when the last
    // undecided build is loaded, switched off, or removed, not when the tab is merely opened.
    if (undecided_count > 0) {
        const brs = it.data().rectScale();
        const r = 4 * brs.s;
        // Anchored to the *glyph's* top-right corner, not the rail cell's: the cell is twice the
        // icon's height, so a corner-anchored dot would float well clear of the icon it marks.
        const center = brs.r.center();
        const at = dvui.Point.Physical{ .x = center.x + rail_icon / 2 * brs.s, .y = center.y - rail_icon / 2 * brs.s };
        var dot = dvui.Rect.Physical.fromPoint(at).toSize(.{ .w = 2 * r, .h = 2 * r });
        dot.x -= r;
        dot.y -= r;
        dot.fill(dvui.CornerRect.Physical.round(r), .{
            .color = .{ .color = dvui.themeGet().color(.highlight, .fill) },
            .fade = 0,
        });
    }
}
