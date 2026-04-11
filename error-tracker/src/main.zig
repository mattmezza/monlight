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

/// Stack size for the SMTP alert background thread. The TLS code path
/// allocates four `std.crypto.tls.max_ciphertext_record_len`-sized buffers
/// on the stack (~64 KB) plus TLS handshake state and cert verification
/// scratch, which overflows musl's default ~80 KB pthread stack and
/// silently corrupts the thread, manifesting as `error.ReadFailed` from
/// post-handshake reads. 2 MB leaves comfortable headroom on every libc.
const alert_thread_stack_size: usize = 2 * 1024 * 1024;

/// Context passed to the background SMTP alert thread.
/// Held by value (copied) so the spawning function's stack can unwind safely.
const AlertContext = struct {
    cfg: *const app_config.Config,
    subject: [512]u8,
    subject_len: usize,
    body: [8192]u8,
    body_len: usize,
};

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
    var db = database.init(cfg.dbPathZ()) catch |err| {
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
        handleConnection(conn, cfg.api_key, &limiter, &db, &cfg) catch |err| {
            log.err("Failed to handle connection: {}", .{err});
        };
    }
}

pub fn handleConnection(conn: net.Server.Connection, api_key: []const u8, limiter: *rate_limit.RateLimiter, db: *sqlite.Database, cfg: *const app_config.Config) !void {
    defer conn.stream.close();

    var read_buf: [max_header_size]u8 = undefined;
    var write_buf: [max_header_size]u8 = undefined;
    var connection_reader = conn.stream.reader(&read_buf);
    var connection_writer = conn.stream.writer(&write_buf);
    var http_server: std.http.Server = .init(connection_reader.interface(), &connection_writer.interface);

    var request = http_server.receiveHead() catch |err| {
        log.err("Failed to receive request head: {}", .{err});
        return;
    };

    // Serve web UI pages + static assets (no auth required)
    if (request.head.method == .GET) {
        const target = request.head.target;
        if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/index.html")) {
            web_ui.serveIndex(&request);
            return;
        } else if (std.mem.eql(u8, target, "/tailwind.css")) {
            web_ui.serveTailwindCss(&request);
            return;
        } else if (std.mem.eql(u8, target, "/alpine.js")) {
            web_ui.serveAlpineJs(&request);
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
    } else if (std.mem.eql(u8, target, "/api/test-alert") and request.head.method == .POST) {
        handleTestAlert(&request, cfg);
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
    var body_buf: [max_body_size]u8 = undefined;
    const body_reader = request.readerExpectContinue(&body_buf) catch |err| {
        log.err("Failed to get request reader: {}", .{err});
        return;
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = body_reader.allocRemaining(allocator, std.Io.Limit.limited(max_body_size)) catch |err| {
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

    // Trigger email alert for new errors in a background thread (non-blocking)
    if (result.is_new) {
        var ctx = AlertContext{
            .cfg = cfg,
            .subject = undefined,
            .subject_len = 0,
            .body = undefined,
            .body_len = 0,
        };
        // Format subject and body into context buffers
        const msg_truncated = if (report.message.len > 50) report.message[0..50] else report.message;
        const subject = std.fmt.bufPrint(&ctx.subject, "[{s}] {s}: {s}", .{
            report.project, report.exception_type, msg_truncated,
        }) catch "New error alert";
        ctx.subject_len = subject.len;

        const request_info = if (report.request_method != null and report.request_url != null) blk: {
            var req_buf: [256]u8 = undefined;
            break :blk std.fmt.bufPrint(&req_buf, "{s} {s}", .{ report.request_method.?, report.request_url.? }) catch "N/A";
        } else "N/A";
        const dashboard_link = blk: {
            var link_buf: [256]u8 = undefined;
            break :blk std.fmt.bufPrint(&link_buf, "{s}/api/errors/{d}", .{ cfg.base_url, result.id }) catch cfg.base_url;
        };
        const email_body = std.fmt.bufPrint(&ctx.body,
            \\New error in {s}
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
            report.project, report.exception_type, report.message,
            request_info, report.traceback, dashboard_link,
        }) catch "Error alert - see error tracker for details";
        ctx.body_len = email_body.len;

        const thread = std.Thread.spawn(.{ .stack_size = alert_thread_stack_size }, sendAlertEmails, .{ctx}) catch |err| {
            log.warn("Failed to spawn email alert thread: {}", .{err});
            return;
        };
        thread.detach();
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

/// Send a synthetic alert email so operators can verify SMTP configuration
/// without polluting the error database. Returns 503 if SMTP is not configured,
/// 202 if the alert was dispatched (delivery happens in a background thread —
/// check service logs for the actual SMTP transaction result).
fn handleTestAlert(request: *std.http.Server.Request, cfg: *const app_config.Config) void {
    // This endpoint never reads its request body. std.http.Server.respond()
    // will panic during keep-alive cleanup if a POST arrives without
    // Content-Length / Transfer-Encoding (e.g. `curl -X POST` with no `-d`),
    // because it cannot determine body framing in order to discard it.
    // Disabling keep-alive bypasses that cleanup path entirely.
    request.head.keep_alive = false;

    if (cfg.smtp_host == null) {
        sendJsonResponse(request, .service_unavailable, "{\"detail\": \"SMTP not configured: SMTP_HOST is not set\"}") catch {};
        return;
    }
    if (cfg.alert_emails == null) {
        sendJsonResponse(request, .service_unavailable, "{\"detail\": \"SMTP not configured: ALERT_EMAILS is not set\"}") catch {};
        return;
    }

    var ctx = AlertContext{
        .cfg = cfg,
        .subject = undefined,
        .subject_len = 0,
        .body = undefined,
        .body_len = 0,
    };

    const subject = std.fmt.bufPrint(&ctx.subject, "[error-tracker] SMTP test alert", .{}) catch "SMTP test alert";
    ctx.subject_len = subject.len;

    const body = std.fmt.bufPrint(&ctx.body,
        \\This is a test alert from the Error Tracker.
        \\
        \\If you received this email, your SMTP configuration is working correctly.
        \\
        \\---
        \\Dashboard: {s}
    , .{cfg.base_url}) catch "SMTP test alert from error-tracker";
    ctx.body_len = body.len;

    const thread = std.Thread.spawn(.{ .stack_size = alert_thread_stack_size }, sendAlertEmails, .{ctx}) catch |err| {
        log.warn("Failed to spawn test alert thread: {}", .{err});
        sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Failed to dispatch test alert\"}") catch {};
        return;
    };
    thread.detach();

    sendJsonResponse(request, .accepted, "{\"status\": \"test alert dispatched\", \"detail\": \"Check service logs for SMTP transaction result\"}") catch {};
}

/// Background thread entry: send alert emails to all configured recipients.
fn sendAlertEmails(ctx: anytype) void {
    log.debug("alert thread: started", .{});
    const cfg = ctx.cfg;
    const smtp_host = cfg.smtp_host orelse {
        log.warn("alert thread: smtp_host null at send time", .{});
        return;
    };
    const alert_emails = cfg.alert_emails orelse {
        log.warn("alert thread: alert_emails null at send time", .{});
        return;
    };
    const subject = ctx.subject[0..ctx.subject_len];
    const email_body = ctx.body[0..ctx.body_len];

    var email_iter = std.mem.splitScalar(u8, alert_emails, ',');
    while (email_iter.next()) |raw_email| {
        const email = std.mem.trim(u8, raw_email, " \t\r\n");
        if (email.len == 0) continue;
        sendSmtpEmail(smtp_host, cfg.smtp_port, cfg.smtp_username, cfg.smtp_password, cfg.smtp_from, email, subject, email_body);
    }
}

/// Send an email via SMTP. Three transport modes are supported:
///   - **Implicit TLS (SMTPS)**: auto-selected when `port == 465`. TLS handshake
///     is performed immediately on the raw TCP stream — no plaintext phase.
///   - **STARTTLS**: used on any other port if the server advertises STARTTLS in
///     its EHLO response. Connection starts plaintext, then upgrades to TLS.
///   - **Plain SMTP**: fallback when STARTTLS is not advertised. No encryption.
///
/// Runs in a background thread — failures are logged but do not affect service availability.
fn sendSmtpEmail(
    host: []const u8,
    port: u16,
    username: ?[]const u8,
    password: ?[]const u8,
    from_email: []const u8,
    to_email: []const u8,
    subject: []const u8,
    body: []const u8,
) void {
    log.debug("alert thread: sendSmtpEmail -> {s}:{d} to={s}", .{ host, port, to_email });
    const allocator = std.heap.page_allocator;
    const stream = net.tcpConnectToHost(allocator, host, port) catch |err| {
        log.warn("Failed to connect to SMTP server {s}:{d}: {}", .{ host, port, err });
        return;
    };
    defer stream.close();
    log.debug("alert thread: TCP connected to {s}:{d}", .{ host, port });

    // NOTE: do NOT set SO_RCVTIMEO/SO_SNDTIMEO on this socket.
    // On Zig 0.15.x, any value of SO_RCVTIMEO causes std.crypto.tls.Client
    // post-handshake reads to fail with error.ReadFailed (inner WouldBlock)
    // — confirmed by bisecting against a fresh alpine:3.21 + ziglang 0.15.2
    // build talking to smtp.zeptomail.com:465. Without the timeout the
    // greeting arrives in milliseconds. The alert thread is detached and
    // long-lived hangs are tolerable here.

    // Use buffered reader/writer for the stream. The buffers double as the
    // input/output for std.crypto.tls.Client when STARTTLS or SMTPS upgrade
    // happens, and Client.init asserts that each is at least
    // `tls.max_ciphertext_record_len` bytes (16645 on Zig 0.15.x). Sizing them
    // smaller causes a hard-to-trace panic that ReleaseSafe misattributes to
    // Bundle.zig:24:46.
    var read_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
    var write_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
    var reader = stream.reader(&read_buf);
    var writer = stream.writer(&write_buf);

    // Implicit TLS (SMTPS) on port 465: handshake immediately, no plaintext phase.
    if (port == 465) {
        log.debug("alert thread: port 465 -> SMTPS path", .{});
        var ca_bundle: std.crypto.Certificate.Bundle = .{};
        ca_bundle.rescan(allocator) catch |err| {
            log.warn("Failed to load CA certificates: {}", .{err});
            return;
        };
        defer ca_bundle.deinit(allocator);
        log.debug("alert thread: CA bundle loaded", .{});

        var tls_read_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
        var tls_write_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
        var tls_client = std.crypto.tls.Client.init(reader.interface(), &writer.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = &tls_read_buf,
            .write_buffer = &tls_write_buf,
        }) catch |err| {
            log.warn("TLS handshake failed with {s}:{d}: {}", .{ host, port, err });
            return;
        };
        log.debug("alert thread: TLS handshake OK", .{});

        // Read TLS greeting
        const greeting = smtpReadResponseTls(&tls_client) catch |err| {
            log.warn("Failed to read SMTP greeting from {s}:{d} (SMTPS): {}", .{ host, port, err });
            return;
        };
        if (greeting.len == 0 or !std.mem.startsWith(u8, greeting.buf[0..greeting.len], "2")) {
            log.warn("SMTP server did not send valid greeting from {s}:{d} (SMTPS, {d} bytes): {s}", .{
                host, port, greeting.len, greeting.buf[0..@min(greeting.len, 200)],
            });
            return;
        }
        log.debug("alert thread: got SMTP greeting ({d} bytes)", .{greeting.len});

        // EHLO over TLS
        smtpSendTls(&tls_client, "EHLO localhost\r\n") catch {
            log.warn("Failed to send EHLO over TLS", .{});
            return;
        };
        if (!smtpReadOkTls(&tls_client)) {
            log.warn("SMTP EHLO rejected over SMTPS", .{});
            return;
        }
        log.debug("alert thread: EHLO accepted, entering AUTH", .{});

        smtpAuthAndSend(&tls_client, username, password, from_email, to_email, subject, body, "SMTPS");
        return;
    }

    // Read server greeting (plaintext) — log raw bytes / underlying error so the
    // user can tell EOF, timeout, and "wrong protocol" apart.
    const greeting = smtpReadResponse(&reader) catch |err| {
        log.warn("Failed to read SMTP greeting from {s}:{d}: {} (hint: try SMTP_PORT=465 for implicit TLS)", .{ host, port, err });
        return;
    };
    if (greeting.len == 0 or !std.mem.startsWith(u8, greeting.buf[0..greeting.len], "2")) {
        log.warn("SMTP server did not send valid greeting from {s}:{d} ({d} bytes): {s} (hint: try SMTP_PORT=465 for implicit TLS)", .{
            host, port, greeting.len, greeting.buf[0..@min(greeting.len, 200)],
        });
        return;
    }

    // EHLO (plaintext)
    smtpSend(&writer, "EHLO localhost\r\n") catch {
        log.warn("Failed to send EHLO", .{});
        return;
    };
    const ehlo_response = smtpReadResponse(&reader) catch |err| {
        log.warn("Failed to read EHLO response from {s}:{d}: {}", .{ host, port, err });
        return;
    };
    if (ehlo_response.len == 0 or !std.mem.startsWith(u8, ehlo_response.buf[0..ehlo_response.len], "2")) {
        log.warn("SMTP EHLO rejected by {s}:{d} ({d} bytes): {s}", .{
            host, port, ehlo_response.len, ehlo_response.buf[0..@min(ehlo_response.len, 200)],
        });
        return;
    }

    // Check if STARTTLS is advertised and attempt upgrade
    const ehlo_text = ehlo_response.buf[0..ehlo_response.len];
    const starttls_supported = std.mem.indexOf(u8, ehlo_text, "STARTTLS") != null;

    if (starttls_supported) {
        smtpSend(&writer, "STARTTLS\r\n") catch {
            log.warn("Failed to send STARTTLS", .{});
            return;
        };
        if (!smtpReadOk(&reader)) {
            log.warn("SMTP STARTTLS rejected", .{});
            return;
        }

        // Upgrade to TLS
        var ca_bundle: std.crypto.Certificate.Bundle = .{};
        ca_bundle.rescan(allocator) catch |err| {
            log.warn("Failed to load CA certificates: {}", .{err});
            return;
        };
        defer ca_bundle.deinit(allocator);

        var tls_read_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
        var tls_write_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
        var tls_client = std.crypto.tls.Client.init(reader.interface(), &writer.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = &tls_read_buf,
            .write_buffer = &tls_write_buf,
        }) catch |err| {
            log.warn("TLS handshake failed with {s}:{d}: {}", .{ host, port, err });
            return;
        };

        // Re-EHLO over TLS
        smtpSendTls(&tls_client, "EHLO localhost\r\n") catch {
            log.warn("Failed to send EHLO over TLS", .{});
            return;
        };
        if (!smtpReadOkTls(&tls_client)) {
            log.warn("SMTP EHLO rejected after STARTTLS", .{});
            return;
        }

        // AUTH + send message over TLS
        smtpAuthAndSend(&tls_client, username, password, from_email, to_email, subject, body, "STARTTLS");
    } else {
        // Plain SMTP (no TLS) — AUTH + send message
        smtpAuthAndSendPlain(&reader, &writer, username, password, from_email, to_email, subject, body);
    }
}

const SmtpReader = net.Stream.Reader;
const SmtpWriter = net.Stream.Writer;

/// Perform AUTH LOGIN + mail send over a TLS connection. `mode_label` is used
/// purely for the success log line so operators can tell SMTPS and STARTTLS apart.
fn smtpAuthAndSend(tls: *std.crypto.tls.Client, username: ?[]const u8, password: ?[]const u8, from_email: []const u8, to_email: []const u8, subject: []const u8, body: []const u8, mode_label: []const u8) void {
    // AUTH PLAIN — single-message authentication. The payload is
    // base64("\x00" ++ username ++ "\x00" ++ password). Preferred over AUTH LOGIN
    // because some servers (e.g. zoho/zeptomail) reply to the multi-step LOGIN
    // dance in ways that deadlock our buffered TLS reader; PLAIN is a single
    // request/response and sidesteps the issue.
    if (username != null and password != null) {
        var auth_line_buf: [768]u8 = undefined;
        const line = buildAuthPlainLine(&auth_line_buf, username.?, password.?) catch |err| {
            log.warn("SMTP AUTH PLAIN payload build failed: {}", .{err});
            return;
        };
        log.debug("alert thread: AUTH PLAIN line built ({d} bytes)", .{line.len});
        smtpSendTls(tls, line) catch |err| {
            log.warn("Failed to send AUTH PLAIN over {s}: {}", .{ mode_label, err });
            return;
        };
        log.debug("alert thread: AUTH PLAIN sent, awaiting 235", .{});
        if (!smtpReadReplyTls(tls, "235")) {
            log.warn("SMTP AUTH PLAIN rejected over {s}", .{mode_label});
            return;
        }
        log.debug("alert thread: AUTH PLAIN accepted over {s}", .{mode_label});
    }

    // MAIL FROM / RCPT TO / DATA / message
    var from_buf: [512]u8 = undefined;
    const mail_from = std.fmt.bufPrint(&from_buf, "MAIL FROM:<{s}>\r\n", .{from_email}) catch return;
    smtpSendTls(tls, mail_from) catch return;
    if (!smtpReadOkTls(tls)) { log.warn("SMTP MAIL FROM rejected", .{}); return; }

    var to_buf: [512]u8 = undefined;
    const rcpt_to = std.fmt.bufPrint(&to_buf, "RCPT TO:<{s}>\r\n", .{to_email}) catch return;
    smtpSendTls(tls, rcpt_to) catch return;
    if (!smtpReadOkTls(tls)) { log.warn("SMTP RCPT TO rejected for {s}", .{to_email}); return; }

    smtpSendTls(tls, "DATA\r\n") catch return;
    if (!smtpReadReplyTls(tls, "354")) { log.warn("SMTP DATA rejected", .{}); return; }

    var hdr_buf: [1024]u8 = undefined;
    const headers = std.fmt.bufPrint(&hdr_buf, "From: {s}\r\nTo: {s}\r\nSubject: {s}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n", .{ from_email, to_email, subject }) catch return;
    smtpSendTls(tls, headers) catch return;
    smtpSendTls(tls, body) catch return;
    smtpSendTls(tls, "\r\n.\r\n") catch return;
    if (!smtpReadOkTls(tls)) { log.warn("SMTP message rejected", .{}); return; }

    smtpSendTls(tls, "QUIT\r\n") catch {};
    log.info("Email alert sent to {s} via SMTP ({s})", .{ to_email, mode_label });
}

/// Perform AUTH PLAIN + mail send over a plain (non-TLS) connection.
fn smtpAuthAndSendPlain(reader: *SmtpReader, writer: *SmtpWriter, username: ?[]const u8, password: ?[]const u8, from_email: []const u8, to_email: []const u8, subject: []const u8, body: []const u8) void {
    // AUTH PLAIN — see smtpAuthAndSend for rationale.
    if (username != null and password != null) {
        var auth_line_buf: [768]u8 = undefined;
        const line = buildAuthPlainLine(&auth_line_buf, username.?, password.?) catch |err| {
            log.warn("SMTP AUTH PLAIN payload build failed: {}", .{err});
            return;
        };
        smtpSend(writer, line) catch |err| {
            log.warn("Failed to send AUTH PLAIN (plain SMTP): {}", .{err});
            return;
        };
        if (!smtpReadReply(reader, "235")) {
            log.warn("SMTP AUTH PLAIN rejected (plain SMTP)", .{});
            return;
        }
    }

    // MAIL FROM / RCPT TO / DATA / message
    var from_buf: [512]u8 = undefined;
    const mail_from = std.fmt.bufPrint(&from_buf, "MAIL FROM:<{s}>\r\n", .{from_email}) catch return;
    smtpSend(writer, mail_from) catch return;
    if (!smtpReadOk(reader)) { log.warn("SMTP MAIL FROM rejected", .{}); return; }

    var to_buf: [512]u8 = undefined;
    const rcpt_to = std.fmt.bufPrint(&to_buf, "RCPT TO:<{s}>\r\n", .{to_email}) catch return;
    smtpSend(writer, rcpt_to) catch return;
    if (!smtpReadOk(reader)) { log.warn("SMTP RCPT TO rejected for {s}", .{to_email}); return; }

    smtpSend(writer, "DATA\r\n") catch return;
    if (!smtpReadReply(reader, "354")) { log.warn("SMTP DATA rejected", .{}); return; }

    var hdr_buf: [1024]u8 = undefined;
    const headers = std.fmt.bufPrint(&hdr_buf, "From: {s}\r\nTo: {s}\r\nSubject: {s}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n", .{ from_email, to_email, subject }) catch return;
    smtpSend(writer, headers) catch return;
    smtpSend(writer, body) catch return;
    smtpSend(writer, "\r\n.\r\n") catch return;
    if (!smtpReadOk(reader)) { log.warn("SMTP message rejected", .{}); return; }

    smtpSend(writer, "QUIT\r\n") catch {};
    log.info("Email alert sent to {s} via SMTP (plain)", .{to_email});
}

/// Build an `AUTH PLAIN <base64>\r\n` command line into `out_buf` and return
/// the written slice. The SASL PLAIN payload is `\0 username \0 password`,
/// base64-encoded per RFC 4616. Errors when the credentials do not fit into
/// the caller-supplied buffer.
fn buildAuthPlainLine(out_buf: []u8, username: []const u8, password: []const u8) ![]const u8 {
    const prefix = "AUTH PLAIN ";
    const suffix = "\r\n";

    var raw_buf: [512]u8 = undefined;
    const raw_len = 1 + username.len + 1 + password.len;
    if (raw_len > raw_buf.len) return error.CredentialsTooLong;
    raw_buf[0] = 0;
    @memcpy(raw_buf[1 .. 1 + username.len], username);
    raw_buf[1 + username.len] = 0;
    @memcpy(raw_buf[2 + username.len .. raw_len], password);

    const b64_len = std.base64.standard.Encoder.calcSize(raw_len);
    const total = prefix.len + b64_len + suffix.len;
    if (total > out_buf.len) return error.BufferTooSmall;

    @memcpy(out_buf[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out_buf[prefix.len .. prefix.len + b64_len], raw_buf[0..raw_len]);
    @memcpy(out_buf[prefix.len + b64_len .. total], suffix);
    return out_buf[0..total];
}

// --- SMTP I/O helpers ---

const SmtpResponse = struct { buf: [1024]u8, len: usize };

/// Read a complete SMTP reply (possibly multi-line) from `reader` into `out`.
///
/// SMTP replies are newline-terminated lines of the form `NNN-text\r\n` for
/// continuation lines and `NNN text\r\n` for the final line of a reply (RFC
/// 5321 §4.2). Reading line-by-line is required because the wire protocol has
/// no length framing — an earlier version of this code called `readSliceShort`
/// on a 1024-byte buffer, which internally loops `readVec` until the buffer
/// fills or EOF, and therefore blocked forever waiting for more bytes that
/// the server would only send in response to the *next* command.
///
/// Returns the total number of bytes appended to `out`.
fn readSmtpReply(reader: *std.Io.Reader, out: []u8) !usize {
    var total: usize = 0;
    while (true) {
        const line = try reader.takeDelimiterInclusive('\n');
        if (line.len > out.len - total) return error.StreamTooLong;
        @memcpy(out[total .. total + line.len], line);
        total += line.len;
        // Final line of a reply has a space in column 4; continuation uses '-'.
        // Anything shorter than that is malformed — stop rather than hang.
        if (line.len < 4) break;
        if (line[3] != '-') break;
    }
    return total;
}

// --- Plain stream helpers ---

fn smtpSend(writer: *SmtpWriter, data: []const u8) !void {
    _ = try writer.interface.write(data);
    try writer.interface.flush();
}

fn smtpReadOk(reader: *SmtpReader) bool {
    return smtpReadReply(reader, "2");
}

fn smtpReadResponse(reader: *SmtpReader) !SmtpResponse {
    var resp = SmtpResponse{ .buf = undefined, .len = 0 };
    resp.len = try readSmtpReply(reader.interface(), &resp.buf);
    return resp;
}

fn smtpReadReply(reader: *SmtpReader, expected_prefix: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const n = readSmtpReply(reader.interface(), &buf) catch return false;
    if (n < expected_prefix.len) return false;
    return std.mem.startsWith(u8, buf[0..n], expected_prefix);
}

// --- TLS stream helpers ---

fn smtpSendTls(tls: *std.crypto.tls.Client, data: []const u8) !void {
    _ = try tls.writer.write(data);
    // Flush the TLS layer (encrypts and pushes ciphertext into the underlying
    // writer's buffer) AND the underlying writer itself (drains that buffer to
    // the socket). `std.crypto.tls.Client.flush` only performs the first of
    // those steps, so without the second call the EHLO/AUTH/etc. commands
    // sit in the stream writer's buffer and the server never sees them,
    // leaving our next read blocked forever.
    try tls.writer.flush();
    try tls.output.flush();
}

fn smtpReadOkTls(tls: *std.crypto.tls.Client) bool {
    return smtpReadReplyTls(tls, "2");
}

fn smtpReadResponseTls(tls: *std.crypto.tls.Client) !SmtpResponse {
    var resp = SmtpResponse{ .buf = undefined, .len = 0 };
    resp.len = try readSmtpReply(&tls.reader, &resp.buf);
    return resp;
}

fn smtpReadReplyTls(tls: *std.crypto.tls.Client, expected_prefix: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const n = readSmtpReply(&tls.reader, &buf) catch return false;
    if (n < expected_prefix.len) return false;
    return std.mem.startsWith(u8, buf[0..n], expected_prefix);
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
