const std = @import("std");
const log = std.log;

/// Maximum size for the transformed payload buffer.
const max_payload_size = 64 * 1024;

/// Browser error report as received from the JavaScript SDK.
/// Required fields: type, message, stack.
/// Optional fields: url, user_agent, session_id, context (object), release, timestamp.
const BrowserErrorFields = struct {
    type: ?[]const u8,
    message: ?[]const u8,
    stack: ?[]const u8,
    url: ?[]const u8,
    user_agent: ?[]const u8,
    session_id: ?[]const u8,
    release: ?[]const u8,
    timestamp: ?[]const u8,
    environment: ?[]const u8,
};

/// Parse the browser error JSON body and validate required fields.
/// Returns the parsed fields or null if validation fails (error message set in detail_out).
fn parseAndValidate(body: []const u8, detail_out: *[]const u8) ?BrowserErrorFields {
    const value = std.json.parseFromSliceLeaky(std.json.Value, std.heap.page_allocator, body, .{}) catch {
        detail_out.* = "Invalid JSON";
        return null;
    };

    const obj = switch (value) {
        .object => |o| o,
        else => {
            detail_out.* = "Request body must be a JSON object";
            return null;
        },
    };

    const err_type = getStringField(obj, "type") orelse {
        detail_out.* = "Missing required field: type";
        return null;
    };

    const message = getStringField(obj, "message") orelse {
        detail_out.* = "Missing required field: message";
        return null;
    };

    const stack = getStringField(obj, "stack") orelse {
        detail_out.* = "Missing required field: stack";
        return null;
    };

    return BrowserErrorFields{
        .type = err_type,
        .message = message,
        .stack = stack,
        .url = getStringField(obj, "url"),
        .user_agent = getStringField(obj, "user_agent"),
        .session_id = getStringField(obj, "session_id"),
        .release = getStringField(obj, "release"),
        .timestamp = getStringField(obj, "timestamp"),
        .environment = getStringField(obj, "environment"),
    };
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Build the error-tracker JSON payload from browser error fields.
/// The error-tracker expects: project, exception_type, message, traceback,
/// and optionally: environment, request_url, request_method, extra.
fn buildPayload(
    buf: []u8,
    fields: BrowserErrorFields,
    project: []const u8,
    context_json: ?[]const u8,
) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    try writer.writeAll("{\"project\": ");
    try writeJsonString(writer, project);

    try writer.writeAll(", \"exception_type\": ");
    try writeJsonString(writer, fields.type orelse "Error");

    try writer.writeAll(", \"message\": ");
    try writeJsonString(writer, fields.message orelse "");

    try writer.writeAll(", \"traceback\": ");
    try writeJsonString(writer, fields.stack orelse "");

    // Environment: from fields.environment, or from context.environment, or default "prod"
    const environment = fields.environment orelse "prod";
    try writer.writeAll(", \"environment\": ");
    try writeJsonString(writer, environment);

    try writer.writeAll(", \"request_method\": \"BROWSER\"");

    if (fields.url) |url| {
        try writer.writeAll(", \"request_url\": ");
        try writeJsonString(writer, url);
    }

    // Build extra object with user_agent, session_id, and context fields
    try writer.writeAll(", \"extra\": {");
    var has_extra = false;

    if (fields.user_agent) |ua| {
        try writer.writeAll("\"user_agent\": ");
        try writeJsonString(writer, ua);
        has_extra = true;
    }

    if (fields.session_id) |sid| {
        if (has_extra) try writer.writeAll(", ");
        try writer.writeAll("\"session_id\": ");
        try writeJsonString(writer, sid);
        has_extra = true;
    }

    if (fields.release) |rel| {
        if (has_extra) try writer.writeAll(", ");
        try writer.writeAll("\"release\": ");
        try writeJsonString(writer, rel);
        has_extra = true;
    }

    if (fields.timestamp) |ts| {
        if (has_extra) try writer.writeAll(", ");
        try writer.writeAll("\"timestamp\": ");
        try writeJsonString(writer, ts);
        has_extra = true;
    }

    // Include raw context JSON if present
    if (context_json) |ctx| {
        if (has_extra) try writer.writeAll(", ");
        try writer.writeAll("\"context\": ");
        try writer.writeAll(ctx);
    }

    try writer.writeAll("}}");

    return buf[0..stream.pos];
}

/// Write a JSON-escaped string (with surrounding double quotes).
fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try std.fmt.format(writer, "\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

/// Extract the raw JSON value for the "context" field as a string,
/// if it's present and is an object.
fn extractContextJson(body: []const u8) ?[]const u8 {
    // Find "context" key in JSON and extract its raw value.
    // We parse the JSON and re-serialize the context field.
    const value = std.json.parseFromSliceLeaky(std.json.Value, std.heap.page_allocator, body, .{}) catch return null;
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const ctx_val = obj.get("context") orelse return null;
    switch (ctx_val) {
        .object => {},
        else => return null, // context must be an object
    }

    // Serialize the context value back to JSON
    var ctx_buf: [16384]u8 = undefined;
    var ctx_stream = std.io.fixedBufferStream(&ctx_buf);
    std.json.stringify(ctx_val, .{}, ctx_stream.writer()) catch return null;
    // We need to return a stable pointer — copy to page allocator
    const result = std.heap.page_allocator.alloc(u8, ctx_stream.pos) catch return null;
    @memcpy(result, ctx_buf[0..ctx_stream.pos]);
    return result;
}

/// Forward a browser error to the error-tracker service.
/// Returns the HTTP status code from the upstream, or null on failure.
fn forwardToErrorTracker(
    allocator: std.mem.Allocator,
    payload: []const u8,
    error_tracker_url: []const u8,
    error_tracker_api_key: []const u8,
) ?ForwardResult {
    // Build full URL: {error_tracker_url}/api/errors
    var url_buf: [1024]u8 = undefined;
    const full_url = std.fmt.bufPrint(&url_buf, "{s}/api/errors", .{error_tracker_url}) catch {
        log.warn("Error tracker URL too long", .{});
        return null;
    };

    const uri = std.Uri.parse(full_url) catch {
        log.warn("Failed to parse error tracker URL: {s}", .{full_url});
        return null;
    };

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var header_buf: [4096]u8 = undefined;
    var req = client.open(.POST, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-API-Key", .value = error_tracker_api_key },
        },
    }) catch |err| {
        log.warn("Failed to connect to error tracker: {}", .{err});
        return null;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    req.send() catch |err| {
        log.warn("Failed to send to error tracker: {}", .{err});
        return null;
    };
    req.writeAll(payload) catch |err| {
        log.warn("Failed to write error tracker payload: {}", .{err});
        return null;
    };
    req.finish() catch |err| {
        log.warn("Failed to finish error tracker request: {}", .{err});
        return null;
    };
    req.wait() catch |err| {
        log.warn("Failed to get error tracker response: {}", .{err});
        return null;
    };

    // Read response body
    var response_buf: [4096]u8 = undefined;
    const reader = req.reader();
    const response_len = reader.readAll(&response_buf) catch {
        // Even if we can't read the body, we have the status
        return ForwardResult{
            .status = req.response.status,
            .body = null,
        };
    };

    return ForwardResult{
        .status = req.response.status,
        .body = if (response_len > 0) response_buf[0..response_len] else null,
    };
}

const ForwardResult = struct {
    status: std.http.Status,
    body: ?[]const u8,
};

/// Handle POST /api/browser/errors
/// Parses the browser error, transforms it, and forwards to the error-tracker.
pub fn handleBrowserError(
    request: *std.http.Server.Request,
    project: []const u8,
    error_tracker_url: []const u8,
    error_tracker_api_key: []const u8,
) !?[]const u8 {
    // Read the request body
    const reader = try request.reader();
    var body_buf: [max_payload_size]u8 = undefined;
    const body_len = reader.readAll(&body_buf) catch {
        return "Failed to read request body";
    };
    const body = body_buf[0..body_len];

    if (body_len == 0) {
        return "Empty request body";
    }

    // Parse and validate
    var detail: []const u8 = "";
    const fields = parseAndValidate(body, &detail) orelse {
        // Send 400 with detail
        var err_buf: [256]u8 = undefined;
        const err_body = std.fmt.bufPrint(&err_buf, "{{\"detail\": \"{s}\"}}", .{detail}) catch
            "{\"detail\": \"Invalid request\"}";
        try sendResponse(request, .bad_request, err_body, null);
        return null; // already handled
    };

    // Extract context JSON if present
    const context_json = extractContextJson(body);

    // Build transformed payload
    var payload_buf: [max_payload_size]u8 = undefined;
    const payload = buildPayload(&payload_buf, fields, project, context_json) catch {
        try sendResponse(request, .internal_server_error, "{\"detail\": \"Failed to build payload\"}", null);
        return null;
    };

    // Forward to error-tracker
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const result = forwardToErrorTracker(
        arena.allocator(),
        payload,
        error_tracker_url,
        error_tracker_api_key,
    );

    if (result) |res| {
        // Map upstream status to our response
        const status = res.status;
        if (status == .created or status == .ok) {
            // Forward the upstream response body
            const response_body = res.body orelse "{\"status\": \"accepted\"}";
            try sendResponse(request, status, response_body, null);
        } else {
            log.warn("Error tracker returned status {d}", .{@intFromEnum(status)});
            try sendResponse(request, .bad_gateway, "{\"detail\": \"Upstream error\"}", null);
        }
    } else {
        log.warn("Failed to forward error to error tracker", .{});
        try sendResponse(request, .bad_gateway, "{\"detail\": \"Upstream error\"}", null);
    }

    return null; // response already sent
}

/// Handle POST /api/browser/errors with CORS headers.
pub fn handleBrowserErrorWithCors(
    request: *std.http.Server.Request,
    project: []const u8,
    error_tracker_url: []const u8,
    error_tracker_api_key: []const u8,
    cors_origin: ?[]const u8,
) !void {
    // Read the request body
    const reader = try request.reader();
    var body_buf: [max_payload_size]u8 = undefined;
    const body_len = reader.readAll(&body_buf) catch {
        try sendResponse(request, .bad_request, "{\"detail\": \"Failed to read request body\"}", cors_origin);
        return;
    };
    const body = body_buf[0..body_len];

    if (body_len == 0) {
        try sendResponse(request, .bad_request, "{\"detail\": \"Empty request body\"}", cors_origin);
        return;
    }

    // Check method
    if (request.head.method != .POST) {
        try sendResponse(request, .method_not_allowed, "{\"detail\": \"Method not allowed\"}", cors_origin);
        return;
    }

    // Parse and validate
    var detail: []const u8 = "";
    const fields = parseAndValidate(body, &detail) orelse {
        var err_buf: [256]u8 = undefined;
        const err_body = std.fmt.bufPrint(&err_buf, "{{\"detail\": \"{s}\"}}", .{detail}) catch
            "{\"detail\": \"Invalid request\"}";
        try sendResponse(request, .bad_request, err_body, cors_origin);
        return;
    };

    // Extract context JSON if present
    const context_json = extractContextJson(body);

    // Build transformed payload
    var payload_buf: [max_payload_size]u8 = undefined;
    const payload = buildPayload(&payload_buf, fields, project, context_json) catch {
        try sendResponse(request, .internal_server_error, "{\"detail\": \"Failed to build payload\"}", cors_origin);
        return;
    };

    // Forward to error-tracker
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const result = forwardToErrorTracker(
        arena.allocator(),
        payload,
        error_tracker_url,
        error_tracker_api_key,
    );

    if (result) |res| {
        const status = res.status;
        if (status == .created or status == .ok) {
            const response_body = res.body orelse "{\"status\": \"accepted\"}";
            try sendResponse(request, status, response_body, cors_origin);
        } else {
            log.warn("Error tracker returned status {d}", .{@intFromEnum(status)});
            try sendResponse(request, .bad_gateway, "{\"detail\": \"Upstream error\"}", cors_origin);
        }
    } else {
        log.warn("Failed to forward error to error tracker", .{});
        try sendResponse(request, .bad_gateway, "{\"detail\": \"Upstream error\"}", cors_origin);
    }
}

/// Send a JSON response, optionally with CORS headers.
fn sendResponse(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    cors_origin: ?[]const u8,
) !void {
    if (cors_origin) |origin| {
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
    } else {
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
}

// ============================================================
// Unit Tests
// ============================================================

test "parseAndValidate succeeds with all required fields" {
    const body =
        \\{"type": "TypeError", "message": "x is not a function", "stack": "TypeError: x is not a function\n    at foo (app.js:10:5)"}
    ;
    var detail: []const u8 = "";
    const fields = parseAndValidate(body, &detail);
    try std.testing.expect(fields != null);
    const f = fields.?;
    try std.testing.expectEqualStrings("TypeError", f.type.?);
    try std.testing.expectEqualStrings("x is not a function", f.message.?);
    try std.testing.expect(f.stack != null);
    try std.testing.expect(f.url == null);
    try std.testing.expect(f.user_agent == null);
    try std.testing.expect(f.session_id == null);
}

test "parseAndValidate fails with missing type" {
    const body =
        \\{"message": "x is not a function", "stack": "at foo (app.js:10:5)"}
    ;
    var detail: []const u8 = "";
    const fields = parseAndValidate(body, &detail);
    try std.testing.expect(fields == null);
    try std.testing.expectEqualStrings("Missing required field: type", detail);
}

test "parseAndValidate fails with missing message" {
    const body =
        \\{"type": "TypeError", "stack": "at foo (app.js:10:5)"}
    ;
    var detail: []const u8 = "";
    const fields = parseAndValidate(body, &detail);
    try std.testing.expect(fields == null);
    try std.testing.expectEqualStrings("Missing required field: message", detail);
}

test "parseAndValidate fails with missing stack" {
    const body =
        \\{"type": "TypeError", "message": "x is not a function"}
    ;
    var detail: []const u8 = "";
    const fields = parseAndValidate(body, &detail);
    try std.testing.expect(fields == null);
    try std.testing.expectEqualStrings("Missing required field: stack", detail);
}

test "parseAndValidate fails with invalid JSON" {
    const body = "not json at all";
    var detail: []const u8 = "";
    const fields = parseAndValidate(body, &detail);
    try std.testing.expect(fields == null);
    try std.testing.expectEqualStrings("Invalid JSON", detail);
}

test "parseAndValidate fails with non-object JSON" {
    const body = "[1, 2, 3]";
    var detail: []const u8 = "";
    const fields = parseAndValidate(body, &detail);
    try std.testing.expect(fields == null);
    try std.testing.expectEqualStrings("Request body must be a JSON object", detail);
}

test "parseAndValidate parses optional fields" {
    const body =
        \\{"type": "Error", "message": "test", "stack": "at main (index.js:1:1)", "url": "https://example.com", "user_agent": "Mozilla/5.0", "session_id": "abc-123", "release": "1.0.0", "timestamp": "2025-01-01T00:00:00Z"}
    ;
    var detail: []const u8 = "";
    const fields = parseAndValidate(body, &detail);
    try std.testing.expect(fields != null);
    const f = fields.?;
    try std.testing.expectEqualStrings("https://example.com", f.url.?);
    try std.testing.expectEqualStrings("Mozilla/5.0", f.user_agent.?);
    try std.testing.expectEqualStrings("abc-123", f.session_id.?);
    try std.testing.expectEqualStrings("1.0.0", f.release.?);
    try std.testing.expectEqualStrings("2025-01-01T00:00:00Z", f.timestamp.?);
}

test "buildPayload produces valid JSON" {
    const fields = BrowserErrorFields{
        .type = "TypeError",
        .message = "x is not a function",
        .stack = "TypeError: x is not a function\n    at foo (app.js:10:5)",
        .url = "https://example.com/page",
        .user_agent = "Mozilla/5.0",
        .session_id = "sess-123",
        .release = "1.0.0",
        .timestamp = null,
        .environment = "staging",
    };

    var buf: [max_payload_size]u8 = undefined;
    const payload = try buildPayload(&buf, fields, "myproject", null);

    // Verify it's valid JSON by parsing it
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("myproject", obj.get("project").?.string);
    try std.testing.expectEqualStrings("TypeError", obj.get("exception_type").?.string);
    try std.testing.expectEqualStrings("x is not a function", obj.get("message").?.string);
    try std.testing.expectEqualStrings("BROWSER", obj.get("request_method").?.string);
    try std.testing.expectEqualStrings("https://example.com/page", obj.get("request_url").?.string);
    try std.testing.expectEqualStrings("staging", obj.get("environment").?.string);

    // Check extra fields
    const extra = obj.get("extra").?.object;
    try std.testing.expectEqualStrings("Mozilla/5.0", extra.get("user_agent").?.string);
    try std.testing.expectEqualStrings("sess-123", extra.get("session_id").?.string);
    try std.testing.expectEqualStrings("1.0.0", extra.get("release").?.string);
}

test "buildPayload defaults environment to prod" {
    const fields = BrowserErrorFields{
        .type = "Error",
        .message = "test",
        .stack = "at main",
        .url = null,
        .user_agent = null,
        .session_id = null,
        .release = null,
        .timestamp = null,
        .environment = null,
    };

    var buf: [max_payload_size]u8 = undefined;
    const payload = try buildPayload(&buf, fields, "proj", null);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("prod", obj.get("environment").?.string);
    // No request_url when url is null
    try std.testing.expect(obj.get("request_url") == null);
}

test "buildPayload includes context JSON" {
    const fields = BrowserErrorFields{
        .type = "Error",
        .message = "test",
        .stack = "at main",
        .url = null,
        .user_agent = null,
        .session_id = null,
        .release = null,
        .timestamp = null,
        .environment = null,
    };

    var buf: [max_payload_size]u8 = undefined;
    const payload = try buildPayload(&buf, fields, "proj", "{\"key\":\"value\"}");

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const extra = obj.get("extra").?.object;
    const ctx = extra.get("context").?.object;
    try std.testing.expectEqualStrings("value", ctx.get("key").?.string);
}

test "buildPayload escapes special characters" {
    const fields = BrowserErrorFields{
        .type = "Error",
        .message = "line1\nline2\ttab\"quote",
        .stack = "at main\\foo",
        .url = null,
        .user_agent = null,
        .session_id = null,
        .release = null,
        .timestamp = null,
        .environment = null,
    };

    var buf: [max_payload_size]u8 = undefined;
    const payload = try buildPayload(&buf, fields, "proj", null);

    // Should be valid JSON despite special chars
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("line1\nline2\ttab\"quote", obj.get("message").?.string);
    try std.testing.expectEqualStrings("at main\\foo", obj.get("traceback").?.string);
}

test "extractContextJson returns null for missing context" {
    const body =
        \\{"type": "Error", "message": "test", "stack": "at main"}
    ;
    try std.testing.expect(extractContextJson(body) == null);
}

test "extractContextJson returns null for non-object context" {
    const body =
        \\{"type": "Error", "message": "test", "stack": "at main", "context": "string"}
    ;
    try std.testing.expect(extractContextJson(body) == null);
}

test "extractContextJson extracts object context" {
    const body =
        \\{"type": "Error", "message": "test", "stack": "at main", "context": {"env": "prod", "version": "1.0"}}
    ;
    const ctx = extractContextJson(body);
    try std.testing.expect(ctx != null);
    // Parse back to verify
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ctx.?, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("prod", obj.get("env").?.string);
    try std.testing.expectEqualStrings("1.0", obj.get("version").?.string);
}

test "writeJsonString escapes correctly" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeJsonString(stream.writer(), "hello \"world\"\nnewline\\backslash");
    const result = buf[0..stream.pos];
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nnewline\\\\backslash\"", result);
}
