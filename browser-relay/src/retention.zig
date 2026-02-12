const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// Result of a retention cleanup run.
pub const CleanupResult = struct {
    /// Number of source maps deleted.
    source_maps_deleted: usize,
};

/// Delete source maps with `uploaded_at` older than `retention_days` days.
/// DSN keys are never auto-deleted.
///
/// Returns the number of source maps deleted.
pub fn cleanupOldSourceMaps(db: *sqlite.Database, retention_days: i64) !CleanupResult {
    const stmt = try db.prepare(
        "DELETE FROM source_maps WHERE uploaded_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || ? || ' days');",
    );
    defer stmt.deinit();

    try stmt.bindInt(1, retention_days);
    const deleted = try stmt.exec();

    if (deleted > 0) {
        log.info("retention cleanup: deleted {d} source map(s) older than {d} days", .{ deleted, retention_days });
    } else {
        log.info("retention cleanup: no source maps older than {d} days to delete", .{retention_days});
    }

    return CleanupResult{
        .source_maps_deleted = deleted,
    };
}

/// Background thread entry point for periodic retention cleanup.
/// Runs cleanup once every `interval_seconds` seconds (default: daily = 86400s).
/// Stops when the `stop` flag is set.
pub fn retentionThread(db_path_z: [*:0]const u8, retention_days: i64, interval_ns: u64, stop: *std.atomic.Value(bool)) void {
    // Open a separate database connection for the background thread
    // (SQLite WAL mode supports concurrent readers/writers from different connections).
    var db = sqlite.Database.open(db_path_z) catch |err| {
        log.err("retention thread: failed to open database: {}", .{err});
        return;
    };
    defer db.close();

    log.info("retention cleanup thread started (interval: {d}s, retention: {d} days)", .{ interval_ns / std.time.ns_per_s, retention_days });

    while (!stop.load(.acquire)) {
        // Sleep for the configured interval, checking stop flag periodically.
        // Sleep in 1-second increments so we can respond to stop signals promptly.
        var slept: u64 = 0;
        while (slept < interval_ns and !stop.load(.acquire)) {
            const sleep_chunk = @min(std.time.ns_per_s, interval_ns - slept);
            std.time.sleep(sleep_chunk);
            slept += sleep_chunk;
        }

        if (stop.load(.acquire)) break;

        // Run cleanup
        _ = cleanupOldSourceMaps(&db, retention_days) catch |err| {
            log.err("retention cleanup failed: {}", .{err});
        };
    }

    log.info("retention cleanup thread stopped", .{});
}

// ============================================================
// Tests
// ============================================================
const database = @import("database.zig");

/// Helper: insert a source map with a specific uploaded_at timestamp.
fn insertTestSourceMap(db: *sqlite.Database, project: []const u8, release: []const u8, file_url: []const u8, uploaded_at: ?[]const u8) !i64 {
    if (uploaded_at) |ts| {
        const stmt = try db.prepare(
            "INSERT INTO source_maps (project, release, file_url, map_content, uploaded_at) " ++
                "VALUES (?, ?, ?, '{\"version\":3,\"sources\":[],\"mappings\":\"\"}', ?);",
        );
        defer stmt.deinit();
        try stmt.bindText(1, project);
        try stmt.bindText(2, release);
        try stmt.bindText(3, file_url);
        try stmt.bindText(4, ts);
        _ = try stmt.exec();
    } else {
        // Use default uploaded_at (now)
        const stmt = try db.prepare(
            "INSERT INTO source_maps (project, release, file_url, map_content) " ++
                "VALUES (?, ?, ?, '{\"version\":3,\"sources\":[],\"mappings\":\"\"}');",
        );
        defer stmt.deinit();
        try stmt.bindText(1, project);
        try stmt.bindText(2, release);
        try stmt.bindText(3, file_url);
        _ = try stmt.exec();
    }
    return db.lastInsertRowId();
}

/// Helper: insert a DSN key for testing that they are never deleted.
fn insertTestDsnKey(db: *sqlite.Database, public_key: []const u8, project: []const u8) !void {
    const stmt = try db.prepare(
        "INSERT INTO dsn_keys (public_key, project) VALUES (?, ?);",
    );
    defer stmt.deinit();
    try stmt.bindText(1, public_key);
    try stmt.bindText(2, project);
    _ = try stmt.exec();
}

/// Helper: count total rows in a table.
fn countRows(db: *sqlite.Database, table: [*:0]const u8) !i64 {
    var buf: [128]u8 = undefined;
    const table_str = std.mem.span(table);
    const query = std.fmt.bufPrint(&buf, "SELECT COUNT(*) FROM {s};", .{table_str}) catch return error.TestUnexpectedResult;
    var query_z_buf: [128]u8 = undefined;
    @memcpy(query_z_buf[0..query.len], query);
    query_z_buf[query.len] = 0;
    const query_z: [*:0]const u8 = query_z_buf[0..query.len :0];

    const stmt = try db.prepare(query_z);
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        return row.int(0);
    }
    return 0;
}

test "cleanup deletes old source maps" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert a source map with uploaded_at 100 days ago
    _ = try insertTestSourceMap(&db, "proj", "1.0.0", "/app.js", "2020-01-01T00:00:00Z");

    // Verify it exists
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "source_maps"));

    // Run cleanup with 90-day retention
    const result = try cleanupOldSourceMaps(&db, 90);
    try std.testing.expectEqual(@as(usize, 1), result.source_maps_deleted);

    // Verify it was deleted
    try std.testing.expectEqual(@as(i64, 0), try countRows(&db, "source_maps"));
}

test "cleanup does NOT delete recently uploaded source maps" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert a source map with default uploaded_at (now)
    _ = try insertTestSourceMap(&db, "proj", "1.0.0", "/app.js", null);

    // Run cleanup with 90-day retention
    const result = try cleanupOldSourceMaps(&db, 90);
    try std.testing.expectEqual(@as(usize, 0), result.source_maps_deleted);

    // Verify it was NOT deleted
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "source_maps"));
}

test "cleanup never deletes DSN keys" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert a DSN key
    try insertTestDsnKey(&db, "abc123", "testproj");

    // Insert an old source map to make sure cleanup runs
    _ = try insertTestSourceMap(&db, "proj", "1.0.0", "/app.js", "2020-01-01T00:00:00Z");

    // Run cleanup with 1-day retention (very aggressive)
    const result = try cleanupOldSourceMaps(&db, 1);
    try std.testing.expectEqual(@as(usize, 1), result.source_maps_deleted);

    // Verify source map was deleted
    try std.testing.expectEqual(@as(i64, 0), try countRows(&db, "source_maps"));

    // Verify DSN key was NOT deleted
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "dsn_keys"));
}

test "cleanup deletes only old source maps, keeps recent ones" {
    var db = try database.init(":memory:");
    defer db.close();

    // Old source map (should be deleted)
    _ = try insertTestSourceMap(&db, "proj", "0.9.0", "/old-app.js", "2020-01-01T00:00:00Z");

    // Recent source map (should NOT be deleted)
    _ = try insertTestSourceMap(&db, "proj", "1.0.0", "/new-app.js", null);

    // Another old source map (should be deleted)
    _ = try insertTestSourceMap(&db, "proj", "0.8.0", "/legacy.js", "2020-06-15T00:00:00Z");

    // Verify initial state: 3 source maps
    try std.testing.expectEqual(@as(i64, 3), try countRows(&db, "source_maps"));

    // Run cleanup with 90-day retention
    const result = try cleanupOldSourceMaps(&db, 90);
    try std.testing.expectEqual(@as(usize, 2), result.source_maps_deleted);

    // Verify: only 1 source map remains (the recent one)
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "source_maps"));
}

test "cleanup with no source maps returns 0 deleted" {
    var db = try database.init(":memory:");
    defer db.close();

    // Empty database
    const result = try cleanupOldSourceMaps(&db, 90);
    try std.testing.expectEqual(@as(usize, 0), result.source_maps_deleted);
}

test "cleanup preserves DSN keys even with aggressive retention" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert multiple DSN keys (some old, some new)
    try insertTestDsnKey(&db, "key1", "proj1");
    try insertTestDsnKey(&db, "key2", "proj2");

    // Run cleanup with 0-day retention (delete everything older than now)
    const result = try cleanupOldSourceMaps(&db, 0);
    try std.testing.expectEqual(@as(usize, 0), result.source_maps_deleted);

    // Verify all DSN keys are intact
    try std.testing.expectEqual(@as(i64, 2), try countRows(&db, "dsn_keys"));
}
