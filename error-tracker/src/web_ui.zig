const std = @import("std");
const log = std.log;

/// Embedded HTML pages (compiled into binary at build time).
const index_html = @embedFile("static/index.html");
const error_detail_html = @embedFile("static/error_detail.html");

/// Compiled Tailwind CSS (built by scripts/build-tailwind.sh and committed to
/// git, then embedded into the binary at build time via @embedFile).
const tailwind_css = @embedFile("static/tailwind.css");

/// Self-hosted Alpine.js v3 minified bundle. Vendored to avoid a CDN dependency.
const alpine_js = @embedFile("static/alpine.min.js");

/// Serve the error listing page (GET /).
pub fn serveIndex(request: *std.http.Server.Request) void {
    sendResponse(request, .ok, index_html, "text/html; charset=utf-8") catch {};
}

/// Serve the error detail page (GET /errors/{id}).
/// The page itself loads the error data via JavaScript fetch to /api/errors/{id}.
pub fn serveErrorDetail(request: *std.http.Server.Request) void {
    sendResponse(request, .ok, error_detail_html, "text/html; charset=utf-8") catch {};
}

/// Serve the compiled Tailwind CSS (GET /tailwind.css).
pub fn serveTailwindCss(request: *std.http.Server.Request) void {
    sendResponse(request, .ok, tailwind_css, "text/css; charset=utf-8") catch {};
}

/// Serve the vendored Alpine.js bundle (GET /alpine.js).
pub fn serveAlpineJs(request: *std.http.Server.Request) void {
    sendResponse(request, .ok, alpine_js, "application/javascript; charset=utf-8") catch {};
}

/// Check if the path matches /errors/{id} (numeric ID, for the web UI page).
/// This is distinct from /api/errors/{id} which returns JSON.
pub fn isErrorDetailPath(target: []const u8) bool {
    // Must start with /errors/
    if (!std.mem.startsWith(u8, target, "/errors/")) return false;
    const rest = target["/errors/".len..];

    // Strip query string if present
    const path_end = std.mem.indexOfScalar(u8, rest, '?') orelse rest.len;
    const id_str = rest[0..path_end];

    // Must be non-empty and all digits
    if (id_str.len == 0) return false;
    for (id_str) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
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

test "isErrorDetailPath matches valid paths" {
    try std.testing.expect(isErrorDetailPath("/errors/1"));
    try std.testing.expect(isErrorDetailPath("/errors/123"));
    try std.testing.expect(isErrorDetailPath("/errors/999999"));
    try std.testing.expect(isErrorDetailPath("/errors/1?foo=bar"));
}

test "isErrorDetailPath rejects invalid paths" {
    try std.testing.expect(!isErrorDetailPath("/errors/"));
    try std.testing.expect(!isErrorDetailPath("/errors/abc"));
    try std.testing.expect(!isErrorDetailPath("/errors/1/resolve"));
    try std.testing.expect(!isErrorDetailPath("/api/errors/1"));
    try std.testing.expect(!isErrorDetailPath("/"));
    try std.testing.expect(!isErrorDetailPath("/errors"));
}

test "tailwind_css is embedded and non-empty" {
    try std.testing.expect(tailwind_css.len > 0);
}

test "alpine_js is embedded and non-empty" {
    try std.testing.expect(alpine_js.len > 0);
}
