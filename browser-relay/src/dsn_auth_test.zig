const std = @import("std");
const net = std.net;
const main = @import("main.zig");
const rate_limit = @import("rate_limit");
const sqlite = @import("sqlite");
const database = @import("database.zig");
const app_config = @import("config.zig");

const test_admin_api_key = "test-admin-secret-key-1234567890";

const HttpResponse = struct {
    status_code: u16,
    body: []const u8,
    raw: []const u8,
};

const TestServer = struct {
    server: net.Server,
    thread: ?std.Thread = null,
    db: sqlite.Database,
    cfg: app_config.Config,

    fn init() !TestServer {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        const server = try address.listen(.{ .reuse_address = true });
        const db = try database.init(":memory:");

        return .{
            .server = server,
            .db = db,
            .cfg = makeTestConfig(),
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
            main.handleConnection(conn, test_admin_api_key, &limiter, &self.db, &self.cfg) catch {};
            handled += 1;
        }
    }

    /// Insert a DSN key into the database for testing.
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

    var response_buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < response_buf.len) {
        const n = stream.read(response_buf[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }

    if (total_read == 0) return error.EmptyResponse;

    const response = response_buf[0..total_read];

    // Parse status code (e.g., "HTTP/1.1 200 OK")
    var status_code: u16 = 0;
    if (std.mem.indexOf(u8, response, "HTTP/1.1 ")) |start| {
        const code_start = start + 9;
        if (code_start + 3 <= response.len) {
            status_code = std.fmt.parseInt(u16, response[code_start .. code_start + 3], 10) catch 0;
        }
    }

    // Find body (after \r\n\r\n)
    const body = if (std.mem.indexOf(u8, response, "\r\n\r\n")) |sep|
        response[sep + 4 ..]
    else
        response[0..0];

    return HttpResponse{
        .status_code = status_code,
        .body = body,
        .raw = response,
    };
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
    cfg.db_path_z = cfg._db_path_buf[0..path.len :0];
    return cfg;
}

// ============================================================
// Health endpoint tests
// ============================================================

test "health endpoint is accessible without any auth" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/health", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"ok\"") != null);
}

// ============================================================
// Browser ingestion endpoint DSN auth tests
// ============================================================

test "browser endpoint without X-Monlight-Key returns 401" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", "");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid DSN key") != null);
}

test "browser endpoint with invalid X-Monlight-Key returns 401" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", "X-Monlight-Key: invalid_key_12345\r\n");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid DSN key") != null);
}

test "browser endpoint with deactivated DSN key returns 401" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.insertDsnKey("deactivated_key_abcdef", "testproject", false);
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", "X-Monlight-Key: deactivated_key_abcdef\r\n");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid DSN key") != null);
}

test "browser endpoint with valid DSN key passes auth" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.insertDsnKey("valid_browser_key_123456", "flowrent", true);
    try srv.start(1);

    // With a valid DSN key, the request should pass auth. Since the actual
    // browser ingestion handlers are not yet implemented, it returns 404.
    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", "X-Monlight-Key: valid_browser_key_123456\r\n");
    try std.testing.expect(resp.status_code != 401);
}

test "browser metrics endpoint with valid DSN key passes auth" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.insertDsnKey("metrics_key_789abc", "flowrent", true);
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "POST", "/api/browser/metrics", "X-Monlight-Key: metrics_key_789abc\r\n");
    try std.testing.expect(resp.status_code != 401);
}

// ============================================================
// Admin endpoint auth tests
// ============================================================

test "admin endpoint without X-API-Key returns 401" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/api/dsn-keys", "");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid API key") != null);
}

test "admin endpoint with wrong X-API-Key returns 401" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/api/dsn-keys", "X-API-Key: wrong_key_xyz\r\n");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid API key") != null);
}

test "admin endpoint with correct X-API-Key passes auth" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const header = std.fmt.comptimePrint("X-API-Key: {s}\r\n", .{test_admin_api_key});
    const resp = try sendRequest(srv.port(), "GET", "/api/dsn-keys", header);
    // With correct admin key, request passes auth. Returns 404 since handlers aren't implemented yet.
    try std.testing.expect(resp.status_code != 401);
}

test "source-maps admin endpoint requires admin API key" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/api/source-maps", "");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
}

test "source-maps admin endpoint with correct key passes auth" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const header = std.fmt.comptimePrint("X-API-Key: {s}\r\n", .{test_admin_api_key});
    const resp = try sendRequest(srv.port(), "GET", "/api/source-maps", header);
    try std.testing.expect(resp.status_code != 401);
}

// ============================================================
// Auth mechanism separation tests
// ============================================================

test "browser endpoint rejects admin API key (wrong auth mechanism)" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    // Using X-API-Key (admin key) on a browser endpoint should fail
    // because browser endpoints expect X-Monlight-Key
    const header = std.fmt.comptimePrint("X-API-Key: {s}\r\n", .{test_admin_api_key});
    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", header);
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid DSN key") != null);
}

test "admin endpoint rejects DSN key (wrong auth mechanism)" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.insertDsnKey("dsn_key_for_admin_test", "testproj", true);
    try srv.start(1);

    // Using X-Monlight-Key (DSN key) on an admin endpoint should fail
    // because admin endpoints expect X-API-Key
    const resp = try sendRequest(srv.port(), "GET", "/api/dsn-keys", "X-Monlight-Key: dsn_key_for_admin_test\r\n");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Invalid API key") != null);
}

test "DSN auth 401 response has JSON content-type" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "POST", "/api/browser/errors", "");
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.raw, "application/json") != null);
}

test "unknown path returns 404" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.start(1);

    const resp = try sendRequest(srv.port(), "GET", "/unknown/path", "");
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
}
