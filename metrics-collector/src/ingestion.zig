const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// A single metric data point parsed from the request body.
pub const MetricPoint = struct {
    name: []const u8,
    metric_type: []const u8, // "counter", "histogram", or "gauge"
    value: f64,
    labels: ?[]const u8, // JSON string of labels object, or null
    timestamp: ?[]const u8, // ISO 8601 timestamp, or null (defaults to now)
};

/// Validation error detail.
pub const ValidationError = struct {
    detail: []const u8,
};

/// Parse and validate a JSON request body into a list of MetricPoints.
/// The request body must be a JSON array of metric objects.
/// Returns null and sets `validation_err` if validation fails.
pub fn parseAndValidate(
    allocator: std.mem.Allocator,
    body: []const u8,
    validation_err: *ValidationError,
) ?[]MetricPoint {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        validation_err.detail = "Invalid JSON";
        return null;
    };

    // Must be an array
    const arr = switch (value) {
        .array => |a| a,
        else => {
            validation_err.detail = "Request body must be a JSON array";
            return null;
        },
    };

    if (arr.items.len == 0) {
        validation_err.detail = "Metrics array must not be empty";
        return null;
    }

    if (arr.items.len > 1000) {
        validation_err.detail = "Metrics batch exceeds maximum of 1000 items";
        return null;
    }

    var metrics = allocator.alloc(MetricPoint, arr.items.len) catch {
        validation_err.detail = "Internal allocation error";
        return null;
    };

    for (arr.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                validation_err.detail = "Each metric must be a JSON object";
                return null;
            },
        };

        // Required: name (string)
        const name = getStringField(obj, "name") orelse {
            validation_err.detail = "Missing required field: name";
            return null;
        };
        if (name.len == 0 or name.len > 200) {
            validation_err.detail = "Field 'name' must be 1-200 characters";
            return null;
        }

        // Required: type (string, must be counter/histogram/gauge)
        const metric_type = getStringField(obj, "type") orelse {
            validation_err.detail = "Missing required field: type";
            return null;
        };
        if (!isValidType(metric_type)) {
            validation_err.detail = "Field 'type' must be 'counter', 'histogram', or 'gauge'";
            return null;
        }

        // Required: value (number)
        const metric_value = getNumberField(obj, "value") orelse {
            validation_err.detail = "Missing required field: value";
            return null;
        };

        // Optional: labels (object → serialized to JSON string)
        const labels = serializeJsonField(allocator, obj, "labels");

        // Optional: timestamp (string, ISO 8601)
        const timestamp = getStringField(obj, "timestamp");

        metrics[i] = MetricPoint{
            .name = name,
            .metric_type = metric_type,
            .value = metric_value,
            .labels = labels,
            .timestamp = timestamp,
        };
    }

    return metrics;
}

/// Insert a batch of metric points into the metrics_raw table.
/// Uses a single prepared statement with reset/rebind for efficiency.
pub fn batchInsert(db: *sqlite.Database, metrics: []const MetricPoint) !usize {
    const stmt = try db.prepare(
        "INSERT INTO metrics_raw (timestamp, name, labels, value, type) " ++
            "VALUES (COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')), ?, ?, ?, ?);",
    );
    defer stmt.deinit();

    var inserted: usize = 0;
    for (metrics) |m| {
        // Bind timestamp (param 1) — null means use COALESCE default
        if (m.timestamp) |ts| {
            try stmt.bindText(1, ts);
        } else {
            try stmt.bindNull(1);
        }
        try stmt.bindText(2, m.name);
        if (m.labels) |labels| {
            try stmt.bindText(3, labels);
        } else {
            try stmt.bindNull(3);
        }
        try stmt.bindFloat(4, m.value);
        try stmt.bindText(5, m.metric_type);

        _ = stmt.exec() catch |err| {
            log.err("Failed to insert metric '{s}': {}", .{ m.name, err });
            stmt.reset();
            continue;
        };
        inserted += 1;
        stmt.reset();
    }

    return inserted;
}

/// Extract a string field from a JSON object map, returning null if missing or wrong type.
fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Extract a number field (integer or float) from a JSON object map.
fn getNumberField(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// Serialize a JSON field (object or array) back to a JSON string.
/// Returns null if the field is missing or null.
fn serializeJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .null => null,
        else => {
            var buf = std.ArrayList(u8).init(allocator);
            std.json.stringify(val, .{}, buf.writer()) catch return null;
            return buf.toOwnedSlice() catch null;
        },
    };
}

/// Check if a metric type string is valid.
fn isValidType(metric_type: []const u8) bool {
    return std.mem.eql(u8, metric_type, "counter") or
        std.mem.eql(u8, metric_type, "histogram") or
        std.mem.eql(u8, metric_type, "gauge");
}

// ============================================================
// Tests
// ============================================================

const database = @import("database.zig");

fn setupTestDb() !sqlite.Database {
    return database.init(":memory:");
}

test "parseAndValidate accepts valid batch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\[{"name": "http_requests_total", "type": "counter", "value": 1},
        \\ {"name": "http_request_duration", "type": "histogram", "value": 0.045, "labels": {"method": "GET", "endpoint": "/api/bookings"}},
        \\ {"name": "cpu_usage", "type": "gauge", "value": 65.2, "timestamp": "2025-01-20T10:00:00Z"}]
    ;
    var err: ValidationError = .{ .detail = "" };
    const metrics = parseAndValidate(allocator, body, &err);
    try std.testing.expect(metrics != null);
    try std.testing.expectEqual(@as(usize, 3), metrics.?.len);

    // First metric: counter, no labels, no timestamp
    try std.testing.expectEqualStrings("http_requests_total", metrics.?[0].name);
    try std.testing.expectEqualStrings("counter", metrics.?[0].metric_type);
    try std.testing.expectEqual(@as(f64, 1.0), metrics.?[0].value);
    try std.testing.expect(metrics.?[0].labels == null);
    try std.testing.expect(metrics.?[0].timestamp == null);

    // Second metric: histogram with labels
    try std.testing.expectEqualStrings("http_request_duration", metrics.?[1].name);
    try std.testing.expectEqualStrings("histogram", metrics.?[1].metric_type);
    try std.testing.expect(metrics.?[1].labels != null);

    // Third metric: gauge with timestamp
    try std.testing.expectEqualStrings("cpu_usage", metrics.?[2].name);
    try std.testing.expectEqualStrings("gauge", metrics.?[2].metric_type);
    try std.testing.expectEqualStrings("2025-01-20T10:00:00Z", metrics.?[2].timestamp.?);
}

test "parseAndValidate rejects invalid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var err: ValidationError = .{ .detail = "" };
    const result = parseAndValidate(allocator, "not json{{{", &err);
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("Invalid JSON", err.detail);
}

test "parseAndValidate rejects non-array body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var err: ValidationError = .{ .detail = "" };
    const result = parseAndValidate(allocator, "{\"name\": \"test\"}", &err);
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("Request body must be a JSON array", err.detail);
}

test "parseAndValidate rejects empty array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var err: ValidationError = .{ .detail = "" };
    const result = parseAndValidate(allocator, "[]", &err);
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("Metrics array must not be empty", err.detail);
}

test "parseAndValidate rejects missing required fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Missing name
    {
        var err: ValidationError = .{ .detail = "" };
        const result = parseAndValidate(allocator, "[{\"type\": \"counter\", \"value\": 1}]", &err);
        try std.testing.expect(result == null);
        try std.testing.expect(std.mem.indexOf(u8, err.detail, "name") != null);
    }

    // Missing type
    {
        var err: ValidationError = .{ .detail = "" };
        const result = parseAndValidate(allocator, "[{\"name\": \"test\", \"value\": 1}]", &err);
        try std.testing.expect(result == null);
        try std.testing.expect(std.mem.indexOf(u8, err.detail, "type") != null);
    }

    // Missing value
    {
        var err: ValidationError = .{ .detail = "" };
        const result = parseAndValidate(allocator, "[{\"name\": \"test\", \"type\": \"counter\"}]", &err);
        try std.testing.expect(result == null);
        try std.testing.expect(std.mem.indexOf(u8, err.detail, "value") != null);
    }
}

test "parseAndValidate rejects invalid type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var err: ValidationError = .{ .detail = "" };
    const result = parseAndValidate(allocator, "[{\"name\": \"test\", \"type\": \"invalid\", \"value\": 1}]", &err);
    try std.testing.expect(result == null);
    try std.testing.expect(std.mem.indexOf(u8, err.detail, "type") != null);
}

test "batchInsert inserts metrics into database" {
    var db = try setupTestDb();
    defer db.close();

    const metrics = [_]MetricPoint{
        .{
            .name = "http_requests_total",
            .metric_type = "counter",
            .value = 1.0,
            .labels = "{\"method\":\"GET\"}",
            .timestamp = "2025-01-20T10:00:00Z",
        },
        .{
            .name = "http_request_duration",
            .metric_type = "histogram",
            .value = 0.045,
            .labels = null,
            .timestamp = null,
        },
        .{
            .name = "cpu_usage",
            .metric_type = "gauge",
            .value = 65.2,
            .labels = null,
            .timestamp = "2025-01-20T10:01:00Z",
        },
    };

    const inserted = try batchInsert(&db, &metrics);
    try std.testing.expectEqual(@as(usize, 3), inserted);

    // Verify data in database
    const stmt = try db.prepare("SELECT COUNT(*) FROM metrics_raw;");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 3), row.int(0));
    } else {
        return error.TestUnexpectedResult;
    }
}

test "batchInsert preserves metric data" {
    var db = try setupTestDb();
    defer db.close();

    const metrics = [_]MetricPoint{
        .{
            .name = "http_requests_total",
            .metric_type = "counter",
            .value = 42.0,
            .labels = "{\"method\":\"POST\",\"endpoint\":\"/api/bookings\"}",
            .timestamp = "2025-01-20T10:00:00Z",
        },
    };

    _ = try batchInsert(&db, &metrics);

    // Verify exact data
    const stmt = try db.prepare(
        "SELECT timestamp, name, labels, value, type FROM metrics_raw WHERE id = 1;",
    );
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        const ts = row.text(0) orelse "";
        try std.testing.expectEqualStrings("2025-01-20T10:00:00Z", ts);
        const name = row.text(1) orelse "";
        try std.testing.expectEqualStrings("http_requests_total", name);
        const labels = row.text(2) orelse "";
        try std.testing.expectEqualStrings("{\"method\":\"POST\",\"endpoint\":\"/api/bookings\"}", labels);
        try std.testing.expectEqual(@as(f64, 42.0), row.float(3));
        const metric_type = row.text(4) orelse "";
        try std.testing.expectEqualStrings("counter", metric_type);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "batchInsert defaults timestamp to now when null" {
    var db = try setupTestDb();
    defer db.close();

    const metrics = [_]MetricPoint{
        .{
            .name = "test_metric",
            .metric_type = "gauge",
            .value = 1.0,
            .labels = null,
            .timestamp = null,
        },
    };

    _ = try batchInsert(&db, &metrics);

    // Verify timestamp is not null (it should be auto-set)
    const stmt = try db.prepare("SELECT timestamp FROM metrics_raw WHERE id = 1;");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expect(!row.isNull(0));
        const ts = row.text(0) orelse "";
        try std.testing.expect(ts.len > 0);
    } else {
        return error.TestUnexpectedResult;
    }
}
