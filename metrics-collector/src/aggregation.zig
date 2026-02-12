const std = @import("std");
const sqlite = @import("sqlite");
const retention = @import("retention.zig");
const log = std.log;

/// Run minute-level aggregation: query raw metrics from the previous minute,
/// group by (name, labels), compute count/sum/min/max/avg.
/// For histogram metrics, also compute p50/p95/p99.
pub fn aggregateMinute(db: *sqlite.Database) !usize {
    // Get the current minute bucket (truncated to minute)
    // We aggregate the PREVIOUS minute (data that's now complete)
    const bucket_stmt = try db.prepare(
        "SELECT strftime('%Y-%m-%dT%H:%M:00Z', 'now', '-1 minute');",
    );
    defer bucket_stmt.deinit();
    var bucket_iter = bucket_stmt.query();
    const bucket = if (bucket_iter.next()) |row|
        row.text(0) orelse return error.TestUnexpectedResult
    else
        return error.TestUnexpectedResult;

    // Copy bucket to stack since it's a borrowed pointer
    var bucket_buf: [32]u8 = undefined;
    @memcpy(bucket_buf[0..bucket.len], bucket);
    const bucket_str = bucket_buf[0..bucket.len];

    return aggregateMinuteBucket(db, bucket_str);
}

/// Aggregate a specific minute bucket. Exported for testing.
pub fn aggregateMinuteBucket(db: *sqlite.Database, bucket: []const u8) !usize {
    // Find distinct (name, labels, type) combinations for this minute
    const groups_stmt = try db.prepare(
        "SELECT DISTINCT name, COALESCE(labels, ''), type FROM metrics_raw " ++
            "WHERE timestamp >= ? AND timestamp < strftime('%Y-%m-%dT%H:%M:%SZ', ?, '+1 minute');",
    );
    defer groups_stmt.deinit();
    try groups_stmt.bindText(1, bucket);
    try groups_stmt.bindText(2, bucket);

    // Collect groups into a list (we need to iterate raw data per group for percentiles)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const Group = struct { name: []const u8, labels: []const u8, metric_type: []const u8 };
    var groups = std.ArrayList(Group).init(allocator);
    defer {
        for (groups.items) |g| {
            allocator.free(g.name);
            allocator.free(g.labels);
            allocator.free(g.metric_type);
        }
        groups.deinit();
    }

    var groups_iter = groups_stmt.query();
    while (groups_iter.next()) |row| {
        const name_src = row.text(0) orelse continue;
        const labels_src = row.text(1) orelse "";
        const type_src = row.text(2) orelse continue;

        const name = allocator.dupe(u8, name_src) catch continue;
        const labels = allocator.dupe(u8, labels_src) catch {
            allocator.free(name);
            continue;
        };
        const metric_type = allocator.dupe(u8, type_src) catch {
            allocator.free(name);
            allocator.free(labels);
            continue;
        };

        groups.append(.{ .name = name, .labels = labels, .metric_type = metric_type }) catch {
            allocator.free(name);
            allocator.free(labels);
            allocator.free(metric_type);
            continue;
        };
    }

    if (groups.items.len == 0) return 0;

    // For each group, compute aggregates
    var aggregated: usize = 0;
    for (groups.items) |group| {
        const agg_result = computeAggregates(db, bucket, group.name, group.labels, group.metric_type, allocator) catch |err| {
            log.err("Failed to compute aggregates for {s}: {}", .{ group.name, err });
            continue;
        };

        // Insert into metrics_aggregated
        insertAggregate(db, bucket, group.name, group.labels, &agg_result) catch |err| {
            log.err("Failed to insert aggregate for {s}: {}", .{ group.name, err });
            continue;
        };

        aggregated += 1;
    }

    if (aggregated > 0) {
        log.info("minute aggregation: {d} groups for bucket {s}", .{ aggregated, bucket });
    }

    return aggregated;
}

/// Aggregation result for a single (name, labels) group.
const AggResult = struct {
    count: i64,
    sum: f64,
    min: f64,
    max: f64,
    avg: f64,
    p50: ?f64,
    p95: ?f64,
    p99: ?f64,
};

/// Compute aggregates for a specific (name, labels) group within a bucket.
fn computeAggregates(
    db: *sqlite.Database,
    bucket: []const u8,
    name: []const u8,
    labels: []const u8,
    metric_type: []const u8,
    allocator: std.mem.Allocator,
) !AggResult {
    // Get basic aggregates from SQL
    const agg_sql = if (labels.len == 0)
        "SELECT COUNT(*), SUM(value), MIN(value), MAX(value), AVG(value) FROM metrics_raw " ++
            "WHERE name = ? AND labels IS NULL AND timestamp >= ? AND timestamp < strftime('%Y-%m-%dT%H:%M:%SZ', ?, '+1 minute');"
    else
        "SELECT COUNT(*), SUM(value), MIN(value), MAX(value), AVG(value) FROM metrics_raw " ++
            "WHERE name = ? AND labels = ? AND timestamp >= ? AND timestamp < strftime('%Y-%m-%dT%H:%M:%SZ', ?, '+1 minute');";

    const agg_stmt = try db.prepare(agg_sql);
    defer agg_stmt.deinit();

    if (labels.len == 0) {
        try agg_stmt.bindText(1, name);
        try agg_stmt.bindText(2, bucket);
        try agg_stmt.bindText(3, bucket);
    } else {
        try agg_stmt.bindText(1, name);
        try agg_stmt.bindText(2, labels);
        try agg_stmt.bindText(3, bucket);
        try agg_stmt.bindText(4, bucket);
    }

    var agg_iter = agg_stmt.query();
    const row = agg_iter.next() orelse return error.TestUnexpectedResult;

    const count = row.int(0);
    const sum = row.float(1);
    const min_val = row.float(2);
    const max_val = row.float(3);
    const avg_val = row.float(4);

    // Compute percentiles for histogram metrics
    var p50: ?f64 = null;
    var p95: ?f64 = null;
    var p99: ?f64 = null;

    if (std.mem.eql(u8, metric_type, "histogram") and count > 0) {
        const pctls = computePercentiles(db, bucket, name, labels, allocator) catch null;
        if (pctls) |p| {
            p50 = p.p50;
            p95 = p.p95;
            p99 = p.p99;
        }
    }

    return AggResult{
        .count = count,
        .sum = sum,
        .min = min_val,
        .max = max_val,
        .avg = avg_val,
        .p50 = p50,
        .p95 = p95,
        .p99 = p99,
    };
}

const Percentiles = struct { p50: f64, p95: f64, p99: f64 };

/// Compute p50, p95, p99 by sorting all values and picking positional indices.
fn computePercentiles(
    db: *sqlite.Database,
    bucket: []const u8,
    name: []const u8,
    labels: []const u8,
    allocator: std.mem.Allocator,
) !Percentiles {
    const val_sql = if (labels.len == 0)
        "SELECT value FROM metrics_raw " ++
            "WHERE name = ? AND labels IS NULL AND timestamp >= ? AND timestamp < strftime('%Y-%m-%dT%H:%M:%SZ', ?, '+1 minute') ORDER BY value ASC;"
    else
        "SELECT value FROM metrics_raw " ++
            "WHERE name = ? AND labels = ? AND timestamp >= ? AND timestamp < strftime('%Y-%m-%dT%H:%M:%SZ', ?, '+1 minute') ORDER BY value ASC;";

    const val_stmt = try db.prepare(val_sql);
    defer val_stmt.deinit();

    if (labels.len == 0) {
        try val_stmt.bindText(1, name);
        try val_stmt.bindText(2, bucket);
        try val_stmt.bindText(3, bucket);
    } else {
        try val_stmt.bindText(1, name);
        try val_stmt.bindText(2, labels);
        try val_stmt.bindText(3, bucket);
        try val_stmt.bindText(4, bucket);
    }

    var values = std.ArrayList(f64).init(allocator);
    defer values.deinit();

    var val_iter = val_stmt.query();
    while (val_iter.next()) |row| {
        try values.append(row.float(0));
    }

    if (values.items.len == 0) return error.TestUnexpectedResult;

    // Values are already sorted (ORDER BY value ASC)
    const n = values.items.len;
    return Percentiles{
        .p50 = values.items[percentileIndex(n, 50)],
        .p95 = values.items[percentileIndex(n, 95)],
        .p99 = values.items[percentileIndex(n, 99)],
    };
}

/// Calculate the index for a given percentile using nearest-rank method.
fn percentileIndex(n: usize, percentile: usize) usize {
    if (n == 0) return 0;
    const idx = (percentile * n + 99) / 100; // ceiling division
    if (idx == 0) return 0;
    return idx - 1;
}

/// Insert a computed aggregate into the metrics_aggregated table.
fn insertAggregate(
    db: *sqlite.Database,
    bucket: []const u8,
    name: []const u8,
    labels: []const u8,
    result: *const AggResult,
) !void {
    const stmt = try db.prepare(
        "INSERT INTO metrics_aggregated (bucket, resolution, name, labels, count, sum, min, max, avg, p50, p95, p99) " ++
            "VALUES (?, 'minute', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
    );
    defer stmt.deinit();

    try stmt.bindText(1, bucket);
    try stmt.bindText(2, name);
    if (labels.len == 0) {
        try stmt.bindNull(3);
    } else {
        try stmt.bindText(3, labels);
    }
    try stmt.bindInt(4, result.count);
    try stmt.bindFloat(5, result.sum);
    try stmt.bindFloat(6, result.min);
    try stmt.bindFloat(7, result.max);
    try stmt.bindFloat(8, result.avg);

    if (result.p50) |v| {
        try stmt.bindFloat(9, v);
    } else {
        try stmt.bindNull(9);
    }
    if (result.p95) |v| {
        try stmt.bindFloat(10, v);
    } else {
        try stmt.bindNull(10);
    }
    if (result.p99) |v| {
        try stmt.bindFloat(11, v);
    } else {
        try stmt.bindNull(11);
    }

    _ = try stmt.exec();
}

/// Run hour-level aggregation: merge minute aggregates into hourly buckets.
/// Aggregates the PREVIOUS hour.
pub fn aggregateHour(db: *sqlite.Database) !usize {
    // Get the previous hour bucket
    const bucket_stmt = try db.prepare(
        "SELECT strftime('%Y-%m-%dT%H:00:00Z', 'now', '-1 hour');",
    );
    defer bucket_stmt.deinit();
    var bucket_iter = bucket_stmt.query();
    const bucket = if (bucket_iter.next()) |row|
        row.text(0) orelse return error.TestUnexpectedResult
    else
        return error.TestUnexpectedResult;

    var bucket_buf: [32]u8 = undefined;
    @memcpy(bucket_buf[0..bucket.len], bucket);
    const bucket_str = bucket_buf[0..bucket.len];

    return aggregateHourBucket(db, bucket_str);
}

/// Aggregate a specific hour bucket. Exported for testing.
pub fn aggregateHourBucket(db: *sqlite.Database, bucket: []const u8) !usize {
    // Find distinct (name, labels) combinations in minute aggregates for this hour
    const groups_stmt = try db.prepare(
        "SELECT DISTINCT name, COALESCE(labels, '') FROM metrics_aggregated " ++
            "WHERE resolution = 'minute' AND bucket >= ? AND bucket < strftime('%Y-%m-%dT%H:%M:%SZ', ?, '+1 hour');",
    );
    defer groups_stmt.deinit();
    try groups_stmt.bindText(1, bucket);
    try groups_stmt.bindText(2, bucket);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const Group = struct { name: []const u8, labels: []const u8 };
    var groups = std.ArrayList(Group).init(allocator);
    defer {
        for (groups.items) |g| {
            allocator.free(g.name);
            allocator.free(g.labels);
        }
        groups.deinit();
    }

    var groups_iter = groups_stmt.query();
    while (groups_iter.next()) |row| {
        const name_src = row.text(0) orelse continue;
        const labels_src = row.text(1) orelse "";

        const name = allocator.dupe(u8, name_src) catch continue;
        const labels = allocator.dupe(u8, labels_src) catch {
            allocator.free(name);
            continue;
        };

        groups.append(.{ .name = name, .labels = labels }) catch {
            allocator.free(name);
            allocator.free(labels);
            continue;
        };
    }

    if (groups.items.len == 0) return 0;

    var aggregated: usize = 0;
    for (groups.items) |group| {
        mergeMinuteToHour(db, bucket, group.name, group.labels) catch |err| {
            log.err("Failed to merge minute to hour for {s}: {}", .{ group.name, err });
            continue;
        };
        aggregated += 1;
    }

    if (aggregated > 0) {
        log.info("hour aggregation: {d} groups for bucket {s}", .{ aggregated, bucket });
    }

    return aggregated;
}

/// Merge minute aggregates into an hourly aggregate for a specific (name, labels) group.
fn mergeMinuteToHour(
    db: *sqlite.Database,
    bucket: []const u8,
    name: []const u8,
    labels: []const u8,
) !void {
    // Merge: count = SUM(count), sum = SUM(sum), min = MIN(min), max = MAX(max),
    // avg = SUM(sum) / SUM(count), percentiles approximated from minute percentiles
    const merge_sql = if (labels.len == 0)
        "SELECT SUM(count), SUM(sum), MIN(min), MAX(max), " ++
            "CASE WHEN SUM(count) > 0 THEN SUM(sum) / SUM(count) ELSE 0 END, " ++
            "AVG(p50), AVG(p95), AVG(p99) " ++
            "FROM metrics_aggregated WHERE resolution = 'minute' AND name = ? AND labels IS NULL " ++
            "AND bucket >= ? AND bucket < strftime('%Y-%m-%dT%H:%M:%SZ', ?, '+1 hour');"
    else
        "SELECT SUM(count), SUM(sum), MIN(min), MAX(max), " ++
            "CASE WHEN SUM(count) > 0 THEN SUM(sum) / SUM(count) ELSE 0 END, " ++
            "AVG(p50), AVG(p95), AVG(p99) " ++
            "FROM metrics_aggregated WHERE resolution = 'minute' AND name = ? AND labels = ? " ++
            "AND bucket >= ? AND bucket < strftime('%Y-%m-%dT%H:%M:%SZ', ?, '+1 hour');";

    const merge_stmt = try db.prepare(merge_sql);
    defer merge_stmt.deinit();

    if (labels.len == 0) {
        try merge_stmt.bindText(1, name);
        try merge_stmt.bindText(2, bucket);
        try merge_stmt.bindText(3, bucket);
    } else {
        try merge_stmt.bindText(1, name);
        try merge_stmt.bindText(2, labels);
        try merge_stmt.bindText(3, bucket);
        try merge_stmt.bindText(4, bucket);
    }

    var merge_iter = merge_stmt.query();
    const row = merge_iter.next() orelse return;

    if (row.isNull(0)) return; // No data

    const count = row.int(0);
    const sum = row.float(1);
    const min_val = row.float(2);
    const max_val = row.float(3);
    const avg_val = row.float(4);
    const p50: ?f64 = if (row.isNull(5)) null else row.float(5);
    const p95: ?f64 = if (row.isNull(6)) null else row.float(6);
    const p99: ?f64 = if (row.isNull(7)) null else row.float(7);

    // Insert hourly aggregate
    const ins_stmt = try db.prepare(
        "INSERT INTO metrics_aggregated (bucket, resolution, name, labels, count, sum, min, max, avg, p50, p95, p99) " ++
            "VALUES (?, 'hour', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
    );
    defer ins_stmt.deinit();

    try ins_stmt.bindText(1, bucket);
    try ins_stmt.bindText(2, name);
    if (labels.len == 0) {
        try ins_stmt.bindNull(3);
    } else {
        try ins_stmt.bindText(3, labels);
    }
    try ins_stmt.bindInt(4, count);
    try ins_stmt.bindFloat(5, sum);
    try ins_stmt.bindFloat(6, min_val);
    try ins_stmt.bindFloat(7, max_val);
    try ins_stmt.bindFloat(8, avg_val);

    if (p50) |v| {
        try ins_stmt.bindFloat(9, v);
    } else {
        try ins_stmt.bindNull(9);
    }
    if (p95) |v| {
        try ins_stmt.bindFloat(10, v);
    } else {
        try ins_stmt.bindNull(10);
    }
    if (p99) |v| {
        try ins_stmt.bindFloat(11, v);
    } else {
        try ins_stmt.bindNull(11);
    }

    _ = try ins_stmt.exec();
}

/// Background aggregation thread function.
/// Opens its own SQLite connection and runs aggregation on a timer.
/// Also runs data retention cleanup hourly.
pub fn aggregationThread(
    db_path: [*:0]const u8,
    interval_seconds: i64,
    retention_raw_hours: i64,
    retention_minute_hours: i64,
    retention_hourly_days: i64,
    stop: *std.atomic.Value(bool),
) void {
    var db = sqlite.Database.open(db_path) catch |err| {
        log.err("Aggregation thread: failed to open database: {}", .{err});
        return;
    };
    defer db.close();

    log.info("aggregation thread started (interval: {d}s)", .{interval_seconds});

    // Track when we last ran hour aggregation
    var minute_counter: i64 = 0;

    while (!stop.load(.acquire)) {
        // Sleep in 1-second chunks for responsive stop-flag checking
        var slept: i64 = 0;
        while (slept < interval_seconds and !stop.load(.acquire)) {
            std.time.sleep(1_000_000_000); // 1 second
            slept += 1;
        }

        if (stop.load(.acquire)) break;

        // Run minute aggregation
        _ = aggregateMinute(&db) catch |err| {
            log.err("Minute aggregation failed: {}", .{err});
        };

        minute_counter += 1;

        // Run hour aggregation and retention cleanup every 60 intervals
        if (@mod(minute_counter, 60) == 0) {
            _ = aggregateHour(&db) catch |err| {
                log.err("Hour aggregation failed: {}", .{err});
            };

            _ = retention.cleanup(&db, retention_raw_hours, retention_minute_hours, retention_hourly_days) catch |err| {
                log.err("Retention cleanup failed: {}", .{err});
            };
        }
    }

    log.info("aggregation thread stopped", .{});
}

// ============================================================
// Tests
// ============================================================

const database = @import("database.zig");

fn setupTestDb() !sqlite.Database {
    return database.init(":memory:");
}

fn insertTestMetric(db: *sqlite.Database, timestamp: []const u8, name: []const u8, labels: ?[]const u8, value: f64, metric_type: []const u8) !void {
    const stmt = try db.prepare(
        "INSERT INTO metrics_raw (timestamp, name, labels, value, type) VALUES (?, ?, ?, ?, ?);",
    );
    defer stmt.deinit();
    try stmt.bindText(1, timestamp);
    try stmt.bindText(2, name);
    if (labels) |l| {
        try stmt.bindText(3, l);
    } else {
        try stmt.bindNull(3);
    }
    try stmt.bindFloat(4, value);
    try stmt.bindText(5, metric_type);
    _ = try stmt.exec();
}

test "minute aggregation computes count/sum/min/max/avg for counter" {
    var db = try setupTestDb();
    defer db.close();

    // Insert 3 counter values in the same minute bucket
    const bucket = "2025-01-20T10:00:00Z";
    try insertTestMetric(&db, "2025-01-20T10:00:05Z", "http_requests", null, 1.0, "counter");
    try insertTestMetric(&db, "2025-01-20T10:00:15Z", "http_requests", null, 1.0, "counter");
    try insertTestMetric(&db, "2025-01-20T10:00:45Z", "http_requests", null, 1.0, "counter");

    const count = try aggregateMinuteBucket(&db, bucket);
    try std.testing.expectEqual(@as(usize, 1), count); // 1 group

    // Verify aggregated data
    const stmt = try db.prepare(
        "SELECT count, sum, min, max, avg, p50, p95, p99 FROM metrics_aggregated " ++
            "WHERE name = 'http_requests' AND resolution = 'minute';",
    );
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 3), row.int(0)); // count
        try std.testing.expectEqual(@as(f64, 3.0), row.float(1)); // sum
        try std.testing.expectEqual(@as(f64, 1.0), row.float(2)); // min
        try std.testing.expectEqual(@as(f64, 1.0), row.float(3)); // max
        try std.testing.expectEqual(@as(f64, 1.0), row.float(4)); // avg
        // Counter metrics should NOT have percentiles
        try std.testing.expect(row.isNull(5)); // p50
        try std.testing.expect(row.isNull(6)); // p95
        try std.testing.expect(row.isNull(7)); // p99
    } else {
        return error.TestUnexpectedResult;
    }
}

test "minute aggregation computes percentiles for histogram" {
    var db = try setupTestDb();
    defer db.close();

    const bucket = "2025-01-20T10:00:00Z";
    // Insert 10 histogram values (latencies in seconds)
    const values = [_]f64{ 0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.10 };
    for (values) |v| {
        try insertTestMetric(&db, "2025-01-20T10:00:30Z", "http_latency", null, v, "histogram");
    }

    const count = try aggregateMinuteBucket(&db, bucket);
    try std.testing.expectEqual(@as(usize, 1), count);

    // Verify percentiles exist
    const stmt = try db.prepare(
        "SELECT count, p50, p95, p99 FROM metrics_aggregated " ++
            "WHERE name = 'http_latency' AND resolution = 'minute';",
    );
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 10), row.int(0)); // count
        // p50 of [0.01..0.10] sorted: index = ceil(50*10/100) - 1 = 4 → 0.05
        try std.testing.expect(!row.isNull(1)); // p50
        try std.testing.expect(!row.isNull(2)); // p95
        try std.testing.expect(!row.isNull(3)); // p99
        const p50 = row.float(1);
        try std.testing.expectApproxEqAbs(@as(f64, 0.05), p50, 0.001);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "minute aggregation handles multiple groups" {
    var db = try setupTestDb();
    defer db.close();

    const bucket = "2025-01-20T10:00:00Z";
    try insertTestMetric(&db, "2025-01-20T10:00:10Z", "metric_a", null, 1.0, "counter");
    try insertTestMetric(&db, "2025-01-20T10:00:20Z", "metric_b", null, 2.0, "gauge");
    try insertTestMetric(&db, "2025-01-20T10:00:30Z", "metric_a", null, 3.0, "counter");

    const count = try aggregateMinuteBucket(&db, bucket);
    try std.testing.expectEqual(@as(usize, 2), count); // 2 groups

    // Verify both exist
    const stmt = try db.prepare("SELECT COUNT(*) FROM metrics_aggregated WHERE resolution = 'minute';");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 2), row.int(0));
    }
}

test "minute aggregation separates by labels" {
    var db = try setupTestDb();
    defer db.close();

    const bucket = "2025-01-20T10:00:00Z";
    try insertTestMetric(&db, "2025-01-20T10:00:10Z", "http_requests", "{\"method\":\"GET\"}", 1.0, "counter");
    try insertTestMetric(&db, "2025-01-20T10:00:20Z", "http_requests", "{\"method\":\"POST\"}", 1.0, "counter");
    try insertTestMetric(&db, "2025-01-20T10:00:30Z", "http_requests", "{\"method\":\"GET\"}", 1.0, "counter");

    const count = try aggregateMinuteBucket(&db, bucket);
    try std.testing.expectEqual(@as(usize, 2), count); // 2 label groups

    // Verify GET group has count 2
    const stmt = try db.prepare(
        "SELECT count FROM metrics_aggregated WHERE name = 'http_requests' AND labels = '{\"method\":\"GET\"}';",
    );
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 2), row.int(0));
    }
}

test "hour aggregation merges minute aggregates" {
    var db = try setupTestDb();
    defer db.close();

    // Insert minute aggregates for 3 minutes within the same hour
    const ins = try db.prepare(
        "INSERT INTO metrics_aggregated (bucket, resolution, name, labels, count, sum, min, max, avg, p50, p95, p99) " ++
            "VALUES (?, 'minute', ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?);",
    );
    defer ins.deinit();

    // Minute 1: count=10, sum=1.0, min=0.01, max=0.2, avg=0.1, p50=0.05, p95=0.18, p99=0.19
    try ins.bindText(1, "2025-01-20T10:00:00Z");
    try ins.bindText(2, "http_latency");
    try ins.bindInt(3, 10);
    try ins.bindFloat(4, 1.0);
    try ins.bindFloat(5, 0.01);
    try ins.bindFloat(6, 0.2);
    try ins.bindFloat(7, 0.1);
    try ins.bindFloat(8, 0.05);
    try ins.bindFloat(9, 0.18);
    try ins.bindFloat(10, 0.19);
    _ = try ins.exec();
    ins.reset();

    // Minute 2: count=20, sum=3.0, min=0.02, max=0.5, avg=0.15, p50=0.08, p95=0.4, p99=0.48
    try ins.bindText(1, "2025-01-20T10:01:00Z");
    try ins.bindText(2, "http_latency");
    try ins.bindInt(3, 20);
    try ins.bindFloat(4, 3.0);
    try ins.bindFloat(5, 0.02);
    try ins.bindFloat(6, 0.5);
    try ins.bindFloat(7, 0.15);
    try ins.bindFloat(8, 0.08);
    try ins.bindFloat(9, 0.4);
    try ins.bindFloat(10, 0.48);
    _ = try ins.exec();
    ins.reset();

    // Minute 3: count=15, sum=2.25, min=0.03, max=0.3, avg=0.15, p50=0.06, p95=0.25, p99=0.28
    try ins.bindText(1, "2025-01-20T10:02:00Z");
    try ins.bindText(2, "http_latency");
    try ins.bindInt(3, 15);
    try ins.bindFloat(4, 2.25);
    try ins.bindFloat(5, 0.03);
    try ins.bindFloat(6, 0.3);
    try ins.bindFloat(7, 0.15);
    try ins.bindFloat(8, 0.06);
    try ins.bindFloat(9, 0.25);
    try ins.bindFloat(10, 0.28);
    _ = try ins.exec();

    const bucket = "2025-01-20T10:00:00Z";
    const count = try aggregateHourBucket(&db, bucket);
    try std.testing.expectEqual(@as(usize, 1), count);

    // Verify hourly aggregate
    const stmt = try db.prepare(
        "SELECT count, sum, min, max, avg, p50, p95, p99 FROM metrics_aggregated " ++
            "WHERE name = 'http_latency' AND resolution = 'hour';",
    );
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        // count = 10 + 20 + 15 = 45
        try std.testing.expectEqual(@as(i64, 45), row.int(0));
        // sum = 1.0 + 3.0 + 2.25 = 6.25
        try std.testing.expectApproxEqAbs(@as(f64, 6.25), row.float(1), 0.001);
        // min = MIN(0.01, 0.02, 0.03) = 0.01
        try std.testing.expectApproxEqAbs(@as(f64, 0.01), row.float(2), 0.001);
        // max = MAX(0.2, 0.5, 0.3) = 0.5
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), row.float(3), 0.001);
        // avg = 6.25 / 45 ≈ 0.1389
        try std.testing.expectApproxEqAbs(@as(f64, 6.25 / 45.0), row.float(4), 0.001);
        // p50 = AVG(0.05, 0.08, 0.06) ≈ 0.0633
        try std.testing.expect(!row.isNull(5));
        // p95 and p99 should exist
        try std.testing.expect(!row.isNull(6));
        try std.testing.expect(!row.isNull(7));
    } else {
        return error.TestUnexpectedResult;
    }
}

test "hour aggregation returns 0 for empty bucket" {
    var db = try setupTestDb();
    defer db.close();

    const count = try aggregateHourBucket(&db, "2025-01-20T10:00:00Z");
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "percentileIndex computes correct indices" {
    // 10 items: indices 0..9
    try std.testing.expectEqual(@as(usize, 4), percentileIndex(10, 50)); // p50: ceil(500/100)-1 = 4
    try std.testing.expectEqual(@as(usize, 9), percentileIndex(10, 95)); // p95: ceil(950/100)-1 = 9
    try std.testing.expectEqual(@as(usize, 9), percentileIndex(10, 99)); // p99: ceil(990/100)-1 = 9

    // 100 items
    try std.testing.expectEqual(@as(usize, 49), percentileIndex(100, 50)); // p50
    try std.testing.expectEqual(@as(usize, 94), percentileIndex(100, 95)); // p95
    try std.testing.expectEqual(@as(usize, 98), percentileIndex(100, 99)); // p99

    // 1 item
    try std.testing.expectEqual(@as(usize, 0), percentileIndex(1, 50));
    try std.testing.expectEqual(@as(usize, 0), percentileIndex(1, 99));
}
