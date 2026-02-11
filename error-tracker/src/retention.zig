const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// Result of a retention cleanup run.
pub const CleanupResult = struct {
    /// Number of resolved error groups deleted.
    errors_deleted: usize,
};

/// Delete resolved errors older than `retention_days` days.
/// Associated `error_occurrences` records are cascade-deleted via FK constraint.
/// Unresolved errors are never deleted regardless of age.
///
/// Returns the number of error groups deleted.
pub fn cleanupResolvedErrors(db: *sqlite.Database, retention_days: i64) !CleanupResult {
    // Delete resolved errors where resolved_at is older than retention_days ago.
    // SQLite datetime functions work with ISO8601 strings.
    // We compare resolved_at against a computed cutoff timestamp.
    const stmt = try db.prepare(
        "DELETE FROM errors WHERE resolved = 1 AND resolved_at IS NOT NULL " ++
            "AND resolved_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-' || ? || ' days');",
    );
    defer stmt.deinit();

    try stmt.bindInt(1, retention_days);
    const deleted = try stmt.exec();

    if (deleted > 0) {
        log.info("retention cleanup: deleted {d} resolved error(s) older than {d} days", .{ deleted, retention_days });
    } else {
        log.info("retention cleanup: no resolved errors older than {d} days to delete", .{retention_days});
    }

    return CleanupResult{
        .errors_deleted = deleted,
    };
}

/// Background thread entry point for periodic retention cleanup.
/// Runs cleanup once every `interval_seconds` seconds.
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
        // Sleep for the configured interval, checking stop flag periodically
        // Sleep in 1-second increments so we can respond to stop signals promptly
        var slept: u64 = 0;
        while (slept < interval_ns and !stop.load(.acquire)) {
            const sleep_chunk = @min(std.time.ns_per_s, interval_ns - slept);
            std.time.sleep(sleep_chunk);
            slept += sleep_chunk;
        }

        if (stop.load(.acquire)) break;

        // Run cleanup
        _ = cleanupResolvedErrors(&db, retention_days) catch |err| {
            log.err("retention cleanup failed: {}", .{err});
        };
    }

    log.info("retention cleanup thread stopped", .{});
}

// ============================================================
// Tests
// ============================================================
const database = @import("database.zig");

/// Helper: insert an error with specified resolved status and resolved_at timestamp.
fn insertTestError(db: *sqlite.Database, fingerprint: []const u8, resolved: bool, resolved_at: ?[]const u8) !i64 {
    const stmt = try db.prepare(
        "INSERT INTO errors (fingerprint, project, environment, exception_type, message, traceback, count, first_seen, last_seen, resolved, resolved_at) " ++
            "VALUES (?, 'testproj', 'prod', 'TestError', 'test message', 'traceback...', 1, " ++
            "strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), ?, ?);",
    );
    defer stmt.deinit();

    try stmt.bindText(1, fingerprint);
    try stmt.bindInt(2, if (resolved) 1 else 0);
    if (resolved_at) |ts| {
        try stmt.bindText(3, ts);
    } else {
        try stmt.bindNull(3);
    }
    _ = try stmt.exec();
    return db.lastInsertRowId();
}

/// Helper: insert an occurrence for an error.
fn insertTestOccurrence(db: *sqlite.Database, error_id: i64) !void {
    const stmt = try db.prepare(
        "INSERT INTO error_occurrences (error_id, traceback) VALUES (?, 'test traceback');",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);
    _ = try stmt.exec();
}

/// Helper: count total rows in a table.
fn countRows(db: *sqlite.Database, table: [*:0]const u8) !i64 {
    // Build query: "SELECT COUNT(*) FROM <table>;"
    var buf: [128]u8 = undefined;
    const table_str = std.mem.span(table);
    const query = std.fmt.bufPrint(&buf, "SELECT COUNT(*) FROM {s};", .{table_str}) catch return error.TestUnexpectedResult;
    // Null-terminate
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

test "cleanup deletes old resolved errors" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert a resolved error with resolved_at 100 days ago
    _ = try insertTestError(&db, "fp_old_resolved", true, "2020-01-01T00:00:00Z");

    // Verify it exists
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "errors"));

    // Run cleanup with 90-day retention
    const result = try cleanupResolvedErrors(&db, 90);
    try std.testing.expectEqual(@as(usize, 1), result.errors_deleted);

    // Verify it was deleted
    try std.testing.expectEqual(@as(i64, 0), try countRows(&db, "errors"));
}

test "cleanup does NOT delete unresolved errors regardless of age" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert an unresolved error (very old first_seen, but not resolved)
    _ = try insertTestError(&db, "fp_old_unresolved", false, null);

    // Run cleanup with 1-day retention (aggressive)
    const result = try cleanupResolvedErrors(&db, 1);
    try std.testing.expectEqual(@as(usize, 0), result.errors_deleted);

    // Verify it was NOT deleted
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "errors"));
}

test "cleanup does NOT delete recently resolved errors" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert a resolved error with resolved_at = now (within retention period)
    _ = try insertTestError(&db, "fp_recent_resolved", true, null);

    // Update resolved_at to now
    {
        const stmt = try db.prepare(
            "UPDATE errors SET resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE fingerprint = 'fp_recent_resolved';",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Run cleanup with 90-day retention
    const result = try cleanupResolvedErrors(&db, 90);
    try std.testing.expectEqual(@as(usize, 0), result.errors_deleted);

    // Verify it was NOT deleted
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "errors"));
}

test "cleanup cascade-deletes associated occurrences" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert a resolved error with old resolved_at
    const error_id = try insertTestError(&db, "fp_with_occurrences", true, "2020-01-01T00:00:00Z");

    // Insert occurrences for this error
    try insertTestOccurrence(&db, error_id);
    try insertTestOccurrence(&db, error_id);
    try insertTestOccurrence(&db, error_id);

    // Verify occurrences exist
    try std.testing.expectEqual(@as(i64, 3), try countRows(&db, "error_occurrences"));

    // Run cleanup
    const result = try cleanupResolvedErrors(&db, 90);
    try std.testing.expectEqual(@as(usize, 1), result.errors_deleted);

    // Verify error was deleted
    try std.testing.expectEqual(@as(i64, 0), try countRows(&db, "errors"));

    // Verify occurrences were cascade-deleted
    try std.testing.expectEqual(@as(i64, 0), try countRows(&db, "error_occurrences"));
}

test "cleanup deletes only old resolved, keeps unresolved and recent resolved" {
    var db = try database.init(":memory:");
    defer db.close();

    // Mix of errors:
    // 1. Old resolved (should be deleted)
    const old_resolved_id = try insertTestError(&db, "fp_old_resolved", true, "2020-01-01T00:00:00Z");
    try insertTestOccurrence(&db, old_resolved_id);

    // 2. Unresolved (should NOT be deleted)
    const unresolved_id = try insertTestError(&db, "fp_unresolved", false, null);
    try insertTestOccurrence(&db, unresolved_id);

    // 3. Recently resolved (should NOT be deleted)
    _ = try insertTestError(&db, "fp_recent_resolved", true, null);
    // Set resolved_at to now
    {
        const stmt = try db.prepare(
            "UPDATE errors SET resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE fingerprint = 'fp_recent_resolved';",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify initial state: 3 errors, 2 occurrences
    try std.testing.expectEqual(@as(i64, 3), try countRows(&db, "errors"));
    try std.testing.expectEqual(@as(i64, 2), try countRows(&db, "error_occurrences"));

    // Run cleanup with 90-day retention
    const result = try cleanupResolvedErrors(&db, 90);
    try std.testing.expectEqual(@as(usize, 1), result.errors_deleted);

    // Verify: 2 errors remain (unresolved + recent resolved)
    try std.testing.expectEqual(@as(i64, 2), try countRows(&db, "errors"));

    // Verify: 1 occurrence remains (the one for the unresolved error)
    try std.testing.expectEqual(@as(i64, 1), try countRows(&db, "error_occurrences"));
}

test "cleanup with zero matching errors returns 0 deleted" {
    var db = try database.init(":memory:");
    defer db.close();

    // Empty database
    const result = try cleanupResolvedErrors(&db, 90);
    try std.testing.expectEqual(@as(usize, 0), result.errors_deleted);
}
