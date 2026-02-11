const std = @import("std");
const net = std.net;
const main = @import("main.zig");
const rate_limit = @import("rate_limit");

const test_api_key = "test-secret-key-12345678901234";

/// Parsed HTTP response from a raw TCP exchange.
const HttpResponse = struct {
    status_code: u16,
    body: []const u8,
    raw: []const u8,
};

/// A test server that handles a fixed number of requests then stops.
const TestServer = struct {
    server: net.Server,
    thread: ?std.Thread = null,

    fn init() !TestServer {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        const server = try address.listen(.{
            .reuse_address = true,
        });
        return .{ .server = server };
    }

    fn port(self: *const TestServer) u16 {
        return self.server.listen_address.getPort();
    }

    fn start(self: *TestServer, n: usize) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{ self, n });
        // Give the server a moment to be ready
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    fn acceptLoop(self: *TestServer, count: usize) void {
        // Use a generous rate limit for auth tests (won't be hit)
        var limiter = rate_limit.RateLimiter.init(std.testing.allocator, 1000, 60_000) catch return;
        defer limiter.deinit();
        var handled: usize = 0;
        while (handled < count) {
            const conn = self.server.accept() catch continue;
            main.handleConnection(conn, test_api_key, &limiter) catch {};
            handled += 1;
        }
    }

    fn waitAndDeinit(self: *TestServer) void {
        if (self.thread) |t| {
            t.join();
        }
        self.server.deinit();
    }
};

/// Send a raw HTTP request and parse the response.
fn sendRequest(srv_port: u16, method: []const u8, path: []const u8, headers: []const u8) !HttpResponse {
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, srv_port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    // Build and send raw HTTP request
    var request_buf: [4096]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n{s}\r\n", .{ method, path, headers }) catch unreachable;
    try stream.writeAll(request);

    // Read response
    var response_buf: [8192]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < response_buf.len) {
        const n = stream.read(response_buf[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }

    if (total_read == 0) {
        return error.EmptyResponse;
    }

    const response = response_buf[0..total_read];

    // Parse status code from first line: "HTTP/1.1 NNN ..."
    const status_code = parseStatusCode(response) orelse return error.InvalidResponse;

    // Find body (after \r\n\r\n)
    const body = if (std.mem.indexOf(u8, response, "\r\n\r\n")) |header_end|
        response[header_end + 4 ..]
    else
        response[0..0];

    return .{
        .status_code = status_code,
        .body = body,
        .raw = response,
    };
}

fn parseStatusCode(response: []const u8) ?u16 {
    // Find "HTTP/1.1 NNN" pattern
    const prefix = "HTTP/1.1 ";
    if (response.len < prefix.len + 3) return null;
    if (!std.mem.startsWith(u8, response, prefix)) return null;
    const code_str = response[prefix.len .. prefix.len + 3];
    return std.fmt.parseInt(u16, code_str, 10) catch null;
}

// ============================================================
// Integration tests for API key authentication
// ============================================================

test "request without X-API-Key header returns 401" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/api/errors", "");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);

    // Verify response body contains the expected error detail
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid API key") != null);
}

test "request with wrong API key returns 401" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/api/errors", "X-API-Key: wrong-key-value\r\n");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid API key") != null);
}

test "request with correct API key passes through to handler" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const header = "X-API-Key: " ++ test_api_key ++ "\r\n";
    const resp = try sendRequest(srv.port(), "GET", "/api/errors", header);

    // With correct key, should get through auth to the route handler.
    // /api/errors is not implemented yet, so it returns 404 (not found).
    // The key point is it did NOT return 401.
    try std.testing.expect(resp.status_code != 401);
}

test "/health endpoint is excluded from auth — no API key needed" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    // No API key header at all
    const resp = try sendRequest(srv.port(), "GET", "/health", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"ok\"") != null);
}

test "/health endpoint works with wrong API key too" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/health", "X-API-Key: totally-wrong\r\n");
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"ok\"") != null);
}

test "auth 401 response has JSON content-type" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/api/errors", "");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    // Verify content-type header is application/json
    try std.testing.expect(std.mem.indexOf(u8, resp.raw, "application/json") != null);
}
