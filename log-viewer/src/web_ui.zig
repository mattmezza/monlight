const std = @import("std");
const log = std.log;

/// Embedded HTML page (compiled into binary at build time).
const index_html = @embedFile("static/index.html");

/// Compiled Tailwind CSS (built by scripts/build-tailwind.sh and committed to
/// git, then embedded into the binary at build time via @embedFile).
const tailwind_css = @embedFile("static/tailwind.css");

/// Self-hosted Alpine.js v3 minified bundle. Vendored to avoid a CDN dependency.
const alpine_js = @embedFile("static/alpine.min.js");

/// Serve the log viewer page (GET /).
pub fn serveIndex(request: *std.http.Server.Request) void {
    sendResponse(request, .ok, index_html, "text/html; charset=utf-8") catch {};
}

/// Serve the compiled Tailwind CSS (GET /tailwind.css).
pub fn serveTailwindCss(request: *std.http.Server.Request) void {
    sendResponse(request, .ok, tailwind_css, "text/css; charset=utf-8") catch {};
}

/// Serve the vendored Alpine.js bundle (GET /alpine.js).
pub fn serveAlpineJs(request: *std.http.Server.Request) void {
    sendResponse(request, .ok, alpine_js, "application/javascript; charset=utf-8") catch {};
}

fn sendResponse(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    content_type: []const u8,
) !void {
    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "public, max-age=3600" },
        },
    }) catch |err| {
        log.err("Failed to send response: {}", .{err});
        return err;
    };
}

// Tests

test "index_html is embedded and non-empty" {
    try std.testing.expect(index_html.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "Log Viewer") != null);
}

test "tailwind_css is embedded and non-empty" {
    try std.testing.expect(tailwind_css.len > 0);
}

test "alpine_js is embedded and non-empty" {
    try std.testing.expect(alpine_js.len > 0);
}
