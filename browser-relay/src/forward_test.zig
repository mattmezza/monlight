const std = @import("std");
const net = std.net;
const main = @import("main.zig");
const rate_limit = @import("rate_limit");
const sqlite = @import("sqlite");
const database = @import("database.zig");
const app_config = @import("config.zig");
const cors = main.cors;

const test_admin_api_key = "test-admin-secret-key-1234567890";

const HttpResponse = struct {
    status_code: u16,
    total_read: usize,
    body_offset: usize,
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

    fn init() !TestServer {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        const server = try address.listen(.{ .reuse_address = true });
        const db = try database.init(":memory:");

        return .{
            .server = server,
            .db = db,
            .cfg = makeTestConfig(),
            .cors_config = cors.parseCorsOrigins(null),
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

    fn insertDsnKey(self: *TestServer, public_key: []const u8, project: []const u8) !void {
        const stmt = try self.db.prepare(
            "INSERT INTO dsn_keys (public_key, project, active) VALUES (?, ?, 1);",
        );
        defer stmt.deinit();
        try stmt.bindText(1, public_key);
        try stmt.bindText(2, project);
        _ = try stmt.exec();
    }

    fn waitAndDeinit(self: *TestServer) void {
        if (self.thread) |t| t.join();
        self.db.close();
        self.server.deinit();
    }
};

fn sendRequestWithBody(srv_port: u16, method: []const u8, path: []const u8, extra_headers: []const u8, json_body: []const u8) !HttpResponse {
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, srv_port);
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();

    var request_buf: [4096]u8 = undefined;
    const request_str = std.fmt.bufPrint(&request_buf, "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n{s}\r\n{s}", .{
        method,
        path,
        json_body.len,
        extra_headers,
        json_body,
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
    cfg.error_tracker_url = "http://127.0.0.1:19999";
    cfg.error_tracker_api_key = "test_et_key";
    cfg.metrics_collector_url = "http://127.0.0.1:19998";
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

const dsn_key = "test_forward_key_abcdef123456";

const valid_error_json =
    \\{"type":"TypeError","message":"Cannot read property 'x' of undefined","stack":"TypeError: Cannot read property 'x' of undefined\n    at Object.<anonymous> (http://example.com/app.js:10:5)","url":"http://example.com/page","timestamp":"2025-01-20T10:00:00Z"}
;

const valid_metrics_json =
    \\{"metrics":[{"name":"LCP","value":2500,"type":"histogram"}],"url":"http://example.com/page"}
;

// ============================================================
// Error Tracker upstream failure tests
// ============================================================

test "browser error returns 502 when error tracker is down" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.insertDsnKey(dsn_key, "testproject");
    try srv.start(1);

    const headers = "X-Monlight-Key: " ++ dsn_key ++ "\r\n";
    const resp = try sendRequestWithBody(srv.port(), "POST", "/api/browser/errors", headers, valid_error_json);

    try std.testing.expectEqual(@as(u16, 502), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body(), "Upstream error") != null);
}

test "browser error 502 response has JSON content-type" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.insertDsnKey(dsn_key, "testproject");
    try srv.start(1);

    const headers = "X-Monlight-Key: " ++ dsn_key ++ "\r\n";
    const resp = try sendRequestWithBody(srv.port(), "POST", "/api/browser/errors", headers, valid_error_json);

    try std.testing.expectEqual(@as(u16, 502), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.raw(), "application/json") != null);
}

// ============================================================
// Metrics Collector upstream failure tests
// ============================================================

test "browser metrics returns 502 when metrics collector is down" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.insertDsnKey(dsn_key, "testproject");
    try srv.start(1);

    const headers = "X-Monlight-Key: " ++ dsn_key ++ "\r\n";
    const resp = try sendRequestWithBody(srv.port(), "POST", "/api/browser/metrics", headers, valid_metrics_json);

    try std.testing.expectEqual(@as(u16, 502), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body(), "Upstream error") != null);
}

test "browser metrics 502 response has JSON content-type" {
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.insertDsnKey(dsn_key, "testproject");
    try srv.start(1);

    const headers = "X-Monlight-Key: " ++ dsn_key ++ "\r\n";
    const resp = try sendRequestWithBody(srv.port(), "POST", "/api/browser/metrics", headers, valid_metrics_json);

    try std.testing.expectEqual(@as(u16, 502), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.raw(), "application/json") != null);
}

// ============================================================
// Graceful degradation tests
// ============================================================

test "relay handles both upstreams being down without crashing" {
    // Mix error and metrics requests — all should get 502 without crashing.
    var srv = try TestServer.init();
    defer srv.waitAndDeinit();
    try srv.insertDsnKey(dsn_key, "testproject");
    try srv.start(4);

    const headers = "X-Monlight-Key: " ++ dsn_key ++ "\r\n";

    const resp1 = try sendRequestWithBody(srv.port(), "POST", "/api/browser/errors", headers, valid_error_json);
    try std.testing.expectEqual(@as(u16, 502), resp1.status_code);

    const resp2 = try sendRequestWithBody(srv.port(), "POST", "/api/browser/metrics", headers, valid_metrics_json);
    try std.testing.expectEqual(@as(u16, 502), resp2.status_code);

    const resp3 = try sendRequestWithBody(srv.port(), "POST", "/api/browser/errors", headers, valid_error_json);
    try std.testing.expectEqual(@as(u16, 502), resp3.status_code);

    const resp4 = try sendRequestWithBody(srv.port(), "POST", "/api/browser/metrics", headers, valid_metrics_json);
    try std.testing.expectEqual(@as(u16, 502), resp4.status_code);
}
