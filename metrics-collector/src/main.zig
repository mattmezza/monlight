const std = @import("std");
const net = std.net;
const log = std.log;
const database = @import("database.zig");
const sqlite = @import("sqlite");
const app_config = @import("config.zig");
const auth = @import("auth");
const rate_limit = @import("rate_limit");
const ingestion = @import("ingestion.zig");
const aggregation = @import("aggregation.zig");
const metrics_query = @import("metrics_query.zig");
const web_ui = @import("web_ui.zig");

const server_port: u16 = 8000;
const max_header_size = 8192;

/// Maximum request body size in bytes (512KB for Metrics Collector).
pub const max_body_size: usize = 512 * 1024;

/// Maximum requests per minute (rate limit for Metrics Collector).
const rate_limit_max_requests: usize = 200;
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

    log.info("configuration loaded (database: {s})", .{cfg.database_path});

    // Initialize database (opens connection + runs migrations)
    var db = database.init(cfg.db_path_z) catch |err| {
        log.err("Failed to initialize database: {}", .{err});
        std.process.exit(1);
    };
    defer db.close();

    // Start HTTP server
    log.info("Starting metrics-collector on port {d}...", .{server_port});

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, server_port);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    log.info("Metrics collector listening on 0.0.0.0:{d}", .{server_port});

    // Start aggregation background thread
    var aggregation_stop = std.atomic.Value(bool).init(false);
    const agg_thread = std.Thread.spawn(.{}, aggregation.aggregationThread, .{
        cfg.db_path_z,
        cfg.aggregation_interval,
        cfg.retention_raw,
        cfg.retention_minute,
        cfg.retention_hourly,
        &aggregation_stop,
    }) catch |err| {
        log.err("Failed to start aggregation thread: {}", .{err});
        std.process.exit(1);
    };
    defer {
        aggregation_stop.store(true, .release);
        agg_thread.join();
    }

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

    // Health endpoint (no auth required)
    if (std.mem.eql(u8, target, "/health")) {
        handleHealth(&request, db);
        return;
    }

    // Web UI (no auth required)
    if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/index.html")) {
        web_ui.serveIndex(&request);
        return;
    }

    // Authenticate the request (skips excluded paths like /health)
    const excluded_paths = [_][]const u8{"/health"};
    if (auth.authenticate(&request, api_key, &excluded_paths) == .rejected) {
        return; // 401 response already sent by auth module
    }

    // Rate limiting
    if (rate_limit.checkRateLimit(&request, limiter, &excluded_paths) == .limited) {
        return; // 429 response already sent by rate_limit module
    }

    // Body size enforcement (checks Content-Length header)
    if (rate_limit.checkBodySize(&request, max_body_size) == .too_large) {
        return; // 413 response already sent by rate_limit module
    }

    // API routes
    if (request.head.method == .GET) {
        if (isApiMetricsNamesPath(target)) {
            handleApiMetricsNames(&request, db);
            return;
        } else if (isApiMetricsPath(target)) {
            handleApiMetrics(&request, db);
            return;
        } else if (isApiDashboardPath(target)) {
            handleApiDashboard(&request, db);
            return;
        }
    } else if (request.head.method == .POST) {
        if (isApiMetricsPath(target)) {
            handleApiMetricsIngest(&request, db);
            return;
        }
    }

    try handleNotFound(&request);
}

fn handleHealth(request: *std.http.Server.Request, db: *sqlite.Database) void {
    var response = std.ArrayList(u8).init(std.heap.page_allocator);
    defer response.deinit();
    var writer = response.writer();

    writer.writeAll("{\"status\": \"ok\"") catch {
        sendJsonResponse(request, .ok, "{\"status\": \"ok\"}") catch {};
        return;
    };

    // Metrics received in last 24h
    {
        const stmt = db.prepare(
            "SELECT COUNT(*) FROM metrics_raw WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-24 hours');",
        ) catch {
            writer.writeAll("}") catch {};
            sendJsonResponse(request, .ok, response.items) catch {};
            return;
        };
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            var int_buf: [32]u8 = undefined;
            writer.writeAll(", \"metrics_received_24h\": ") catch {};
            const count_str = std.fmt.bufPrint(&int_buf, "{d}", .{row.int(0)}) catch "0";
            writer.writeAll(count_str) catch {};
        }
    }

    // Last aggregation timestamp
    {
        const stmt = db.prepare(
            "SELECT MAX(bucket) FROM metrics_aggregated;",
        ) catch {
            writer.writeAll("}") catch {};
            sendJsonResponse(request, .ok, response.items) catch {};
            return;
        };
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            const ts = row.text(0);
            if (ts) |t| {
                writer.writeAll(", \"last_aggregation\": \"") catch {};
                writer.writeAll(t) catch {};
                writer.writeAll("\"") catch {};
            } else {
                writer.writeAll(", \"last_aggregation\": null") catch {};
            }
        }
    }

    writer.writeAll("}") catch {};
    sendJsonResponse(request, .ok, response.items) catch {};
}

fn handleApiMetrics(request: *std.http.Server.Request, db: *sqlite.Database) void {
    const params = metrics_query.parseQueryParams(request.head.target);

    if (params.name == null) {
        sendJsonResponse(request, .bad_request, "{\"detail\": \"Missing required parameter: name\"}") catch {};
        return;
    }

    var response = std.ArrayList(u8).init(std.heap.page_allocator);
    defer response.deinit();
    var writer = response.writer();

    _ = metrics_query.queryMetrics(db, &params, &writer) catch |err| {
        log.err("Failed to query metrics: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Failed to query metrics\"}") catch {};
        return;
    };

    sendJsonResponse(request, .ok, response.items) catch {};
}

fn handleApiMetricsNames(request: *std.http.Server.Request, db: *sqlite.Database) void {
    var response = std.ArrayList(u8).init(std.heap.page_allocator);
    defer response.deinit();
    var writer = response.writer();

    _ = metrics_query.queryMetricNames(db, &writer) catch |err| {
        log.err("Failed to query metric names: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Failed to query metric names\"}") catch {};
        return;
    };

    sendJsonResponse(request, .ok, response.items) catch {};
}

fn handleApiDashboard(request: *std.http.Server.Request, db: *sqlite.Database) void {
    // Parse period from query params (default: 24h)
    const target = request.head.target;
    const period = parseDashboardPeriod(target);
    const offset = periodToOffset(period);

    var response = std.ArrayList(u8).init(std.heap.page_allocator);
    defer response.deinit();
    var writer = response.writer();

    buildDashboardJson(db, &writer, offset, period) catch |err| {
        log.err("Failed to build dashboard data: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Failed to build dashboard\"}") catch {};
        return;
    };

    sendJsonResponse(request, .ok, response.items) catch {};
}

fn parseDashboardPeriod(target: []const u8) []const u8 {
    const query_start = std.mem.indexOf(u8, target, "?") orelse return "24h";
    const query_string = target[query_start + 1 ..];
    var pairs_iter = std.mem.splitScalar(u8, query_string, '&');
    while (pairs_iter.next()) |pair| {
        const eq_pos = std.mem.indexOf(u8, pair, "=") orelse continue;
        const key = pair[0..eq_pos];
        const value = pair[eq_pos + 1 ..];
        if (std.mem.eql(u8, key, "period")) {
            if (std.mem.eql(u8, value, "1h") or std.mem.eql(u8, value, "24h") or
                std.mem.eql(u8, value, "7d") or std.mem.eql(u8, value, "30d"))
            {
                return value;
            }
        }
    }
    return "24h";
}

fn periodToOffset(period: []const u8) []const u8 {
    if (std.mem.eql(u8, period, "1h")) return "-1 hours";
    if (std.mem.eql(u8, period, "24h")) return "-24 hours";
    if (std.mem.eql(u8, period, "7d")) return "-7 days";
    if (std.mem.eql(u8, period, "30d")) return "-30 days";
    return "-24 hours";
}

fn buildDashboardJson(
    db: *sqlite.Database,
    writer: *std.ArrayList(u8).Writer,
    offset: []const u8,
    period: []const u8,
) !void {
    try writer.writeAll("{\"period\": \"");
    try writer.writeAll(period);
    try writer.writeAll("\"");

    // Summary: total metrics received in period, distinct metric names
    {
        // Build SQL with offset embedded (safe — offset is from our own constant)
        var sql_buf: [256]u8 = undefined;
        const prefix = "SELECT COUNT(*), COUNT(DISTINCT name) FROM metrics_raw WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '";
        const suffix = "');";
        var pos: usize = 0;
        @memcpy(sql_buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;
        @memcpy(sql_buf[pos .. pos + offset.len], offset);
        pos += offset.len;
        @memcpy(sql_buf[pos .. pos + suffix.len], suffix);
        pos += suffix.len;
        sql_buf[pos] = 0;

        const stmt = try db.prepare(@ptrCast(sql_buf[0..pos :0]));
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            var int_buf: [32]u8 = undefined;
            try writer.writeAll(", \"summary\": {\"total_datapoints\": ");
            const total = std.fmt.bufPrint(&int_buf, "{d}", .{row.int(0)}) catch "0";
            try writer.writeAll(total);
            try writer.writeAll(", \"distinct_metrics\": ");
            const distinct = std.fmt.bufPrint(&int_buf, "{d}", .{row.int(1)}) catch "0";
            try writer.writeAll(distinct);
            try writer.writeAll("}");
        } else {
            try writer.writeAll(", \"summary\": {\"total_datapoints\": 0, \"distinct_metrics\": 0}");
        }
    }

    // Top metrics by count
    {
        var sql_buf: [256]u8 = undefined;
        const prefix = "SELECT name, type, COUNT(*), SUM(value) FROM metrics_raw WHERE timestamp >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '";
        const suffix = "') GROUP BY name, type ORDER BY COUNT(*) DESC LIMIT 10;";
        var pos: usize = 0;
        @memcpy(sql_buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;
        @memcpy(sql_buf[pos .. pos + offset.len], offset);
        pos += offset.len;
        @memcpy(sql_buf[pos .. pos + suffix.len], suffix);
        pos += suffix.len;
        sql_buf[pos] = 0;

        const stmt = try db.prepare(@ptrCast(sql_buf[0..pos :0]));
        defer stmt.deinit();

        try writer.writeAll(", \"top_metrics\": [");
        var iter = stmt.query();
        var count: usize = 0;
        while (iter.next()) |row| {
            if (count > 0) try writer.writeAll(",");
            try writer.writeAll("{\"name\": \"");
            try metrics_query.writeJsonEscaped(writer, row.text(0) orelse "");
            try writer.writeAll("\", \"type\": \"");
            try metrics_query.writeJsonEscaped(writer, row.text(1) orelse "");
            try writer.writeAll("\"");

            var int_buf: [32]u8 = undefined;
            try writer.writeAll(", \"count\": ");
            const cnt = std.fmt.bufPrint(&int_buf, "{d}", .{row.int(2)}) catch "0";
            try writer.writeAll(cnt);

            var float_buf: [32]u8 = undefined;
            try writer.writeAll(", \"total\": ");
            const total = std.fmt.bufPrint(&float_buf, "{d:.6}", .{row.float(3)}) catch "0";
            try writer.writeAll(total);

            try writer.writeAll("}");
            count += 1;
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("}");
}

fn handleApiMetricsIngest(request: *std.http.Server.Request, db: *sqlite.Database) void {
    // Read request body
    const body_reader = request.reader() catch |err| {
        log.err("Failed to get request reader: {}", .{err});
        return;
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = body_reader.readAllAlloc(allocator, max_body_size) catch |err| {
        log.err("Failed to read request body: {}", .{err});
        sendJsonResponse(request, .bad_request, "{\"detail\": \"Failed to read request body\"}") catch {};
        return;
    };

    // Parse and validate
    var validation_err: ingestion.ValidationError = .{ .detail = "" };
    const metrics = ingestion.parseAndValidate(allocator, body, &validation_err) orelse {
        var err_buf: [256]u8 = undefined;
        const err_json = std.fmt.bufPrint(&err_buf, "{{\"detail\": \"{s}\"}}", .{validation_err.detail}) catch
            "{\"detail\": \"Validation error\"}";
        sendJsonResponse(request, .bad_request, err_json) catch {};
        return;
    };

    // Batch insert into database
    const inserted = ingestion.batchInsert(db, metrics) catch |err| {
        log.err("Failed to insert metrics: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Failed to store metrics\"}") catch {};
        return;
    };

    // Return 202 Accepted
    var resp_buf: [128]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"status\": \"accepted\", \"count\": {d}}}", .{inserted}) catch
        "{\"status\": \"accepted\", \"count\": 0}";
    sendJsonResponse(request, .accepted, resp_json) catch {};
}

/// Check if the target path matches /api/metrics/names (with or without query string).
fn isApiMetricsNamesPath(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "/api/metrics/names")) {
        const rest = target["/api/metrics/names".len..];
        return rest.len == 0 or rest[0] == '?';
    }
    return false;
}

/// Check if the target path matches /api/metrics (with or without query string).
/// Excludes /api/metrics/names which is handled separately.
fn isApiMetricsPath(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "/api/metrics")) {
        const rest = target["/api/metrics".len..];
        if (rest.len > 0 and rest[0] == '/') return false; // /api/metrics/names etc.
        return rest.len == 0 or rest[0] == '?';
    }
    return false;
}

/// Check if the target path matches /api/dashboard (with or without query string).
fn isApiDashboardPath(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "/api/dashboard")) {
        const rest = target["/api/dashboard".len..];
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

test "isApiMetricsPath matches correctly" {
    try std.testing.expect(isApiMetricsPath("/api/metrics"));
    try std.testing.expect(isApiMetricsPath("/api/metrics?name=test"));
    try std.testing.expect(!isApiMetricsPath("/api/metrics/names"));
    try std.testing.expect(!isApiMetricsPath("/api/metrics/other"));
    try std.testing.expect(!isApiMetricsPath("/api/other"));
}

test "isApiMetricsNamesPath matches correctly" {
    try std.testing.expect(isApiMetricsNamesPath("/api/metrics/names"));
    try std.testing.expect(isApiMetricsNamesPath("/api/metrics/names?foo=bar"));
    try std.testing.expect(!isApiMetricsNamesPath("/api/metrics"));
    try std.testing.expect(!isApiMetricsNamesPath("/api/metrics/other"));
}

test "isApiDashboardPath matches correctly" {
    try std.testing.expect(isApiDashboardPath("/api/dashboard"));
    try std.testing.expect(isApiDashboardPath("/api/dashboard?period=24h"));
    try std.testing.expect(!isApiDashboardPath("/api/dashboardx"));
    try std.testing.expect(!isApiDashboardPath("/api/other"));
}
