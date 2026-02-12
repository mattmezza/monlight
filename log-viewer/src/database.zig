const sqlite = @import("sqlite");
const std = @import("std");
const log = std.log;

/// Schema migrations for the Log Viewer database.
/// Each entry is a SQL string applied in order; the migration runner
/// tracks which have already been applied via the `_meta` table.
pub const migrations = [_][]const u8{
    // Migration 1: log_entries table
    \\CREATE TABLE log_entries (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    timestamp DATETIME NOT NULL,
    \\    container VARCHAR(200) NOT NULL,
    \\    stream VARCHAR(10) NOT NULL DEFAULT 'stdout',
    \\    level VARCHAR(10) NOT NULL DEFAULT 'INFO',
    \\    message TEXT NOT NULL,
    \\    raw TEXT
    \\);
    ,
    // Migration 2: FTS5 virtual table on message field for full-text search
    \\CREATE VIRTUAL TABLE log_entries_fts USING fts5(
    \\    message,
    \\    content='log_entries',
    \\    content_rowid='id'
    \\);
    \\
    \\CREATE TRIGGER log_entries_ai AFTER INSERT ON log_entries BEGIN
    \\    INSERT INTO log_entries_fts(rowid, message) VALUES (new.id, new.message);
    \\END;
    \\
    \\CREATE TRIGGER log_entries_ad AFTER DELETE ON log_entries BEGIN
    \\    INSERT INTO log_entries_fts(log_entries_fts, rowid, message) VALUES('delete', old.id, old.message);
    \\END;
    \\
    \\CREATE TRIGGER log_entries_au AFTER UPDATE ON log_entries BEGIN
    \\    INSERT INTO log_entries_fts(log_entries_fts, rowid, message) VALUES('delete', old.id, old.message);
    \\    INSERT INTO log_entries_fts(rowid, message) VALUES (new.id, new.message);
    \\END;
    ,
    // Migration 3: cursors table for tracking Docker log file read positions
    \\CREATE TABLE cursors (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    container_id VARCHAR(200) NOT NULL UNIQUE,
    \\    file_path TEXT NOT NULL,
    \\    position INTEGER NOT NULL DEFAULT 0,
    \\    inode INTEGER NOT NULL DEFAULT 0,
    \\    updated_at DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    \\);
    ,
    // Migration 4: Indexes for efficient querying
    \\CREATE INDEX idx_timestamp ON log_entries(timestamp);
    \\CREATE INDEX idx_container ON log_entries(container);
    \\CREATE INDEX idx_level ON log_entries(level);
    \\CREATE INDEX idx_container_timestamp ON log_entries(container, timestamp);
    ,
};

/// Initialize the log viewer database: open connection and run migrations.
pub fn init(db_path: [*:0]const u8) !sqlite.Database {
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();

    db.migrate(&migrations) catch |err| {
        log.err("log viewer database migration failed", .{});
        return err;
    };

    log.info("log viewer database initialized at {s}", .{db_path});
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

test "init creates log_entries table with correct columns" {
    var db = try init(":memory:");
    defer db.close();

    try std.testing.expect(try tableExists(&db, "log_entries"));

    // Insert a row with required fields
    const stmt = try db.prepare(
        "INSERT INTO log_entries (timestamp, container, message) " ++
            "VALUES ('2025-01-20T10:00:00Z', 'web-app', 'Server started');",
    );
    defer stmt.deinit();
    _ = try stmt.exec();

    // Verify defaults
    const q = try db.prepare(
        "SELECT id, timestamp, container, stream, level, message, raw FROM log_entries WHERE id = 1;",
    );
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
        const ts = row.text(1) orelse "";
        try std.testing.expectEqualStrings("2025-01-20T10:00:00Z", ts);
        const container = row.text(2) orelse "";
        try std.testing.expectEqualStrings("web-app", container);
        const stream = row.text(3) orelse "";
        try std.testing.expectEqualStrings("stdout", stream);
        const level = row.text(4) orelse "";
        try std.testing.expectEqualStrings("INFO", level);
        const msg = row.text(5) orelse "";
        try std.testing.expectEqualStrings("Server started", msg);
        try std.testing.expect(row.isNull(6)); // raw is nullable
    } else {
        return error.TestUnexpectedResult;
    }
}

test "FTS5 full-text search works" {
    var db = try init(":memory:");
    defer db.close();

    // Insert some log entries
    {
        const stmt = try db.prepare(
            "INSERT INTO log_entries (timestamp, container, message) VALUES ('2025-01-20T10:00:00Z', 'web', 'Connection established to database');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare(
            "INSERT INTO log_entries (timestamp, container, message) VALUES ('2025-01-20T10:01:00Z', 'web', 'User login successful');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare(
            "INSERT INTO log_entries (timestamp, container, message) VALUES ('2025-01-20T10:02:00Z', 'web', 'Database query failed with timeout');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Search for "database" — should match entries 1 and 3
    const stmt = try db.prepare(
        "SELECT COUNT(*) FROM log_entries WHERE id IN (SELECT rowid FROM log_entries_fts WHERE log_entries_fts MATCH 'database');",
    );
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 2), row.int(0));
    } else {
        return error.TestUnexpectedResult;
    }
}

test "FTS5 index stays consistent after deletion" {
    var db = try init(":memory:");
    defer db.close();

    // Insert entries
    {
        const stmt = try db.prepare(
            "INSERT INTO log_entries (timestamp, container, message) VALUES ('2025-01-20T10:00:00Z', 'web', 'Error connecting to redis');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare(
            "INSERT INTO log_entries (timestamp, container, message) VALUES ('2025-01-20T10:01:00Z', 'web', 'Redis connection restored');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Delete entry 1
    {
        const stmt = try db.prepare("DELETE FROM log_entries WHERE id = 1;");
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // FTS search for "redis" should return only 1 result now
    const stmt = try db.prepare(
        "SELECT COUNT(*) FROM log_entries WHERE id IN (SELECT rowid FROM log_entries_fts WHERE log_entries_fts MATCH 'redis');",
    );
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
    } else {
        return error.TestUnexpectedResult;
    }
}

test "init creates cursors table" {
    var db = try init(":memory:");
    defer db.close();

    try std.testing.expect(try tableExists(&db, "cursors"));

    // Insert a cursor
    const stmt = try db.prepare(
        "INSERT INTO cursors (container_id, file_path, position, inode) " ++
            "VALUES ('web-app', '/var/lib/docker/containers/abc/abc-json.log', 1024, 12345);",
    );
    defer stmt.deinit();
    _ = try stmt.exec();

    // Verify
    const q = try db.prepare("SELECT container_id, file_path, position, inode FROM cursors WHERE id = 1;");
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        const cid = row.text(0) orelse "";
        try std.testing.expectEqualStrings("web-app", cid);
        const fp = row.text(1) orelse "";
        try std.testing.expectEqualStrings("/var/lib/docker/containers/abc/abc-json.log", fp);
        try std.testing.expectEqual(@as(i64, 1024), row.int(2));
        try std.testing.expectEqual(@as(i64, 12345), row.int(3));
    } else {
        return error.TestUnexpectedResult;
    }
}

test "all indexes are created on startup" {
    var db = try init(":memory:");
    defer db.close();

    try std.testing.expect(try indexExists(&db, "idx_timestamp"));
    try std.testing.expect(try indexExists(&db, "idx_container"));
    try std.testing.expect(try indexExists(&db, "idx_level"));
    try std.testing.expect(try indexExists(&db, "idx_container_timestamp"));
}

test "init is idempotent" {
    var db = try init(":memory:");

    try std.testing.expect(try tableExists(&db, "log_entries"));

    // Insert data
    {
        const stmt = try db.prepare(
            "INSERT INTO log_entries (timestamp, container, message) " ++
                "VALUES ('2025-01-20T10:00:00Z', 'web', 'test');",
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
        const stmt = try db.prepare("SELECT COUNT(*) FROM log_entries;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }

    db.close();
}
