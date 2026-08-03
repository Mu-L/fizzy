//! Format sniffing for markdown images. std-only by design (same reasoning as `url_join.zig`):
//! it is pure byte inspection, so it is unit-tested from the app build rather than needing dvui.
const std = @import("std");

/// True for SVG, which stb_image will never decode and which READMEs are full of — every
/// shields.io / GitHub Actions badge is one. Those are skipped entirely (see `renderImageUrl`),
/// so this is checked *before* handing bytes to stbi and the common case costs no failed decode
/// (and no dvui warning) at all.
pub fn isSvg(bytes: []const u8) bool {
    var head = bytes;
    if (std.mem.startsWith(u8, head, "\xEF\xBB\xBF")) head = head[3..]; // UTF-8 BOM
    head = std.mem.trimStart(u8, head, " \t\r\n");
    // Only the start of the document is scanned, so a stray "<svg" deep inside a binary blob
    // can't match: either the root element is `<svg`, or it follows an XML declaration / doctype
    // preamble within the first kilobyte.
    const window = head[0..@min(head.len, 1024)];
    if (std.ascii.startsWithIgnoreCase(window, "<svg")) return true;
    if (!std.ascii.startsWithIgnoreCase(window, "<?xml") and
        !std.ascii.startsWithIgnoreCase(window, "<!doctype")) return false;
    return std.ascii.indexOfIgnoreCase(window, "<svg") != null;
}

test "isSvg: bare root element" {
    try std.testing.expect(isSvg("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"));
    try std.testing.expect(isSvg("<SVG></SVG>"));
}

test "isSvg: leading whitespace and BOM" {
    try std.testing.expect(isSvg("\n  <svg/>"));
    try std.testing.expect(isSvg("\xEF\xBB\xBF<svg/>"));
}

test "isSvg: after xml declaration or doctype" {
    try std.testing.expect(isSvg("<?xml version=\"1.0\"?>\n<svg width=\"10\"/>"));
    try std.testing.expect(isSvg("<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\">\n<svg/>"));
}

test "isSvg: not svg" {
    try std.testing.expect(!isSvg(""));
    try std.testing.expect(!isSvg("\x89PNG\r\n\x1a\n"));
    try std.testing.expect(!isSvg("<html><body>nope</body></html>"));
    // An `<svg` past the sniff window doesn't count.
    var buf: [2048]u8 = undefined;
    @memcpy(buf[0..5], "<?xml");
    @memset(buf[5..2044], ' ');
    @memcpy(buf[2044..], "<svg");
    try std.testing.expect(!isSvg(&buf));
}
