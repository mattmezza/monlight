const std = @import("std");
const log = std.log;

/// Result of an authentication check.
pub const AuthResult = enum {
    /// Request is authenticated (valid API key or excluded path).
    ok,
    /// Request is not authenticated; a 401 response has already been sent.
    rejected,
};

/// Authenticate an incoming HTTP request by checking the `X-API-Key` header.
///
/// If the request path matches any of the `excluded_paths`, authentication
/// is skipped and `.ok` is returned immediately.
///
/// If the API key is missing or incorrect, a 401 JSON response is sent on
/// the request and `.rejected` is returned. The caller should not send any
/// further response.
///
/// If the API key is correct, `.ok` is returned and the caller should
/// proceed with normal request handling.
pub fn authenticate(
    request: *std.http.Server.Request,
    api_key: []const u8,
    excluded_paths: []const []const u8,
) AuthResult {
    // Check if the path is excluded from auth
    const target = request.head.target;
    // Strip query string for path comparison
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |qmark|
        target[0..qmark]
    else
        target;

    for (excluded_paths) |excluded| {
        if (std.mem.eql(u8, path, excluded)) {
            return .ok;
        }
    }

    // Look for the X-API-Key header (case-insensitive per HTTP spec)
    const provided_key = getApiKeyHeader(request) orelse {
        // No API key header present
        sendUnauthorized(request);
        return .rejected;
    };

    // Constant-time comparison to prevent timing attacks
    if (!constantTimeEql(provided_key, api_key)) {
        sendUnauthorized(request);
        return .rejected;
    }

    return .ok;
}

/// Extract the X-API-Key header value from a request.
/// Header names are compared case-insensitively.
fn getApiKeyHeader(request: *std.http.Server.Request) ?[]const u8 {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (asciiEqlIgnoreCase(header.name, "x-api-key")) {
            return header.value;
        }
    }
    return null;
}

/// Send a 401 Unauthorized JSON response.
fn sendUnauthorized(request: *std.http.Server.Request) void {
    const body =
        \\{"detail": "Invalid API key"}
    ;
    request.respond(body, .{
        .status = .unauthorized,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch |err| {
        log.err("Failed to send 401 response: {}", .{err});
    };
}

/// Constant-time byte comparison to prevent timing attacks.
/// Returns true only if both slices have the same length and content.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var diff: u8 = 0;
    for (a, b) |a_byte, b_byte| {
        diff |= a_byte ^ b_byte;
    }
    return diff == 0;
}

/// Case-insensitive ASCII string comparison.
fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_byte, b_byte| {
        if (std.ascii.toLower(a_byte) != std.ascii.toLower(b_byte)) return false;
    }
    return true;
}

// ============================================================
// Tests
// ============================================================

test "constantTimeEql returns true for equal strings" {
    try std.testing.expect(constantTimeEql("hello", "hello"));
    try std.testing.expect(constantTimeEql("", ""));
    try std.testing.expect(constantTimeEql("a-long-api-key-value-12345", "a-long-api-key-value-12345"));
}

test "constantTimeEql returns false for different strings" {
    try std.testing.expect(!constantTimeEql("hello", "world"));
    try std.testing.expect(!constantTimeEql("hello", "hell"));
    try std.testing.expect(!constantTimeEql("hello", "hellp"));
    try std.testing.expect(!constantTimeEql("", "a"));
    try std.testing.expect(!constantTimeEql("a", ""));
}

test "asciiEqlIgnoreCase compares case-insensitively" {
    try std.testing.expect(asciiEqlIgnoreCase("x-api-key", "X-API-Key"));
    try std.testing.expect(asciiEqlIgnoreCase("X-API-KEY", "x-api-key"));
    try std.testing.expect(asciiEqlIgnoreCase("Content-Type", "content-type"));
    try std.testing.expect(!asciiEqlIgnoreCase("x-api-key", "x-api-keys"));
    try std.testing.expect(!asciiEqlIgnoreCase("x-api-key", "y-api-key"));
}

// Note: Testing `authenticate` directly requires constructing a real
// `std.http.Server.Request`, which requires an active TCP connection.
// Full integration tests for auth behavior are in the error-tracker's
// main.zig test suite, which spins up a real HTTP server.
// The unit tests above cover the helper functions used by authenticate.
