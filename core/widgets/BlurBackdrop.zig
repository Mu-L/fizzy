//! Cached, downsampled "blurred backdrop" for content behind modals, floating
//! windows, or transparent bars (e.g. a nav bar over scrolling content).
//! Approximates CSS `backdrop-filter: blur(radius_px)` the way compositors
//! do: halve until the blur left is a few texels, run a separable Gaussian
//! there, and stretch the result back up (`runGauss`).
//!
//! Unlike a live per-frame blur, this only re-captures the background when
//! it actually changed - every other frame it just redraws a small cached
//! texture (one cheap textured quad). This matters because dvui's renderer
//! is deferred: replaying a subwindow's `RenderCommand`s re-runs real glyph
//! shaping / path triangulation, not just a GPU blit, so doing it every
//! frame is a real (avoidable) CPU cost.
//!
//! Usage (bracket the background content you want blurred):
//! ```
//! const blur = dvui.BlurBackdrop.get(@src());
//! blur.init(rect, .{scroll_offset, window_w}); // witness: anything that should invalidate the cache when it changes
//! // ... draw background widgets (scroll area, page content, etc) ...
//! blur.deinit();
//! blur.draw(); // draws cached blurred texture over `rect`
//! // ... draw modal / nav bar contents on top ...
//! ```
//!
//! Cache invalidation is automatic for anything captured in `rect` and
//! `witness` (hashed and compared to the previous frame's). Call
//! `markDirty()` yourself only for changes that hash can't see, e.g. the
//! background content itself changed shape/content without `rect` or
//! `witness` changing.

const std = @import("std");
const dvui = @import("dvui");

const Rect = dvui.Rect;
const Size = dvui.Size;
const Texture = dvui.Texture;

const BlurBackdrop = @This();

/// Physical-pixel rect this backdrop covers. Set by `init`.
rect: Rect.Physical = .{},
/// CSS `backdrop-filter: blur(radius_px)`-equivalent blur strength.
radius_px: f32 = 16,
/// Cached small texture, redrawn as-is on non-dirty frames. A view of the blur's last
/// level (`levels`), so it lives and dies with that.
small: ?Texture = null,
/// Fizzy addition: the blur's targets, kept from one capture to the next and reused when
/// the size still fits. Creating a target is a texture allocation plus a clear — a render-target
/// switch and a pipeline flush — and a capture needs several; that was most of what a capture
/// cost, and why one could not be afforded every frame. Slot 0 is the copy of the rect, then
/// the halvings, then the Gaussian's two axes (`runGauss`).
levels: [max_levels]?Texture.Target = @splat(null),
/// True until the next `deinit` runs a real capture.
dirty: bool = true,
/// Hash of the last `init`'s `rect` + `witness`, for auto-dirty.
last_hash: u64 = 0,

cmd_start: usize = undefined,
prev_rendering: bool = undefined,
/// Fizzy addition: how the backdrop gets the pixels under it. `.replay` is upstream's — defer
/// the bracketed draws and replay them into a capture target. `.readback` reads the rectangle
/// back from the window after the bracketed draws have landed there (`Backend.readPixels`),
/// which needs no cooperation from anything drawn inside the bracket — a `Picture` capture, a
/// front-to-back region, a plugin drawing through a bridge — where the replay repeats commands
/// that were only meant to run once. Costs a GPU→CPU→GPU round trip of the rect on dirty frames.
mode: Mode = .replay,
/// Fizzy addition: blur without decimating halvings (`runFine`), for a frost whose content
/// moves under it — a canvas zooming — where halvings, on a grid fixed to the screen, shimmer.
/// Any radius: a big one is box-averaged down first, which stays put as content slides under
/// it. Off, `runGauss` serves every radius (the cheap default — dialogs, menus, the palette).
stable: bool = false,
/// Fizzy addition: how much definition the frost keeps, 0…1. The last halvings, less blurred
/// than the Gaussian, are mixed into the result by this much — a blur with a sharper core and
/// the same soft reach, so shapes behind read through the frost instead of washing out. 0 is
/// the plain Gaussian. Never the unblurred source, so there is no sharp double image.
detail: f32 = 0,

pub const Mode = enum { replay, readback };

/// Enough for a 16k-pixel rect at radius 2^11, in both directions.
const max_levels = 24;

/// Get the persistent `BlurBackdrop` for this call site, creating it on
/// first call. Registers its GPU-texture teardown with dvui's data store so
/// the cached texture is freed automatically once this storage key stops
/// being touched (e.g. the tab/panel it lives in closes) - unlike a bare
/// `dataGetPtrDefault`, which would otherwise silently leak `self.small`.
///
/// Safe to call every frame, any time before `init`/`deinit` - in
/// particular, before other same-frame code needs to mutate fields on the
/// returned pointer (e.g. a slider bound to `&backdrop.radius_px`).
pub fn get(src: std.builtin.SourceLocation) *BlurBackdrop {
    const id = dvui.parentGet().extendId(src, 0);
    const self = dvui.dataGetPtrDefault(null, id, "blur_backdrop", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "blur_backdrop", &releaseTexture);
    return self;
}

/// Force a re-capture on the next `init`/`deinit` bracket, for invalidation
/// that `init`'s rect/witness hash can't see (e.g. modal reopened,
/// background content changed shape without `rect` moving).
pub fn markDirty(self: *BlurBackdrop) void {
    self.dirty = true;
}

/// Call immediately before drawing the background content that should show
/// through the blur. `witness` is anything (a value or tuple) that should
/// invalidate the cache when it changes - e.g. scroll offset, window width.
/// Cheap and safe to call every frame even when not dirty. Per-frame
/// bracket-open; does not allocate or own any resources itself (see `get`
/// for the one-time setup and `releaseTexture` for GPU teardown).
pub fn init(self: *BlurBackdrop, rect: Rect, witness: anytype) void {
    self.rect = dvui.windowRectScale().rectToPhysical(rect);

    var hasher = dvui.fnv.init();
    hasher.update(std.mem.asBytes(&rect));
    hasher.update(std.mem.asBytes(&witness));
    const h = hasher.final();
    if (h != self.last_hash) self.dirty = true;
    self.last_hash = h;

    if (!self.dirty) return;
    // Readback wants the content *on the target* when `deinit` runs, so it must not defer.
    if (self.mode == .readback) return;

    const cw = dvui.currentWindow();
    const sw = cw.subwindows.current() orelse &cw.subwindows.stack.items[0];
    self.cmd_start = sw.render_cmds.items.len;

    // Rendering defaults to immediate (draws straight to the current
    // target as each widget call happens), so without this the bracketed
    // draws below never get queued into `sw.render_cmds` and there's
    // nothing to replay into the offscreen texture. Force deferred mode
    // so we can replay the same commands twice below: once onscreen
    // (so the background stays visible) and once into the capture target.
    self.prev_rendering = dvui.renderingSet(false);
}

/// Call immediately after drawing the background content bracketed by
/// `init`. Re-captures + re-blurs only when dirty. Per-frame bracket-close -
/// call every frame, cheap when not dirty. Does not free the cached
/// texture; see `releaseTexture` for that.
pub fn deinit(self: *BlurBackdrop) void {
    if (!self.dirty) return;
    defer self.dirty = false;
    defer self.frostReplaces();
    if (self.mode == .readback) return self.deinitReadback();

    const cw = dvui.currentWindow();
    _ = dvui.renderingSet(self.prev_rendering);

    const sw = cw.subwindows.current() orelse &cw.subwindows.stack.items[0];
    // Left in the subwindow's normal queue (not stripped, not replayed here)
    // so they draw exactly once, in their natural queue order, via the
    // normal `Window.endRendering` deferred replay - same as any other
    // widget's deferred draws. Replaying them immediately here (as an
    // earlier version did) drew them "now" during build, which is fine at
    // top level but wrong when this widget is nested inside another
    // floating window: an enclosing background fill queued *earlier* in the
    // same subwindow only actually draws *later*, at `endRendering`, and
    // painted right over content already drawn early by an immediate
    // replay - the bracketed content (e.g. a checkerboard background)
    // vanishing behind the enclosing window every dirty frame.
    const cmds = sw.render_cmds.items[self.cmd_start..];

    var r = self.rect;
    if (r.empty()) return;
    // enlarge to pixel boundaries, same as Picture.start
    const x_start = @floor(r.x);
    const x_end = @ceil(r.x + r.w);
    r.x = x_start;
    r.w = @round(x_end - x_start);
    const y_start = @floor(r.y);
    const y_end = @ceil(r.y + r.h);
    r.y = y_start;
    r.h = @round(y_end - y_start);
    if (r.w < 1 or r.h < 1) return;

    // The rest of this function renders into offscreen targets (the full-res
    // capture, then each downsample/upsample pass) and must happen
    // immediately, not be deferred - `renderTexture` silently queues a
    // `RenderCommand` instead of drawing when `rendering` is false, which is
    // the ambient state whenever this whole widget is itself nested inside
    // another deferred floating window. Left alone, every blur pass would be
    // queued instead of drawn, its offscreen target would stay blank, and
    // `self.small` would end up fully transparent.
    const blur_prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(blur_prev_rendering);

    // capture the bracketed commands at full res into an offscreen target.
    // Stays bound to offscreen targets for the whole downsample/upsample
    // pipeline below - restored to `prev1` (the real onscreen/window
    // target) exactly once at the end. Restoring it between passes (as a
    // naive save/restore per pass would) touches the live window target
    // once per blur pass for no reason, and on backends that clear-on-bind
    // that flashes away whatever was already drawn there - a visible
    // flicker every dirty frame (e.g. every tick while dragging the radius
    // slider).
    const full_target = dvui.textureCreateTarget(.{ .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) }) catch return;
    const prev1 = dvui.renderTarget(.{ .texture = full_target, .offset = r.topLeft() });
    defer _ = dvui.renderTarget(prev1);
    cw.renderCommands(cmds) catch {};

    const cur = dvui.textureFromTarget(full_target) catch return; // destroys full_target
    defer dvui.textureDestroyLater(cur);
    // Capture target is already bound; the outer `defer` restores the window.
    _ = self.run(cur, false, 1, 1);
}

/// Fizzy addition: the fast `.readback`. When the frame is being drawn into a texture
/// (`core.FrameTarget`, or any bound target — a `Picture` capture mid-transition), "what is
/// under me" is already on the GPU: copy `rect` out of it into a target of its own and blur
/// that. No sync, no CPU copy — ~1 ms in Debug against ~9 for the framebuffer read. False when
/// nothing is bound (the window itself is the target) and the read has to happen.
fn deinitFromTarget(self: *BlurBackdrop) bool {
    const cw = dvui.currentWindow();
    const bound = cw.render_target.texture orelse return false;
    const src = dvui.Texture.fromTargetTemp(bound) catch return false;
    var r = self.rect;
    if (r.empty()) return true;
    r.x = @floor(r.x);
    r.y = @floor(r.y);
    r.w = @round(r.w);
    r.h = @round(r.h);
    if (r.w < 1 or r.h < 1) return true;
    // At any real radius the copy is taken at half size: the first halving is the largest
    // pass of the blur and the blur that follows swallows what decimating loses, so it is
    // folded into the copy. The result is half size for the same reason (`runGauss`), and the
    // final quad stretches it — the two most expensive passes of every capture, gone, on a
    // frost that is re-read every frame.
    const shrink = self.coarse();
    const w: u32 = @max(1, @as(u32, @intFromFloat(r.w)) / shrink);
    const h: u32 = @max(1, @as(u32, @intFromFloat(r.h)) / shrink);

    const blur_prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(blur_prev_rendering);
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);

    const step = self.level(0, w, h) orelse return false;
    var rt = cw.render_target;
    const off = rt.offset;
    rt.texture = step;
    rt.offset = .{};
    const prev = dvui.renderTarget(rt);
    {
        const prev_clip = dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        const dest: dvui.Rect.Physical = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        dvui.clipSet(dest);
        // `rect` is in window pixels; the bound target may sit at an offset in the window.
        const sw: f32 = @floatFromInt(src.width);
        const sh: f32 = @floatFromInt(src.height);
        // Copy, not over: the level holds the last capture, and the source's alpha (a
        // see-through window) must land as it is rather than over the old pixels.
        const copy = tapsBlend(src, .copy);
        if (!copy) step.clear();
        defer if (copy) tapsEnd(src, true);
        const uv: dvui.Rect = .{ .x = (r.x - off.x) / sw, .y = (r.y - off.y) / sh, .w = r.w / sw, .h = r.h / sh };
        if (shrink > 1 and copy) {
            // The frame target samples `.nearest`, so a single tap at half size keeps one
            // pixel of every 2×2 block and drops the rest: a 1px edge (pixel-art outlines,
            // text) lands in or out of the copy as content moves under the frost by a pixel,
            // and the blur, fed a different picture each frame, flickers. Four taps, one on
            // each pixel's centre, summed at a quarter each — a true box average.
            // Exactly 2:1, so each tap lands on a pixel centre (an odd rect drops its last
            // row/column, as the integer halving of `w`/`h` already does).
            var box = uv;
            box.w = @as(f32, @floatFromInt(w * shrink)) / sw;
            box.h = @as(f32, @floatFromInt(h * shrink)) / sh;
            const du = 0.5 / sw;
            const dv = 0.5 / sh;
            const offsets = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };
            for (offsets, 0..) |o, i| {
                var tap = box;
                tap.x += o[0] * du;
                tap.y += o[1] * dv;
                dvui.renderTexture(src, .{ .r = dest, .s = 1 }, .{
                    .uv = tap,
                    .colormod = tapWeight(@floatFromInt(i), 1, 4),
                }) catch {};
                if (i == 0) _ = tapsBlend(src, .add);
            }
        } else {
            dvui.renderTexture(src, .{ .r = dest, .s = 1 }, .{ .uv = uv }) catch {};
        }
    }
    _ = dvui.renderTarget(prev);
    const source = dvui.Texture.fromTargetTemp(step) catch return false;
    _ = self.run(source, true, 1, shrink);
    return true;
}

/// How much smaller than the rect the copy the blur starts from is: for `runGauss`, 2 at a
/// radius it blurs; for a `stable` blur, 2 once `fineShrink` wants any shrinking (the copy's
/// 2×2 box average is the first halving), else 1.
fn coarse(self: *const BlurBackdrop) u32 {
    if (self.stable) return if (self.fineShrink() >= 2) 2 else 1;
    return if (self.radius_px >= 4) 2 else 1;
}

/// How far a `stable` blur box-averages down before its passes: halvings until the radius in
/// those texels is under `fine_texel_radius_max`, so the passes stay few (~7) at any radius.
fn fineShrink(self: *const BlurBackdrop) u32 {
    var k: u32 = 1;
    while (self.radius_px / @as(f32, @floatFromInt(k)) >= fine_texel_radius_max and k < 32) k *= 2;
    return k;
}

/// The most blur `runFine` does in passes at one resolution (texels). Past it, halving first is
/// cheaper than the passes it saves — and past ~40 same-size taps start to read as shifted
/// copies rather than a wider blur.
const fine_texel_radius_max: f32 = 20;

/// Fizzy addition: the blur target for slot `i` at `w`×`h`, kept from the last capture when
/// it is that size already, made (and so cleared) otherwise. Null when the backend has none.
fn level(self: *BlurBackdrop, i: usize, w: u32, h: u32) ?Texture.Target {
    if (i >= max_levels) return null;
    if (self.levels[i]) |t| {
        if (t.width == w and t.height == h) return t;
        t.destroyLater();
        self.levels[i] = null;
    }
    const t = Texture.Target.create(.{ .width = w, .height = h, .interpolation = .linear, .precision = .high }) catch return null;
    self.levels[i] = t;
    return t;
}

/// Drop every level. `small` is a view of one of them, so it goes too.
fn releaseLevels(self: *BlurBackdrop) void {
    for (&self.levels) |*slot| {
        if (slot.*) |t| t.destroyLater();
        slot.* = null;
    }
    self.small = null;
}

/// Fizzy addition: the `.readback` capture. Reads `rect` back from the current target as it
/// stands, uploads it, and runs the same pipeline `deinit` does on a replayed capture.
fn deinitReadback(self: *BlurBackdrop) void {
    if (self.deinitFromTarget()) return;
    if (!dvui.Backend.support_read_pixels) return;
    var r = self.rect;
    if (r.empty()) return;
    r.x = @floor(r.x);
    r.y = @floor(r.y);
    r.w = @round(r.w);
    r.h = @round(r.h);
    if (r.w < 1 or r.h < 1) return;
    const w: u32 = @intFromFloat(r.w);
    const h: u32 = @intFromFloat(r.h);

    const cw = dvui.currentWindow();
    // The texture is always the full rect, cleared to nothing; only the part of it that is on
    // the window is read. A rect half off the edge used to fail the read outright and leave the
    // previous frost drawn at the new position — the blur "moving with" the card past the edge.
    const pixels = cw.arena().alloc(dvui.Color.PMA, w * h) catch return;
    @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const vis = r.intersect(dvui.windowRectPixels());
    var vr = vis;
    vr.x = @floor(vr.x);
    vr.y = @floor(vr.y);
    vr.w = @floor(vr.w);
    vr.h = @floor(vr.h);
    if (vr.w >= 1 and vr.h >= 1) {
        const vw: usize = @intFromFloat(vr.w);
        const vh: usize = @intFromFloat(vr.h);
        const read = cw.arena().alloc(u8, vw * vh * 4) catch return;
        cw.backend.readPixels(vr, read.ptr) catch return;
        const ox: usize = @intFromFloat(vr.x - r.x);
        const oy: usize = @intFromFloat(vr.y - r.y);
        // The drawable holds what dvui blended into it, and dvui blends premultiplied — so
        // these bytes already are PMA and copy straight across. Premultiplying again
        // (`PMA.fromColor`) squared the alpha into the colour and a see-through window read
        // back as near-black.
        for (0..vh) |y| {
            const row = read[y * vw * 4 .. (y + 1) * vw * 4];
            const dst = std.mem.sliceAsBytes(pixels[(oy + y) * w + ox ..][0..vw]);
            @memcpy(dst, row);
        }
    }
    const source = dvui.textureCreate(pixels, .{ .width = w, .height = h, .interpolation = .linear }) catch return;
    defer dvui.textureDestroyLater(source);

    const blur_prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(blur_prev_rendering);
    _ = self.run(source, true, 1, 1);
}

/// Fizzy addition (proposed for upstream): a blur of an already-captured texture, as a new
/// texture the caller owns (destroy it with `dvui.textureDestroyLater`) — exactly the pipeline
/// `deinit` runs after its own capture (`runGauss`), without the bracket, at half the texture's
/// size (the stretch it is drawn with is free). `tex` is not touched. Null when the backend has
/// no render targets, or `radius_px` is too small for a single pass.
///
/// A transition blurs once, here, and then fades between the sharp snapshot and this: two quads
/// a frame for a sharp → blurred → sharp swap, never a blur per frame.
pub fn blurred(tex: Texture, radius_px: f32) ?Texture {
    if (tex.width < 2 or tex.height < 2) return null;
    var tmp: BlurBackdrop = .{ .radius_px = radius_px };
    const prev_rendering = dvui.renderingSet(true);
    defer _ = dvui.renderingSet(prev_rendering);
    defer tmp.releaseLevels();
    const last = tmp.run(tex, true, 1, 1) orelse return null;
    // Take the last level out of `levels` as the caller's own texture; `releaseLevels`
    // then drops the rest.
    const out = dvui.textureFromTarget(tmp.levels[last].?) catch return null;
    tmp.levels[last] = null;
    return out;
}

/// The blur of `source` into `levels`, from slot `first` on; the slot of the last level written
/// comes back, and `small` is a view of it. Null when no pass ran (a radius too small to blur) or
/// the backend has no targets; `small` is then cleared. `source` is the caller's and is never
/// written or destroyed.
///
/// The levels are precise targets (`CreateOptions.precision = .high`: float where the backend has
/// it). At 8 bits a dark theme's frost lives in ~30 levels, and rounding it at every pass —
/// coarsest at the small levels, then magnified back up — drew contour blobs instead of a
/// gradient. Only the final draw onto the frame is 8-bit again (`dither`).
///
/// `restore_target` saves/restores the current render target around the passes (`blurred`).
/// `deinit` already has an outer restore to the window target and passes false so we don't
/// rebind a destroyed capture target mid-pipeline. Restore happens only if a pass actually bound a
/// step target — a no-op restore would rebind the window (clear-on-bind flicker).
///
/// `source_coarse` is how many rect pixels one source texel already stands for, so the radius
/// means the same thing whether the copy was taken full size or not.
fn run(self: *BlurBackdrop, source: Texture, restore_target: bool, first: usize, source_coarse: u32) ?usize {
    if (self.stable) return self.runFine(source, restore_target, first, source_coarse);
    return self.runGauss(source, restore_target, first, source_coarse);
}

/// The blur's Gaussian σ is this many times `radius_px`. Measured off the dual-Kawase pyramid
/// `runGauss` replaced, which spread a point to σ ≈ 1.45 R at every radius — so a radius, and
/// every setting and frost tuned in one, still means what it did.
const sigma_per_radius: f32 = 1.45;

/// The least σ, in its own texels, the Gaussian is left to do after the halvings. Each halving
/// is a render-target switch, so the fewer the better; but a Gaussian of under ~2 texels,
/// stretched back up, shows its texel grid. At 2.5 the halvings stop with σ between 2.5 and 5
/// texels, which a pass of 9–15 taps covers.
const sigma_min_texels: f32 = 2.5;

/// Fizzy addition: the blur as compositors do it — halve until the blur left to do is a few
/// texels, run it there as a separable Gaussian, and stretch the result back in the same pass as
/// the Gaussian's second axis.
///
/// What a blur costs here is passes, not pixels: every pass is a render-target switch, and on
/// SDL's Metal renderer a switch is a new command encoder, fresh buffers, and — leaving the frame
/// — a flush of everything queued so far. The dual-Kawase pyramid it replaced halved all the way
/// to `radius` texels and doubled all the way back, ~11 switches and ~75 draws a capture; this is
/// `halvings + 3` switches and ~35 draws, for the same Gaussian (`sigma_per_radius`).
///
/// Passes: the halvings (`source` → 1/2 → … → 1/2^m, the same 4-tap diagonal kernel the pyramid
/// went down with, each tap on a texel centre); a horizontal Gaussian at 1/2^m; then a vertical
/// Gaussian drawn straight into the output, magnifying as it goes — the bilinear stretch of a
/// Gaussian several texels wide has no grid left to show. `detail` mixes a finer halving into that
/// last pass. The output is `source`'s size, halved once more when `source` is full resolution:
/// a stretch is what it is drawn with anyway, and it is dithered at that size (`dither`).
fn runGauss(self: *BlurBackdrop, source: Texture, restore_target: bool, first: usize, source_coarse: u32) ?usize {
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);

    var prev1: dvui.RenderTarget = undefined;
    var switched = false;
    defer if (restore_target and switched) {
        _ = dvui.renderTarget(prev1);
    };

    // Nothing blurred (a radius too small for a pass): no result. Left in place, `small` was
    // drawn at this capture's rect as if it were current, and a tooltip fading in from a
    // sub-pixel blur flashed its previous showing's backdrop.
    if (self.radius_px <= 1 or source.width < 2 or source.height < 2) {
        self.small = null;
        return null;
    }

    // σ in source texels, and what the halvings already spread: each halving's two taps per axis
    // sit ±1.5 of its input's texels out, 2.25 of those texels² of variance.
    const sigma_src = sigma_per_radius * self.radius_px / @as(f32, @floatFromInt(source_coarse));
    var halvings: u5 = 0;
    var spread: f32 = 0;
    while (halvings < 16) {
        const next: u5 = halvings + 1;
        const texel: f32 = @floatFromInt(@as(u32, 1) << next);
        if (sigma_src / texel < sigma_min_texels) break;
        if ((source.width >> next) < 2 or (source.height >> next) < 2) break;
        const t_in: f32 = @floatFromInt(@as(u32, 1) << halvings);
        spread += 2.25 * t_in * t_in;
        halvings = next;
    }
    const texel: f32 = @floatFromInt(@as(u32, 1) << halvings);
    const sigma_lo = std.math.clamp(@sqrt(@max(sigma_src * sigma_src - spread, 0.25)) / texel, 0.5, 8);

    var slot = first;
    var cur = source;
    // The halvings as they are made, for `detail`.
    var downs: [16]Texture = undefined;
    for (0..halvings) |i| {
        const w = cur.width / 2;
        const h = cur.height / 2;
        const step = self.level(slot, w, h) orelse return null;
        bindPass(step, &prev1, &switched);
        defer unbindPassClip();
        // Exactly 2:1, so ±1.5 input texels from an output centre is a texel centre and each tap
        // reads one texel: the kernel is [½ 0 0 ½] per axis — wider than the 2×2 box a plain
        // halving averages, which is what keeps it from aliasing as content slides under it.
        const du = 1.5 / @as(f32, @floatFromInt(cur.width));
        const dv = 1.5 / @as(f32, @floatFromInt(cur.height));
        // The uv spans exactly the 2w×2h texels the halving covers (an odd edge drops its last).
        const uw = @as(f32, @floatFromInt(w * 2)) / @as(f32, @floatFromInt(cur.width));
        const uh = @as(f32, @floatFromInt(h * 2)) / @as(f32, @floatFromInt(cur.height));
        const taps = [4][2]f32{ .{ -du, -dv }, .{ du, -dv }, .{ -du, dv }, .{ du, dv } };
        const add = tapsBegin(cur, step);
        defer tapsEnd(cur, add);
        const dest: dvui.Rect.Physical = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        for (taps, 0..) |tap, t| {
            const mod = if (add) tapWeight(@floatFromInt(t), 1, 4) else dvui.Color.white.opacity(1.0 / @as(f32, @floatFromInt(t + 1)));
            dvui.renderTexture(cur, .{ .r = dest }, .{ .uv = .{ .x = tap[0], .y = tap[1], .w = uw, .h = uh }, .colormod = mod }) catch {};
            if (add and t == 0) _ = tapsBlend(cur, .add);
        }
        cur = dvui.Texture.fromTargetTemp(step) catch return null;
        downs[i] = cur;
        slot += 1;
    }

    var buf: [max_gauss_taps]GaussTap = undefined;
    const taps = gaussTaps(sigma_lo, &buf);

    // Horizontal, at the halvings' size.
    const across = self.level(slot, cur.width, cur.height) orelse return null;
    gaussPass(cur, across, taps, .x, &.{}, &prev1, &switched);
    cur = dvui.Texture.fromTargetTemp(across) catch return null;
    slot += 1;

    // Vertical, straight into the output. `detail` is the last two halvings, half each: blurred
    // enough to read as a sharper core rather than a second, crisp image — the finest halvings
    // ghost text through the frost, the coarsest alone is too soft to show anything.
    const out_div: u32 = if (source_coarse == 1 and halvings >= 1) 2 else 1;
    const out = self.level(slot, @max(1, source.width / out_div), @max(1, source.height / out_div)) orelse return null;
    const detail = std.math.clamp(self.detail, 0, 0.9);
    var layers: [2]Layer = undefined;
    var n_layers: usize = 0;
    if (detail > 0.001 and halvings >= 1) {
        const pair = @min(halvings, 2);
        for (downs[halvings - pair .. halvings]) |d| {
            layers[n_layers] = .{ .tex = d, .weight = detail / @as(f32, @floatFromInt(pair)) };
            n_layers += 1;
        }
    }
    gaussPass(cur, out, taps, .y, layers[0..n_layers], &prev1, &switched);
    const result = dvui.Texture.fromTargetTemp(out) catch return null;

    dither(result);
    self.small = result;
    return slot;
}

const max_gauss_taps = 1 + 2 * 11;
const GaussTap = struct { o: f32, w: f32 };
const Layer = struct { tex: Texture, weight: f32 };

/// A Gaussian of `sigma` texels as bilinear taps: the centre texel, then each pair of texels
/// either side merged into one tap between them, weighted so the sampler's lerp returns the pair's
/// weighted sum. Cut at 2.5σ (99% of it); weights sum to one.
fn gaussTaps(sigma: f32, buf: *[max_gauss_taps]GaussTap) []const GaussTap {
    const reach: u32 = @min(@as(u32, @intFromFloat(@ceil(2.5 * sigma))), 2 * ((max_gauss_taps - 1) / 2));
    const g = struct {
        fn at(i: u32, s: f32) f32 {
            const x = @as(f32, @floatFromInt(i)) / s;
            return @exp(-0.5 * x * x);
        }
    };
    var n: usize = 1;
    buf[0] = .{ .o = 0, .w = 1 };
    var total: f32 = 1;
    var i: u32 = 1;
    while (i <= reach) : (i += 2) {
        const a = g.at(i, sigma);
        const b = if (i + 1 <= reach) g.at(i + 1, sigma) else 0;
        const o = (@as(f32, @floatFromInt(i)) * a + @as(f32, @floatFromInt(i + 1)) * b) / (a + b);
        buf[n] = .{ .o = o, .w = a + b };
        buf[n + 1] = .{ .o = -o, .w = a + b };
        n += 2;
        total += 2 * (a + b);
    }
    for (buf[0..n]) |*t| t.w /= total;
    return buf[0..n];
}

/// Bind `target` for a pass, clipped to itself (the ambient clip is in window coordinates and
/// means nothing in a target addressed from (0,0): a clip that happens not to cover the origin
/// would clip away every tap and leave the target blank). The first bind of a run
/// remembers what was bound before it, for the caller to restore. Pair with `unbindPassClip`.
fn bindPass(target: Texture.Target, prev1: *dvui.RenderTarget, switched: *bool) void {
    const prev = dvui.renderTarget(.{ .texture = target, .offset = .{} });
    if (!switched.*) {
        prev1.* = prev;
        switched.* = true;
    }
    pass_prev_clip = dvui.clipGet();
    dvui.clipSet(.{ .w = @floatFromInt(target.width), .h = @floatFromInt(target.height) });
}

var pass_prev_clip: dvui.Rect.Physical = .{};

fn unbindPassClip() void {
    dvui.clipSet(pass_prev_clip);
}

/// One axis of a separable Gaussian: `src` drawn over the whole of `into` once per tap, offset
/// along `axis` by the tap's texels of `src`, at the tap's weight — `into` may be bigger than
/// `src`, and the draw then magnifies as it blurs. `extra` are whole-texture layers mixed in at
/// their weights, the taps sharing what is left.
fn gaussPass(src: Texture, into: Texture.Target, taps: []const GaussTap, axis: enum { x, y }, extra: []const Layer, prev1: *dvui.RenderTarget, switched: *bool) void {
    bindPass(into, prev1, switched);
    defer unbindPassClip();
    const dest: dvui.Rect.Physical = .{ .w = @floatFromInt(into.width), .h = @floatFromInt(into.height) };
    const span: f32 = @floatFromInt(if (axis == .x) src.width else src.height);
    var keep: f32 = 1;
    for (extra) |e| keep -= e.weight;
    const add = tapsBegin(src, into);
    defer tapsEnd(src, add);
    var before: f32 = 0;
    for (taps, 0..) |tap, i| {
        const w = tap.w * keep;
        const mod = if (add) tapWeight(before, w, 1) else dvui.Color.white.opacity(w / (before + w));
        before += w;
        const d = tap.o / span;
        dvui.renderTexture(src, .{ .r = dest }, .{
            .uv = if (axis == .x) .{ .x = d, .w = 1, .h = 1 } else .{ .y = d, .w = 1, .h = 1 },
            .colormod = mod,
        }) catch {};
        if (add and i == 0) _ = tapsBlend(src, .add);
    }
    for (extra) |e| {
        const mod = if (add) tapWeight(before, e.weight, 1) else dvui.Color.white.opacity(e.weight / (before + e.weight));
        before += e.weight;
        const e_add = add and tapsBlend(e.tex, .add);
        defer tapsEnd(e.tex, e_add);
        dvui.renderTexture(e.tex, .{ .r = dest }, .{ .colormod = mod }) catch {};
    }
}

/// Fizzy addition: a blur that holds still under moving content — classic (same-size) Kawase,
/// after box-averaging down (`fineShrink`) when the radius is big. Each pass averages four
/// diagonal bilinear taps `o` texels out, which adds `o² + ¼` to the variance per axis (each tap
/// is itself a 2-texel average); passes run at o = ½, 1½, 2½ … until the variance reaches σ² for
/// σ = radius/2 in the working texels, the last pass at whatever offset lands it exactly, so the
/// blur grows continuously with the radius.
///
/// Why it is stable where `runGauss` shimmers: its halvings are *decimated*, so what a
/// coarse texel holds jumps as content slides a pixel; a box average changes by exactly the
/// pixel that slid, and the blur above it is shift-invariant. Each halving here is one bilinear
/// tap on the corner four texels share — their exact mean. `source` (already `source_coarse`
/// down, by the copy's own 2×2 box) is never written; halvings take slots from `first`, and the
/// passes ping-pong between the next two.
fn runFine(self: *BlurBackdrop, source: Texture, restore_target: bool, first: usize, source_coarse: u32) ?usize {
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);

    var prev1: dvui.RenderTarget = undefined;
    var switched = false;
    defer if (restore_target and switched) {
        _ = dvui.renderTarget(prev1);
    };

    var cur = source;
    var last: ?usize = null;
    var slot = first;
    var scale = source_coarse;
    const want = @max(self.fineShrink(), source_coarse);
    while (scale < want and cur.width >= 4 and cur.height >= 4) : (scale *= 2) {
        const nw = cur.width / 2;
        const nh = cur.height / 2;
        const step_target = self.level(slot, nw, nh) orelse break;
        const prev = dvui.renderTarget(.{ .texture = step_target, .offset = .{} });
        if (!switched) {
            prev1 = prev;
            switched = true;
        }
        const prev_clip = dvui.clipGet();
        defer dvui.clipSet(prev_clip);
        dvui.clipSet(.{ .w = @floatFromInt(nw), .h = @floatFromInt(nh) });
        // Exactly 2:1 (an odd edge drops its last texel), so each output centre lands on the
        // corner four source texels share and linear filtering returns their mean.
        dvui.renderTexture(cur, .{ .r = .{ .w = @floatFromInt(nw), .h = @floatFromInt(nh) } }, .{
            .uv = .{
                .w = @as(f32, @floatFromInt(nw * 2)) / @as(f32, @floatFromInt(cur.width)),
                .h = @as(f32, @floatFromInt(nh * 2)) / @as(f32, @floatFromInt(cur.height)),
            },
        }) catch {};
        cur = dvui.Texture.fromTargetTemp(step_target) catch break;
        last = slot;
        slot += 1;
    }

    const w = cur.width;
    const h = cur.height;
    const sigma = self.radius_px * 0.5 / @as(f32, @floatFromInt(scale));
    var remaining = sigma * sigma;
    var pass: usize = 0;
    while (remaining > 0.01 and pass < 16) : (pass += 1) {
        var o: f32 = @as(f32, @floatFromInt(pass)) + 0.5;
        if (o * o + 0.25 > remaining) o = @sqrt(@max(remaining - 0.25, 0));
        remaining -= o * o + 0.25;

        const pslot = slot + pass % 2;
        const step_target = self.level(pslot, w, h) orelse break;
        const prev = dvui.renderTarget(.{ .texture = step_target, .offset = .{} });
        if (!switched) {
            prev1 = prev;
            switched = true;
        }
        // See `bindPass`: the ambient clip means nothing here.
        const prev_clip = dvui.clipGet();
        dvui.clipSet(.{ .w = @floatFromInt(w), .h = @floatFromInt(h) });
        defer dvui.clipSet(prev_clip);

        const dest_r: dvui.Rect.Physical = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        const du = o / @as(f32, @floatFromInt(w));
        const dv = o / @as(f32, @floatFromInt(h));
        const taps = [4]dvui.Point{
            .{ .x = -du, .y = -dv },
            .{ .x = du, .y = -dv },
            .{ .x = -du, .y = dv },
            .{ .x = du, .y = dv },
        };
        const add = tapsBegin(cur, step_target);
        defer tapsEnd(cur, add);
        for (taps, 0..) |tap, i| {
            const mod = if (add)
                tapWeight(@floatFromInt(i), 1, 4)
            else
                dvui.Color.white.opacity(1.0 / @as(f32, @floatFromInt(i + 1)));
            dvui.renderTexture(cur, .{ .r = dest_r }, .{
                .uv = .{ .x = tap.x, .y = tap.y, .w = 1, .h = 1 },
                .colormod = mod,
            }) catch {};
            if (add and i == 0) _ = tapsBlend(cur, .add);
        }

        cur = dvui.Texture.fromTargetTemp(step_target) catch break;
        last = pslot;
    }

    // Nothing blurred (a radius too small for a pass): no result — not the last capture's.
    // Left in place, `small` was drawn at this capture's rect as if it were current, and a
    // tooltip fading in from a sub-pixel blur flashed its previous showing's backdrop.
    const done = last orelse {
        self.small = null;
        return null;
    };
    dither(cur);
    self.small = cur;
    return done;
}

/// Fizzy addition: ordered dithering, so the one quantising write left — the finished frost
/// onto the 8-bit frame — does not step. A dark theme's frost spans ~40 levels, and a smooth
/// ramp across 200px is then a staircase of 4px treads, which the eye picks out on dark tones
/// however exact the passes were. Adding a tiled 8×8 Bayer pattern at 0…1 LSB into the last
/// (float) level breaks each tread into a pattern that averages to the true value; the final
/// draw rounds signal plus noise once. Only worth doing when the level really is float — into
/// an 8-bit level the sub-LSB noise itself rounds away to nothing.
///
/// The pattern is positive-only (an additive draw cannot subtract), which biases the frost by
/// half a level; invisible, and less than the bias the taps' own rounding carried before.
fn dither(last: Texture) void {
    if (!dvui.Backend.support_precise_targets) return;
    const noise = ditherTexture() orelse return;
    const cw = dvui.currentWindow();
    if (!tapsBlend(noise, .add)) return;
    defer cw.backend.textureBlend(noise, .over) catch {};
    const prev = dvui.renderTarget(.{ .texture = Texture.Target.cast(last), .offset = .{}, .rendering = cw.render_target.rendering });
    defer _ = dvui.renderTarget(prev);
    const w: f32 = @floatFromInt(last.width);
    const h: f32 = @floatFromInt(last.height);
    const prev_clip = dvui.clipGet();
    defer dvui.clipSet(prev_clip);
    dvui.clipSet(.{ .w = w, .h = h });
    const prev_alpha = dvui.alpha(1);
    defer dvui.alphaSet(prev_alpha);
    // The texture holds 0…63 (in 1/255 units); 1/64 of that is 0…1 LSB. Tiled by uv > 1.
    dvui.renderTexture(noise, .{ .r = .{ .w = w, .h = h }, .s = 1 }, .{
        .uv = .{ .w = w / bayer_size, .h = h / bayer_size },
        .colormod = dvui.Color.white.opacity(1.0 / 64.0),
    }) catch {};
}

const bayer_size: f32 = 8;
var dither_tex: ?Texture = null;

/// The 8×8 Bayer matrix as a repeating texture, made once per process (per dylib, which is
/// fine: it is 256 bytes). Never destroyed — it lives as long as the renderer.
fn ditherTexture() ?Texture {
    if (dither_tex) |t| return t;
    // Recursive definition: B(2n) = [4B(n)+0, 4B(n)+2; 4B(n)+3, 4B(n)+1].
    var px: [64]dvui.Color.PMA = undefined;
    for (0..8) |y| {
        for (0..8) |x| {
            var v: u8 = 0;
            var bit: u3 = 0;
            var xx = x;
            var yy = y;
            while (bit < 3) : (bit += 1) {
                const xb: u8 = @intCast(xx & 1);
                const yb: u8 = @intCast(yy & 1);
                v = v * 4 + (xb ^ yb) * 2 + yb;
                xx >>= 1;
                yy >>= 1;
            }
            // Bit-reversal above ordered from the finest level; the value set is 0…63 either way.
            px[y * 8 + x] = .{ .r = v, .g = v, .b = v, .a = v };
        }
    }
    dither_tex = dvui.textureCreate(&px, .{ .width = 8, .height = 8, .interpolation = .nearest, .wrap_u = .repeat, .wrap_v = .repeat }) catch return null;
    return dither_tex;
}

/// Draw the cached blurred texture over `rect` (set by the last
/// `init`). Cheap: just queues one textured-quad render command.
/// Must be the first thing drawn wherever content on top of the blur goes,
/// so that content paints over it.
pub fn draw(self: *BlurBackdrop) void {
    self.drawRounded(.{}, 1);
}

/// Fizzy addition: `draw` with rounded corners (natural units, scaled by `scale`), for a frost
/// under a card that has them.
pub fn drawRounded(self: *BlurBackdrop, corners: dvui.CornerRect, scale: f32) void {
    const tex = self.small orelse return;
    dvui.renderTexture(tex, .{ .r = self.rect, .s = scale }, .{ .corners = corners }) catch {};
}

/// Fizzy addition: how a frosted pane is composed. See `frostPane`.
pub const Pane = struct {
    /// Blur strength — halvings; 8 a soft focus, 16 a heavy frost, 32 a wash of colour.
    radius: f32 = 20,
    /// How often to re-read what is underneath while the pane's geometry holds. Zero re-reads
    /// every frame, which is the default now that a re-read is a handful of draws into targets
    /// the pane keeps: content scrolling under a window moves in its blur at the frame rate.
    refresh_ms: u32 = 0,
    /// The pane's own colour, composited with the frost: `out = (1 - mix) * frost + mix * tint`.
    /// The tint's alpha is the coverage the whole thing ends up with. Null keeps only the frost.
    tint: ?dvui.Color = null,
    /// 0 is all frost, 1 is all tint.
    mix: f32 = 0.5,
    /// White added over the whole pane after the mix, 0…1 — a glass material's lift.
    lift: f32 = 0,
    /// How much definition the frost keeps, 0…1 (`BlurBackdrop.detail`).
    detail: f32 = 0,
};

/// Fizzy addition: a frosted pane — what is under `rect`, blurred, composed with a tint and a
/// lift per `pane`, drawn with `corners`. Keyed by `id`, so the blur texture lives and dies with
/// the widget that owns it (a floating window, a menu, a popover).
///
/// Declared now, done later: the copy of "what is under me" and the draw are queued with
/// `dvui.deferRender`, so they run when this subwindow's commands replay at the end of the
/// frame — after every subwindow below it has rendered. Taken at declaration, a frost saw only
/// the main window: another floating window under this one had queued its draws but put
/// nothing on the frame yet, and the frost looked straight through it.
///
/// Draw order is the caller's: shadow first (a box shadow covers the pane's interior too, and
/// the frost replaces what it covers, so a shadow drawn first survives only outside), then this,
/// then the contents. The caller paints no fill of its own — the tint is the fill.
pub fn frostPane(id: dvui.Id, rect: Rect.Physical, corners: dvui.CornerRect, scale: f32, pane: Pane) void {
    const job = dvui.dataGetPtrDefault(null, id, "_frost_job", FrostJob, .{});
    const backdrop = dvui.dataGetPtrDefault(null, id, "_frost", BlurBackdrop, .{});
    dvui.dataSetDeinitFunction(null, id, "_frost", &releaseTexture);
    backdrop.mode = .readback;
    backdrop.radius_px = pane.radius;
    backdrop.detail = pane.detail;

    // `init` takes a rect in *window* coordinates.
    const nat = dvui.windowRectScale().rectFromPhysical(rect);
    // A witness that changes with the geometry and, coarsely, with time.
    const tick: i128 = if (pane.refresh_ms == 0) dvui.currentWindow().frame_time_ns else @divTrunc(dvui.currentWindow().frame_time_ns, @as(i128, pane.refresh_ms) * std.time.ns_per_ms);
    backdrop.init(nat, .{ rect, tick });

    job.* = .{
        .backdrop = backdrop,
        .corners = corners,
        .scale = scale,
        .rect = rect,
        .tint = pane.tint,
        .mix = std.math.clamp(pane.mix, 0, 1),
        .lift = std.math.clamp(pane.lift, 0, 1),
    };
    dvui.deferRender(job, FrostJob.draw);
}

/// What `frostPane` hands to the replay. Lives in the data store under the owner's id, so the
/// pointer is good until the frame ends.
const FrostJob = struct {
    backdrop: *BlurBackdrop = undefined,
    corners: dvui.CornerRect = .{},
    scale: f32 = 1,
    rect: Rect.Physical = .{},
    tint: ?dvui.Color = null,
    mix: f32 = 0,
    lift: f32 = 0,

    fn draw(ctx: ?*anyopaque) void {
        const self: *FrostJob = @ptrCast(@alignCast(ctx orelse return));
        // The capture, now that everything below this pane is on the target.
        self.backdrop.deinit();
        const tint = self.tint orelse {
            self.backdrop.drawRounded(self.corners, self.scale);
            return;
        };
        self.backdrop.drawRoundedScaled(self.corners, self.scale, 1 - self.mix);
        addTint(self.rect, self.corners, self.scale, tint, self.mix);
        addTint(self.rect, self.corners, self.scale, .white, self.lift);
    }
};

/// Fizzy addition: `drawRounded` at `weight` of itself — the frost half of a frost/tint mix.
/// The texture's copy blend writes exactly `weight * frost`, alpha included.
pub fn drawRoundedScaled(self: *BlurBackdrop, corners: dvui.CornerRect, scale: f32, weight: f32) void {
    const tex = self.small orelse return;
    dvui.renderTexture(tex, .{ .r = self.rect, .s = scale }, .{ .corners = corners, .colormod = dvui.Color.white.opacity(weight) }) catch {};
}

/// Fizzy addition: the tint half of a frost/tint mix — `weight * tint` added onto `rect`, with
/// the window's corners. A 1×1 white texture that carries an additive blend, so it queues like
/// any other texture draw (a deferred floating window renders it later, blend intact).
pub fn addTint(rect: Rect.Physical, corners: dvui.CornerRect, scale: f32, tint: dvui.Color, weight: f32) void {
    const white = whiteTexture() orelse return;
    const w = std.math.clamp(weight, 0, 1);
    if (w <= 0.001) return;
    var c = tint;
    c.a = @intFromFloat(@round(@as(f32, @floatFromInt(tint.a)) * w));
    dvui.renderTexture(white, .{ .r = rect, .s = scale }, .{ .corners = corners, .colormod = c }) catch {};
}

var white_tex: ?Texture = null;

fn whiteTexture() ?Texture {
    if (white_tex) |t| return t;
    if (!dvui.Backend.support_texture_blend) return null;
    const px = [_]dvui.Color.PMA{.{ .r = 255, .g = 255, .b = 255, .a = 255 }};
    const t = dvui.textureCreate(&px, .{ .width = 1, .height = 1, .interpolation = .nearest }) catch return null;
    if (!tapsBlend(t, .add)) {
        dvui.textureDestroyLater(t);
        return null;
    }
    white_tex = t;
    return t;
}

/// Fizzy addition: a frosted pane *replaces* what is under it. Drawn source-over, the frost of
/// a see-through window (alpha ~0.7) let 30% of the sharp content through, and the sharp edges
/// read as "not blurred". So the cached frost carries a copy blend: wherever it is drawn it
/// writes its own colour and alpha, and the OS's blur of the desktop shows through it exactly
/// as it did through the content. Set on the texture, not around the draw — the draw is
/// usually queued inside a floating window and runs at the end of the frame.
fn frostReplaces(self: *BlurBackdrop) void {
    if (self.small) |tex| _ = tapsBlend(tex, .copy);
}

/// Release the levels (and with it the cached texture). Never called directly by user code -
/// registered by `get` as the data store's deinit function for this key, so
/// dvui calls it exactly once, whenever the storage key is finally
/// reclaimed (e.g. the widget that owns it stops being touched).
pub fn releaseTexture(ptr: *anyopaque) void {
    const self: *BlurBackdrop = @ptrCast(@alignCast(ptr));
    self.releaseLevels();
    self.* = undefined;
}

/// Fizzy addition: the taps of one pass are a weighted *mean* of the source, and a mean is a
/// sum. Where the backend can blend additively each tap is drawn at its own weight and the
/// sum is exact for any source alpha. The fallback is upstream's running-weight source-over
/// (weights 1, ½, ⅓ …), which is only a mean when the source is opaque: a translucent source
/// — a see-through window read back, a pane photographed with its fill at content opacity —
/// gains ~20% colour *and* alpha per pass, alpha saturates, and the colour overshoots it into
/// glare. Returns whether additive is on; `tapsEnd` puts the texture's blend back.
/// The first tap of a pass *writes* (`.copy`) and the rest add: a reused level still holds
/// the last capture, and a copy over it is what a clear plus a sum would give, without the
/// clear's target switch and flush. The caller switches the source to `.add` after its first
/// draw. Without blend control the level is cleared here and the taps composite as before.
/// An additive tap's weight `w` (of `total`, with `before` handed out already) as a colormod.
/// The alpha is a byte, and truncating each tap's share on its own lost the remainder every
/// pass — 0.25 is 63/255, four of them 252/255 — so ~12 passes of a frost came out ~13% less
/// opaque and darker than what they blurred: a see-through window showed through the blur.
/// Cumulative rounding hands out whole bytes that always sum to exactly 255.
fn tapWeight(before: f32, w: f32, total: f32) dvui.Color {
    const lo: u8 = @intFromFloat(@round(255 * before / total));
    const hi: u8 = @intFromFloat(@round(255 * (before + w) / total));
    return .{ .r = 255, .g = 255, .b = 255, .a = hi - lo };
}

test "additive tap weights sum to exactly one" {
    var sum: u32 = 0;
    for (0..4) |i| sum += tapWeight(@floatFromInt(i), 1, 4).a;
    try std.testing.expectEqual(@as(u32, 255), sum);
    sum = 0;
    var before: f32 = 0;
    for ([_]f32{ 1, 2, 1, 2, 1, 2, 1, 2 }) |w| {
        sum += tapWeight(before, w, 12).a;
        before += w;
    }
    try std.testing.expectEqual(@as(u32, 255), sum);
}

fn tapsBegin(cur: Texture, into: Texture.Target) bool {
    if (tapsBlend(cur, .copy)) return true;
    into.clear();
    return false;
}

fn tapsBlend(tex: Texture, blend: dvui.Backend.TextureBlend) bool {
    if (!dvui.Backend.support_texture_blend) return false;
    dvui.currentWindow().backend.textureBlend(tex, blend) catch return false;
    return true;
}

fn tapsEnd(cur: Texture, add: bool) void {
    if (!add) return;
    dvui.currentWindow().backend.textureBlend(cur, .over) catch {};
}
