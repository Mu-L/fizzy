const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const App = fizzy.App;
const Editor = fizzy.Editor;

const Pane = @import("explorer/Explorer.zig").Pane;

pub const Sidebar = @This();

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

pub fn draw(_: Sidebar) !Action {
    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
        .background = false,
        .min_size_content = .{ .w = 40, .h = 100 },
    });
    defer vbox.deinit();

    const options = [_]struct { pane: Pane, icon: []const u8 }{
        .{ .pane = .files, .icon = dvui.entypo.folder },
        .{ .pane = .tools, .icon = dvui.entypo.pencil },
        .{ .pane = .sprites, .icon = dvui.entypo.grid },
        //.{ .pane = .animations, .icon = dvui.entypo.controller_play },
        //.{ .pane = .keyframe_animations, .icon = dvui.entypo.key },
        .{ .pane = .project, .icon = dvui.entypo.box },
        .{ .pane = .settings, .icon = dvui.entypo.cog },
    };

    var ret: Action = .none;

    for (options) |option| {
        const a = try drawOption(option.pane, option.icon, 20);
        if (a != .none) ret = a;
    }

    return ret;
}

fn drawOption(option: Pane, icon: []const u8, size: f32) !Action {
    const selected = option == fizzy.editor.explorer.pane;
    var ret: Action = .none;

    const theme = dvui.themeGet();

    var bw: dvui.ButtonWidget = undefined;

    bw.init(@src(), .{}, .{
        .id_extra = @intFromEnum(option),
        .min_size_content = .{ .h = size },
    });
    defer bw.deinit();
    bw.processEvents();

    // Register the button as interactive in the title bar so clicks reach DVUI even when the
    // button overlaps the top drag strip on Windows. Only the topmost sidebar button(s) actually
    // sit inside the strip — anything below is registered harmlessly (no overlap with drag rect).
    if (builtin.os.tag == .windows) {
        const r = bw.data().rectScale().r;
        const strip_h = (fizzy.editor.settings.titlebar_top_buffer + fizzy.editor.settings.titlebar_height) * dvui.windowNaturalScale();
        if (r.y < strip_h) fizzy.backend.pushTitleBarInteractiveRect(r);
    }

    const color: dvui.Color = if (selected) theme.color(.highlight, .fill) else if (bw.hovered()) theme.color(.window, .text) else theme.color(.window, .fill);

    dvui.icon(
        @src(),
        @tagName(option),
        icon,
        .{ .fill_color = color },
        .{
            .min_size_content = .{ .h = size },
        },
    );

    if (bw.clicked()) {
        // Tapping the icon for the pane that's already showing toggles the explorer
        // closed (same effect as the floating collapse button). We *report* the intent
        // here; Editor.zig invokes `peekClose` / `open` after `editor.explorer.paned` has
        // been recreated for this frame. Doing the call directly here would dereference
        // last frame's freed paned widget and crash on wasm.
        const explorer_visible = fizzy.editor.explorer.peek_open or !fizzy.editor.explorer.closed;
        if (selected and explorer_visible) {
            ret = .close;
        } else {
            fizzy.editor.explorer.pane = option;
            ret = .open;
        }
        dvui.refresh(null, @src(), null);
    }

    if (!selected) {
        var tooltip: dvui.FloatingTooltipWidget = undefined;
        tooltip.init(@src(), .{
            .active_rect = bw.data().rectScale().r,
            .delay = 350_000,
        }, .{
            .id_extra = @intFromEnum(option),
            .color_fill = dvui.themeGet().color(.window, .fill),
            .border = dvui.Rect.all(0),
            .box_shadow = .{
                .color = .black,
                .shrink = 0,
                .corner_radius = dvui.Rect.all(8),
                .offset = .{ .x = 0, .y = 2 },
                .fade = 4,
                .alpha = 0.2,
            },
        });
        defer tooltip.deinit();

        if (tooltip.shown()) {
            var animator = dvui.animate(@src(), .{
                .kind = .alpha,
                .duration = 350_000,
            }, .{
                .expand = .both,
            });
            defer animator.deinit();

            var vbox2 = dvui.box(@src(), .{ .dir = .vertical }, dvui.FloatingTooltipWidget.defaults.override(.{
                .background = false,
                .expand = .both,
                .border = dvui.Rect.all(0),
            }));
            defer vbox2.deinit();

            var tl2 = dvui.textLayout(@src(), .{}, .{
                .background = false,
                .padding = dvui.Rect.all(4),
            });
            tl2.format("{s}", .{fizzy.Editor.Explorer.title(option, true)}, .{
                .font = dvui.Font.theme(.heading),
            });
            tl2.deinit();
        }
    }

    return ret;
}
