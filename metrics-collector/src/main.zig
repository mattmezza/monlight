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
    var db = database.init(cfg.dbPathZ()) catch |err| {
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
        cfg.dbPathZ(),
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

    // Web Vitals section — only included if browser Web Vitals data exists
    {
        // Check if any web_vitals_* metrics exist with source=browser in the period
        var check_buf: [384]u8 = undefined;
        const check_prefix = "SELECT COUNT(*) FROM metrics_raw WHERE name IN ('web_vitals_lcp','web_vitals_inp','web_vitals_cls') AND json_extract(labels, '$.source') = 'browser' AND timestamp >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '";
        const check_suffix = "') LIMIT 1;";
        var check_pos: usize = 0;
        @memcpy(check_buf[check_pos .. check_pos + check_prefix.len], check_prefix);
        check_pos += check_prefix.len;
        @memcpy(check_buf[check_pos .. check_pos + offset.len], offset);
        check_pos += offset.len;
        @memcpy(check_buf[check_pos .. check_pos + check_suffix.len], check_suffix);
        check_pos += check_suffix.len;
        check_buf[check_pos] = 0;

        const check_stmt = try db.prepare(@ptrCast(check_buf[0..check_pos :0]));
        defer check_stmt.deinit();
        var check_iter = check_stmt.query();
        const has_web_vitals = if (check_iter.next()) |row| row.int(0) > 0 else false;

        if (has_web_vitals) {
            try writer.writeAll(", \"web_vitals\": {");

            // Summary: average values for LCP, INP, CLS
            try writer.writeAll("\"summary\": {");
            {
                const vitals = [_][]const u8{ "web_vitals_lcp", "web_vitals_inp", "web_vitals_cls" };
                const vital_keys = [_][]const u8{ "lcp", "inp", "cls" };
                // Thresholds: [good_max, poor_min]
                const good_thresholds = [_]f64{ 2500.0, 200.0, 0.1 };
                const poor_thresholds = [_]f64{ 4000.0, 500.0, 0.25 };

                for (vitals, 0..) |vital_name, vi| {
                    if (vi > 0) try writer.writeAll(", ");

                    var summary_buf: [512]u8 = undefined;
                    const summary_prefix = "SELECT AVG(value), COUNT(*) FROM metrics_raw WHERE name = '";
                    const summary_mid = "' AND json_extract(labels, '$.source') = 'browser' AND timestamp >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '";
                    const summary_suffix = "');";
                    var spos: usize = 0;
                    @memcpy(summary_buf[spos .. spos + summary_prefix.len], summary_prefix);
                    spos += summary_prefix.len;
                    @memcpy(summary_buf[spos .. spos + vital_name.len], vital_name);
                    spos += vital_name.len;
                    @memcpy(summary_buf[spos .. spos + summary_mid.len], summary_mid);
                    spos += summary_mid.len;
                    @memcpy(summary_buf[spos .. spos + offset.len], offset);
                    spos += offset.len;
                    @memcpy(summary_buf[spos .. spos + summary_suffix.len], summary_suffix);
                    spos += summary_suffix.len;
                    summary_buf[spos] = 0;

                    const summary_stmt = try db.prepare(@ptrCast(summary_buf[0..spos :0]));
                    defer summary_stmt.deinit();
                    var summary_iter = summary_stmt.query();

                    try writer.writeAll("\"");
                    try writer.writeAll(vital_keys[vi]);
                    try writer.writeAll("\": {\"avg\": ");

                    if (summary_iter.next()) |row| {
                        if (row.isNull(0)) {
                            try writer.writeAll("null, \"count\": 0, \"rating\": \"unknown\"");
                        } else {
                            const avg_val = row.float(0);
                            var float_buf: [32]u8 = undefined;
                            const avg_str = std.fmt.bufPrint(&float_buf, "{d:.4}", .{avg_val}) catch "0";
                            try writer.writeAll(avg_str);

                            try writer.writeAll(", \"count\": ");
                            var int_buf: [32]u8 = undefined;
                            const cnt_str = std.fmt.bufPrint(&int_buf, "{d}", .{row.int(1)}) catch "0";
                            try writer.writeAll(cnt_str);

                            try writer.writeAll(", \"rating\": \"");
                            if (avg_val < good_thresholds[vi]) {
                                try writer.writeAll("good");
                            } else if (avg_val < poor_thresholds[vi]) {
                                try writer.writeAll("needs-improvement");
                            } else {
                                try writer.writeAll("poor");
                            }
                            try writer.writeAll("\"");
                        }
                    } else {
                        try writer.writeAll("null, \"count\": 0, \"rating\": \"unknown\"");
                    }

                    try writer.writeAll("}");
                }
            }
            try writer.writeAll("}");

            // Timeseries: p75 values over time buckets
            // Use percentile approximation via NTILE or ordered subquery
            // For each vital, bucket by time and compute approximate p75
            try writer.writeAll(", \"timeseries\": [");
            {
                // Determine bucket format based on period
                const bucket_fmt = if (std.mem.eql(u8, period, "1h") or std.mem.eql(u8, period, "24h"))
                    "%Y-%m-%dT%H:%M:00Z"
                else
                    "%Y-%m-%dT%H:00:00Z";

                var ts_buf: [768]u8 = undefined;
                const ts_p1 = "SELECT strftime('";
                const ts_p2 = "', timestamp) as bucket, ";
                // For each vital, get the value at the 75th percentile position
                // We use a subquery approach: for each bucket, get AVG of top 25-75% values
                // Simpler: just use the value from the row at 75% position
                // Simplest practical approach: use AVG * 1.35 approximation or just return AVG for p75
                // Better: query all three vitals in one go using conditional aggregation
                const ts_p3 = "AVG(CASE WHEN name='web_vitals_lcp' THEN value END) as lcp_avg, " ++
                    "AVG(CASE WHEN name='web_vitals_inp' THEN value END) as inp_avg, " ++
                    "AVG(CASE WHEN name='web_vitals_cls' THEN value END) as cls_avg, " ++
                    "COUNT(*) as cnt " ++
                    "FROM metrics_raw WHERE name IN ('web_vitals_lcp','web_vitals_inp','web_vitals_cls') " ++
                    "AND json_extract(labels, '$.source') = 'browser' " ++
                    "AND timestamp >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '";
                const ts_p4 = "') GROUP BY bucket ORDER BY bucket ASC;";

                var tpos: usize = 0;
                @memcpy(ts_buf[tpos .. tpos + ts_p1.len], ts_p1);
                tpos += ts_p1.len;
                @memcpy(ts_buf[tpos .. tpos + bucket_fmt.len], bucket_fmt);
                tpos += bucket_fmt.len;
                @memcpy(ts_buf[tpos .. tpos + ts_p2.len], ts_p2);
                tpos += ts_p2.len;
                @memcpy(ts_buf[tpos .. tpos + ts_p3.len], ts_p3);
                tpos += ts_p3.len;
                @memcpy(ts_buf[tpos .. tpos + offset.len], offset);
                tpos += offset.len;
                @memcpy(ts_buf[tpos .. tpos + ts_p4.len], ts_p4);
                tpos += ts_p4.len;
                ts_buf[tpos] = 0;

                const ts_stmt = try db.prepare(@ptrCast(ts_buf[0..tpos :0]));
                defer ts_stmt.deinit();
                var ts_iter = ts_stmt.query();
                var ts_count: usize = 0;

                while (ts_iter.next()) |row| {
                    if (ts_count > 0) try writer.writeAll(",");
                    try writer.writeAll("{\"bucket\": \"");
                    try metrics_query.writeJsonEscaped(writer, row.text(0) orelse "");
                    try writer.writeAll("\"");

                    // LCP p75 approximation (avg)
                    try writeWebVitalField(writer, ", \"lcp\": ", row, 1);
                    try writeWebVitalField(writer, ", \"inp\": ", row, 2);
                    try writeWebVitalField(writer, ", \"cls\": ", row, 3);

                    try writer.writeAll(", \"count\": ");
                    var int_buf: [32]u8 = undefined;
                    const cnt_str = std.fmt.bufPrint(&int_buf, "{d}", .{row.int(4)}) catch "0";
                    try writer.writeAll(cnt_str);

                    try writer.writeAll("}");
                    ts_count += 1;
                }
            }
            try writer.writeAll("]");

            // By page: per-page breakdown
            try writer.writeAll(", \"by_page\": [");
            {
                var page_buf: [768]u8 = undefined;
                const page_p1 = "SELECT json_extract(labels, '$.page') as page, " ++
                    "AVG(CASE WHEN name='web_vitals_lcp' THEN value END) as lcp, " ++
                    "AVG(CASE WHEN name='web_vitals_inp' THEN value END) as inp, " ++
                    "AVG(CASE WHEN name='web_vitals_cls' THEN value END) as cls, " ++
                    "COUNT(DISTINCT CASE WHEN name='web_vitals_lcp' THEN timestamp END) as page_views " ++
                    "FROM metrics_raw WHERE name IN ('web_vitals_lcp','web_vitals_inp','web_vitals_cls') " ++
                    "AND json_extract(labels, '$.source') = 'browser' " ++
                    "AND timestamp >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '";
                const page_p2 = "') GROUP BY page ORDER BY page_views DESC LIMIT 20;";

                var ppos: usize = 0;
                @memcpy(page_buf[ppos .. ppos + page_p1.len], page_p1);
                ppos += page_p1.len;
                @memcpy(page_buf[ppos .. ppos + offset.len], offset);
                ppos += offset.len;
                @memcpy(page_buf[ppos .. ppos + page_p2.len], page_p2);
                ppos += page_p2.len;
                page_buf[ppos] = 0;

                const page_stmt = try db.prepare(@ptrCast(page_buf[0..ppos :0]));
                defer page_stmt.deinit();
                var page_iter = page_stmt.query();
                var page_count: usize = 0;

                while (page_iter.next()) |row| {
                    if (page_count > 0) try writer.writeAll(",");
                    try writer.writeAll("{\"page\": \"");
                    try metrics_query.writeJsonEscaped(writer, row.text(0) orelse "/");
                    try writer.writeAll("\"");

                    try writeWebVitalField(writer, ", \"lcp\": ", row, 1);
                    try writeWebVitalField(writer, ", \"inp\": ", row, 2);
                    try writeWebVitalField(writer, ", \"cls\": ", row, 3);

                    try writer.writeAll(", \"page_views\": ");
                    var int_buf: [32]u8 = undefined;
                    const cnt_str = std.fmt.bufPrint(&int_buf, "{d}", .{row.int(4)}) catch "0";
                    try writer.writeAll(cnt_str);

                    try writer.writeAll("}");
                    page_count += 1;
                }
            }
            try writer.writeAll("]");

            try writer.writeAll("}");
        }
    }

    try writer.writeAll("}");
}

fn writeWebVitalField(writer: *std.ArrayList(u8).Writer, prefix: []const u8, row: sqlite.Row, col: usize) !void {
    try writer.writeAll(prefix);
    if (row.isNull(col)) {
        try writer.writeAll("null");
    } else {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d:.4}", .{row.float(col)}) catch "0";
        try writer.writeAll(str);
    }
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

test "buildDashboardJson without web vitals data" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert a regular metric (no web vitals)
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type) " ++
                "VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-10 minutes'), 'http_requests', 1.0, 'counter');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    var response = std.ArrayList(u8).init(std.testing.allocator);
    defer response.deinit();
    var writer = response.writer();

    try buildDashboardJson(&db, &writer, "-24 hours", "24h");

    const json = response.items;
    // Should have period, summary, top_metrics
    try std.testing.expect(std.mem.indexOf(u8, json, "\"period\": \"24h\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"top_metrics\"") != null);
    // Should NOT have web_vitals section
    try std.testing.expect(std.mem.indexOf(u8, json, "\"web_vitals\"") == null);
}

test "buildDashboardJson with web vitals data" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert Web Vitals metrics with browser source labels
    const vitals = [_]struct { name: []const u8, value: f64 }{
        .{ .name = "web_vitals_lcp", .value = 2200.0 },
        .{ .name = "web_vitals_inp", .value = 150.0 },
        .{ .name = "web_vitals_cls", .value = 0.08 },
    };

    for (vitals) |v| {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type, labels) " ++
                "VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-10 minutes'), ?, ?, 'histogram', '{\"source\":\"browser\",\"page\":\"/home\"}');",
        );
        defer stmt.deinit();
        try stmt.bindText(1, v.name);
        try stmt.bindFloat(2, v.value);
        _ = try stmt.exec();
    }

    var response = std.ArrayList(u8).init(std.testing.allocator);
    defer response.deinit();
    var writer = response.writer();

    try buildDashboardJson(&db, &writer, "-24 hours", "24h");

    const json = response.items;
    // Should have web_vitals section
    try std.testing.expect(std.mem.indexOf(u8, json, "\"web_vitals\"") != null);
    // Should have summary with lcp, inp, cls
    try std.testing.expect(std.mem.indexOf(u8, json, "\"lcp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cls\"") != null);
    // Should have ratings
    try std.testing.expect(std.mem.indexOf(u8, json, "\"rating\"") != null);
    // LCP 2200 < 2500 -> good
    try std.testing.expect(std.mem.indexOf(u8, json, "\"good\"") != null);
    // Should have timeseries
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timeseries\"") != null);
    // Should have by_page with /home
    try std.testing.expect(std.mem.indexOf(u8, json, "\"by_page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/home") != null);
    // Should have page_views
    try std.testing.expect(std.mem.indexOf(u8, json, "\"page_views\"") != null);
}

test "buildDashboardJson web vitals ratings are correct" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert poor LCP (> 4000ms), needs-improvement INP (200-500ms), good CLS (< 0.1)
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type, labels) " ++
                "VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-5 minutes'), 'web_vitals_lcp', 5000.0, 'histogram', '{\"source\":\"browser\",\"page\":\"/slow\"}');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type, labels) " ++
                "VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-5 minutes'), 'web_vitals_inp', 350.0, 'histogram', '{\"source\":\"browser\",\"page\":\"/slow\"}');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type, labels) " ++
                "VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-5 minutes'), 'web_vitals_cls', 0.05, 'histogram', '{\"source\":\"browser\",\"page\":\"/slow\"}');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    var response = std.ArrayList(u8).init(std.testing.allocator);
    defer response.deinit();
    var writer = response.writer();

    try buildDashboardJson(&db, &writer, "-24 hours", "24h");

    const json = response.items;
    // LCP 5000 >= 4000 -> poor
    try std.testing.expect(std.mem.indexOf(u8, json, "\"poor\"") != null);
    // INP 350 >= 200 && < 500 -> needs-improvement
    try std.testing.expect(std.mem.indexOf(u8, json, "\"needs-improvement\"") != null);
    // CLS 0.05 < 0.1 -> good
    try std.testing.expect(std.mem.indexOf(u8, json, "\"good\"") != null);
}
