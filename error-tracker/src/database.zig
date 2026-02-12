const sqlite = @import("sqlite");
const std = @import("std");
const log = std.log;

/// Schema migrations for the Error Tracker database.
/// Each entry is a SQL string applied in order; the migration runner
/// tracks which have already been applied via the `_meta` table.
pub const migrations = [_][]const u8{
    // Migration 1: errors table
    \\CREATE TABLE errors (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    fingerprint VARCHAR(32) NOT NULL,
    \\    project VARCHAR(100) NOT NULL,
    \\    environment VARCHAR(20) NOT NULL DEFAULT 'prod',
    \\    exception_type VARCHAR(200) NOT NULL,
    \\    message TEXT NOT NULL,
    \\    traceback TEXT NOT NULL,
    \\    count INTEGER NOT NULL DEFAULT 1,
    \\    first_seen DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    \\    last_seen DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    \\    resolved BOOLEAN NOT NULL DEFAULT 0,
    \\    resolved_at DATETIME
    \\);
    ,
    // Migration 2: error_occurrences table
    \\CREATE TABLE error_occurrences (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    error_id INTEGER NOT NULL REFERENCES errors(id) ON DELETE CASCADE,
    \\    timestamp DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    \\    request_url VARCHAR(500),
    \\    request_method VARCHAR(10),
    \\    request_headers TEXT,
    \\    user_id VARCHAR(100),
    \\    extra TEXT,
    \\    traceback TEXT NOT NULL
    \\);
    ,
    // Migration 3: indexes
    \\CREATE INDEX idx_fingerprint_resolved ON errors(fingerprint, resolved);
    \\CREATE INDEX idx_project_env ON errors(project, environment);
    \\CREATE INDEX idx_last_seen ON errors(last_seen);
    \\CREATE INDEX idx_resolved ON errors(resolved);
    \\CREATE INDEX idx_occurrence_error_id ON error_occurrences(error_id);
    ,
};

/// Initialize the error tracker database: open connection and run migrations.
pub fn init(db_path: [*:0]const u8) !sqlite.Database {
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();

    db.migrate(&migrations) catch |err| {
        log.err("error tracker database migration failed", .{});
        return err;
    };

    log.info("error tracker database initialized at {s}", .{db_path});
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

/// Helper: get EXPLAIN QUERY PLAN detail for a SQL statement
fn getQueryPlanDetail(db: *sqlite.Database, sql: [*:0]const u8) !?[]const u8 {
    // Build EXPLAIN QUERY PLAN + sql
    var buf: [1024]u8 = undefined;
    const sql_span = std.mem.span(sql);
    const prefix = "EXPLAIN QUERY PLAN ";
    if (prefix.len + sql_span.len >= buf.len) return null;

    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + sql_span.len], sql_span);
    buf[prefix.len + sql_span.len] = 0;
    const eqp_sql: [*:0]const u8 = buf[0 .. prefix.len + sql_span.len :0];

    const stmt = try db.prepare(eqp_sql);
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        // Column 3 is the "detail" field in EXPLAIN QUERY PLAN
        return row.text(3);
    }
    return null;
}

test "init creates errors table with correct columns" {
    var db = try init(":memory:");
    defer db.close();

    // Verify errors table exists
    try std.testing.expect(try tableExists(&db, "errors"));

    // Insert a row with only required fields to verify defaults work
    const stmt = try db.prepare(
        "INSERT INTO errors (fingerprint, project, exception_type, message, traceback) " ++
            "VALUES ('abc123', 'testproj', 'ValueError', 'test msg', 'Traceback...');",
    );
    defer stmt.deinit();
    _ = try stmt.exec();

    // Verify defaults were applied
    const q = try db.prepare(
        "SELECT id, fingerprint, project, environment, exception_type, message, traceback, " ++
            "count, first_seen, last_seen, resolved, resolved_at FROM errors WHERE id = 1;",
    );
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0)); // id autoincrement
        const fp = row.text(1) orelse "";
        try std.testing.expectEqualStrings("abc123", fp); // fingerprint
        const proj = row.text(2) orelse "";
        try std.testing.expectEqualStrings("testproj", proj); // project
        const env = row.text(3) orelse "";
        try std.testing.expectEqualStrings("prod", env); // environment default
        const exc = row.text(4) orelse "";
        try std.testing.expectEqualStrings("ValueError", exc); // exception_type
        const msg = row.text(5) orelse "";
        try std.testing.expectEqualStrings("test msg", msg); // message
        const tb = row.text(6) orelse "";
        try std.testing.expectEqualStrings("Traceback...", tb); // traceback
        try std.testing.expectEqual(@as(i64, 1), row.int(7)); // count default 1
        // first_seen and last_seen should be non-null (auto-set)
        try std.testing.expect(!row.isNull(8)); // first_seen
        try std.testing.expect(!row.isNull(9)); // last_seen
        try std.testing.expectEqual(@as(i64, 0), row.int(10)); // resolved default false
        try std.testing.expect(row.isNull(11)); // resolved_at nullable
    } else {
        return error.TestUnexpectedResult;
    }
}

test "init creates error_occurrences table with FK to errors" {
    var db = try init(":memory:");
    defer db.close();

    // Verify error_occurrences table exists
    try std.testing.expect(try tableExists(&db, "error_occurrences"));

    // Insert a parent error
    {
        const stmt = try db.prepare(
            "INSERT INTO errors (fingerprint, project, exception_type, message, traceback) " ++
                "VALUES ('fp1', 'proj', 'Err', 'msg', 'tb');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Insert an occurrence linked to the error
    {
        const stmt = try db.prepare(
            "INSERT INTO error_occurrences (error_id, traceback, request_url, request_method, request_headers, user_id, extra) " ++
                "VALUES (1, 'traceback here', '/api/test', 'POST', '{\"User-Agent\": \"test\"}', 'user42', '{\"key\": \"val\"}');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify the occurrence was created with correct values
    {
        const stmt = try db.prepare(
            "SELECT id, error_id, timestamp, request_url, request_method, request_headers, user_id, extra, traceback " ++
                "FROM error_occurrences WHERE id = 1;",
        );
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0)); // id
            try std.testing.expectEqual(@as(i64, 1), row.int(1)); // error_id FK
            try std.testing.expect(!row.isNull(2)); // timestamp auto-set
            const url = row.text(3) orelse "";
            try std.testing.expectEqualStrings("/api/test", url);
            const method = row.text(4) orelse "";
            try std.testing.expectEqualStrings("POST", method);
            const headers = row.text(5) orelse "";
            try std.testing.expectEqualStrings("{\"User-Agent\": \"test\"}", headers);
            const uid = row.text(6) orelse "";
            try std.testing.expectEqualStrings("user42", uid);
            const extra = row.text(7) orelse "";
            try std.testing.expectEqualStrings("{\"key\": \"val\"}", extra);
            const tb = row.text(8) orelse "";
            try std.testing.expectEqualStrings("traceback here", tb);
        } else {
            return error.TestUnexpectedResult;
        }
    }
}

test "error_occurrences FK cascade deletes occurrences when error is deleted" {
    var db = try init(":memory:");
    defer db.close();

    // Insert an error
    {
        const stmt = try db.prepare(
            "INSERT INTO errors (fingerprint, project, exception_type, message, traceback) " ++
                "VALUES ('fp1', 'proj', 'Err', 'msg', 'tb');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Insert two occurrences
    {
        const stmt = try db.prepare(
            "INSERT INTO error_occurrences (error_id, traceback) VALUES (1, 'tb1');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare(
            "INSERT INTO error_occurrences (error_id, traceback) VALUES (1, 'tb2');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify 2 occurrences exist
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM error_occurrences;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 2), row.int(0));
        }
    }

    // Delete the error
    {
        const stmt = try db.prepare("DELETE FROM errors WHERE id = 1;");
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify occurrences were cascade-deleted
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM error_occurrences;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 0), row.int(0));
        }
    }
}

test "all indexes are created on startup" {
    var db = try init(":memory:");
    defer db.close();

    // Verify all 5 indexes exist
    try std.testing.expect(try indexExists(&db, "idx_fingerprint_resolved"));
    try std.testing.expect(try indexExists(&db, "idx_project_env"));
    try std.testing.expect(try indexExists(&db, "idx_last_seen"));
    try std.testing.expect(try indexExists(&db, "idx_resolved"));
    try std.testing.expect(try indexExists(&db, "idx_occurrence_error_id"));
}

test "query planner uses idx_fingerprint_resolved for fingerprint+resolved queries" {
    var db = try init(":memory:");
    defer db.close();

    const detail = try getQueryPlanDetail(
        &db,
        "SELECT id FROM errors WHERE fingerprint = 'abc' AND resolved = 0;",
    ) orelse return error.TestUnexpectedResult;

    // EXPLAIN QUERY PLAN should mention idx_fingerprint_resolved
    try std.testing.expect(std.mem.indexOf(u8, detail, "idx_fingerprint_resolved") != null);
}

test "query planner uses idx_project_env for project+environment queries" {
    var db = try init(":memory:");
    defer db.close();

    const detail = try getQueryPlanDetail(
        &db,
        "SELECT id FROM errors WHERE project = 'flowrent' AND environment = 'prod';",
    ) orelse return error.TestUnexpectedResult;

    try std.testing.expect(std.mem.indexOf(u8, detail, "idx_project_env") != null);
}

test "query planner uses idx_last_seen for ordering by last_seen" {
    var db = try init(":memory:");
    defer db.close();

    const detail = try getQueryPlanDetail(
        &db,
        "SELECT id FROM errors ORDER BY last_seen DESC;",
    ) orelse return error.TestUnexpectedResult;

    try std.testing.expect(std.mem.indexOf(u8, detail, "idx_last_seen") != null);
}

test "query planner uses idx_occurrence_error_id for occurrence lookups" {
    var db = try init(":memory:");
    defer db.close();

    const detail = try getQueryPlanDetail(
        &db,
        "SELECT id FROM error_occurrences WHERE error_id = 1;",
    ) orelse return error.TestUnexpectedResult;

    try std.testing.expect(std.mem.indexOf(u8, detail, "idx_occurrence_error_id") != null);
}

test "init is idempotent - can be called multiple times" {
    // First init
    var db = try init(":memory:");

    // Verify table exists
    try std.testing.expect(try tableExists(&db, "errors"));

    // Insert data
    {
        const stmt = try db.prepare(
            "INSERT INTO errors (fingerprint, project, exception_type, message, traceback) " ++
                "VALUES ('fp1', 'proj', 'Err', 'msg', 'tb');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Since we can't re-init an in-memory DB with the same handle,
    // verify the migration runner is idempotent by running migrate again
    db.migrate(&migrations) catch |err| {
        std.debug.print("Unexpected migration error: {}\n", .{err});
        return error.TestUnexpectedResult;
    };

    // Verify data is still there
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM errors;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }

    db.close();
}
