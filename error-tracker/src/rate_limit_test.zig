const std = @import("std");
const net = std.net;
const main = @import("main.zig");
const rate_limit = @import("rate_limit");
const sqlite = @import("sqlite");
const database = @import("database.zig");
const app_config = @import("config.zig");

const test_api_key = "test-secret-key-12345678901234";

/// Parsed HTTP response from a raw TCP exchange.
const HttpResponse = struct {
    status_code: u16,
    body: []const u8,
    raw: []const u8,
};

/// Create a minimal Config for testing purposes.
fn makeTestConfig() app_config.Config {
    var cfg: app_config.Config = undefined;
    cfg.database_path = ":memory:";
    cfg.api_key = test_api_key;
    cfg.postmark_api_token = null;
    cfg.postmark_from_email = "test@example.com";
    cfg.alert_emails = null;
    cfg.retention_days = 90;
    cfg.base_url = "http://localhost:8000";
    const path = ":memory:";
    @memcpy(cfg._db_path_buf[0..path.len], path);
    cfg._db_path_buf[path.len] = 0;
    return cfg;
}

/// A test server that handles a fixed number of requests then stops.
/// Uses a tight rate limit for testing purposes.
const TestServer = struct {
    server: net.Server,
    thread: ?std.Thread = null,
    limiter: rate_limit.RateLimiter,
    db: sqlite.Database,
    cfg: app_config.Config,

    fn init(max_requests: usize) !TestServer {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        const server = try address.listen(.{
            .reuse_address = true,
        });
        const limiter = try rate_limit.RateLimiter.init(std.testing.allocator, max_requests, 60_000);
        const db = try database.init(":memory:");
        return .{
            .server = server,
            .limiter = limiter,
            .db = db,
            .cfg = makeTestConfig(),
        };
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
        var handled: usize = 0;
        while (handled < count) {
            const conn = self.server.accept() catch continue;
            main.handleConnection(conn, test_api_key, &self.limiter, &self.db, &self.cfg) catch {};
            handled += 1;
        }
    }

    fn waitAndDeinit(self: *TestServer) void {
        if (self.thread) |t| {
            t.join();
        }
        self.limiter.deinit();
        self.db.close();
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
// Integration tests for rate limiting
// ============================================================

test "requests within rate limit return normal responses" {
    // Allow 3 requests/minute
    var srv = try TestServer.init(3);
    defer srv.waitAndDeinit();
    try srv.start(3);

    const auth_header = "X-API-Key: " ++ test_api_key ++ "\r\n";

    // All 3 requests should succeed (get 404 since /api/test doesn't exist, but NOT 429)
    const resp1 = try sendRequest(srv.port(), "GET", "/api/test", auth_header);
    try std.testing.expectEqual(@as(u16, 404), resp1.status_code);

    const resp2 = try sendRequest(srv.port(), "GET", "/api/test", auth_header);
    try std.testing.expectEqual(@as(u16, 404), resp2.status_code);

    const resp3 = try sendRequest(srv.port(), "GET", "/api/test", auth_header);
    try std.testing.expectEqual(@as(u16, 404), resp3.status_code);
}

test "request exceeding rate limit returns 429" {
    // Allow only 2 requests/minute
    var srv = try TestServer.init(2);
    defer srv.waitAndDeinit();
    try srv.start(3);

    const auth_header = "X-API-Key: " ++ test_api_key ++ "\r\n";

    // First 2 requests succeed
    const resp1 = try sendRequest(srv.port(), "GET", "/api/test", auth_header);
    try std.testing.expect(resp1.status_code != 429);

    const resp2 = try sendRequest(srv.port(), "GET", "/api/test", auth_header);
    try std.testing.expect(resp2.status_code != 429);

    // 3rd request should be rate limited
    const resp3 = try sendRequest(srv.port(), "GET", "/api/test", auth_header);
    try std.testing.expectEqual(@as(u16, 429), resp3.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp3.body, "Rate limit exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp3.body, "retry_after") != null);
}

test "rate limit 429 response has JSON content-type" {
    var srv = try TestServer.init(1);
    defer srv.waitAndDeinit();
    try srv.start(2);

    const auth_header = "X-API-Key: " ++ test_api_key ++ "\r\n";

    // Use up the limit
    _ = try sendRequest(srv.port(), "GET", "/api/test", auth_header);

    // Next request should be rate limited
    const resp = try sendRequest(srv.port(), "GET", "/api/test", auth_header);
    try std.testing.expectEqual(@as(u16, 429), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.raw, "application/json") != null);
}

test "/health endpoint is not rate limited" {
    // Allow only 1 request/minute
    var srv = try TestServer.init(1);
    defer srv.waitAndDeinit();
    try srv.start(3);

    // First request uses up the rate limit on a normal endpoint
    const auth_header = "X-API-Key: " ++ test_api_key ++ "\r\n";
    const resp1 = try sendRequest(srv.port(), "GET", "/api/test", auth_header);
    try std.testing.expect(resp1.status_code != 429);

    // /health should still work (no auth needed, not rate limited)
    const resp2 = try sendRequest(srv.port(), "GET", "/health", "");
    try std.testing.expectEqual(@as(u16, 200), resp2.status_code);

    // Another /health should also work
    const resp3 = try sendRequest(srv.port(), "GET", "/health", "");
    try std.testing.expectEqual(@as(u16, 200), resp3.status_code);
}

// ============================================================
// Integration tests for body size enforcement
// ============================================================

test "request with Content-Length within limit is accepted" {
    var srv = try TestServer.init(100);
    defer srv.waitAndDeinit();
    try srv.start(1);

    // Content-Length: 50 (well under 256KB limit)
    // Use /api/test (not /api/errors) to avoid the handler trying to read body data
    const headers = "X-API-Key: " ++ test_api_key ++ "\r\nContent-Length: 50\r\n";
    const resp = try sendRequest(srv.port(), "POST", "/api/test", headers);

    // Should NOT get 413 (gets 404 since /api/test doesn't exist)
    try std.testing.expect(resp.status_code != 413);
}

test "request with Content-Length exceeding limit returns 413" {
    var srv = try TestServer.init(100);
    defer srv.waitAndDeinit();
    try srv.start(1);

    // Content-Length: 300000 (exceeds 256KB = 262144 bytes)
    const headers = "X-API-Key: " ++ test_api_key ++ "\r\nContent-Length: 300000\r\n";
    const resp = try sendRequest(srv.port(), "POST", "/api/errors", headers);

    try std.testing.expectEqual(@as(u16, 413), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Request body exceeds maximum size") != null);
}

test "body size 413 response has JSON content-type" {
    var srv = try TestServer.init(100);
    defer srv.waitAndDeinit();
    try srv.start(1);

    // Content-Length way over limit
    const headers = "X-API-Key: " ++ test_api_key ++ "\r\nContent-Length: 999999\r\n";
    const resp = try sendRequest(srv.port(), "POST", "/api/errors", headers);

    try std.testing.expectEqual(@as(u16, 413), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.raw, "application/json") != null);
}

test "request with Content-Length exactly at limit is accepted" {
    var srv = try TestServer.init(100);
    defer srv.waitAndDeinit();
    try srv.start(1);

    // Content-Length: 262144 (exactly 256KB — should be accepted)
    // Use /api/test (not /api/errors) to avoid the handler trying to read body data
    const headers = "X-API-Key: " ++ test_api_key ++ "\r\nContent-Length: 262144\r\n";
    const resp = try sendRequest(srv.port(), "POST", "/api/test", headers);

    // Should NOT get 413
    try std.testing.expect(resp.status_code != 413);
}

test "request without Content-Length header is accepted" {
    var srv = try TestServer.init(100);
    defer srv.waitAndDeinit();
    try srv.start(1);

    // No Content-Length header at all (GET request)
    const headers = "X-API-Key: " ++ test_api_key ++ "\r\n";
    const resp = try sendRequest(srv.port(), "GET", "/api/errors", headers);

    // Should NOT get 413
    try std.testing.expect(resp.status_code != 413);
}
