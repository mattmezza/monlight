const sqlite = @import("sqlite");
const std = @import("std");
const log = std.log;

/// Schema migrations for the Browser Relay database.
/// Each entry is a SQL string applied in order; the migration runner
/// tracks which have already been applied via the `_meta` table.
pub const migrations = [_][]const u8{
    // Migration 1: dsn_keys table
    \\CREATE TABLE dsn_keys (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    public_key VARCHAR(64) NOT NULL UNIQUE,
    \\    project VARCHAR(100) NOT NULL,
    \\    created_at DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    \\    active BOOLEAN NOT NULL DEFAULT 1
    \\);
    ,
    // Migration 2: source_maps table
    \\CREATE TABLE source_maps (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    project VARCHAR(100) NOT NULL,
    \\    release VARCHAR(100) NOT NULL,
    \\    file_url VARCHAR(500) NOT NULL,
    \\    map_content TEXT NOT NULL,
    \\    uploaded_at DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    \\    UNIQUE(project, release, file_url)
    \\);
    ,
    // Migration 3: indexes
    \\CREATE INDEX idx_dsn_public_key ON dsn_keys(public_key);
    \\CREATE INDEX idx_source_map_lookup ON source_maps(project, release, file_url);
    ,
};

/// Initialize the browser relay database: open connection and run migrations.
pub fn init(db_path: [*:0]const u8) !sqlite.Database {
    var db = try sqlite.Database.open(db_path);
    errdefer db.close();

    db.migrate(&migrations) catch |err| {
        log.err("browser relay database migration failed", .{});
        return err;
    };

    log.info("browser relay database initialized at {s}", .{db_path});
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
        return row.text(3);
    }
    return null;
}

test "init creates dsn_keys table with correct columns" {
    var db = try init(":memory:");
    defer db.close();

    try std.testing.expect(try tableExists(&db, "dsn_keys"));

    // Insert a DSN key and verify defaults
    const stmt = try db.prepare(
        "INSERT INTO dsn_keys (public_key, project) VALUES ('abc123def456', 'testproj');",
    );
    defer stmt.deinit();
    _ = try stmt.exec();

    const q = try db.prepare(
        "SELECT id, public_key, project, created_at, active FROM dsn_keys WHERE id = 1;",
    );
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0)); // id
        const pk = row.text(1) orelse "";
        try std.testing.expectEqualStrings("abc123def456", pk);
        const proj = row.text(2) orelse "";
        try std.testing.expectEqualStrings("testproj", proj);
        try std.testing.expect(!row.isNull(3)); // created_at auto-set
        try std.testing.expectEqual(@as(i64, 1), row.int(4)); // active default true
    } else {
        return error.TestUnexpectedResult;
    }
}

test "dsn_keys public_key column is unique" {
    var db = try init(":memory:");
    defer db.close();

    // Insert first key
    {
        const stmt = try db.prepare(
            "INSERT INTO dsn_keys (public_key, project) VALUES ('key1', 'proj1');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Insert duplicate key should fail — verify via COUNT staying at 1
    {
        const stmt = db.prepare(
            "INSERT OR IGNORE INTO dsn_keys (public_key, project) VALUES ('key1', 'proj2');",
        ) catch return error.TestUnexpectedResult;
        defer stmt.deinit();
        _ = stmt.exec() catch return error.TestUnexpectedResult;
    }

    // Verify only 1 row exists (duplicate was rejected)
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM dsn_keys;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }
}

test "init creates source_maps table with correct columns" {
    var db = try init(":memory:");
    defer db.close();

    try std.testing.expect(try tableExists(&db, "source_maps"));

    // Insert a source map and verify defaults
    const stmt = try db.prepare(
        "INSERT INTO source_maps (project, release, file_url, map_content) " ++
            "VALUES ('myproj', '1.0.0', '/static/app.min.js', '{\"version\":3}');",
    );
    defer stmt.deinit();
    _ = try stmt.exec();

    const q = try db.prepare(
        "SELECT id, project, release, file_url, map_content, uploaded_at FROM source_maps WHERE id = 1;",
    );
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0)); // id
        const proj = row.text(1) orelse "";
        try std.testing.expectEqualStrings("myproj", proj);
        const rel = row.text(2) orelse "";
        try std.testing.expectEqualStrings("1.0.0", rel);
        const url = row.text(3) orelse "";
        try std.testing.expectEqualStrings("/static/app.min.js", url);
        const content = row.text(4) orelse "";
        try std.testing.expectEqualStrings("{\"version\":3}", content);
        try std.testing.expect(!row.isNull(5)); // uploaded_at auto-set
    } else {
        return error.TestUnexpectedResult;
    }
}

test "source_maps composite unique constraint on (project, release, file_url)" {
    var db = try init(":memory:");
    defer db.close();

    // Insert first source map
    {
        const stmt = try db.prepare(
            "INSERT INTO source_maps (project, release, file_url, map_content) " ++
                "VALUES ('proj', '1.0', '/app.js', '{\"version\":3}');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Insert duplicate (same project+release+file_url) with OR IGNORE
    {
        const stmt = try db.prepare(
            "INSERT OR IGNORE INTO source_maps (project, release, file_url, map_content) " ++
                "VALUES ('proj', '1.0', '/app.js', '{\"version\":3,\"updated\":true}');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify only 1 row exists (duplicate was rejected)
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM source_maps;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }

    // Different release should succeed
    {
        const stmt = try db.prepare(
            "INSERT INTO source_maps (project, release, file_url, map_content) " ++
                "VALUES ('proj', '2.0', '/app.js', '{\"version\":3}');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify 2 rows now
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM source_maps;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 2), row.int(0));
        }
    }
}

test "all indexes are created on startup" {
    var db = try init(":memory:");
    defer db.close();

    try std.testing.expect(try indexExists(&db, "idx_dsn_public_key"));
    try std.testing.expect(try indexExists(&db, "idx_source_map_lookup"));
}

test "query planner uses index for public key lookups" {
    var db = try init(":memory:");
    defer db.close();

    const detail = try getQueryPlanDetail(
        &db,
        "SELECT project FROM dsn_keys WHERE public_key = 'abc123' AND active = 1;",
    ) orelse return error.TestUnexpectedResult;

    // Query planner should use an index (either the explicit idx_dsn_public_key
    // or the autoindex from the UNIQUE constraint on public_key)
    try std.testing.expect(std.mem.indexOf(u8, detail, "USING INDEX") != null or
        std.mem.indexOf(u8, detail, "USING COVERING INDEX") != null);
}

test "query planner uses index for source map lookups" {
    var db = try init(":memory:");
    defer db.close();

    const detail = try getQueryPlanDetail(
        &db,
        "SELECT map_content FROM source_maps WHERE project = 'proj' AND release = '1.0' AND file_url = '/app.js';",
    ) orelse return error.TestUnexpectedResult;

    // Query planner should use an index (either idx_source_map_lookup
    // or the autoindex from the UNIQUE constraint on (project, release, file_url))
    try std.testing.expect(std.mem.indexOf(u8, detail, "USING INDEX") != null or
        std.mem.indexOf(u8, detail, "USING COVERING INDEX") != null);
}

test "init is idempotent - can be called multiple times" {
    var db = try init(":memory:");

    try std.testing.expect(try tableExists(&db, "dsn_keys"));
    try std.testing.expect(try tableExists(&db, "source_maps"));

    // Insert data
    {
        const stmt = try db.prepare(
            "INSERT INTO dsn_keys (public_key, project) VALUES ('key1', 'proj1');",
        );
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Re-run migrations (idempotent)
    db.migrate(&migrations) catch |err| {
        std.debug.print("Unexpected migration error: {}\n", .{err});
        return error.TestUnexpectedResult;
    };

    // Verify data is still there
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM dsn_keys;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }

    db.close();
}
