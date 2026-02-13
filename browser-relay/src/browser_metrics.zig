const std = @import("std");
const log = std.log;

/// Maximum size for the request/response payload buffer.
const max_payload_size = 64 * 1024;

/// Maximum number of metrics in a single batch.
const max_metrics_batch = 1000;

/// Handle POST /api/browser/metrics with CORS headers.
/// Parses browser metrics, enriches labels, and forwards to metrics-collector.
pub fn handleBrowserMetricsWithCors(
    request: *std.http.Server.Request,
    project: []const u8,
    metrics_collector_url: []const u8,
    metrics_collector_api_key: []const u8,
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

    // Parse and validate the browser metrics payload
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail) orelse {
        var err_buf: [256]u8 = undefined;
        const err_body = std.fmt.bufPrint(&err_buf, "{{\"detail\": \"{s}\"}}", .{detail}) catch
            "{\"detail\": \"Invalid request\"}";
        try sendResponse(request, .bad_request, err_body, cors_origin);
        return;
    };

    // Build the metrics-collector payload (JSON array with enriched labels)
    var payload_buf: [max_payload_size]u8 = undefined;
    const payload = buildPayload(&payload_buf, parsed, project) catch {
        try sendResponse(request, .internal_server_error, "{\"detail\": \"Failed to build payload\"}", cors_origin);
        return;
    };

    // Forward to metrics-collector
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const result = forwardToMetricsCollector(
        arena.allocator(),
        payload,
        metrics_collector_url,
        metrics_collector_api_key,
    );

    if (result) |res| {
        const status = res.status;
        if (status == .accepted or status == .ok or status == .created) {
            // Return 202 with count
            var resp_buf: [128]u8 = undefined;
            const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"status\": \"accepted\", \"count\": {d}}}", .{parsed.metrics_count}) catch
                "{\"status\": \"accepted\", \"count\": 0}";
            try sendResponse(request, .accepted, resp_json, cors_origin);
        } else {
            log.warn("Metrics collector returned status {d}", .{@intFromEnum(status)});
            try sendResponse(request, .bad_gateway, "{\"detail\": \"Upstream error\"}", cors_origin);
        }
    } else {
        log.warn("Failed to forward metrics to metrics collector", .{});
        try sendResponse(request, .bad_gateway, "{\"detail\": \"Upstream error\"}", cors_origin);
    }
}

/// Parsed browser metrics payload.
const ParsedMetrics = struct {
    /// The original JSON array of metrics from the parsed body.
    metrics: std.json.Array,
    /// Number of metrics in the batch.
    metrics_count: usize,
    /// Optional top-level session_id.
    session_id: ?[]const u8,
    /// Optional top-level url (page URL).
    url: ?[]const u8,
};

/// Parse and validate the browser metrics JSON body.
/// Expected format:
/// {
///   "metrics": [{"name": "...", "type": "counter"|"histogram"|"gauge", "value": N, ...}, ...],
///   "session_id": "...",  // optional
///   "url": "..."          // optional
/// }
fn parseAndValidate(body: []const u8, detail_out: *[]const u8) ?ParsedMetrics {
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

    // Get the "metrics" array
    const metrics_val = obj.get("metrics") orelse {
        detail_out.* = "Missing required field: metrics";
        return null;
    };

    const metrics_array = switch (metrics_val) {
        .array => |a| a,
        else => {
            detail_out.* = "Field 'metrics' must be an array";
            return null;
        },
    };

    if (metrics_array.items.len == 0) {
        detail_out.* = "Metrics array must not be empty";
        return null;
    }

    if (metrics_array.items.len > max_metrics_batch) {
        detail_out.* = "Metrics batch exceeds maximum of 1000 items";
        return null;
    }

    // Validate each metric object
    for (metrics_array.items) |item| {
        const metric_obj = switch (item) {
            .object => |o| o,
            else => {
                detail_out.* = "Each metric must be a JSON object";
                return null;
            },
        };

        // Required: name (string)
        const name = getStringField(metric_obj, "name") orelse {
            detail_out.* = "Missing required field: name";
            return null;
        };
        if (name.len == 0 or name.len > 200) {
            detail_out.* = "Field 'name' must be 1-200 characters";
            return null;
        }

        // Required: type (string, must be counter/histogram/gauge)
        const metric_type = getStringField(metric_obj, "type") orelse {
            detail_out.* = "Missing required field: type";
            return null;
        };
        if (!isValidType(metric_type)) {
            detail_out.* = "Field 'type' must be 'counter', 'histogram', or 'gauge'";
            return null;
        }

        // Required: value (number)
        if (!hasNumberField(metric_obj, "value")) {
            detail_out.* = "Missing required field: value";
            return null;
        }
    }

    return ParsedMetrics{
        .metrics = metrics_array,
        .metrics_count = metrics_array.items.len,
        .session_id = getStringField(obj, "session_id"),
        .url = getStringField(obj, "url"),
    };
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn hasNumberField(obj: std.json.ObjectMap, key: []const u8) bool {
    const val = obj.get(key) orelse return false;
    return switch (val) {
        .integer, .float => true,
        else => false,
    };
}

fn isValidType(t: []const u8) bool {
    return std.mem.eql(u8, t, "counter") or
        std.mem.eql(u8, t, "histogram") or
        std.mem.eql(u8, t, "gauge");
}

/// Extract the URL path from a full URL string, stripping query params and fragment.
/// e.g. "https://example.com/page?foo=bar#section" -> "/page"
fn extractUrlPath(url: []const u8) []const u8 {
    // Find the path start (after scheme://host)
    var path_start: usize = 0;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const after_scheme = scheme_end + 3;
        if (std.mem.indexOfScalarPos(u8, url, after_scheme, '/')) |slash| {
            path_start = slash;
        } else {
            return "/"; // URL is just "https://example.com" with no path
        }
    }
    // If no scheme, assume relative path starting from beginning

    const path_slice = url[path_start..];

    // Strip query params
    const before_query = if (std.mem.indexOfScalar(u8, path_slice, '?')) |q|
        path_slice[0..q]
    else
        path_slice;

    // Strip fragment
    const before_fragment = if (std.mem.indexOfScalar(u8, before_query, '#')) |f|
        before_query[0..f]
    else
        before_query;

    if (before_fragment.len == 0) return "/";
    return before_fragment;
}

/// Build the metrics-collector payload: a JSON array of metric objects
/// with enriched labels (project, source, session_id, page).
fn buildPayload(buf: []u8, parsed: ParsedMetrics, project: []const u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    try writer.writeByte('[');

    for (parsed.metrics.items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');

        const metric_obj = item.object;

        // Write required fields
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, getStringField(metric_obj, "name").?);

        try writer.writeAll(",\"type\":");
        try writeJsonString(writer, getStringField(metric_obj, "type").?);

        try writer.writeAll(",\"value\":");
        const value_entry = metric_obj.get("value").?;
        switch (value_entry) {
            .integer => |v| try std.fmt.format(writer, "{d}", .{v}),
            .float => |v| try std.fmt.format(writer, "{d}", .{v}),
            else => unreachable, // validated above
        }

        // Build enriched labels object
        try writer.writeAll(",\"labels\":{");

        // Always add project and source labels
        try writer.writeAll("\"project\":");
        try writeJsonString(writer, project);
        try writer.writeAll(",\"source\":\"browser\"");

        // Add session_id if present
        if (parsed.session_id) |sid| {
            try writer.writeAll(",\"session_id\":");
            try writeJsonString(writer, sid);
        }

        // Add page label from URL (path only)
        if (parsed.url) |url| {
            const path = extractUrlPath(url);
            try writer.writeAll(",\"page\":");
            try writeJsonString(writer, path);
        }

        // Merge in any existing labels from the metric
        if (metric_obj.get("labels")) |labels_val| {
            switch (labels_val) {
                .object => |labels_obj| {
                    var label_iter = labels_obj.iterator();
                    while (label_iter.next()) |entry| {
                        try writer.writeByte(',');
                        try writeJsonString(writer, entry.key_ptr.*);
                        try writer.writeByte(':');
                        switch (entry.value_ptr.*) {
                            .string => |s| try writeJsonString(writer, s),
                            .integer => |v| try std.fmt.format(writer, "{d}", .{v}),
                            .float => |v| try std.fmt.format(writer, "{d}", .{v}),
                            .bool => |v| try writer.writeAll(if (v) "true" else "false"),
                            else => try writer.writeAll("null"),
                        }
                    }
                },
                else => {},
            }
        }

        try writer.writeByte('}');

        // Include timestamp if present
        if (getStringField(metric_obj, "timestamp")) |ts| {
            try writer.writeAll(",\"timestamp\":");
            try writeJsonString(writer, ts);
        }

        try writer.writeByte('}');
    }

    try writer.writeByte(']');

    return buf[0..stream.pos];
}

/// Write a JSON-escaped string with surrounding double quotes.
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

/// Forward metrics payload to the metrics-collector service.
fn forwardToMetricsCollector(
    allocator: std.mem.Allocator,
    payload: []const u8,
    metrics_collector_url: []const u8,
    metrics_collector_api_key: []const u8,
) ?ForwardResult {
    var url_buf: [1024]u8 = undefined;
    const full_url = std.fmt.bufPrint(&url_buf, "{s}/api/metrics", .{metrics_collector_url}) catch {
        log.warn("Metrics collector URL too long", .{});
        return null;
    };

    const uri = std.Uri.parse(full_url) catch {
        log.warn("Failed to parse metrics collector URL: {s}", .{full_url});
        return null;
    };

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var header_buf: [4096]u8 = undefined;
    var req = client.open(.POST, uri, .{
        .server_header_buffer = &header_buf,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-API-Key", .value = metrics_collector_api_key },
        },
    }) catch |err| {
        log.warn("Failed to connect to metrics collector: {}", .{err});
        return null;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    req.send() catch |err| {
        log.warn("Failed to send to metrics collector: {}", .{err});
        return null;
    };
    req.writeAll(payload) catch |err| {
        log.warn("Failed to write metrics collector payload: {}", .{err});
        return null;
    };
    req.finish() catch |err| {
        log.warn("Failed to finish metrics collector request: {}", .{err});
        return null;
    };
    req.wait() catch |err| {
        log.warn("Failed to get metrics collector response: {}", .{err});
        return null;
    };

    return ForwardResult{
        .status = req.response.status,
    };
}

const ForwardResult = struct {
    status: std.http.Status,
};

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

test "parseAndValidate succeeds with valid metrics" {
    const body =
        \\{"metrics": [{"name": "web_vitals_lcp", "type": "histogram", "value": 2500}]}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(@as(usize, 1), parsed.?.metrics_count);
    try std.testing.expect(parsed.?.session_id == null);
    try std.testing.expect(parsed.?.url == null);
}

test "parseAndValidate succeeds with multiple metrics and optional fields" {
    const body =
        \\{"metrics": [{"name": "lcp", "type": "histogram", "value": 2500}, {"name": "cls", "type": "gauge", "value": 0.1}], "session_id": "abc-123", "url": "https://example.com/page?q=1"}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(@as(usize, 2), parsed.?.metrics_count);
    try std.testing.expectEqualStrings("abc-123", parsed.?.session_id.?);
    try std.testing.expectEqualStrings("https://example.com/page?q=1", parsed.?.url.?);
}

test "parseAndValidate fails with missing metrics field" {
    const body =
        \\{"session_id": "abc"}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed == null);
    try std.testing.expectEqualStrings("Missing required field: metrics", detail);
}

test "parseAndValidate fails with non-array metrics" {
    const body =
        \\{"metrics": "not an array"}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed == null);
    try std.testing.expectEqualStrings("Field 'metrics' must be an array", detail);
}

test "parseAndValidate fails with empty metrics array" {
    const body =
        \\{"metrics": []}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed == null);
    try std.testing.expectEqualStrings("Metrics array must not be empty", detail);
}

test "parseAndValidate fails with missing name" {
    const body =
        \\{"metrics": [{"type": "counter", "value": 1}]}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed == null);
    try std.testing.expectEqualStrings("Missing required field: name", detail);
}

test "parseAndValidate fails with missing type" {
    const body =
        \\{"metrics": [{"name": "test", "value": 1}]}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed == null);
    try std.testing.expectEqualStrings("Missing required field: type", detail);
}

test "parseAndValidate fails with invalid type" {
    const body =
        \\{"metrics": [{"name": "test", "type": "invalid", "value": 1}]}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed == null);
    try std.testing.expectEqualStrings("Field 'type' must be 'counter', 'histogram', or 'gauge'", detail);
}

test "parseAndValidate fails with missing value" {
    const body =
        \\{"metrics": [{"name": "test", "type": "counter"}]}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed == null);
    try std.testing.expectEqualStrings("Missing required field: value", detail);
}

test "parseAndValidate fails with invalid JSON" {
    const body = "not json";
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail);
    try std.testing.expect(parsed == null);
    try std.testing.expectEqualStrings("Invalid JSON", detail);
}

test "extractUrlPath extracts path from full URL" {
    try std.testing.expectEqualStrings("/page", extractUrlPath("https://example.com/page"));
    try std.testing.expectEqualStrings("/page", extractUrlPath("https://example.com/page?q=1"));
    try std.testing.expectEqualStrings("/page", extractUrlPath("https://example.com/page#section"));
    try std.testing.expectEqualStrings("/page", extractUrlPath("https://example.com/page?q=1#s"));
    try std.testing.expectEqualStrings("/a/b/c", extractUrlPath("https://example.com/a/b/c"));
    try std.testing.expectEqualStrings("/", extractUrlPath("https://example.com"));
}

test "extractUrlPath handles relative paths" {
    try std.testing.expectEqualStrings("/page", extractUrlPath("/page"));
    try std.testing.expectEqualStrings("/page", extractUrlPath("/page?q=1"));
    try std.testing.expectEqualStrings("/", extractUrlPath("/"));
}

test "buildPayload produces valid JSON with enriched labels" {
    const body =
        \\{"metrics": [{"name": "web_vitals_lcp", "type": "histogram", "value": 2500, "labels": {"custom": "val"}}], "session_id": "sess-1", "url": "https://example.com/dashboard?tab=1"}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail).?;

    var buf: [max_payload_size]u8 = undefined;
    const payload = try buildPayload(&buf, parsed, "myproject");

    // Verify it's valid JSON
    const result = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer result.deinit();

    const arr = result.value.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);

    const metric = arr.items[0].object;
    try std.testing.expectEqualStrings("web_vitals_lcp", metric.get("name").?.string);
    try std.testing.expectEqualStrings("histogram", metric.get("type").?.string);

    const labels = metric.get("labels").?.object;
    try std.testing.expectEqualStrings("myproject", labels.get("project").?.string);
    try std.testing.expectEqualStrings("browser", labels.get("source").?.string);
    try std.testing.expectEqualStrings("sess-1", labels.get("session_id").?.string);
    try std.testing.expectEqualStrings("/dashboard", labels.get("page").?.string);
    try std.testing.expectEqualStrings("val", labels.get("custom").?.string);
}

test "buildPayload without optional fields" {
    const body =
        \\{"metrics": [{"name": "clicks", "type": "counter", "value": 1}]}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail).?;

    var buf: [max_payload_size]u8 = undefined;
    const payload = try buildPayload(&buf, parsed, "proj");

    const result = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer result.deinit();

    const arr = result.value.array;
    const metric = arr.items[0].object;
    const labels = metric.get("labels").?.object;
    try std.testing.expectEqualStrings("proj", labels.get("project").?.string);
    try std.testing.expectEqualStrings("browser", labels.get("source").?.string);
    // No session_id or page labels
    try std.testing.expect(labels.get("session_id") == null);
    try std.testing.expect(labels.get("page") == null);
}

test "buildPayload preserves timestamp" {
    const body =
        \\{"metrics": [{"name": "lcp", "type": "histogram", "value": 2500, "timestamp": "2025-01-20T10:00:00Z"}]}
    ;
    var detail: []const u8 = "";
    const parsed = parseAndValidate(body, &detail).?;

    var buf: [max_payload_size]u8 = undefined;
    const payload = try buildPayload(&buf, parsed, "proj");

    const result = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer result.deinit();

    const metric = result.value.array.items[0].object;
    try std.testing.expectEqualStrings("2025-01-20T10:00:00Z", metric.get("timestamp").?.string);
}

test "writeJsonString escapes correctly" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeJsonString(stream.writer(), "hello \"world\"\nnewline");
    const result = buf[0..stream.pos];
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nnewline\"", result);
}
