//! A view lifted out of its place and carried to another one.
//!
//! The gesture is one thing, so it is one file: the state that survives
//! between frames, the hit-test that decides what is under the pointer, the
//! drop zones that show where it can go, and the assignment that lands when
//! the button comes up. `Region` declares places; this moves views between
//! them. The rule the zones and the landing obey is `Drop`, and the whole
//! design is written down in `SPLITS.md`.
//!
//! Two things are worth knowing before changing anything here:
//!
//! **The app under a drag does not change.** The dragged surface is
//! photographed once, at lift, and a card of it rides the pointer; its place
//! goes on drawing it, and no place poses it as a preview of landing there —
//! one view shown in two places at once was harder to read than a card over
//! a window that stays put. The layout moves after the drop, with the
//! animations every split and swap already has.
//!
//! **The place under the pointer shows its drop zones** (`drawZones`,
//! `core.widgets.DropZones`), all five of its options at once; the one under
//! the pointer is the one a release takes. Moving to another place, its zones
//! clear as the new place's come in — the window is never covered in targets,
//! and the one change on screen is where the pointer is. The middle of the
//! other half of a split is a join (`drawJoin`): aimed at, the place's zones
//! step back for one pane across both halves — the place the drop leaves.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");
const Split = core.widgets.Split;
const Layout = @import("Layout.zig");
const Region = @import("Region.zig");
const SplitTree = @import("SplitTree.zig");
const Drop = @import("Drop.zig");
const DropZones = core.widgets.DropZones;

const ViewDrag = @This();

/// Interned name of the place the view was lifted from. Empty when idle, so
/// `active()` is the one question everything else asks first.
name: []const u8 = "",
/// Physical size of the source when the drag began — the card shrinks from it.
from: dvui.Size.Physical = .{},
/// The lifted surface as it last drew. The floating card is this texture.
texture: ?dvui.Texture = null,
/// Where it was taken.
texture_rect: dvui.Rect.Physical = .{},
start_ns: i128 = 0,
/// Surface lifted from the source: what the card under the pointer shows, and what lands.
moved_id: []const u8 = "",
/// The places this drag can land on, and where they were, frozen at lift.
targets: [max_targets]Target = undefined,
target_count: usize = 0,

/// One place the pointer can be read against.
pub const Target = struct {
    /// Interned, so it outlives the frame the map was taken on.
    name: []const u8,
    bounds: dvui.Rect.Physical,
    /// Content size in points, for the extent a landing split settles at.
    size: dvui.Size,
};

/// Generous: a shape's places plus every pane a plugin opens inside them.
/// Past this the drag simply cannot aim at the newest places, which is a far
/// better failure than a map that shifts while you are reading it.
pub const max_targets = 64;

pub fn active(self: ViewDrag) bool {
    return self.name.len > 0;
}

/// The source of a view lifted out of the picker rather than out of a place.
/// No shape declares a place by this name, so every question the gesture
/// asks of its source — its bounds, its assignment, whether it may shut —
/// answers "none", which is exactly what a view in nobody's hands has.
pub const loose_source = "\x00picker";

/// A drag with no source place: the view came from the picker.
pub fn loose(self: ViewDrag) bool {
    return std.mem.eql(u8, self.name, loose_source);
}

pub fn discard(self: *ViewDrag) void {
    if (self.texture) |tex| dvui.Texture.destroyLater(tex);
    self.* = .{};
}

pub fn takePicture(self: *ViewDrag, pic: *dvui.Picture) void {
    pic.stop();
    const tex = dvui.textureFromTarget(pic.texture) catch return;
    if (self.texture) |old| dvui.Texture.destroyLater(old);
    self.texture = tex;
    self.texture_rect = pic.r;
}

/// What photograph this place owes the drag this frame.
///
/// A photograph is taken *from the place's own draw*, never from a second
/// one. Drawing a subtree twice in a frame gives every widget inside it a
/// duplicate id — dvui paints the lot red and the two copies fight over the
/// same stored state — and the subtree under a place is the whole editor.
pub const Shot = struct {
    /// The lifted view, for the floating card. Taken once, at lift.
    card: bool = false,

    pub fn any(self: Shot) bool {
        return self.card;
    }
};

/// Nothing is owed unless a drag is live, this is its source, and the card has no picture yet.
pub fn shotWanted(l: *Layout, is_source: bool) Shot {
    const d = l.state.view_drag;
    if (!d.active()) return .{};
    return .{ .card = is_source and d.texture == null };
}

/// Keep what the source's draw recorded as the card's picture, and put it on the screen the
/// draw was taken from — the place goes on showing its view under the drag.
pub fn keepShot(l: *Layout, shot: Shot, pic: *dvui.Picture) void {
    const d = &l.state.view_drag;
    if (shot.card) {
        d.takePicture(pic);
        if (d.texture) |tex| core.anim.blit(tex, null, d.texture_rect, 0, 1);
        return;
    }
    pic.stop();
}

/// Begin carrying the view out of `name`. The place keeps drawing it throughout.
pub fn begin(l: *Layout, name: []const u8, from: dvui.Rect.Physical) void {
    var d = &l.state.view_drag;
    d.name = l.state.internName(l.gpa, name);
    d.from = from.size();
    d.start_ns = dvui.currentWindow().frame_time_ns;
    if (visibleId(l, name)) |id| d.moved_id = id;
    mapTargets(l, d);
}

/// Begin carrying surface `id` from the picker. There is no source place,
/// so nothing is photographed: the float starts at
/// the card that was grabbed and shows the picture the card showed, which
/// the caller hands over (`State.stealSnapshot`) and the drag destroys.
pub fn beginLoose(l: *Layout, id: []const u8, from: dvui.Rect.Physical, texture: ?dvui.Texture) void {
    var d = &l.state.view_drag;
    const s = l.host.surfaceById(id) orelse return;
    d.name = loose_source;
    d.from = from.size();
    d.start_ns = dvui.currentWindow().frame_time_ns;
    d.moved_id = s.id;
    d.texture = texture;
    d.texture_rect = from;
    mapTargets(l, d);
}

// ── What is under the pointer ───────────────────────────────────────────────────────────────────

/// Photograph the places, the way the card photographs the view.
///
/// **A drag must not change the map it is being read against.** Places can
/// move under a drag — a split easing shut, a window resized — and a hit-test
/// read against the live layout would chase them. Frozen at lift, it is a pure function of where the pointer is,
/// and the drag is as steady as your hand.
fn mapTargets(l: *Layout, d: *ViewDrag) void {
    d.target_count = 0;
    const surface_kw = draggedKeywords(l);
    // A tab's content goes to a slot made for it, never a plain place (`Layout.slotted`).
    const slotted = if (l.host.surfaceById(d.moved_id)) |s| l.slotted(s) else false;
    // Last frame's registry: complete, where this frame's is still being
    // filled in around the click that started the drag.
    const places = if (l.state.regions.items.len > 0)
        l.state.regions.items
    else
        l.state.regions_building.items;
    for (places) |r| {
        if (d.target_count == max_targets) break;
        if (!accepts(r, surface_kw)) continue;
        if (slotted and !r.kind_slot) continue;
        if (r.bounds.w <= 0 or r.bounds.h <= 0) continue;
        d.targets[d.target_count] = .{
            .name = l.state.internName(l.gpa, r.name),
            .bounds = r.bounds,
            .size = r.size,
        };
        d.target_count += 1;
    }
}

/// What a place was when the drag began, or null if it was not one of the
/// places this drag can land on.
fn frozen(state: *const Layout.State, name: []const u8) ?Target {
    const d = &state.view_drag;
    if (!d.active()) return null;
    for (d.targets[0..d.target_count]) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn kindAt(state: *const Layout.State, dest: []const u8, mouse: dvui.Point.Physical, scale: f32) Drop.Kind {
    const dest_b = placeBounds(state, dest) orelse return .swap;
    return Drop.kindAt(dest_b, mouse, scale);
}

/// The place a release at `mouse` would land on, for a view lifted from
/// `source`. The smallest place containing the pointer wins, so a document
/// pane beats the main area it sits in.
pub fn targetAt(l: *Layout, mouse: dvui.Point.Physical, source: []const u8) ?[]const u8 {
    const state = l.state;
    // The source's own edge is a self-split, and it outranks any pane nested
    // inside it — otherwise a document filling the place always wins on area
    // and its own edges become unreachable.
    if (placeBounds(state, source)) |bounds| {
        if (bounds.contains(mouse)) {
            switch (Drop.kindAt(bounds, mouse, dvui.currentWindow().natural_scale)) {
                .split => return source,
                .swap => {},
            }
        }
    }
    const d = &state.view_drag;
    var best: ?[]const u8 = null;
    var best_area: f32 = std.math.floatMax(f32);
    for (d.targets[0..d.target_count]) |t| {
        if (!t.bounds.contains(mouse)) continue;
        const area = t.bounds.w * t.bounds.h;
        if (area >= best_area) continue;
        best = t.name;
        best_area = area;
    }
    return best;
}

/// What the view being carried is, for deciding which places will take it.
/// The surface lifted at the start, not whatever the source place happens to
/// be showing — mid-swap it is showing the *other* view, and reading that
/// would change which places accept the drop halfway through it.
fn draggedKeywords(l: *Layout) []const []const u8 {
    const id = l.state.view_drag.moved_id;
    if (id.len == 0) return &.{};
    const s = l.host.surfaceById(id) orelse return &.{};
    return s.keywords;
}

/// A shape place (Main, Panel, a leftover Center) can receive any surface.
/// A plugin kind slot (a workbench document pane) only receives what it
/// accepts, so dropping Output on the canvas lands on Main rather than
/// becoming a document tab.
pub fn accepts(r: Region, surface_kw: []const []const u8) bool {
    if (r.name.len == 0) return false;
    if (!r.kind_slot) return true;
    if (surface_kw.len == 0) return false;
    return sdk.keywords.accepts(r.keywords, surface_kw);
}

pub fn placeBounds(state: *const Layout.State, name: []const u8) ?dvui.Rect.Physical {
    // Mid-drag, a place is where it was when the drag began — see
    // `mapTargets`. Everything the gesture measures reads this, so the zones,
    // the edge the pointer is tested against and the split a drop settles are
    // all cut from the same rect.
    if (frozen(state, name)) |t| return t.bounds;
    for (state.regions_building.items) |r| {
        if (std.mem.eql(u8, r.name, name) and r.bounds.w > 0 and r.bounds.h > 0) return r.bounds;
    }
    for (state.regions.items) |r| {
        if (std.mem.eql(u8, r.name, name) and r.bounds.w > 0 and r.bounds.h > 0) return r.bounds;
    }
    return null;
}

/// A place's content size in points, frozen mid-drag for the same reason its
/// bounds are: the split a drop settles is sized from the place the user saw.
pub fn placeSize(state: *const Layout.State, name: []const u8) ?dvui.Size {
    if (frozen(state, name)) |t| {
        if (t.size.w > 0 and t.size.h > 0) return t.size;
    }
    return state.placeSize(name);
}

pub fn regionNamed(state: *const Layout.State, name: []const u8) ?*const Region {
    for (state.regions.items) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    for (state.regions_building.items) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// The surface a place is showing — the selected one, not its whole
/// assignment. A multi place drags the tab you can see, not all of them.
pub fn visibleId(l: *Layout, name: []const u8) ?[]const u8 {
    if (regionNamed(l.state, name)) |r| {
        if (l.selectedIn(r)) |s| return s.id;
    }
    const ids = l.state.assignment(name) orelse return null;
    return if (ids.len > 0) ids[0] else null;
}

// ── The live drag ───────────────────────────────────────────────────────────────────────────────

/// Keep a live drag moving: its view named, and frames coming while it rides the pointer.
/// Called from every place that draws during a drag; idempotent within a frame.
pub fn tick(l: *Layout) void {
    var d = &l.state.view_drag;
    if (!d.active()) return;
    if (d.moved_id.len == 0) {
        if (visibleId(l, d.name)) |id| d.moved_id = id;
    }
}

// ── Painting ────────────────────────────────────────────────────────────────────────────────────

/// Whether the pointer is over `name` as the place a release would land on.
fn aimedAt(l: *Layout, name: []const u8) bool {
    const d = l.state.view_drag;
    if (!d.active() or name.len == 0) return false;
    const target = targetAt(l, dvui.currentWindow().mouse_pt, d.name) orelse return false;
    return std.mem.eql(u8, target, name);
}

/// The drop zones over `name` while the dragged view is over it and could land there
/// (`core.widgets.DropZones`): every option the place offers at once, as the dialogs' frosted
/// glass, the one under the pointer lit. Call after the place's own contents, so the glass lies
/// over them. `key` is any id stable for the place.
pub fn drawZones(l: *Layout, name: []const u8, key: dvui.Id) void {
    // Only the place under the pointer: its zones come in as the pointer arrives and clear as it
    // leaves for another, whose come in over it — for as long as they are still showing, so a
    // place left mid-fade finishes going. Aimed at a join, they step back for the one pane across
    // both halves (`drawJoin`).
    const aimed = aimedAt(l, name);
    const target = aimed and isTarget(l, name) and aimedJoin(l) == null;
    if (!target and !DropZones.showing(key)) return;
    const whole = placeBounds(l.state, name) orelse {
        DropZones.forget(key);
        return;
    };
    const scale = dvui.currentWindow().natural_scale;
    const zones = DropZones.rects(whole, scale);
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(whole);
    const d = l.state.view_drag;
    const center: DropZones.Center = if (std.mem.eql(u8, d.name, name))
        .none
    else if (joins(l, d.name, name))
        .join
    else if (regionNamed(l.state, name)) |r| (if (r.shows == .many) .add else .replace) else .replace;
    DropZones.draw(key, zones, scale, .{
        .hovered = if (aimed) DropZones.at(zones, dvui.currentWindow().mouse_pt) else null,
        .target = target,
        .center = center,
    });
}

/// Whether dropping the view lifted from `source` in the middle of `dest` joins them: the two
/// halves of one split (`State.joinable`), with the view the last thing `source` shows — a
/// place of one, or a place of tabs down to this one. Carried out of a place that keeps other
/// views, it is only moving, and the middle means what it means anywhere else.
fn joins(l: *Layout, source: []const u8, dest: []const u8) bool {
    if (source.len == 0 or dest.len == 0) return false;
    if (l.state.joinable(source, dest) == null) return false;
    const r = regionNamed(l.state, source) orelse return true;
    return r.shows == .one or holding(l, source).len <= 1;
}

/// The join a release here would make, if the pointer is on the middle of the other half of
/// the split the view was lifted from.
fn aimedJoin(l: *Layout) ?SplitTree.Forest.Pair {
    const d = l.state.view_drag;
    if (!d.active() or d.loose()) return null;
    const mouse = dvui.currentWindow().mouse_pt;
    const dest = targetAt(l, mouse, d.name) orelse return null;
    if (!joins(l, d.name, dest)) return null;
    if (kindAt(l.state, dest, mouse, dvui.currentWindow().natural_scale) != .swap) return null;
    return l.state.joinable(d.name, dest);
}

/// The join's pane: one lit sheet of the zones' glass across both halves of the split being
/// joined, while it is aimed at, where each half showed its own zones. It is the one place the
/// drop will leave, shown before it is made — the answer to "what does dropping here do" that a
/// single zone's icon cannot give. Drawn after every place (the framework calls it once the
/// shape has declared them all), so it lies over the zones stepping back beneath it.
pub fn drawJoin(l: *Layout) void {
    const key = dvui.Id.extendId(null, @src(), 0);
    const scale = dvui.currentWindow().natural_scale;
    const pair = aimedJoin(l) orelse return DropZones.drawJoin(key, null, scale);
    const a = placeBounds(l.state, pair.keep) orelse return DropZones.drawJoin(key, null, scale);
    const b = placeBounds(l.state, pair.drop) orelse return DropZones.drawJoin(key, null, scale);
    DropZones.drawJoin(key, a.unionWith(b), scale);
}

/// Whether `name` is somewhere the dragged view could land — one of the places mapped at lift
/// (`mapTargets`), or the place it came from.
fn isTarget(l: *Layout, name: []const u8) bool {
    const d = l.state.view_drag;
    if (!d.active() or name.len == 0) return false;
    if (std.mem.eql(u8, d.name, name)) return true;
    for (d.targets[0..d.target_count]) |t| if (std.mem.eql(u8, t.name, name)) return true;
    return false;
}

/// Whether `key`'s zones are on screen — the place the drag is over, or fading out after it.
pub fn zonesShowing(l: *Layout, name: []const u8, key: dvui.Id) bool {
    return (isTarget(l, name) and aimedAt(l, name)) or DropZones.showing(key);
}

/// The card under the pointer. Always visible while dragging: it is the only
/// thing that says what is being carried, and hiding it over a drop target
/// left the gesture looking cancelled.
pub fn drawFloat(l: *Layout) void {
    tick(l);
    const d = l.state.view_drag;
    if (!d.active()) return;
    const mouse = dvui.currentWindow().mouse_pt;
    const now = dvui.currentWindow().frame_time_ns;
    // The lift is a move to a new size, at the app's motion level: instant when motion is off.
    const dur: f64 = core.motion.durationMs(220) * @as(f64, std.time.ns_per_ms);
    const elapsed: f64 = @floatFromInt(now - d.start_ns);
    const t = if (dur <= 0) 1 else core.motion.settle(@floatCast(std.math.clamp(elapsed / dur, 0, 1)));

    // Shrink from the place's own size to a card, keeping the grab point
    // under the pointer, so the view appears to be picked up rather than
    // replaced by an icon.
    const from = d.from;
    const scale = dvui.currentWindow().natural_scale;
    const target = floatTarget(from, scale);
    const w = from.w + (target.w - from.w) * t;
    const h = from.h + (target.h - from.h) * t;
    const sx = if (from.w > 0) w / from.w else 1;
    const sy = if (from.h > 0) h / from.h else 1;
    const off = dvui.dragOffset();
    const tl = mouse.plus(.{ .x = off.x * sx, .y = off.y * sy });
    const nat = dvui.Rect.Physical.fromPoint(tl).toSize(.{ .w = w, .h = h }).toNatural();

    const theme = dvui.themeGet();
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = false }, .{
        .rect = .{ .x = nat.x, .y = nat.y, .w = nat.w, .h = nat.h },
        .padding = .{},
        .corners = core.corners.round(core.corners.card),
        .background = true,
        .color_fill = .{ .color = theme.color(.window, .fill) },
        .border = dvui.Rect.all(1),
        .color_border = .{ .color = theme.color(.highlight, .fill) },
        .box_shadow = .{
            .color = .black,
            .alpha = 0.28,
            .fade = 12,
            .offset = .{ .x = 0, .y = 4 },
            .corners = core.corners.round(core.corners.card),
        },
    });
    defer fw.deinit();

    const dest = fw.data().contentRectScale().r;
    if (d.texture) |tex| {
        core.anim.blit(tex, null, dest, 0, 1);
    } else {
        // Nothing photographed it — a document tab, lifted off its strip — so the card says what
        // it is carrying by name.
        const title = if (l.host.surfaceById(d.moved_id)) |s| s.title else "view";
        dvui.labelNoFmt(@src(), title, .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = theme.color(.control, .text) },
        });
    }
    // Frames only while the card is still shrinking into the hand: after that it moves when the
    // pointer does, and the pointer moving is a frame anyway.
    if (elapsed < dur) dvui.refresh(null, @src(), null);
}

fn floatTarget(from: dvui.Size.Physical, scale: f32) dvui.Size.Physical {
    if (from.w <= 0 or from.h <= 0) return .{ .w = 280 * scale, .h = 180 * scale };
    const max_w = 280 * scale;
    const max_h = 200 * scale;
    const aspect = from.w / from.h;
    var w = @min(from.w, max_w);
    var h = w / aspect;
    if (h > max_h) {
        h = @min(from.h, max_h);
        w = h * aspect;
    }
    return .{ .w = w, .h = h };
}

// ── The landing ─────────────────────────────────────────────────────────────────────────────────

/// Release at `mouse`. Does nothing unless the pointer is somewhere a drop
/// means something, so letting go over the window frame cancels.
pub fn apply(l: *Layout, source: []const u8, mouse: dvui.Point.Physical) void {
    const dest = targetAt(l, mouse, source) orelse return;
    if (placeBounds(l.state, dest) == null) return;
    const scale = dvui.currentWindow().natural_scale;
    place(l, source, dest, kindAt(l.state, dest, mouse, scale));
}

/// Move the visible surface of `source` onto `dest`. The picker's own moves
/// come through here too, which is why it takes a `Drop.Kind` rather than a
/// pointer position.
pub fn place(l: *Layout, source: []const u8, dest: []const u8, kind: Drop.Kind) void {
    const plan = Drop.plan(kind, std.mem.eql(u8, source, dest), joins(l, source, dest)) orelse return;
    const moved = ownId(l.arena, movedFrom(l, source) orelse return) orelse return;
    if (regionNamed(l.state, dest)) |r| {
        const s = l.host.surfaceById(moved) orelse return;
        if (!accepts(r.*, s.keywords)) return;
        if (!r.kind_slot and l.slotted(s)) return;
        // A plugin's region is asked first: it makes its own places, so a split of it is
        // something only it can do (`RegionSpec.on_drop`).
        if (r.on_drop) |on_drop| {
            const zone: sdk.RegionSpec.Drop.Zone = switch (plan) {
                .swap, .join => .center,
                .split => |sp| .{ .edge = switch (sp.landing) {
                    .left => .left,
                    .right => .right,
                    .top => .top,
                    .bottom => .bottom,
                } },
            };
            if (on_drop(r.drop_ctx, .{ .surface_id = moved, .zone = zone })) {
                l.state.markDirty();
                dvui.refresh(null, @src(), null);
                return;
            }
            // Unhandled: the middle falls through to the default below. A plugin's region
            // cannot be split by the app, so an edge nobody handled is no drop.
            if (plan == .split and r.kind_slot) return;
        }
    }
    switch (plan) {
        .swap => swap(l, source, dest, moved),
        .join => join(l, source, dest, moved),
        .split => |s| {
            const new = Region.splitOn(l, dest, s.mint) orelse return;
            // A self-split leaves the view in the origin, which `mint` has
            // already put under the pointer. Moving it onto the fresh leaf
            // would remount the surface and lose everything it was holding.
            if (s.fills_mint) {
                l.state.assign(l.gpa, new, &.{moved}) catch {};
                selectNamed(l, new, moved);
                takeOut(l, source, moved, null);
            }
        },
    }
    shutIfEmptied(l, source);
    l.state.markDirty();
    dvui.refresh(null, @src(), null);
}

/// The surface a drop from `source` lands: the one the live drag lifted when
/// it is this drag's source (a picker drag carries a view its source may not
/// be showing — or, loose, has no source at all), else what the place shows.
fn movedFrom(l: *Layout, source: []const u8) ?[]const u8 {
    const d = l.state.view_drag;
    if (d.active() and d.moved_id.len > 0 and std.mem.eql(u8, d.name, source)) return d.moved_id;
    return visibleId(l, source);
}

/// Land the view. A place that shows many takes it; a place that shows one
/// trades for it.
///
/// The difference is whether anything had to be displaced. A shelf has room,
/// so the view joins what is already there and the source simply loses it. A
/// slot has one view in it, and that view has to go somewhere — back where the
/// new one came from, because nowhere else is anywhere: an unassigned surface
/// whose place is now spoken for is a surface the user can no longer find.
fn swap(l: *Layout, source: []const u8, dest: []const u8, moved: []const u8) void {
    const other_raw = visibleId(l, dest);
    const other = if (other_raw) |o| ownId(l.arena, o) else null;

    // Dropped on a place that shows several and already holds it (a tab dropped back into its
    // own strip's place): it is already there, so show it and leave the list alone — claiming
    // it the way a one-view place does would shrink the place to it.
    const dest_many = if (regionNamed(l.state, dest)) |r| r.shows == .many else false;
    if (dest_many) {
        for (holding(l, dest)) |id| if (std.mem.eql(u8, id, moved)) {
            selectNamed(l, dest, moved);
            if (!std.mem.eql(u8, source, dest)) takeOut(l, source, moved, null);
            return;
        };
    }

    // Dropping a view onto a place that is already showing it: claim it here
    // and let the source go empty, rather than trading it with itself.
    if (other) |o| {
        if (std.mem.eql(u8, o, moved)) {
            l.state.assign(l.gpa, dest, &.{moved}) catch {};
            selectNamed(l, dest, moved);
            if (l.state.assignment(source) == null)
                l.state.assign(l.gpa, source, &.{}) catch {};
            return;
        }
    }

    const dest_shows = if (regionNamed(l.state, dest)) |r| r.shows else .one;
    if (dest_shows == .many) {
        l.state.assign(l.gpa, dest, idsWith(l.arena, holding(l, dest), moved)) catch {};
        selectNamed(l, dest, moved);
        takeOut(l, source, moved, null);
        return;
    }

    l.state.assign(l.gpa, dest, &.{moved}) catch {};
    selectNamed(l, dest, moved);
    takeOut(l, source, moved, other);
}

/// Make the two halves of a split one place again, holding the views of both: the place under
/// the pointer's first, in its order, then the source's, the dragged one selected. The split's
/// origin is what stays, whichever half the drag started in (`SplitTree.Forest.joinable`); it
/// shows them as tabs, since it now holds more than one. The minted half slides shut and is
/// dropped once it has (`shutIfEmptied`).
fn join(l: *Layout, source: []const u8, dest: []const u8, moved: []const u8) void {
    const pair = l.state.joinable(source, dest) orelse return swap(l, source, dest, moved);
    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
    for ([_][]const u8{ dest, source }) |name| {
        for (shownIn(l, name)) |id| {
            const own = ownId(l.arena, id) orelse continue;
            if (!containsId(ids.items, own)) ids.append(l.arena, own) catch {};
        }
    }
    if (!containsId(ids.items, moved)) ids.append(l.arena, moved) catch {};
    l.state.setShows(l.gpa, pair.keep, .many);
    l.state.assign(l.gpa, pair.keep, ids.items) catch {};
    l.state.assign(l.gpa, pair.drop, &.{}) catch {};
    selectNamed(l, pair.keep, moved);
    shutIfEmptied(l, pair.drop);
}

/// What a place is showing, for a join to keep: every view a place of tabs holds, the one view
/// a place of one does. A place of one matched by keywords "holds" every surface they match —
/// the whole list it picks from — and joining must not turn that into a row of tabs.
fn shownIn(l: *Layout, name: []const u8) []const []const u8 {
    const many = if (regionNamed(l.state, name)) |r| r.shows == .many else false;
    if (many) return holding(l, name);
    const id = visibleId(l, name) orelse return &.{};
    const out = l.arena.alloc([]const u8, 1) catch return &.{};
    out[0] = id;
    return out;
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

/// What a place is holding: the list it was given, or the one its keywords
/// attract when it has never been given one. A `.many` place usually has no
/// list of its own — the sidebar's tabs are every plugin that asked for the
/// sidebar — and reading only the assignment there says "nothing", so a drop
/// onto the rail would leave it holding one lone view.
fn holding(l: *Layout, name: []const u8) []const []const u8 {
    if (l.state.assignment(name)) |ids| return ids;
    const r = regionNamed(l.state, name) orelse return &.{};
    const items = l.matchingIn(r);
    var out = std.ArrayListUnmanaged([]const u8).initCapacity(l.arena, items.len) catch return &.{};
    for (items) |s| out.appendAssumeCapacity(s.id);
    return out.items;
}

/// Take `moved` out of `name`, putting `give` where it was if the trade sent
/// one back.
fn takeOut(l: *Layout, name: []const u8, moved: []const u8, give: ?[]const u8) void {
    // Nothing to take it out of: the destination's assignment already claims
    // the view away from wherever keywords had put it (`State.assign` evicts
    // it from every other list), and a view the trade sends back has nowhere
    // to go but its keywords.
    if (std.mem.eql(u8, name, loose_source)) return;
    const held = holding(l, name);
    const kept = if (give) |g|
        idsReplacing(l.arena, held, moved, g)
    else
        idsWithout(l.arena, held, moved);

    // A place whose keywords chose its list, losing a view and getting none
    // back, is left alone: the destination's assignment already claims the
    // view away from it. Writing the list down instead would freeze the place
    // against every surface a plugin registers from here on.
    if (give != null or l.state.assignment(name) != null)
        l.state.assign(l.gpa, name, kept) catch {};
    reselect(l, name, moved, kept);
}

/// A place never stays selected on a view it no longer holds.
///
/// The selection is remembered per place and only *read* against what the
/// place shows, so a chooser that has already dropped the icon can sit beside
/// a body still drawing what that icon used to choose — which is what dragging
/// Files out of the sidebar looked like until you clicked another icon.
fn reselect(l: *Layout, name: []const u8, gone: []const u8, kept: []const []const u8) void {
    const key = if (regionNamed(l.state, name)) |r| r.selectionKey() else slotKey(name);
    const cur = l.host.selectionForKey(key) orelse return;
    if (!std.mem.eql(u8, cur, gone)) return;
    if (kept.len > 0) selectNamed(l, name, kept[0]);
}

fn ownId(arena: std.mem.Allocator, id: []const u8) ?[]const u8 {
    return arena.dupe(u8, id) catch null;
}

fn slotKey(name: []const u8) u64 {
    const group = sdk.keywords.groupKey(Layout.slot_keywords);
    return group ^ std.hash.Wyhash.hash(0x51a7, name);
}

fn selectNamed(l: *Layout, name: []const u8, id: []const u8) void {
    const stable = if (l.host.surfaceById(id)) |s| s.id else return;
    if (regionNamed(l.state, name)) |r| {
        l.selectIn(r, stable);
        return;
    }
    l.host.setSelectionForKey(slotKey(name), stable);
}

/// A place that exists only because a split made it, left holding nothing,
/// shuts itself and hands the room back to its neighbour.
///
/// The shape's own places stay. Main with nothing in it is still where Main
/// is, and a user who empties it expects to be able to put something back. A
/// minted leaf is not furniture: it was a container for the view that has
/// just been carried out of it, and leaving a blank rectangle behind makes
/// the user tidy up after their own drag. `State.isMinted` is exactly that
/// distinction — a place the tree is allowed to drop.
///
/// The leaf a split *mints* is empty on purpose and is never passed here: it
/// is the room being made, not room left over.
///
/// Shut rather than deleted, so it slides closed on the curve it opened on;
/// `Region.persistExtent` drops the leaf once the animation has finished.
fn shutIfEmptied(l: *Layout, name: []const u8) void {
    if (!l.state.isMinted(name)) return;
    if (l.state.assignment(name)) |ids| {
        if (ids.len > 0) return;
    }
    // A seed's dock tree closes its own leaves, easing the split shut over it.
    if (l.state.dock) |*dock| {
        if (dock.findPanel(name)) |idx| dock.closeLeaf(idx);
        return;
    }
    const r = regionNamed(l.state, name) orelse return;
    if (r.id != .zero and Split.sizeOf(r.id) > 0) {
        Split.close(r.id);
        l.extents_changed = true;
        return;
    }
    // Never drawn at a size, so there is nothing to slide: drop it outright.
    if (l.state.splits.collapse(l.gpa, name)) {
        if (l.state.clearExtent(l.gpa, name)) l.extents_changed = true;
        l.state.unassign(l.gpa, name);
    }
}

fn idsWith(arena: std.mem.Allocator, ids: []const []const u8, add: []const u8) []const []const u8 {
    return idsReplacing(arena, ids, "", add);
}

fn idsWithout(arena: std.mem.Allocator, ids: []const []const u8, drop: []const u8) []const []const u8 {
    var out = std.ArrayListUnmanaged([]const u8).initCapacity(arena, ids.len) catch return &.{};
    for (ids) |id| {
        if (!std.mem.eql(u8, id, drop)) out.appendAssumeCapacity(id);
    }
    return out.items;
}

fn idsReplacing(arena: std.mem.Allocator, ids: []const []const u8, drop: []const u8, add: []const u8) []const []const u8 {
    var out = std.ArrayListUnmanaged([]const u8).initCapacity(arena, ids.len + 1) catch return &.{add};
    var replaced = false;
    for (ids) |id| {
        if (std.mem.eql(u8, id, drop)) {
            if (!replaced) {
                out.appendAssumeCapacity(add);
                replaced = true;
            }
            continue;
        }
        if (std.mem.eql(u8, id, add)) continue;
        out.appendAssumeCapacity(id);
    }
    if (!replaced) out.appendAssumeCapacity(add);
    return out.items;
}

test "a document pane does not accept a panel surface" {
    const pane: Region = .{ .name = "Pane 1", .keywords = &.{"main.document"}, .by_name = true, .kind_slot = true };
    const main: Region = .{ .name = "Main", .keywords = sdk.keywords.ide.main };
    const center: Region = .{ .name = "Center", .keywords = &.{"slot"}, .by_name = true };
    try std.testing.expect(!accepts(pane, sdk.keywords.ide.panel));
    try std.testing.expect(accepts(pane, &.{"document"}));
    try std.testing.expect(accepts(main, sdk.keywords.ide.panel));
    try std.testing.expect(accepts(center, sdk.keywords.ide.panel));
}
