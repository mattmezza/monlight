const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// Query parameters for metrics retrieval.
pub const QueryParams = struct {
    name: ?[]const u8,
    period: []const u8, // "1h", "24h", "7d", "30d"
    resolution: []const u8, // "minute", "hour", "auto"
    labels: ?[]const u8, // raw labels filter string e.g. "method:GET,status:200"
    project: ?[]const u8, // optional project filter
};

/// Parse query parameters from the request target URL.
pub fn parseQueryParams(target: []const u8) QueryParams {
    var params = QueryParams{
        .name = null,
        .period = "24h",
        .resolution = "auto",
        .labels = null,
        .project = null,
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
        } else if (std.mem.eql(u8, key, "project")) {
            if (value.len > 0) params.project = value;
        }
    }

    return params;
}

/// Parse a period string like "30s", "5m", "1h", "24h", "7d" into (number, unit).
fn parsePeriod(p: []const u8) ?struct { n: u32, unit: u8 } {
    if (p.len < 2 or p.len > 10) return null;
    const unit = p[p.len - 1];
    if (unit != 's' and unit != 'm' and unit != 'h' and unit != 'd') return null;
    const n = std.fmt.parseInt(u32, p[0 .. p.len - 1], 10) catch return null;
    if (n == 0) return null;
    return .{ .n = n, .unit = unit };
}

fn isValidPeriod(p: []const u8) bool {
    return parsePeriod(p) != null;
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
    // Auto: minute for <=24h, hour for >24h
    const parsed = parsePeriod(period) orelse return "minute";
    const total_seconds: u64 = switch (parsed.unit) {
        's' => parsed.n,
        'm' => @as(u64, parsed.n) * 60,
        'h' => @as(u64, parsed.n) * 3600,
        'd' => @as(u64, parsed.n) * 86400,
        else => 86400,
    };
    return if (total_seconds <= 86400) "minute" else "hour";
}

/// Format a period string into a SQLite time offset, e.g. "5m" → "-5 minutes".
fn periodToOffset(period: []const u8, buf: *[48]u8) []const u8 {
    const parsed = parsePeriod(period) orelse {
        const fb = "-24 hours";
        @memcpy(buf[0..fb.len], fb);
        return buf[0..fb.len];
    };
    const unit_word: []const u8 = switch (parsed.unit) {
        's' => " seconds",
        'm' => " minutes",
        'h' => " hours",
        'd' => " days",
        else => " hours",
    };
    // Format: "-N unit"
    const dash = "-";
    @memcpy(buf[0..1], dash);
    const num_slice = std.fmt.bufPrint(buf[1..], "{d}", .{parsed.n}) catch {
        const fb = "-24 hours";
        @memcpy(buf[0..fb.len], fb);
        return buf[0..fb.len];
    };
    const num_end = 1 + num_slice.len;
    @memcpy(buf[num_end .. num_end + unit_word.len], unit_word);
    return buf[0 .. num_end + unit_word.len];
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
    var offset_buf: [48]u8 = undefined;
    const offset = periodToOffset(params.period, &offset_buf);

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

/// Query distinct metric names and types, optionally filtered by project.
pub fn queryMetricNames(
    db: *sqlite.Database,
    writer: *std.ArrayList(u8).Writer,
    project: ?[]const u8,
) !usize {
    var sql_buf: [256]u8 = undefined;
    var pos: usize = 0;
    const base = "SELECT DISTINCT name, type FROM metrics_raw";
    @memcpy(sql_buf[pos .. pos + base.len], base);
    pos += base.len;
    if (project) |p| {
        const frag = " WHERE project = '";
        @memcpy(sql_buf[pos .. pos + frag.len], frag);
        pos += frag.len;
        @memcpy(sql_buf[pos .. pos + p.len], p);
        pos += p.len;
        sql_buf[pos] = '\'';
        pos += 1;
    }
    const tail = " ORDER BY name ASC;";
    @memcpy(sql_buf[pos .. pos + tail.len], tail);
    pos += tail.len;
    sql_buf[pos] = 0;

    const stmt = try db.prepare(@ptrCast(sql_buf[0..pos :0]));
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
        .project = null,
    };

    var response = std.ArrayList(u8){};
    defer response.deinit(std.testing.allocator);
    var writer = response.writer(std.testing.allocator);

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
        .project = null,
    };

    var response = std.ArrayList(u8){};
    defer response.deinit(std.testing.allocator);
    var writer = response.writer(std.testing.allocator);

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
        .project = null,
    };

    var response = std.ArrayList(u8){};
    defer response.deinit(std.testing.allocator);
    var writer = response.writer(std.testing.allocator);

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

    var response = std.ArrayList(u8){};
    defer response.deinit(std.testing.allocator);
    var writer = response.writer(std.testing.allocator);

    const count = try queryMetricNames(&db, &writer, null);
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
