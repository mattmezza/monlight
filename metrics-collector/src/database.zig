const sqlite = @import("sqlite");
const std = @import("std");
const log = std.log;

/// Schema migrations for the Metrics Collector database.
/// Each entry is a SQL string applied in order; the migration runner
/// tracks which have already been applied via the `_meta` table.
pub const migrations = [_][]const u8{
    // Migration 1: metrics_raw table — stores individual metric data points
    \\CREATE TABLE metrics_raw (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    timestamp DATETIME NOT NULL,
    \\    name VARCHAR(200) NOT NULL,
    \\    labels TEXT,
    \\    value REAL NOT NULL,
    \\    type VARCHAR(20) NOT NULL
    \\);
    ,
    // Migration 2: metrics_aggregated table — stores pre-computed rollups
    \\CREATE TABLE metrics_aggregated (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    bucket DATETIME NOT NULL,
    \\    resolution VARCHAR(10) NOT NULL,
    \\    name VARCHAR(200) NOT NULL,
    \\    labels TEXT,
    \\    count INTEGER NOT NULL DEFAULT 0,
    \\    sum REAL NOT NULL DEFAULT 0,
    \\    min REAL NOT NULL DEFAULT 0,
    \\    max REAL NOT NULL DEFAULT 0,
    \\    avg REAL NOT NULL DEFAULT 0,
    \\    p50 REAL,
    \\    p95 REAL,
    \\    p99 REAL
    \\);
    ,
    // Migration 3: All indexes for efficient querying
    \\CREATE INDEX idx_raw_timestamp ON metrics_raw(timestamp);
    \\CREATE INDEX idx_raw_name ON metrics_raw(name);
    \\CREATE INDEX idx_raw_name_timestamp ON metrics_raw(name, timestamp);
    \\CREATE INDEX idx_agg_bucket ON metrics_aggregated(bucket);
    \\CREATE INDEX idx_agg_name_resolution ON metrics_aggregated(name, resolution);
    \\CREATE INDEX idx_agg_name_resolution_bucket ON metrics_aggregated(name, resolution, bucket);
    ,
};

/// Initialize the metrics collector database: open connection and run migrations.
pub fn init(db_path: [*:0]const u8) !sqlite.Database {
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();

    db.migrate(&migrations) catch |err| {
        log.err("metrics collector database migration failed", .{});
        return err;
    };

    log.info("metrics collector database initialized at {s}", .{db_path});
    return db;
}

// ============================================================
// Tests
// ============================================================

/// Helper: check if a table exists in the database
fn tableExists(db: *sqlite.Database, table_name: []const u8) !bool {
    const stmt = try db.prepare(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?;",
    );
    defer stmt.deinit();
    try stmt.bindText(1, table_name);
    var iter = stmt.query();
    if (iter.next()) |row| {
        return row.int(0) == 1;
    }
    return false;
}

/// Helper: check if an index exists in the database
fn indexExists(db: *sqlite.Database, index_name: []const u8) !bool {
    const stmt = try db.prepare(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?;",
    );
    defer stmt.deinit();
    try stmt.bindText(1, index_name);
    var iter = stmt.query();
    if (iter.next()) |row| {
        return row.int(0) == 1;
    }
    return false;
}

test "init creates metrics_raw table with correct columns" {
    var db = try init(":memory:");
    defer db.close();

    try std.testing.expect(try tableExists(&db, "metrics_raw"));

    // Insert a row with all fields
    const stmt = try db.prepare(
        "INSERT INTO metrics_raw (timestamp, name, labels, value, type) " ++
            "VALUES ('2025-01-20T10:00:00Z', 'http_requests_total', '{\"method\":\"GET\"}', 42.0, 'counter');",
    );
    defer stmt.deinit();
    _ = try stmt.exec();

    // Verify data
    const q = try db.prepare(
        "SELECT id, timestamp, name, labels, value, type FROM metrics_raw WHERE id = 1;",
    );
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
        const ts = row.text(1) orelse "";
        try std.testing.expectEqualStrings("2025-01-20T10:00:00Z", ts);
        const name = row.text(2) orelse "";
        try std.testing.expectEqualStrings("http_requests_total", name);
        const labels = row.text(3) orelse "";
        try std.testing.expectEqualStrings("{\"method\":\"GET\"}", labels);
        // value is REAL — use float
        const value = row.float(4);
        try std.testing.expectEqual(@as(f64, 42.0), value);
        const metric_type = row.text(5) orelse "";
        try std.testing.expectEqualStrings("counter", metric_type);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "init creates metrics_aggregated table with correct columns" {
    var db = try init(":memory:");
    defer db.close();

    try std.testing.expect(try tableExists(&db, "metrics_aggregated"));

    // Insert a row with all fields including percentiles
    const stmt = try db.prepare(
        "INSERT INTO metrics_aggregated (bucket, resolution, name, labels, count, sum, min, max, avg, p50, p95, p99) " ++
            "VALUES ('2025-01-20T10:00:00Z', 'minute', 'http_request_duration', '{\"method\":\"GET\"}', 100, 5.5, 0.01, 2.5, 0.055, 0.04, 0.2, 1.5);",
    );
    defer stmt.deinit();
    _ = try stmt.exec();

    // Verify data
    const q = try db.prepare(
        "SELECT bucket, resolution, name, count, sum, min, max, avg, p50, p95, p99 FROM metrics_aggregated WHERE id = 1;",
    );
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        const bucket = row.text(0) orelse "";
        try std.testing.expectEqualStrings("2025-01-20T10:00:00Z", bucket);
        const resolution = row.text(1) orelse "";
        try std.testing.expectEqualStrings("minute", resolution);
        const name = row.text(2) orelse "";
        try std.testing.expectEqualStrings("http_request_duration", name);
        try std.testing.expectEqual(@as(i64, 100), row.int(3));
        try std.testing.expectEqual(@as(f64, 5.5), row.float(4));
        try std.testing.expectEqual(@as(f64, 0.01), row.float(5));
        try std.testing.expectEqual(@as(f64, 2.5), row.float(6));
        try std.testing.expectEqual(@as(f64, 0.055), row.float(7));
        try std.testing.expectEqual(@as(f64, 0.04), row.float(8));
        try std.testing.expectEqual(@as(f64, 0.2), row.float(9));
        try std.testing.expectEqual(@as(f64, 1.5), row.float(10));
    } else {
        return error.TestUnexpectedResult;
    }
}

test "metrics_aggregated allows NULL percentiles for non-histogram metrics" {
    var db = try init(":memory:");
    defer db.close();

    // Insert a counter aggregate (no percentiles)
    const stmt = try db.prepare(
        "INSERT INTO metrics_aggregated (bucket, resolution, name, count, sum, min, max, avg) " ++
            "VALUES ('2025-01-20T10:00:00Z', 'minute', 'http_requests_total', 500, 500.0, 1.0, 1.0, 1.0);",
    );
    defer stmt.deinit();
    _ = try stmt.exec();

    // Verify percentiles are NULL
    const q = try db.prepare(
        "SELECT p50, p95, p99 FROM metrics_aggregated WHERE id = 1;",
    );
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        try std.testing.expect(row.isNull(0)); // p50
        try std.testing.expect(row.isNull(1)); // p95
        try std.testing.expect(row.isNull(2)); // p99
    } else {
        return error.TestUnexpectedResult;
    }
}

test "all indexes are created on startup" {
    var db = try init(":memory:");
    defer db.close();

    try std.testing.expect(try indexExists(&db, "idx_raw_timestamp"));
    try std.testing.expect(try indexExists(&db, "idx_raw_name"));
    try std.testing.expect(try indexExists(&db, "idx_raw_name_timestamp"));
    try std.testing.expect(try indexExists(&db, "idx_agg_bucket"));
    try std.testing.expect(try indexExists(&db, "idx_agg_name_resolution"));
    try std.testing.expect(try indexExists(&db, "idx_agg_name_resolution_bucket"));
}

test "init is idempotent" {
    var db = try init(":memory:");

    try std.testing.expect(try tableExists(&db, "metrics_raw"));
    try std.testing.expect(try tableExists(&db, "metrics_aggregated"));

    // Insert data
    {
        const stmt = try db.prepare(
            "INSERT INTO metrics_raw (timestamp, name, value, type) " ++
                "VALUES ('2025-01-20T10:00:00Z', 'test', 1.0, 'counter');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Run migrate again
    db.migrate(&migrations) catch |err| {
        std.debug.print("Unexpected migration error: {}\n", .{err});
        return error.TestUnexpectedResult;
    };

    // Verify data is still there
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM metrics_raw;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }

    db.close();
}
