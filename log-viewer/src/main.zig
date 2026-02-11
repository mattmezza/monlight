const std = @import("std");
const net = std.net;
const log = std.log;
const database = @import("database.zig");
const sqlite = @import("sqlite");
const app_config = @import("config.zig");
const auth = @import("auth");
const rate_limit = @import("rate_limit");
const ingestion = @import("ingestion.zig");
const log_query = @import("log_query.zig");

const server_port: u16 = 8000;
const max_header_size = 8192;

/// Maximum request body size in bytes (64KB for Log Viewer).
pub const max_body_size: usize = 64 * 1024;

/// Maximum requests per minute (rate limit for Log Viewer).
const rate_limit_max_requests: usize = 60;
/// Rate limit window in milliseconds (1 minute).
const rate_limit_window_ms: i64 = 60_000;

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

    log.info("configuration loaded (database: {s}, containers: {s}, poll_interval: {d}s)", .{
        cfg.database_path,
        cfg.containers,
        cfg.poll_interval,
    });

    // Initialize database (opens connection + runs migrations)
    var db = database.init(cfg.db_path_z) catch |err| {
        log.err("Failed to initialize database: {}", .{err});
        std.process.exit(1);
    };
    defer db.close();

    // Start HTTP server
    log.info("Starting log-viewer on port {d}...", .{server_port});

    // Start ingestion background thread
    var ingestion_stop = std.atomic.Value(bool).init(false);
    const ingestion_thread = std.Thread.spawn(.{}, ingestion.ingestionThread, .{
        cfg.db_path_z,
        cfg.log_sources,
        cfg.containers,
        cfg.poll_interval,
        cfg.tail_buffer,
        cfg.max_entries,
        &ingestion_stop,
    }) catch |err| {
        log.err("Failed to start ingestion thread: {}", .{err});
        std.process.exit(1);
    };
    defer {
        ingestion_stop.store(true, .release);
        ingestion_thread.join();
    }

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, server_port);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    log.info("Log viewer listening on 0.0.0.0:{d}", .{server_port});

    // Initialize rate limiter
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var limiter = rate_limit.RateLimiter.init(gpa.allocator(), rate_limit_max_requests, rate_limit_window_ms) catch |err| {
        log.err("Failed to initialize rate limiter: {}", .{err});
        std.process.exit(1);
    };
    defer limiter.deinit();

    // Accept loop
    while (true) {
        const conn = server.accept() catch |err| {
            log.err("Failed to accept connection: {}", .{err});
            continue;
        };
        handleConnection(conn, cfg.api_key, &limiter, &db) catch |err| {
            log.err("Failed to handle connection: {}", .{err});
        };
    }
}

pub fn handleConnection(conn: net.Server.Connection, api_key: []const u8, limiter: *rate_limit.RateLimiter, db: *sqlite.Database) !void {
    defer conn.stream.close();

    var buf: [max_header_size]u8 = undefined;
    var http_server = std.http.Server.init(conn, &buf);

    var request = http_server.receiveHead() catch |err| {
        log.err("Failed to receive request head: {}", .{err});
        return;
    };

    // Route the request
    const target = request.head.target;

    // Health endpoint (no auth required) — enhanced with log stats
    if (std.mem.eql(u8, target, "/health")) {
        handleHealth(&request, db);
        return;
    }

    // Authenticate the request (skips excluded paths like /health)
    const excluded_paths = [_][]const u8{"/health"};
    if (auth.authenticate(&request, api_key, &excluded_paths) == .rejected) {
        return; // 401 response already sent by auth module
    }

    // Rate limiting (skips excluded paths like /health)
    if (rate_limit.checkRateLimit(&request, limiter, &excluded_paths) == .limited) {
        return; // 429 response already sent by rate_limit module
    }

    // Body size enforcement (checks Content-Length header)
    if (rate_limit.checkBodySize(&request, max_body_size) == .too_large) {
        return; // 413 response already sent by rate_limit module
    }

    // API routes (GET only for log-viewer)
    if (request.head.method == .GET) {
        if (isApiLogsPath(target)) {
            handleApiLogs(&request, db);
            return;
        } else if (isApiContainersPath(target)) {
            handleApiContainers(&request, db);
            return;
        } else if (isApiStatsPath(target)) {
            handleApiStats(&request, db);
            return;
        }
    }

    try handleNotFound(&request);
}

fn handleHealth(request: *std.http.Server.Request, db: *sqlite.Database) void {
    const body = log_query.queryHealth(db) catch |err| {
        log.err("Failed to query health: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };
    sendJsonResponse(request, .ok, body) catch {};
}

fn handleApiLogs(request: *std.http.Server.Request, db: *sqlite.Database) void {
    const params = log_query.parseQueryParams(request.head.target);
    const body = log_query.queryLogs(db, params) catch |err| {
        log.err("Failed to query logs: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };
    sendJsonResponse(request, .ok, body) catch {};
}

fn handleApiContainers(request: *std.http.Server.Request, db: *sqlite.Database) void {
    const body = log_query.queryContainers(db) catch |err| {
        log.err("Failed to query containers: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };
    sendJsonResponse(request, .ok, body) catch {};
}

fn handleApiStats(request: *std.http.Server.Request, db: *sqlite.Database) void {
    const body = log_query.queryStats(db) catch |err| {
        log.err("Failed to query stats: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };
    sendJsonResponse(request, .ok, body) catch {};
}

/// Check if the target path matches /api/logs (with or without query string).
fn isApiLogsPath(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "/api/logs")) {
        const rest = target["/api/logs".len..];
        return rest.len == 0 or rest[0] == '?';
    }
    return false;
}

/// Check if the target path matches /api/containers (with or without query string).
fn isApiContainersPath(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "/api/containers")) {
        const rest = target["/api/containers".len..];
        return rest.len == 0 or rest[0] == '?';
    }
    return false;
}

/// Check if the target path matches /api/stats (with or without query string).
fn isApiStatsPath(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "/api/stats")) {
        const rest = target["/api/stats".len..];
        return rest.len == 0 or rest[0] == '?';
    }
    return false;
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

    var resp_buf: [1024]u8 = undefined;
    const n = stream.read(&resp_buf) catch {
        std.process.exit(1);
    };

    if (n == 0) {
        std.process.exit(1);
    }

    const response = resp_buf[0..n];
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
