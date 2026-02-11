const std = @import("std");
const log = std.log;

/// Result of a rate limit check.
pub const RateLimitResult = enum {
    /// Request is within limits.
    ok,
    /// Request exceeds rate limit; a 429 response has already been sent.
    limited,
};

/// Result of a body size check.
pub const BodySizeResult = enum {
    /// Request body size is within limits (or no body present).
    ok,
    /// Request body exceeds maximum size; a 413 response has already been sent.
    too_large,
};

/// In-memory sliding window rate limiter.
///
/// Tracks request timestamps in a fixed-size ring buffer per client.
/// Uses a simple sliding window approach: counts requests within the
/// last `window_ms` milliseconds.
///
/// Since all services use a single API key (not per-user keys), rate
/// limiting is applied globally (single bucket). The `RateLimiter`
/// supports a configurable number of slots if per-IP limiting is
/// added later.
pub const RateLimiter = struct {
    /// Ring buffer of request timestamps (epoch milliseconds).
    timestamps: []i64,
    /// Current write position in the ring buffer.
    head: usize,
    /// Number of valid entries in the buffer.
    count: usize,
    /// Maximum requests allowed within the window.
    max_requests: usize,
    /// Window duration in milliseconds (default: 60_000 for 1 minute).
    window_ms: i64,
    /// Allocator used for the timestamps buffer.
    allocator: std.mem.Allocator,

    /// Initialize a rate limiter.
    ///
    /// - `max_requests`: maximum requests allowed per window
    /// - `window_ms`: sliding window duration in milliseconds
    pub fn init(allocator: std.mem.Allocator, max_requests: usize, window_ms: i64) !RateLimiter {
        const timestamps = try allocator.alloc(i64, max_requests);
        @memset(timestamps, 0);
        return .{
            .timestamps = timestamps,
            .head = 0,
            .count = 0,
            .max_requests = max_requests,
            .window_ms = window_ms,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.allocator.free(self.timestamps);
    }

    /// Check if a request should be allowed.
    ///
    /// Returns `true` if the request is within limits, `false` if rate limited.
    /// When allowed, the current timestamp is recorded.
    pub fn checkRequest(self: *RateLimiter) bool {
        const now = std.time.milliTimestamp();
        return self.checkRequestAt(now);
    }

    /// Check if a request at the given timestamp should be allowed.
    /// (Exposed for testing with controlled timestamps.)
    pub fn checkRequestAt(self: *RateLimiter, now_ms: i64) bool {
        // First, count how many requests are within the window
        const window_start = now_ms - self.window_ms;
        var active_count: usize = 0;

        for (0..self.count) |i| {
            // Walk backwards from head to find valid entries
            const idx = if (self.head >= 1 + i)
                self.head - 1 - i
            else
                self.max_requests - (1 + i - self.head);
            if (self.timestamps[idx] > window_start) {
                active_count += 1;
            }
        }

        if (active_count >= self.max_requests) {
            return false; // Rate limited
        }

        // Record this request
        self.timestamps[self.head] = now_ms;
        self.head = (self.head + 1) % self.max_requests;
        if (self.count < self.max_requests) {
            self.count += 1;
        }

        return true;
    }

    /// Calculate seconds until a new request would be allowed.
    /// Returns 0 if not currently rate-limited.
    pub fn retryAfterSeconds(self: *const RateLimiter) u32 {
        const now = std.time.milliTimestamp();
        return self.retryAfterSecondsAt(now);
    }

    /// Calculate retry-after for a given timestamp (for testing).
    pub fn retryAfterSecondsAt(self: *const RateLimiter, now_ms: i64) u32 {
        if (self.count == 0) return 0;

        const window_start = now_ms - self.window_ms;

        // Find the oldest timestamp that's still within the window
        var oldest_in_window: i64 = now_ms;
        for (0..self.count) |i| {
            const idx = if (self.head >= 1 + i)
                self.head - 1 - i
            else
                self.max_requests - (1 + i - self.head);
            const ts = self.timestamps[idx];
            if (ts > window_start and ts < oldest_in_window) {
                oldest_in_window = ts;
            }
        }

        // Time until that oldest entry expires from the window
        const expires_at = oldest_in_window + self.window_ms;
        if (expires_at <= now_ms) return 0;

        const remaining_ms = expires_at - now_ms;
        // Round up to next whole second
        return @intCast(@divTrunc(remaining_ms + 999, 1000));
    }
};

/// Check rate limit for an HTTP request. If the limit is exceeded,
/// sends a 429 response and returns `.limited`. Otherwise returns `.ok`.
///
/// Excluded paths (e.g., `/health`) are not rate-limited.
pub fn checkRateLimit(
    request: *std.http.Server.Request,
    limiter: *RateLimiter,
    excluded_paths: []const []const u8,
) RateLimitResult {
    // Check if the path is excluded from rate limiting
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |qmark|
        target[0..qmark]
    else
        target;

    for (excluded_paths) |excluded| {
        if (std.mem.eql(u8, path, excluded)) {
            return .ok;
        }
    }

    if (limiter.checkRequest()) {
        return .ok;
    }

    // Rate limited — send 429 response
    const retry_after = limiter.retryAfterSeconds();
    sendRateLimited(request, retry_after);
    return .limited;
}

/// Check if the request body size exceeds the maximum allowed.
/// Uses the `content-length` header to check without reading the body.
///
/// Returns `.ok` if the body is within limits or no content-length is present.
/// Returns `.too_large` if the body exceeds `max_body_size` bytes, after
/// sending a 413 response.
pub fn checkBodySize(
    request: *std.http.Server.Request,
    max_body_size: usize,
) BodySizeResult {
    // Look for content-length header
    const content_length = getContentLength(request) orelse {
        // No content-length header — allow (may have no body, or chunked)
        return .ok;
    };

    if (content_length > max_body_size) {
        sendBodyTooLarge(request);
        return .too_large;
    }

    return .ok;
}

/// Extract the Content-Length header value from a request.
fn getContentLength(request: *std.http.Server.Request) ?usize {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (asciiEqlIgnoreCase(header.name, "content-length")) {
            return std.fmt.parseInt(usize, header.value, 10) catch null;
        }
    }
    return null;
}

/// Send a 429 Too Many Requests JSON response.
fn sendRateLimited(request: *std.http.Server.Request, retry_after: u32) void {
    var buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"detail\": \"Rate limit exceeded\", \"retry_after\": {d}}}", .{retry_after}) catch {
        // Fallback to static response if formatting fails
        const fallback =
            \\{"detail": "Rate limit exceeded", "retry_after": 60}
        ;
        request.respond(fallback, .{
            .status = .too_many_requests,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        }) catch |err| {
            log.err("Failed to send 429 response: {}", .{err});
        };
        return;
    };

    request.respond(body, .{
        .status = .too_many_requests,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch |err| {
        log.err("Failed to send 429 response: {}", .{err});
    };
}

/// Send a 413 Payload Too Large JSON response.
fn sendBodyTooLarge(request: *std.http.Server.Request) void {
    const body =
        \\{"detail": "Request body exceeds maximum size"}
    ;
    request.respond(body, .{
        .status = .payload_too_large,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch |err| {
        log.err("Failed to send 413 response: {}", .{err});
    };
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

test "RateLimiter allows requests within limit" {
    var limiter = try RateLimiter.init(std.testing.allocator, 3, 60_000);
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    // First 3 requests should be allowed
    try std.testing.expect(limiter.checkRequestAt(base_time));
    try std.testing.expect(limiter.checkRequestAt(base_time + 1_000));
    try std.testing.expect(limiter.checkRequestAt(base_time + 2_000));
}

test "RateLimiter rejects requests over limit" {
    var limiter = try RateLimiter.init(std.testing.allocator, 3, 60_000);
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    // Fill up the limit
    try std.testing.expect(limiter.checkRequestAt(base_time));
    try std.testing.expect(limiter.checkRequestAt(base_time + 1_000));
    try std.testing.expect(limiter.checkRequestAt(base_time + 2_000));

    // 4th request should be rejected
    try std.testing.expect(!limiter.checkRequestAt(base_time + 3_000));
}

test "RateLimiter sliding window resets after window expires" {
    var limiter = try RateLimiter.init(std.testing.allocator, 3, 60_000);
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    // Fill up the limit
    try std.testing.expect(limiter.checkRequestAt(base_time));
    try std.testing.expect(limiter.checkRequestAt(base_time + 1_000));
    try std.testing.expect(limiter.checkRequestAt(base_time + 2_000));

    // Should be rejected within the window
    try std.testing.expect(!limiter.checkRequestAt(base_time + 30_000));

    // After the window expires (60s after first request), should be allowed again
    try std.testing.expect(limiter.checkRequestAt(base_time + 61_000));
}

test "RateLimiter sliding window allows partial recovery" {
    var limiter = try RateLimiter.init(std.testing.allocator, 3, 60_000);
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    // Request at t=0, t=10s, t=20s
    try std.testing.expect(limiter.checkRequestAt(base_time));
    try std.testing.expect(limiter.checkRequestAt(base_time + 10_000));
    try std.testing.expect(limiter.checkRequestAt(base_time + 20_000));

    // At t=30s, all 3 are still within window, reject
    try std.testing.expect(!limiter.checkRequestAt(base_time + 30_000));

    // At t=61s, the first request (t=0) has expired, so only 2 in window => allow
    try std.testing.expect(limiter.checkRequestAt(base_time + 61_000));

    // Now 3 in window again (t=10, t=20, t=61), reject
    try std.testing.expect(!limiter.checkRequestAt(base_time + 62_000));
}

test "RateLimiter retryAfterSeconds calculates correctly" {
    var limiter = try RateLimiter.init(std.testing.allocator, 2, 60_000);
    defer limiter.deinit();

    const base_time: i64 = 1_000_000;

    // Two requests at t=0 and t=5s
    try std.testing.expect(limiter.checkRequestAt(base_time));
    try std.testing.expect(limiter.checkRequestAt(base_time + 5_000));

    // At t=10s, rate limited. Oldest in window is t=0, expires at t=60s.
    // retry_after should be ceil((60_000 - 10_000) / 1000) = 50 seconds
    const retry = limiter.retryAfterSecondsAt(base_time + 10_000);
    try std.testing.expectEqual(@as(u32, 50), retry);
}

test "asciiEqlIgnoreCase matches Content-Length" {
    try std.testing.expect(asciiEqlIgnoreCase("content-length", "Content-Length"));
    try std.testing.expect(asciiEqlIgnoreCase("Content-Length", "content-length"));
    try std.testing.expect(asciiEqlIgnoreCase("CONTENT-LENGTH", "content-length"));
    try std.testing.expect(!asciiEqlIgnoreCase("content-length", "content-type"));
}
