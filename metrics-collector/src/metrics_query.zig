const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// Query parameters for metrics retrieval.
pub const QueryParams = struct {
    name: ?[]const u8,
    period: []const u8, // "1h", "24h", "7d", "30d"
    resolution: []const u8, // "minute", "hour", "auto"
    labels: ?[]const u8, // raw labels filter string e.g. "method:GET,status:200"
};

/// Parse query parameters from the request target URL.
pub fn parseQueryParams(target: []const u8) QueryParams {
    var params = QueryParams{
        .name = null,
        .period = "24h",
        .resolution = "auto",
        .labels = null,
    };

    const query_start = std.mem.indexOf(u8, target, "?") orelse return params;
    const query_string = target[query_start + 1 ..];

    var pairs_iter = std.mem.splitScalar(u8, query_string, '&');
    while (pairs_iter.next()) |pair| {
        const eq_pos = std.mem.indexOf(u8, pair, "=") orelse continue;
        const key = pair[0..eq_pos];
        const value = pair[eq_pos + 1 ..];

        if (std.mem.eql(u8, key, "name")) {
            if (value.len > 0) params.name = value;
        } else if (std.mem.eql(u8, key, "period")) {
            if (isValidPeriod(value)) params.period = value;
        } else if (std.mem.eql(u8, key, "resolution")) {
            if (isValidResolution(value)) params.resolution = value;
        } else if (std.mem.eql(u8, key, "labels")) {
            if (value.len > 0) params.labels = value;
        }
    }

    return params;
}

fn isValidPeriod(p: []const u8) bool {
    return std.mem.eql(u8, p, "1h") or
        std.mem.eql(u8, p, "24h") or
        std.mem.eql(u8, p, "7d") or
        std.mem.eql(u8, p, "30d");
}

fn isValidResolution(r: []const u8) bool {
    return std.mem.eql(u8, r, "minute") or
        std.mem.eql(u8, r, "hour") or
        std.mem.eql(u8, r, "auto");
}

/// Resolve the effective resolution based on auto logic.
/// Auto: minute for <=24h, hour for >24h.
fn resolveResolution(period: []const u8, resolution: []const u8) []const u8 {
    if (!std.mem.eql(u8, resolution, "auto")) return resolution;

    // Auto: minute for 1h and 24h, hour for 7d and 30d
    if (std.mem.eql(u8, period, "1h") or std.mem.eql(u8, period, "24h")) {
        return "minute";
    }
    return "hour";
}

/// Get the SQLite time offset string for a given period.
fn periodToOffset(period: []const u8) []const u8 {
    if (std.mem.eql(u8, period, "1h")) return "-1 hours";
    if (std.mem.eql(u8, period, "24h")) return "-24 hours";
    if (std.mem.eql(u8, period, "7d")) return "-7 days";
    if (std.mem.eql(u8, period, "30d")) return "-30 days";
    return "-24 hours";
}

/// Query aggregated metrics and write JSON response to the writer.
/// Returns the number of data points written.
pub fn queryMetrics(
    db: *sqlite.Database,
    params: *const QueryParams,
    writer: *std.ArrayList(u8).Writer,
) !usize {
    const name = params.name orelse return error.MissingName;
    const effective_resolution = resolveResolution(params.period, params.resolution);
    const offset = periodToOffset(params.period);

    // Build SQL query
    var sql_buf: [512]u8 = undefined;
    var sql_len: usize = 0;

    // Base query
    const base = "SELECT bucket, count, sum, min, max, avg, p50, p95, p99 FROM metrics_aggregated " ++
        "WHERE name = ? AND resolution = ? AND bucket >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '";
    @memcpy(sql_buf[sql_len .. sql_len + base.len], base);
    sql_len += base.len;

    // Add offset
    @memcpy(sql_buf[sql_len .. sql_len + offset.len], offset);
    sql_len += offset.len;

    const rest_no_labels = "') ORDER BY bucket ASC;";
    const rest_with_labels = "') AND labels = ? ORDER BY bucket ASC;";

    if (params.labels != null) {
        @memcpy(sql_buf[sql_len .. sql_len + rest_with_labels.len], rest_with_labels);
        sql_len += rest_with_labels.len;
    } else {
        @memcpy(sql_buf[sql_len .. sql_len + rest_no_labels.len], rest_no_labels);
        sql_len += rest_no_labels.len;
    }

    // Null-terminate
    sql_buf[sql_len] = 0;
    const sql_z: [*:0]const u8 = @ptrCast(sql_buf[0..sql_len :0]);

    const stmt = try db.prepare(sql_z);
    defer stmt.deinit();

    try stmt.bindText(1, name);
    try stmt.bindText(2, effective_resolution);

    if (params.labels) |labels| {
        // Convert "key:value,key2:value2" format to JSON {"key":"value","key2":"value2"}
        var label_json_buf: [512]u8 = undefined;
        const label_json = labelsToJson(labels, &label_json_buf) catch {
            // If conversion fails, just use the raw string
            try stmt.bindText(3, labels);
            return queryAndWrite(stmt, writer, params, effective_resolution);
        };
        try stmt.bindText(3, label_json);
    }

    return queryAndWrite(stmt, writer, params, effective_resolution);
}

fn queryAndWrite(
    stmt: sqlite.Statement,
    writer: *std.ArrayList(u8).Writer,
    params: *const QueryParams,
    effective_resolution: []const u8,
) !usize {
    try writer.writeAll("{\"name\": \"");
    try writeJsonEscaped(writer, params.name orelse "");
    try writer.writeAll("\", \"resolution\": \"");
    try writer.writeAll(effective_resolution);
    try writer.writeAll("\", \"period\": \"");
    try writer.writeAll(params.period);
    try writer.writeAll("\", \"data\": [");

    var iter = stmt.query();
    var count: usize = 0;
    while (iter.next()) |row| {
        if (count > 0) try writer.writeAll(",");
        try writer.writeAll("{\"bucket\": \"");
        try writeJsonEscaped(writer, row.text(0) orelse "");
        try writer.writeAll("\"");

        // count
        try writer.writeAll(", \"count\": ");
        var int_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&int_buf, "{d}", .{row.int(1)}) catch "0";
        try writer.writeAll(count_str);

        // sum
        try writer.writeAll(", \"sum\": ");
        var float_buf: [32]u8 = undefined;
        const sum_str = std.fmt.bufPrint(&float_buf, "{d:.6}", .{row.float(2)}) catch "0";
        try writer.writeAll(sum_str);

        // min
        try writer.writeAll(", \"min\": ");
        const min_str = std.fmt.bufPrint(&float_buf, "{d:.6}", .{row.float(3)}) catch "0";
        try writer.writeAll(min_str);

        // max
        try writer.writeAll(", \"max\": ");
        const max_str = std.fmt.bufPrint(&float_buf, "{d:.6}", .{row.float(4)}) catch "0";
        try writer.writeAll(max_str);

        // avg
        try writer.writeAll(", \"avg\": ");
        const avg_str = std.fmt.bufPrint(&float_buf, "{d:.6}", .{row.float(5)}) catch "0";
        try writer.writeAll(avg_str);

        // p50, p95, p99 (nullable)
        try writeNullableFloat(writer, ", \"p50\": ", row, 6);
        try writeNullableFloat(writer, ", \"p95\": ", row, 7);
        try writeNullableFloat(writer, ", \"p99\": ", row, 8);

        try writer.writeAll("}");
        count += 1;
    }

    try writer.writeAll("]}");
    return count;
}

fn writeNullableFloat(writer: *std.ArrayList(u8).Writer, prefix: []const u8, row: sqlite.Row, col: usize) !void {
    try writer.writeAll(prefix);
    if (row.isNull(col)) {
        try writer.writeAll("null");
    } else {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d:.6}", .{row.float(col)}) catch "0";
        try writer.writeAll(str);
    }
}

/// Query distinct metric names and types.
pub fn queryMetricNames(
    db: *sqlite.Database,
    writer: *std.ArrayList(u8).Writer,
) !usize {
    const stmt = try db.prepare(
        "SELECT DISTINCT name, type FROM metrics_raw ORDER BY name ASC;",
    );
    defer stmt.deinit();

    try writer.writeAll("{\"metrics\": [");

    var iter = stmt.query();
    var count: usize = 0;
    while (iter.next()) |row| {
        if (count > 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\": \"");
        try writeJsonEscaped(writer, row.text(0) orelse "");
        try writer.writeAll("\", \"type\": \"");
        try writeJsonEscaped(writer, row.text(1) orelse "");
        try writer.writeAll("\"}");
        count += 1;
    }

    try writer.writeAll("]}");
    return count;
}

/// Convert "key:value,key2:value2" label format to JSON {"key":"value","key2":"value2"}.
fn labelsToJson(labels: []const u8, buf: *[512]u8) ![]const u8 {
    var pos: usize = 0;
    buf[pos] = '{';
    pos += 1;

    var first = true;
    var pairs_iter = std.mem.splitScalar(u8, labels, ',');
    while (pairs_iter.next()) |pair| {
        const colon = std.mem.indexOf(u8, pair, ":") orelse continue;
        const key = pair[0..colon];
        const value = pair[colon + 1 ..];

        if (!first) {
            buf[pos] = ',';
            pos += 1;
        }
        first = false;

        // "key":"value"
        buf[pos] = '"';
        pos += 1;
        if (pos + key.len >= buf.len) return error.BufferOverflow;
        @memcpy(buf[pos .. pos + key.len], key);
        pos += key.len;
        buf[pos] = '"';
        pos += 1;
        buf[pos] = ':';
        pos += 1;
        buf[pos] = '"';
        pos += 1;
        if (pos + value.len >= buf.len) return error.BufferOverflow;
        @memcpy(buf[pos .. pos + value.len], value);
        pos += value.len;
        buf[pos] = '"';
        pos += 1;
    }

    buf[pos] = '}';
    pos += 1;
    return buf[0..pos];
}

/// Write a JSON-escaped string.
pub fn writeJsonEscaped(writer: *std.ArrayList(u8).Writer, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.writeAll("\\u00");
                    const hex = "0123456789abcdef";
                    try writer.writeByte(hex[c >> 4]);
                    try writer.writeByte(hex[c & 0x0f]);
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ============================================================
// Tests
// ============================================================

const database = @import("database.zig");

fn setupTestDb() !sqlite.Database {
    return database.init(":memory:");
}

fn insertTestAggregate(db: *sqlite.Database, bucket: []const u8, resolution: []const u8, name: []const u8, labels: ?[]const u8, count: i64, sum: f64) !void {
    const stmt = try db.prepare(
        "INSERT INTO metrics_aggregated (bucket, resolution, name, labels, count, sum, min, max, avg) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
    );
    defer stmt.deinit();
    try stmt.bindText(1, bucket);
    try stmt.bindText(2, resolution);
    try stmt.bindText(3, name);
    if (labels) |l| {
        try stmt.bindText(4, l);
    } else {
        try stmt.bindNull(4);
    }
    try stmt.bindInt(5, count);
    try stmt.bindFloat(6, sum);
    try stmt.bindFloat(7, 0.01); // min
    try stmt.bindFloat(8, 1.0); // max
    try stmt.bindFloat(9, sum / @as(f64, @floatFromInt(count))); // avg
    _ = try stmt.exec();
}

test "parseQueryParams parses all parameters" {
    const params = parseQueryParams("/api/metrics?name=http_requests&period=7d&resolution=hour&labels=method:GET");
    try std.testing.expectEqualStrings("http_requests", params.name.?);
    try std.testing.expectEqualStrings("7d", params.period);
    try std.testing.expectEqualStrings("hour", params.resolution);
    try std.testing.expectEqualStrings("method:GET", params.labels.?);
}

test "parseQueryParams uses defaults" {
    const params = parseQueryParams("/api/metrics");
    try std.testing.expect(params.name == null);
    try std.testing.expectEqualStrings("24h", params.period);
    try std.testing.expectEqualStrings("auto", params.resolution);
    try std.testing.expect(params.labels == null);
}

test "parseQueryParams ignores invalid period" {
    const params = parseQueryParams("/api/metrics?name=test&period=invalid");
    try std.testing.expectEqualStrings("24h", params.period); // falls back to default
}

test "auto resolution resolves to minute for 1h" {
    const r = resolveResolution("1h", "auto");
    try std.testing.expectEqualStrings("minute", r);
}

test "auto resolution resolves to minute for 24h" {
    const r = resolveResolution("24h", "auto");
    try std.testing.expectEqualStrings("minute", r);
}

test "auto resolution resolves to hour for 7d" {
    const r = resolveResolution("7d", "auto");
    try std.testing.expectEqualStrings("hour", r);
}

test "auto resolution resolves to hour for 30d" {
    const r = resolveResolution("30d", "auto");
    try std.testing.expectEqualStrings("hour", r);
}

test "explicit resolution is preserved" {
    const r = resolveResolution("7d", "minute");
    try std.testing.expectEqualStrings("minute", r);
}

test "queryMetrics returns error for missing name" {
    var db = try setupTestDb();
    defer db.close();

    var params = QueryParams{
        .name = null,
        .period = "24h",
        .resolution = "auto",
        .labels = null,
    };

    var response = std.ArrayList(u8).init(std.testing.allocator);
    defer response.deinit();
    var writer = response.writer();

    const result = queryMetrics(&db, &params, &writer);
    try std.testing.expectError(error.MissingName, result);
}

test "queryMetrics returns data for existing metric" {
    var db = try setupTestDb();
    defer db.close();

    // Insert an aggregate with a recent bucket (within 24h)
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_aggregated (bucket, resolution, name, labels, count, sum, min, max, avg) " ++
                "VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-30 minutes'), 'minute', 'http_requests', NULL, 100, 100.0, 1.0, 1.0, 1.0);",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    var params = QueryParams{
        .name = "http_requests",
        .period = "24h",
        .resolution = "auto",
        .labels = null,
    };

    var response = std.ArrayList(u8).init(std.testing.allocator);
    defer response.deinit();
    var writer = response.writer();

    const count = try queryMetrics(&db, &params, &writer);
    try std.testing.expectEqual(@as(usize, 1), count);

    // Verify JSON structure
    const json = response.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"http_requests\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resolution\": \"minute\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"data\": [") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\": 100") != null);
}

test "queryMetrics returns empty data for non-existent metric" {
    var db = try setupTestDb();
    defer db.close();

    var params = QueryParams{
        .name = "nonexistent",
        .period = "24h",
        .resolution = "auto",
        .labels = null,
    };

    var response = std.ArrayList(u8).init(std.testing.allocator);
    defer response.deinit();
    var writer = response.writer();

    const count = try queryMetrics(&db, &params, &writer);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expect(std.mem.indexOf(u8, response.items, "\"data\": []") != null);
}

test "queryMetricNames returns distinct names" {
    var db = try setupTestDb();
    defer db.close();

    // Insert raw metrics with different names
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type) VALUES ('2025-01-20T10:00:00Z', 'metric_a', 1.0, 'counter');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type) VALUES ('2025-01-20T10:00:00Z', 'metric_b', 2.0, 'histogram');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type) VALUES ('2025-01-20T10:01:00Z', 'metric_a', 3.0, 'counter');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    var response = std.ArrayList(u8).init(std.testing.allocator);
    defer response.deinit();
    var writer = response.writer();

    const count = try queryMetricNames(&db, &writer);
    try std.testing.expectEqual(@as(usize, 2), count);

    const json = response.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"metric_a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"metric_b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"counter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"histogram\"") != null);
}

test "labelsToJson converts correctly" {
    var buf: [512]u8 = undefined;
    const result = try labelsToJson("method:GET,status:200", &buf);
    try std.testing.expectEqualStrings("{\"method\":\"GET\",\"status\":\"200\"}", result);
}

test "labelsToJson handles single label" {
    var buf: [512]u8 = undefined;
    const result = try labelsToJson("method:POST", &buf);
    try std.testing.expectEqualStrings("{\"method\":\"POST\"}", result);
}
