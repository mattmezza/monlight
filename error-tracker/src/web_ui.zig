const std = @import("std");
const log = std.log;

/// Embedded HTML pages (compiled into binary at build time).
const index_html = @embedFile("static/index.html");
const error_detail_html = @embedFile("static/error_detail.html");

/// Serve the error listing page (GET /).
pub fn serveIndex(request: *std.http.Server.Request) void {
    sendHtmlResponse(request, .ok, index_html) catch {};
}

/// Serve the error detail page (GET /errors/{id}).
/// The page itself loads the error data via JavaScript fetch to /api/errors/{id}.
pub fn serveErrorDetail(request: *std.http.Server.Request) void {
    sendHtmlResponse(request, .ok, error_detail_html) catch {};
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

fn sendHtmlResponse(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
) !void {
    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    }) catch |err| {
        log.err("Failed to send HTML response: {}", .{err});
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
