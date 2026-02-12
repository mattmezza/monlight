const std = @import("std");
const net = std.net;
const log = std.log;
const database = @import("database.zig");
const sqlite = @import("sqlite");
const app_config = @import("config.zig");
const auth = @import("auth");
const rate_limit = @import("rate_limit");
const dsn_auth = @import("dsn_auth.zig");
pub const cors = @import("cors.zig");
pub const browser_errors = @import("browser_errors.zig");
pub const browser_metrics = @import("browser_metrics.zig");
pub const dsn_keys = @import("dsn_keys.zig");
pub const source_maps = @import("source_maps.zig");
const retention = @import("retention.zig");

const server_port: u16 = 8000;
const max_header_size = 8192;

/// Maximum requests per minute per public key (rate limit for Browser Relay).
const rate_limit_max_requests: usize = 300;
/// Rate limit window in milliseconds (1 minute).
const rate_limit_window_ms: i64 = 60_000;

/// Retention cleanup interval: run once every 24 hours.
const retention_cleanup_interval_ns: u64 = 24 * 60 * 60 * std.time.ns_per_s;

pub fn main() !void {
    // Check for --healthcheck CLI flag
    var args = std.process.args();
    _ = args.skip(); // skip binary name
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--healthcheck")) {
            return healthcheck();
        }
    }

    // Load configuration from environment variables
    const cfg = app_config.load() catch {
        // load() already prints descriptive error messages
        std.process.exit(1);
    };

    log.info("configuration loaded (database: {s})", .{cfg.database_path});

    // Initialize database (opens connection + runs migrations)
    var db = database.init(cfg.dbPathZ()) catch |err| {
        log.err("Failed to initialize database: {}", .{err});
        std.process.exit(1);
    };
    defer db.close();

    log.info("Starting browser-relay on port {d}...", .{server_port});

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, server_port);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    log.info("Browser relay listening on 0.0.0.0:{d}", .{server_port});

    // Parse CORS origins from config
    const cors_config = cors.parseCorsOrigins(cfg.cors_origins);
    log.info("CORS: {d} allowed origins configured", .{cors_config.count});

    // Initialize rate limiter
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var limiter = rate_limit.RateLimiter.init(gpa.allocator(), rate_limit_max_requests, rate_limit_window_ms) catch |err| {
        log.err("Failed to initialize rate limiter: {}", .{err});
        std.process.exit(1);
    };
    defer limiter.deinit();

    // Start retention cleanup background thread
    var retention_stop = std.atomic.Value(bool).init(false);
    const retention_thread = std.Thread.spawn(.{}, retention.retentionThread, .{
        cfg.dbPathZ(),
        cfg.retention_days,
        retention_cleanup_interval_ns,
        &retention_stop,
    }) catch |err| {
        log.err("Failed to start retention cleanup thread: {}", .{err});
        std.process.exit(1);
    };
    defer {
        retention_stop.store(true, .release);
        retention_thread.join();
    }

    // Accept loop
    while (true) {
        const conn = server.accept() catch |err| {
            log.err("Failed to accept connection: {}", .{err});
            continue;
        };
        handleConnection(conn, cfg.admin_api_key, &limiter, &db, &cfg, &cors_config) catch |err| {
            log.err("Failed to handle connection: {}", .{err});
        };
    }
}

pub fn handleConnection(conn: net.Server.Connection, admin_api_key: []const u8, limiter: *rate_limit.RateLimiter, db: *sqlite.Database, cfg: *const app_config.Config, cors_config: *const cors.CorsConfig) !void {
    defer conn.stream.close();

    var buf: [max_header_size]u8 = undefined;
    var http_server = std.http.Server.init(conn, &buf);

    var request = http_server.receiveHead() catch |err| {
        log.err("Failed to receive request head: {}", .{err});
        return;
    };

    const target = request.head.target;

    // Health endpoint: no auth required
    if (std.mem.eql(u8, target, "/health")) {
        try handleHealth(&request);
        return;
    }

    // Rate limiting for all authenticated endpoints
    const rate_excluded = [_][]const u8{"/health"};
    if (rate_limit.checkRateLimit(&request, limiter, &rate_excluded) == .limited) {
        return; // 429 response already sent
    }

    // Body size enforcement for all endpoints
    if (rate_limit.checkBodySize(&request, @as(usize, 64 * 1024)) == .too_large) {
        return; // 413 response already sent
    }

    // Determine which auth mechanism to use based on the path
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |qmark|
        target[0..qmark]
    else
        target;

    if (isBrowserIngestionPath(path)) {
        // CORS handling for browser ingestion endpoints
        const cors_action = cors.handleCors(&request, cors_config);
        switch (cors_action) {
            .preflight_handled => return, // 204 already sent
            .allowed, .no_cors => {}, // continue processing
        }

        // Browser ingestion endpoints use DSN public key auth (X-Monlight-Key header)
        const dsn_result = dsn_auth.authenticateDsn(&request, db);
        if (!dsn_result.authenticated) {
            return; // 401 response already sent by dsn_auth
        }
        const dsn_project = dsn_result.project();

        // Get CORS origin for response headers
        const cors_hdrs = cors.getCorsHeaders(&request, cors_config);
        const cors_origin: ?[]const u8 = if (cors_hdrs) |hdrs| hdrs.origin else null;

        // Route to browser ingestion handlers
        if (std.mem.eql(u8, path, "/api/browser/errors")) {
            try browser_errors.handleBrowserErrorWithCors(
                &request,
                dsn_project,
                cfg.error_tracker_url,
                cfg.error_tracker_api_key,
                cors_origin,
                db,
            );
        } else if (std.mem.eql(u8, path, "/api/browser/metrics")) {
            try browser_metrics.handleBrowserMetricsWithCors(
                &request,
                dsn_project,
                cfg.metrics_collector_url,
                cfg.metrics_collector_api_key,
                cors_origin,
            );
        } else {
            if (cors_origin) |origin| {
                try sendJsonResponseWithCors(&request, .not_found, "{\"detail\": \"Not found\"}", origin);
            } else {
                try handleNotFound(&request);
            }
        }
    } else if (isAdminPath(path)) {
        // Admin/management endpoints use admin API key auth (X-API-Key header)
        const no_exclusions = [_][]const u8{};
        if (auth.authenticate(&request, admin_api_key, &no_exclusions) == .rejected) {
            return; // 401 response already sent by auth module
        }
        // Route to admin handlers
        if (std.mem.eql(u8, path, "/api/dsn-keys")) {
            if (request.head.method == .POST) {
                try dsn_keys.handleCreateDsnKey(&request, db);
            } else if (request.head.method == .GET) {
                try dsn_keys.handleListDsnKeys(&request, db);
            } else {
                try sendJsonResponse(&request, .method_not_allowed, "{\"detail\": \"Method not allowed\"}");
            }
        } else if (std.mem.startsWith(u8, path, "/api/dsn-keys/")) {
            try dsn_keys.handleDeleteDsnKey(&request, db, path);
        } else if (std.mem.eql(u8, path, "/api/source-maps")) {
            if (request.head.method == .POST) {
                try source_maps.handleUploadSourceMap(&request, db);
            } else if (request.head.method == .GET) {
                try source_maps.handleListSourceMaps(&request, db);
            } else {
                try sendJsonResponse(&request, .method_not_allowed, "{\"detail\": \"Method not allowed\"}");
            }
        } else if (std.mem.startsWith(u8, path, "/api/source-maps/")) {
            try source_maps.handleDeleteSourceMap(&request, db, path);
        } else {
            try handleNotFound(&request);
        }
    } else {
        // Unknown path
        try handleNotFound(&request);
    }
}

/// Check if the path is a browser ingestion endpoint.
/// These use DSN public key authentication.
fn isBrowserIngestionPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/browser/");
}

/// Check if the path is an admin/management endpoint.
/// These use admin API key authentication.
fn isAdminPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/source-maps") or
        std.mem.startsWith(u8, path, "/api/dsn-keys");
}

fn handleHealth(request: *std.http.Server.Request) !void {
    const body =
        \\{"status": "ok"}
    ;
    try sendJsonResponse(request, .ok, body);
}

fn handleNotFound(request: *std.http.Server.Request) !void {
    const body =
        \\{"detail": "Not found"}
    ;
    try sendJsonResponse(request, .not_found, body);
}

fn sendJsonResponse(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
) !void {
    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch |err| {
        log.err("Failed to send response: {}", .{err});
        return err;
    };
}

/// Send a JSON response with CORS Access-Control-Allow-Origin header.
pub fn sendJsonResponseWithCors(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    origin: []const u8,
) !void {
    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = origin },
        },
    }) catch |err| {
        log.err("Failed to send response: {}", .{err});
        return err;
    };
}

/// Perform a health check by connecting to the local server.
/// Exits with code 0 if healthy, 1 if not.
fn healthcheck() void {
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, server_port);
    const stream = net.tcpConnectToAddress(address) catch {
        std.process.exit(1);
    };
    defer stream.close();

    const request_bytes =
        "GET /health HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    stream.writeAll(request_bytes) catch {
        std.process.exit(1);
    };

    var response_buf: [1024]u8 = undefined;
    const n = stream.read(&response_buf) catch {
        std.process.exit(1);
    };

    if (n == 0) {
        std.process.exit(1);
    }

    const response = response_buf[0..n];
    // Check for "200 OK" in response
    if (std.mem.indexOf(u8, response, "200") != null) {
        std.process.exit(0);
    }

    std.process.exit(1);
}

test "health endpoint returns ok" {
    const body =
        \\{"status": "ok"}
    ;
    try std.testing.expectEqualStrings("{\"status\": \"ok\"}", body);
}

test "not found response" {
    const body =
        \\{"detail": "Not found"}
    ;
    try std.testing.expectEqualStrings("{\"detail\": \"Not found\"}", body);
}

test "isBrowserIngestionPath matches browser paths" {
    try std.testing.expect(isBrowserIngestionPath("/api/browser/errors"));
    try std.testing.expect(isBrowserIngestionPath("/api/browser/metrics"));
    try std.testing.expect(isBrowserIngestionPath("/api/browser/anything"));
    try std.testing.expect(!isBrowserIngestionPath("/api/errors"));
    try std.testing.expect(!isBrowserIngestionPath("/api/source-maps"));
    try std.testing.expect(!isBrowserIngestionPath("/api/dsn-keys"));
    try std.testing.expect(!isBrowserIngestionPath("/health"));
}

test "isAdminPath matches admin paths" {
    try std.testing.expect(isAdminPath("/api/source-maps"));
    try std.testing.expect(isAdminPath("/api/source-maps/1"));
    try std.testing.expect(isAdminPath("/api/dsn-keys"));
    try std.testing.expect(isAdminPath("/api/dsn-keys/1"));
    try std.testing.expect(!isAdminPath("/api/browser/errors"));
    try std.testing.expect(!isAdminPath("/api/errors"));
    try std.testing.expect(!isAdminPath("/health"));
}
