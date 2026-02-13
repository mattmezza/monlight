const std = @import("std");
const net = std.net;
const main = @import("main.zig");
const rate_limit = @import("rate_limit");
const sqlite = @import("sqlite");
const database = @import("database.zig");
const app_config = @import("config.zig");
const cors = main.cors;

const test_admin_api_key = "test-admin-secret-key-1234567890";
const test_allowed_origin = "https://example.com";
const test_allowed_origin_2 = "https://other.com";

const HttpResponse = struct {
    status_code: u16,
    total_read: usize,
    body_offset: usize,
    // Owns the response data so slices remain valid.
    _buf: [4096]u8,

    fn raw(self: *const HttpResponse) []const u8 {
        return self._buf[0..self.total_read];
    }

    fn body(self: *const HttpResponse) []const u8 {
        return self._buf[self.body_offset..self.total_read];
    }
};

const TestServer = struct {
    server: net.Server,
    thread: ?std.Thread = null,
    db: sqlite.Database,
    cfg: app_config.Config,
    cors_config: cors.CorsConfig,

    fn init(cors_origins: ?[]const u8) !TestServer {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        const server = try address.listen(.{ .reuse_address = true });
        const db = try database.init(":memory:");

        return .{
            .server = server,
            .db = db,
            .cfg = makeTestConfig(),
            .cors_config = cors.parseCorsOrigins(cors_origins),
        };
    }

    fn port(self: *const TestServer) u16 {
        return self.server.listen_address.getPort();
    }

    fn start(self: *TestServer, n: usize) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{ self, n });
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    fn acceptLoop(self: *TestServer, count: usize) void {
        var limiter = rate_limit.RateLimiter.init(std.testing.allocator, 1000, 60_000) catch return;
        defer limiter.deinit();
        var handled: usize = 0;
        while (handled < count) {
            const conn = self.server.accept() catch continue;
            main.handleConnection(conn, test_admin_api_key, &limiter, &self.db, &self.cfg, &self.cors_config) catch {};
            handled += 1;
        }
    }

    fn insertDsnKey(self: *TestServer, public_key: []const u8, project: []const u8, active: bool) !void {
        const stmt = try self.db.prepare(
            "INSERT INTO dsn_keys (public_key, project, active) VALUES (?, ?, ?);",
        );
        defer stmt.deinit();
        try stmt.bindText(1, public_key);
        try stmt.bindText(2, project);
        try stmt.bindInt(3, if (active) 1 else 0);
        _ = try stmt.exec();
    }

    fn waitAndDeinit(self: *TestServer) void {
        if (self.thread) |t| t.join();
        self.db.close();
        self.server.deinit();
    }
};

fn sendRequest(srv_port: u16, method: []const u8, path: []const u8, headers: []const u8) !HttpResponse {
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, srv_port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    var request_buf: [2048]u8 = undefined;
    const request_str = std.fmt.bufPrint(&request_buf, "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n{s}\r\n", .{
        method,
        path,
        headers,
    }) catch return error.BufferTooSmall;

    try stream.writeAll(request_str);

    var result = HttpResponse{
        .status_code = 0,
        .total_read = 0,
        .body_offset = 0,
        ._buf = undefined,
    };
    while (result.total_read < result._buf.len) {
        const n = stream.read(result._buf[result.total_read..]) catch break;
        if (n == 0) break;
        result.total_read += n;
    }

    if (result.total_read == 0) return error.EmptyResponse;

    const response = result._buf[0..result.total_read];

    if (std.mem.indexOf(u8, response, "HTTP/1.1 ")) |start_idx| {
        const code_start = start_idx + 9;
        if (code_start + 3 <= response.len) {
            result.status_code = std.fmt.parseInt(u16, response[code_start .. code_start + 3], 10) catch 0;
        }
    }

    result.body_offset = if (std.mem.indexOf(u8, response, "\r\n\r\n")) |sep|
        sep + 4
    else
        result.total_read;

    return result;
}

fn makeTestConfig() app_config.Config {
    var cfg: app_config.Config = undefined;
    cfg.database_path = ":memory:";
    cfg.admin_api_key = test_admin_api_key;
    cfg.error_tracker_url = "http://localhost:5010";
    cfg.error_tracker_api_key = "test_et_key";
    cfg.metrics_collector_url = "http://localhost:5012";
    cfg.metrics_collector_api_key = "test_mc_key";
    cfg.cors_origins = null;
    cfg.max_body_size = 64 * 1024;
    cfg.rate_limit = 300;
    cfg.retention_days = 90;
    const path = ":memory:";
    @memcpy(cfg._db_path_buf[0..path.len], path);
    cfg._db_path_buf[path.len] = 0;
    return cfg;
}

/// Check if raw response contains a specific header (case-insensitive name, exact value).
fn hasHeader(raw: []const u8, name: []const u8, value: []const u8) bool {
    const headers_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return false;
    const headers_section = raw[0..headers_end];

    var iter = std.mem.splitSequence(u8, headers_section, "\r\n");
    _ = iter.next(); // Skip status line
    while (iter.next()) |line| {
        // Find ": " separator to correctly split header name from value
        const sep = std.mem.indexOf(u8, line, ": ") orelse continue;
        const header_name = line[0..sep];
        const header_value = line[sep + 2 ..];

        // Compare name case-insensitively
        if (header_name.len == name.len) {
            var name_match = true;
            for (header_name, name) |a, b| {
                if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                    name_match = false;
                    break;
                }
            }
            if (name_match and std.mem.eql(u8, header_value, value)) {
                return true;
            }
        }
    }
    return false;
}

/// Check if raw response contains a header name (regardless of value).
fn hasHeaderName(raw: []const u8, name: []const u8) bool {
    const headers_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return false;
    const headers_section = raw[0..headers_end];

    var iter = std.mem.splitSequence(u8, headers_section, "\r\n");
    _ = iter.next(); // Skip status line
    while (iter.next()) |line| {
        const sep = std.mem.indexOf(u8, line, ": ") orelse continue;
        const header_name = line[0..sep];

        if (header_name.len == name.len) {
            var match = true;
            for (header_name, name) |a, b| {
                if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
    }
    return false;
}

// ============================================================
// Preflight OPTIONS tests
// ============================================================

test "OPTIONS preflight with allowed origin returns 204 with CORS headers" {
    const origins = test_allowed_origin ++ "," ++ test_allowed_origin_2;
    var srv = try TestServer.init(origins);
    defer srv.waitAndDeinit();
    try srv.insertDsnKey("cors_test_key_1", "flowrent", true);
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "OPTIONS", "/api/browser/errors", "Origin: " ++ test_allowed_origin ++ "\r\n");
    try std.testing.expectEqual(@as(u16, 204), resp.status_code);
    try std.testing.expect(hasHeader(resp.raw(), "access-control-allow-origin", test_allowed_origin));
    try std.testing.expect(hasHeader(resp.raw(), "access-control-allow-methods", "POST, OPTIONS"));
    try std.testing.expect(hasHeader(resp.raw(), "access-control-allow-headers", "X-Monlight-Key, Content-Type"));
    try std.testing.expect(hasHeader(resp.raw(), "access-control-max-age", "86400"));
}

test "OPTIONS preflight with second allowed origin returns matching origin" {
    const origins = test_allowed_origin ++ "," ++ test_allowed_origin_2;
    var srv = try TestServer.init(origins);
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "OPTIONS", "/api/browser/errors", "Origin: " ++ test_allowed_origin_2 ++ "\r\n");
    try std.testing.expectEqual(@as(u16, 204), resp.status_code);
    try std.testing.expect(hasHeader(resp.raw(), "access-control-allow-origin", test_allowed_origin_2));
}

test "OPTIONS preflight with disallowed origin does not return CORS headers" {
    var srv = try TestServer.init(test_allowed_origin);
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "OPTIONS", "/api/browser/errors", "Origin: https://evil.com\r\n");
    // Should not have CORS headers at all
    try std.testing.expect(!hasHeaderName(resp.raw(), "access-control-allow-origin"));
}

test "OPTIONS preflight without Origin header does not return CORS headers" {
    var srv = try TestServer.init(test_allowed_origin);
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "OPTIONS", "/api/browser/errors", "");
    try std.testing.expect(!hasHeaderName(resp.raw(), "access-control-allow-origin"));
}

// ============================================================
// Normal request CORS header tests
// ============================================================

test "POST with allowed origin includes Access-Control-Allow-Origin in response" {
    var srv = try TestServer.init(test_allowed_origin);
    defer srv.waitAndDeinit();
    try srv.insertDsnKey("cors_test_key_2", "flowrent", true);
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", "Origin: " ++ test_allowed_origin ++ "\r\nX-Monlight-Key: cors_test_key_2\r\n");
    // Should have CORS header in response
    try std.testing.expect(hasHeader(resp.raw(), "access-control-allow-origin", test_allowed_origin));
}

test "POST with disallowed origin does not include CORS headers" {
    var srv = try TestServer.init(test_allowed_origin);
    defer srv.waitAndDeinit();
    try srv.insertDsnKey("cors_test_key_3", "flowrent", true);
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", "Origin: https://evil.com\r\nX-Monlight-Key: cors_test_key_3\r\n");
    try std.testing.expect(!hasHeaderName(resp.raw(), "access-control-allow-origin"));
}

test "POST without Origin header does not include CORS headers" {
    var srv = try TestServer.init(test_allowed_origin);
    defer srv.waitAndDeinit();
    try srv.insertDsnKey("cors_test_key_4", "flowrent", true);
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", "X-Monlight-Key: cors_test_key_4\r\n");
    try std.testing.expect(!hasHeaderName(resp.raw(), "access-control-allow-origin"));
}

// ============================================================
// No CORS configured tests
// ============================================================

test "no CORS origins configured - no CORS headers on any request" {
    var srv = try TestServer.init(null);
    defer srv.waitAndDeinit();
    try srv.insertDsnKey("cors_test_key_5", "flowrent", true);
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", "Origin: https://example.com\r\nX-Monlight-Key: cors_test_key_5\r\n");
    try std.testing.expect(!hasHeaderName(resp.raw(), "access-control-allow-origin"));
}

// ============================================================
// CORS only applies to browser ingestion paths
// ============================================================

test "admin endpoint does not get CORS headers even with Origin" {
    var srv = try TestServer.init(test_allowed_origin);
    defer srv.waitAndDeinit();
    try srv.start(1);

    const header = std.fmt.comptimePrint("X-API-Key: {s}\r\nOrigin: {s}\r\n", .{ test_admin_api_key, test_allowed_origin });
    const resp = try sendRequest(srv.port(), "GET", "/api/dsn-keys", header);
    // Admin endpoints don't go through CORS handling
    try std.testing.expect(!hasHeaderName(resp.raw(), "access-control-allow-origin"));
}

test "health endpoint does not get CORS headers" {
    var srv = try TestServer.init(test_allowed_origin);
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/health", "Origin: " ++ test_allowed_origin ++ "\r\n");
    try std.testing.expect(!hasHeaderName(resp.raw(), "access-control-allow-origin"));
}
