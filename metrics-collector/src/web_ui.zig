const std = @import("std");
const log = std.log;

/// Embedded HTML page (compiled into binary at build time).
const index_html = @embedFile("static/index.html");

/// Serve the metrics dashboard page (GET /).
pub fn serveIndex(request: *std.http.Server.Request) void {
    sendHtmlResponse(request, .ok, index_html) catch {};
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

test "index_html is embedded and non-empty" {
    try std.testing.expect(index_html.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "Metrics Dashboard") != null);
}
