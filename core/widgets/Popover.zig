//! A popover: one level of a flyout, drawn like a dialog. A frosted, rounded, shadowed
//! floating window that grows from its anchor to fit its rows with the same overshoot the
//! store's cards and the palette use, holding rows styled like the command palette's — no
//! border, nothing at rest, a wash of `control.fill_hover` when hovered, generous padding.
//!
//! Not a dvui menu: `dvui.floatingMenu` styles its rows as menubar rows and paints its own
//! opaque chrome around them, and a submenu opened from it closes the chain on the press that
//! should have chosen a row. A flyout with more than one level draws one `Popover` per level
//! (the second anchored at the row that opened it) and closes on a press outside all of them —
//! see `outside`.
//!
//! Rows are the caller's: `row` lays out the hover/press shell and returns whether it was
//! clicked; the caller draws the label, picture or chevron inside it before `rowEnd`.
const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("../dialogs.zig");
const widgets = @import("../widgets.zig");
const FloatingWindowWidget = @import("FloatingWindowWidget.zig");

const Popover = @This();

win: *FloatingWindowWidget,
/// The window's rect this frame, physical. Where a press counts as inside.
rect: dvui.Rect.Physical,
/// What else counts as inside — see `InitOptions.keep`.
keep: []const dvui.Rect.Physical = &.{},

/// The shared surface radius (`core.dialogs`), re-exported because callers anchor submenus
/// against it.
pub const corners: dvui.CornerRect = dialogs.surface_corners;

pub const InitOptions = struct {
    /// Persistent, caller-owned: the window animates its size through it across frames. Zero
    /// it to open fresh (the grow-from-nothing is the open animation).
    rect: *dvui.Rect,
    /// Where the window's top-left sits, natural coordinates.
    anchor: dvui.Point.Natural,
    id_extra: usize = 0,
    /// Rects that count as part of this popover for `dismissed`: the control it hangs off, the
    /// row that opened a submenu. A press there is not a press outside — pressing the button
    /// that opens a panel is the caller's own toggle, and taking it as a dismissal too would
    /// close and reopen in one frame.
    keep: []const dvui.Rect.Physical = &.{},
    /// Where the popover opens leftward from when there is no room right of `anchor` (natural
    /// x): its right edge goes here instead, and it grows to the left — the way a tooltip
    /// flips at the window's edge. Null keeps it right of `anchor` whatever the room. A
    /// flyout beside a control passes that control's far edge (or, when the control itself
    /// spans the window, its near one, so the popover opens over it rather than off-screen).
    flip_x: ?f32 = null,
    /// The width assumed before the popover has one (its first frame, growing from nothing),
    /// for deciding whether it fits right of `anchor`.
    expected_w: f32 = 240,
};

/// Open (or continue) the popover. Rows go between this and `deinit`.
pub fn init(src: std.builtin.SourceLocation, init_opts: InitOptions) Popover {
    // Only the position is ours each frame; the size is auto-size's, animated from whatever it
    // was — a fresh rect grows from the anchor with the overshoot.
    const window = dvui.windowRect();
    const r = init_opts.rect;
    const w = if (r.w > 0) r.w else init_opts.expected_w;
    // Flip when it would run off the right edge and the flipped side has more room. Decided
    // from the width it will have (or is expected to), so a popover that will not fit opens
    // leftward from its first frame rather than growing off-screen and then jumping.
    const flipped = if (init_opts.flip_x) |fx|
        init_opts.anchor.x + w > window.x + window.w and (fx - window.x) > (window.x + window.w - init_opts.anchor.x)
    else
        false;
    r.x = if (flipped) init_opts.flip_x.? - r.w else init_opts.anchor.x;
    // And never off the top or bottom: a flyout beside a row near the window's foot moves up
    // to show whole, as a tooltip does.
    r.y = if (r.h > 0) std.math.clamp(init_opts.anchor.y, window.y, @max(window.y, window.y + window.h - r.h)) else init_opts.anchor.y;
    const theme = dvui.themeGet();
    const win = widgets.floatingWindow(src, .{
        .rect = init_opts.rect,
        .resize = .none,
        // Held edge while the size animates: the anchor's side — the right edge when flipped,
        // so it grows leftward out of the flip edge instead of past it.
        .size_anchor = if (flipped) .{ .x = 1, .y = 0 } else .top_left,
        .auto_size_axes = .both,
        .window_avoid = .nudge,
        .process_events_in_deinit = true,
        .frost = dialogs.dialogFrost(),
    }, .{
        .id_extra = init_opts.id_extra,
        .color_text = .{ .color = theme.color(.control, .text) },
        .color_fill = .{ .color = dialogs.dialogFill() },
        .corners = corners,
        .padding = dialogs.surface_padding,
        .border = .all(0),
        .box_shadow = dialogs.surfaceShadow(),
    });
    // Not a window anyone drags: no drag area, so the pointer over it is not the move cursor.
    win.dragAreaSet(.{});
    return .{ .win = win, .rect = win.data().borderRectScale().r, .keep = init_opts.keep };
}

pub fn deinit(self: *Popover) void {
    self.win.deinit();
}

/// Whether a press this frame landed outside this popover (and outside whatever the caller
/// named in `keep`) — the caller's cue to put it away.
///
/// Here rather than in each caller because it is not a decision any of them get to make
/// differently: a floating thing that stays up after you click elsewhere is a bug wherever it
/// appears. Callers still *do* the closing, since only they know what "closed" means for them —
/// a selection cleared, a flag unset.
///
/// False while the popover has no rect yet: on its first frame there is nothing to be outside
/// of, and "everywhere" would dismiss it on the press that opened it.
pub fn dismissed(self: Popover) bool {
    if (self.rect.empty()) return false;
    var rects: [8]dvui.Rect.Physical = undefined;
    var n: usize = 0;
    rects[n] = self.rect;
    n += 1;
    for (self.keep) |r| {
        if (n == rects.len) break;
        rects[n] = r;
        n += 1;
    }
    return outside(rects[0..n]);
}

pub const RowOptions = struct {
    enabled: bool = true,
    /// Held highlighted regardless of the mouse — the row whose submenu is open.
    active: bool = false,
    id_extra: usize = 0,
};

pub const Row = struct {
    box: *dvui.BoxWidget,
    hovered: bool,
    clicked: bool,

    /// Physical rect of the row, for anchoring a submenu at its right edge.
    pub fn rect(self: Row) dvui.Rect.Physical {
        return self.box.data().borderRectScale().r;
    }
    pub fn deinit(self: *Row) void {
        self.box.deinit();
    }
};

/// One row: the palette's shell, inside the open popover. The caller draws the row's
/// content (horizontal box) after, then `deinit`s it. Text inside inherits the popover's text colour; nothing changes on hover
/// but the fill.
pub fn row(src: std.builtin.SourceLocation, opts: RowOptions) Row {
    const theme = dvui.themeGet();
    const box = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = opts.id_extra,
        .expand = .horizontal,
        .background = false,
        .corners = .all(4),
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .margin = .{ .x = 0, .y = 1, .w = 0, .h = 1 },
    });
    const r = box.data().borderRectScale().r;
    const mouse = dvui.currentWindow().mouse_pt;
    const hovered = opts.enabled and r.contains(mouse) and dvui.clipGet().contains(mouse);
    var clicked = false;
    if (opts.enabled) {
        for (dvui.events()) |*e| {
            if (!dvui.eventMatchSimple(e, box.data())) continue;
            if (e.evt != .mouse) continue;
            const me = e.evt.mouse;
            if (me.action == .press and me.button.pointer()) {
                e.handle(@src(), box.data());
                clicked = true;
            } else if (me.action == .release and me.button.pointer()) {
                e.handle(@src(), box.data());
            }
        }
    }
    if (hovered) dvui.cursorSet(.hand);
    if (hovered or opts.active) {
        r.fill(.all(4 * box.data().rectScale().s), .{ .color = .{ .color = theme.color(.control, .fill_hover) }, .fade = 1.0 });
    }
    return .{ .box = box, .hovered = hovered, .clicked = clicked };
}

/// Whether a pointer press landed this frame outside every rect given (the popovers of a
/// flyout and the control that opened it): the flyout's cue to close.
pub fn outside(rects: []const dvui.Rect.Physical) bool {
    for (dvui.events()) |*e| {
        if (e.evt != .mouse or e.evt.mouse.action != .press or !e.evt.mouse.button.pointer()) continue;
        const p = e.evt.mouse.p;
        var inside = false;
        for (rects) |r| {
            if (r.contains(p)) inside = true;
        }
        if (!inside) return true;
    }
    return false;
}
