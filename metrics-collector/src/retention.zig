const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// Result of a cleanup run.
pub const CleanupResult = struct {
    raw_deleted: usize,
    minute_deleted: usize,
    hourly_deleted: usize,
};

/// Delete raw metrics older than `retention_hours` hours,
/// minute aggregates older than `retention_minute_hours` hours,
/// and hourly aggregates older than `retention_hourly_days` days.
pub fn cleanup(
    db: *sqlite.Database,
    retention_raw_hours: i64,
    retention_minute_hours: i64,
    retention_hourly_days: i64,
) !CleanupResult {
    var result = CleanupResult{
        .raw_deleted = 0,
        .minute_deleted = 0,
        .hourly_deleted = 0,
    };

    // Delete old raw metrics
    {
        var buf: [128]u8 = undefined;
        const hours_str = std.fmt.bufPrint(&buf, "{d}", .{retention_raw_hours}) catch "1";
        const stmt = try db.prepare(
            "DELETE FROM metrics_raw WHERE timestamp < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || ? || ' hours');",
        );
        defer stmt.deinit();
        try stmt.bindText(1, hours_str);
        result.raw_deleted = stmt.exec() catch |err| {
            log.err("Failed to delete old raw metrics: {}", .{err});
            return err;
        };
    }

    // Delete old minute aggregates
    {
        var buf: [128]u8 = undefined;
        const hours_str = std.fmt.bufPrint(&buf, "{d}", .{retention_minute_hours}) catch "24";
        const stmt = try db.prepare(
            "DELETE FROM metrics_aggregated WHERE resolution = 'minute' AND bucket < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || ? || ' hours');",
        );
        defer stmt.deinit();
        try stmt.bindText(1, hours_str);
        result.minute_deleted = stmt.exec() catch |err| {
            log.err("Failed to delete old minute aggregates: {}", .{err});
            return err;
        };
    }

    // Delete old hourly aggregates
    {
        var buf: [128]u8 = undefined;
        const days_str = std.fmt.bufPrint(&buf, "{d}", .{retention_hourly_days}) catch "30";
        const stmt = try db.prepare(
            "DELETE FROM metrics_aggregated WHERE resolution = 'hour' AND bucket < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || ? || ' days');",
        );
        defer stmt.deinit();
        try stmt.bindText(1, days_str);
        result.hourly_deleted = stmt.exec() catch |err| {
            log.err("Failed to delete old hourly aggregates: {}", .{err});
            return err;
        };
    }

    if (result.raw_deleted > 0 or result.minute_deleted > 0 or result.hourly_deleted > 0) {
        log.info("retention cleanup: raw={d}, minute={d}, hourly={d} deleted", .{
            result.raw_deleted, result.minute_deleted, result.hourly_deleted,
        });
    }

    return result;
}

// ============================================================
// Tests
// ============================================================

const database = @import("database.zig");

fn setupTestDb() !sqlite.Database {
    return database.init(":memory:");
}

test "cleanup deletes old raw metrics" {
    var db = try setupTestDb();
    defer db.close();

    // Insert a metric with a very old timestamp
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type) VALUES ('2020-01-01T00:00:00Z', 'old_metric', 1.0, 'counter');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Insert a metric with current timestamp
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type) VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 'new_metric', 1.0, 'counter');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    const result = try cleanup(&db, 1, 24, 30);
    try std.testing.expectEqual(@as(usize, 1), result.raw_deleted);

    // Verify only the new metric remains
    const stmt = try db.prepare("SELECT COUNT(*) FROM metrics_raw;");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
    }
}

test "cleanup does not delete recent raw metrics" {
    var db = try setupTestDb();
    defer db.close();

    // Insert a metric with current timestamp
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type) VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 'recent_metric', 1.0, 'counter');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    const result = try cleanup(&db, 1, 24, 30);
    try std.testing.expectEqual(@as(usize, 0), result.raw_deleted);

    // Verify the metric is still there
    const stmt = try db.prepare("SELECT COUNT(*) FROM metrics_raw;");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
    }
}

test "cleanup deletes old minute aggregates" {
    var db = try setupTestDb();
    defer db.close();

    // Insert an old minute aggregate
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_aggregated (bucket, resolution, name, count, sum, min, max, avg) " ++
                "VALUES ('2020-01-01T00:00:00Z', 'minute', 'old_agg', 10, 10.0, 1.0, 1.0, 1.0);",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Insert a recent minute aggregate
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_aggregated (bucket, resolution, name, count, sum, min, max, avg) " ++
                "VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 'minute', 'new_agg', 10, 10.0, 1.0, 1.0, 1.0);",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    const result = try cleanup(&db, 1, 24, 30);
    try std.testing.expectEqual(@as(usize, 1), result.minute_deleted);

    // Verify only the recent aggregate remains
    const stmt = try db.prepare("SELECT COUNT(*) FROM metrics_aggregated WHERE resolution = 'minute';");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
    }
}

test "cleanup deletes old hourly aggregates" {
    var db = try setupTestDb();
    defer db.close();

    // Insert an old hourly aggregate (more than 30 days old)
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_aggregated (bucket, resolution, name, count, sum, min, max, avg) " ++
                "VALUES ('2020-01-01T00:00:00Z', 'hour', 'old_hourly', 100, 100.0, 1.0, 1.0, 1.0);",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Insert a recent hourly aggregate
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_aggregated (bucket, resolution, name, count, sum, min, max, avg) " ++
                "VALUES (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), 'hour', 'new_hourly', 100, 100.0, 1.0, 1.0, 1.0);",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    const result = try cleanup(&db, 1, 24, 30);
    try std.testing.expectEqual(@as(usize, 1), result.hourly_deleted);

    // Verify only the recent aggregate remains
    const stmt = try db.prepare("SELECT COUNT(*) FROM metrics_aggregated WHERE resolution = 'hour';");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
    }
}

test "cleanup returns zeros on empty database" {
    var db = try setupTestDb();
    defer db.close();

    const result = try cleanup(&db, 1, 24, 30);
    try std.testing.expectEqual(@as(usize, 0), result.raw_deleted);
    try std.testing.expectEqual(@as(usize, 0), result.minute_deleted);
    try std.testing.expectEqual(@as(usize, 0), result.hourly_deleted);
}

test "cleanup only deletes matching resolution" {
    var db = try setupTestDb();
    defer db.close();

    // Insert old minute and hourly aggregates
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_aggregated (bucket, resolution, name, count, sum, min, max, avg) " ++
                "VALUES ('2020-01-01T00:00:00Z', 'minute', 'min_agg', 10, 10.0, 1.0, 1.0, 1.0);",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_aggregated (bucket, resolution, name, count, sum, min, max, avg) " ++
                "VALUES ('2020-01-01T00:00:00Z', 'hour', 'hour_agg', 100, 100.0, 1.0, 1.0, 1.0);",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // With very large retention for hourly (9999 days), only minute should be deleted
    const result = try cleanup(&db, 1, 24, 9999);
    try std.testing.expectEqual(@as(usize, 1), result.minute_deleted);
    try std.testing.expectEqual(@as(usize, 0), result.hourly_deleted);

    // Verify hourly aggregate still exists
    const stmt = try db.prepare("SELECT COUNT(*) FROM metrics_aggregated WHERE resolution = 'hour';");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
    }
}
