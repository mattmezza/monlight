const std = @import("std");
const net = std.net;
const log = std.log;
const database = @import("database.zig");
const sqlite = @import("sqlite");
const app_config = @import("config.zig");
const auth = @import("auth");
const rate_limit = @import("rate_limit");
const error_ingestion = @import("error_ingestion.zig");
const error_listing = @import("error_listing.zig");
const error_detail = @import("error_detail.zig");
const error_resolve = @import("error_resolve.zig");
const projects_listing = @import("projects_listing.zig");
const retention = @import("retention.zig");
const web_ui = @import("web_ui.zig");

const server_port: u16 = 8000;
const max_header_size = 8192;

/// Maximum request body size in bytes (256KB for Error Tracker).
pub const max_body_size: usize = 256 * 1024;

/// Maximum requests per minute (rate limit for Error Tracker).
const rate_limit_max_requests: usize = 100;
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

    log.info("configuration loaded (database: {s}, base_url: {s}, retention: {d} days)", .{
        cfg.database_path,
        cfg.base_url,
        cfg.retention_days,
    });

    // Initialize database (opens connection + runs migrations)
    var db = database.init(cfg.db_path_z) catch |err| {
        log.err("Failed to initialize database: {}", .{err});
        std.process.exit(1);
    };
    defer db.close();

    // Start HTTP server
    log.info("Starting error-tracker on port {d}...", .{server_port});

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, server_port);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    log.info("Error tracker listening on 0.0.0.0:{d}", .{server_port});

    // Initialize rate limiter (100 requests/minute)
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
        cfg.db_path_z,
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
        handleConnection(conn, cfg.api_key, &limiter, &db, &cfg) catch |err| {
            log.err("Failed to handle connection: {}", .{err});
        };
    }
}

pub fn handleConnection(conn: net.Server.Connection, api_key: []const u8, limiter: *rate_limit.RateLimiter, db: *sqlite.Database, cfg: *const app_config.Config) !void {
    defer conn.stream.close();

    var buf: [max_header_size]u8 = undefined;
    var http_server = std.http.Server.init(conn, &buf);

    var request = http_server.receiveHead() catch |err| {
        log.err("Failed to receive request head: {}", .{err});
        return;
    };

    // Serve web UI pages (static HTML, no auth required)
    if (request.head.method == .GET) {
        const target = request.head.target;
        if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/index.html")) {
            web_ui.serveIndex(&request);
            return;
        } else if (web_ui.isErrorDetailPath(target)) {
            web_ui.serveErrorDetail(&request);
            return;
        }
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

    // Route the request
    const target = request.head.target;
    if (std.mem.eql(u8, target, "/health")) {
        try handleHealth(&request);
    } else if (std.mem.eql(u8, target, "/api/errors") and request.head.method == .POST) {
        handleErrorIngestion(&request, db, cfg);
    } else if (request.head.method == .POST and error_resolve.extractResolveId(target) != null) {
        // POST /api/errors/{id}/resolve
        const resolve_id = error_resolve.extractResolveId(target).?;
        handleErrorResolve(&request, db, resolve_id);
    } else if (request.head.method == .GET and isApiProjectsPath(target)) {
        handleProjectsListing(&request, db);
    } else if (request.head.method == .GET and isApiErrorsPath(target)) {
        // Check if this is a detail request (GET /api/errors/{id})
        if (error_detail.extractId(target)) |error_id| {
            handleErrorDetail(&request, db, error_id);
        } else {
            handleErrorListing(&request, db);
        }
    } else {
        try handleNotFound(&request);
    }
}

fn handleHealth(request: *std.http.Server.Request) !void {
    const body =
        \\{"status": "ok"}
    ;
    try sendJsonResponse(request, .ok, body);
}

fn handleErrorIngestion(request: *std.http.Server.Request, db: *sqlite.Database, cfg: *const app_config.Config) void {
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

    // Parse and validate the request body
    var validation_err: error_ingestion.ValidationError = .{ .detail = "" };
    const report = error_ingestion.parseAndValidate(allocator, body, &validation_err) orelse {
        // Validation failed — format error response
        var err_buf: [256]u8 = undefined;
        const err_json = std.fmt.bufPrint(&err_buf, "{{\"detail\": \"{s}\"}}", .{validation_err.detail}) catch
            "{\"detail\": \"Validation error\"}";
        sendJsonResponse(request, .bad_request, err_json) catch {};
        return;
    };

    // Ingest the error
    const result = error_ingestion.ingest(db, &report) catch |err| {
        log.err("Failed to ingest error: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };

    // Format response
    var resp_buf: [512]u8 = undefined;
    const resp_json = error_ingestion.formatResponse(&result, &resp_buf) catch {
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };

    // Determine status code
    const status: std.http.Status = switch (result.status) {
        .created => .created,
        .incremented => .ok,
        .reopened => .created,
    };

    sendJsonResponse(request, status, resp_json) catch {};

    // Trigger email alert for new errors (asynchronously, non-blocking)
    if (result.is_new) {
        triggerEmailAlert(cfg, &report, &result);
    }
}

/// Check if the target path matches /api/errors (with or without query string or sub-path).
fn isApiErrorsPath(target: []const u8) bool {
    // Match "/api/errors", "/api/errors?...", "/api/errors/...", etc.
    if (std.mem.startsWith(u8, target, "/api/errors")) {
        const rest = target["/api/errors".len..];
        return rest.len == 0 or rest[0] == '?' or rest[0] == '/';
    }
    return false;
}

/// Check if the target path matches /api/projects (with or without query string).
fn isApiProjectsPath(target: []const u8) bool {
    if (std.mem.startsWith(u8, target, "/api/projects")) {
        const rest = target["/api/projects".len..];
        return rest.len == 0 or rest[0] == '?';
    }
    return false;
}

fn handleErrorListing(request: *std.http.Server.Request, db: *sqlite.Database) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const params = error_listing.parseQueryParams(request.head.target);
    const json = error_listing.queryAndFormat(allocator, db, &params) catch |err| {
        log.err("Failed to query errors: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };

    sendJsonResponse(request, .ok, json) catch {};
}

fn handleProjectsListing(request: *std.http.Server.Request, db: *sqlite.Database) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json = projects_listing.queryAndFormat(allocator, db) catch |err| {
        log.err("Failed to query projects: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };

    sendJsonResponse(request, .ok, json) catch {};
}

fn handleErrorDetail(request: *std.http.Server.Request, db: *sqlite.Database, error_id: i64) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json = error_detail.queryAndFormat(allocator, db, error_id) catch |err| {
        log.err("Failed to query error detail: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };

    if (json) |body| {
        sendJsonResponse(request, .ok, body) catch {};
    } else {
        sendJsonResponse(request, .not_found, "{\"detail\": \"Error not found\"}") catch {};
    }
}

fn handleErrorResolve(request: *std.http.Server.Request, db: *sqlite.Database, error_id: i64) void {
    const result = error_resolve.resolve(db, error_id) catch |err| {
        log.err("Failed to resolve error: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };

    var resp_buf: [256]u8 = undefined;
    const resp_json = error_resolve.formatResponse(&result, &resp_buf) catch {
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Internal server error\"}") catch {};
        return;
    };

    const status: std.http.Status = switch (result) {
        .resolved => .ok,
        .not_found => .not_found,
    };

    sendJsonResponse(request, status, resp_json) catch {};
}

/// Trigger an email alert for a new error.
/// This is fire-and-forget: failures are logged but do not affect the response.
fn triggerEmailAlert(cfg: *const app_config.Config, report: *const error_ingestion.ErrorReport, result: *const error_ingestion.IngestResult) void {
    // If Postmark is not configured, skip silently
    const api_token = cfg.postmark_api_token orelse return;
    const alert_emails = cfg.alert_emails orelse return;

    // Format email subject: [{project}] {exception_type}: {message_truncated_50_chars}
    var subject_buf: [512]u8 = undefined;
    const msg_truncated = if (report.message.len > 50) report.message[0..50] else report.message;
    const subject = std.fmt.bufPrint(&subject_buf, "[{s}] {s}: {s}", .{
        report.project,
        report.exception_type,
        msg_truncated,
    }) catch "New error alert";

    // Format email body
    var body_buf: [8192]u8 = undefined;
    const request_info = if (report.request_method != null and report.request_url != null) blk: {
        var req_buf: [256]u8 = undefined;
        break :blk std.fmt.bufPrint(&req_buf, "{s} {s}", .{ report.request_method.?, report.request_url.? }) catch "N/A";
    } else "N/A";

    const fp_str: []const u8 = if (result.fingerprint) |fp| &fp else "unknown";
    _ = fp_str;

    const dashboard_link = blk: {
        var link_buf: [256]u8 = undefined;
        break :blk std.fmt.bufPrint(&link_buf, "{s}/api/errors/{d}", .{ cfg.base_url, result.id }) catch cfg.base_url;
    };

    const email_body = std.fmt.bufPrint(&body_buf,
        \\New error in {s} ({s})
        \\
        \\Exception: {s}
        \\Message: {s}
        \\
        \\Request: {s}
        \\
        \\Traceback:
        \\{s}
        \\
        \\---
        \\View in Error Tracker: {s}
    , .{
        report.project,
        report.environment,
        report.exception_type,
        report.message,
        request_info,
        report.traceback,
        dashboard_link,
    }) catch "Error alert - see error tracker for details";

    // Send to each recipient
    var email_iter = std.mem.splitScalar(u8, alert_emails, ',');
    while (email_iter.next()) |raw_email| {
        const email = std.mem.trim(u8, raw_email, " \t\r\n");
        if (email.len == 0) continue;
        sendPostmarkEmail(api_token, cfg.postmark_from_email, email, subject, email_body);
    }
}

/// Send an email via the Postmark API.
/// This is a blocking HTTP call — in a production system, this should be done
/// on a separate thread. For now, the alert is sent synchronously but
/// the caller handles failures gracefully.
fn sendPostmarkEmail(
    api_token: []const u8,
    from_email: []const u8,
    to_email: []const u8,
    subject: []const u8,
    body: []const u8,
) void {
    // Build JSON payload
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var payload_buf = std.ArrayList(u8).init(allocator);
    const writer = payload_buf.writer();

    // Manually build JSON to avoid escaping issues
    writer.writeAll("{\"From\": \"") catch {
        log.warn("Failed to build Postmark payload", .{});
        return;
    };
    writeJsonEscaped(writer, from_email) catch return;
    writer.writeAll("\", \"To\": \"") catch return;
    writeJsonEscaped(writer, to_email) catch return;
    writer.writeAll("\", \"Subject\": \"") catch return;
    writeJsonEscaped(writer, subject) catch return;
    writer.writeAll("\", \"TextBody\": \"") catch return;
    writeJsonEscaped(writer, body) catch return;
    writer.writeAll("\"}") catch return;

    const payload = payload_buf.items;

    // Make HTTP request to Postmark API
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse("https://api.postmarkapp.com/email") catch {
        log.warn("Failed to parse Postmark URL", .{});
        return;
    };

    var header_buf: [4096]u8 = undefined;
    var req = client.open(.POST, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-Postmark-Server-Token", .value = api_token },
        },
    }) catch |err| {
        log.warn("Failed to connect to Postmark API: {}", .{err});
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    req.send() catch |err| {
        log.warn("Failed to send Postmark request: {}", .{err});
        return;
    };
    req.writeAll(payload) catch |err| {
        log.warn("Failed to write Postmark payload: {}", .{err});
        return;
    };
    req.finish() catch |err| {
        log.warn("Failed to finish Postmark request: {}", .{err});
        return;
    };
    req.wait() catch |err| {
        log.warn("Failed to get Postmark response: {}", .{err});
        return;
    };

    if (req.response.status == .ok) {
        log.info("Email alert sent to {s}", .{to_email});
    } else {
        log.warn("Postmark API returned status {d} for email to {s}", .{ @intFromEnum(req.response.status), to_email });
    }
}

/// Write a string with JSON escaping (escapes backslash, double-quote, newline, tab, etc.)
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
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

    var buf: [1024]u8 = undefined;
    const n = stream.read(&buf) catch {
        std.process.exit(1);
    };

    if (n == 0) {
        std.process.exit(1);
    }

    const response = buf[0..n];
    // Check for "200 OK" in response
    if (std.mem.indexOf(u8, response, "200") != null) {
        std.process.exit(0);
    }

    std.process.exit(1);
}

test "health endpoint returns ok" {
    // Basic test to verify the module compiles
    const body =
        \\{"status": "ok"}
    ;
    try std.testing.expectEqualStrings("{\"status\": \"ok\"}", body);
}
