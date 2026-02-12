const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const log = std.log;

/// SQLite error with descriptive message
pub const SqliteError = error{
    OpenFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    ExecFailed,
    MigrationFailed,
    ColumnError,
};

/// Column value types returned by queries
pub const Value = union(enum) {
    int: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    null_val: void,
};

/// A single row from a query result
pub const Row = struct {
    stmt: *c.sqlite3_stmt,
    column_count: usize,

    /// Get column value as i64
    pub fn int(self: Row, col: usize) i64 {
        return c.sqlite3_column_int64(self.stmt, @intCast(col));
    }

    /// Get column value as f64
    pub fn float(self: Row, col: usize) f64 {
        return c.sqlite3_column_double(self.stmt, @intCast(col));
    }

    /// Get column value as text (borrowed pointer, valid until next step/finalize)
    pub fn text(self: Row, col: usize) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, @intCast(col));
        if (ptr == null) return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, @intCast(col)));
        return ptr[0..len];
    }

    /// Get column value type
    pub fn columnType(self: Row, col: usize) c_int {
        return c.sqlite3_column_type(self.stmt, @intCast(col));
    }

    /// Check if column is NULL
    pub fn isNull(self: Row, col: usize) bool {
        return c.sqlite3_column_type(self.stmt, @intCast(col)) == c.SQLITE_NULL;
    }
};

/// Iterator over query results
pub const RowIterator = struct {
    stmt: *c.sqlite3_stmt,
    column_count: usize,
    done: bool = false,

    /// Get next row, or null if no more rows
    pub fn next(self: *RowIterator) ?Row {
        if (self.done) return null;

        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_ROW) {
            return Row{
                .stmt = self.stmt,
                .column_count = self.column_count,
            };
        }

        self.done = true;
        if (rc != c.SQLITE_DONE) {
            const errmsg = c.sqlite3_errmsg(@ptrCast(@alignCast(c.sqlite3_db_handle(self.stmt))));
            log.err("sqlite step error: {s}", .{std.mem.span(errmsg)});
        }
        return null;
    }

    /// Finalize the statement and release resources
    pub fn deinit(self: *RowIterator) void {
        _ = c.sqlite3_finalize(self.stmt);
    }
};

/// Prepared statement wrapper with parameter binding
pub const Statement = struct {
    stmt: *c.sqlite3_stmt,
    db: *c.sqlite3,

    /// Bind an i64 value to parameter at given 1-based index
    pub fn bindInt(self: Statement, idx: usize, val: i64) SqliteError!void {
        const rc = c.sqlite3_bind_int64(self.stmt, @intCast(idx), val);
        if (rc != c.SQLITE_OK) {
            const errmsg = c.sqlite3_errmsg(self.db);
            log.err("sqlite bind int error at index {d}: {s}", .{ idx, std.mem.span(errmsg) });
            return SqliteError.BindFailed;
        }
    }

    /// Bind a f64 value to parameter at given 1-based index
    pub fn bindFloat(self: Statement, idx: usize, val: f64) SqliteError!void {
        const rc = c.sqlite3_bind_double(self.stmt, @intCast(idx), val);
        if (rc != c.SQLITE_OK) {
            const errmsg = c.sqlite3_errmsg(self.db);
            log.err("sqlite bind float error at index {d}: {s}", .{ idx, std.mem.span(errmsg) });
            return SqliteError.BindFailed;
        }
    }

    /// Bind a text value to parameter at given 1-based index
    pub fn bindText(self: Statement, idx: usize, val: []const u8) SqliteError!void {
        const rc = c.sqlite3_bind_text(self.stmt, @intCast(idx), val.ptr, @intCast(val.len), c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) {
            const errmsg = c.sqlite3_errmsg(self.db);
            log.err("sqlite bind text error at index {d}: {s}", .{ idx, std.mem.span(errmsg) });
            return SqliteError.BindFailed;
        }
    }

    /// Bind a null value to parameter at given 1-based index
    pub fn bindNull(self: Statement, idx: usize) SqliteError!void {
        const rc = c.sqlite3_bind_null(self.stmt, @intCast(idx));
        if (rc != c.SQLITE_OK) {
            const errmsg = c.sqlite3_errmsg(self.db);
            log.err("sqlite bind null error at index {d}: {s}", .{ idx, std.mem.span(errmsg) });
            return SqliteError.BindFailed;
        }
    }

    /// Execute the statement (for INSERT/UPDATE/DELETE) - returns number of changes
    pub fn exec(self: Statement) SqliteError!usize {
        const rc = c.sqlite3_step(self.stmt);
        if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
            const errmsg = c.sqlite3_errmsg(self.db);
            log.err("sqlite exec error: {s}", .{std.mem.span(errmsg)});
            return SqliteError.ExecFailed;
        }
        return @intCast(c.sqlite3_changes(self.db));
    }

    /// Execute and return an iterator over result rows
    pub fn query(self: Statement) RowIterator {
        const col_count: usize = @intCast(c.sqlite3_column_count(self.stmt));
        return RowIterator{
            .stmt = self.stmt,
            .column_count = col_count,
        };
    }

    /// Reset the statement for reuse with new parameters
    pub fn reset(self: Statement) void {
        _ = c.sqlite3_reset(self.stmt);
        _ = c.sqlite3_clear_bindings(self.stmt);
    }

    /// Finalize (free) the prepared statement
    pub fn deinit(self: Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }
};

/// Database connection wrapper
pub const Database = struct {
    db: *c.sqlite3,

    /// Open a SQLite database at the given path with recommended pragmas.
    /// Applies: WAL mode, busy_timeout=5000, synchronous=NORMAL, foreign_keys=ON.
    pub fn open(path: [*:0]const u8) SqliteError!Database {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &db);
        if (rc != c.SQLITE_OK or db == null) {
            if (db) |d| {
                const errmsg = c.sqlite3_errmsg(d);
                log.err("sqlite open failed: {s}", .{std.mem.span(errmsg)});
                _ = c.sqlite3_close(d);
            } else {
                log.err("sqlite open failed: out of memory", .{});
            }
            return SqliteError.OpenFailed;
        }

        const self = Database{ .db = db.? };

        // Apply recommended pragmas
        self.execSimple("PRAGMA journal_mode=WAL;") catch |err| {
            log.err("failed to set WAL mode", .{});
            return err;
        };
        self.execSimple("PRAGMA busy_timeout=5000;") catch |err| {
            log.err("failed to set busy_timeout", .{});
            return err;
        };
        self.execSimple("PRAGMA synchronous=NORMAL;") catch |err| {
            log.err("failed to set synchronous", .{});
            return err;
        };
        self.execSimple("PRAGMA foreign_keys=ON;") catch |err| {
            log.err("failed to enable foreign_keys", .{});
            return err;
        };

        log.info("sqlite database opened: {s}", .{path});
        return self;
    }

    /// Close the database connection
    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.db);
        log.info("sqlite database closed", .{});
    }

    /// Execute a simple SQL statement with no parameters and no result
    pub fn execSimple(self: Database, sql: [*:0]const u8) SqliteError!void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg) |msg| {
                log.err("sqlite exec error: {s}", .{std.mem.span(msg)});
                c.sqlite3_free(msg);
            }
            return SqliteError.ExecFailed;
        }
    }

    /// Execute a multi-statement SQL string (useful for migrations)
    pub fn execMulti(self: Database, sql: []const u8) SqliteError!void {
        // We need a null-terminated copy
        var buf: [8192]u8 = undefined;
        if (sql.len >= buf.len) {
            log.err("SQL too long for execMulti buffer ({d} bytes)", .{sql.len});
            return SqliteError.ExecFailed;
        }
        @memcpy(buf[0..sql.len], sql);
        buf[sql.len] = 0;
        const sql_z: [*:0]const u8 = buf[0..sql.len :0];

        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql_z, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg) |msg| {
                log.err("sqlite exec error: {s}", .{std.mem.span(msg)});
                c.sqlite3_free(msg);
            }
            return SqliteError.ExecFailed;
        }
    }

    /// Prepare a SQL statement for execution with parameter binding
    pub fn prepare(self: Database, sql: [*:0]const u8) SqliteError!Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            const errmsg = c.sqlite3_errmsg(self.db);
            log.err("sqlite prepare error: {s}", .{std.mem.span(errmsg)});
            return SqliteError.PrepareFailed;
        }
        return Statement{ .stmt = stmt.?, .db = self.db };
    }

    /// Get the rowid of the last inserted row
    pub fn lastInsertRowId(self: Database) i64 {
        return c.sqlite3_last_insert_rowid(self.db);
    }

    /// Get the number of rows changed by the last statement
    pub fn changes(self: Database) usize {
        return @intCast(c.sqlite3_changes(self.db));
    }

    /// Run schema migrations.
    /// Creates a `_meta` table on first run, reads `schema_version`,
    /// executes migrations with version > current inside a transaction,
    /// and updates `schema_version` after success.
    /// If any migration fails, logs the error and returns an error.
    pub fn migrate(self: Database, migrations: []const []const u8) SqliteError!void {
        // Create _meta table if it doesn't exist
        self.execSimple(
            "CREATE TABLE IF NOT EXISTS _meta (key TEXT PRIMARY KEY, value TEXT);",
        ) catch |err| {
            log.err("failed to create _meta table", .{});
            return err;
        };

        // Read current schema version
        const current_version = self.getSchemaVersion() catch |err| {
            log.err("failed to read schema version", .{});
            return err;
        };

        log.info("current schema version: {d}, {d} migrations available", .{ current_version, migrations.len });

        if (current_version >= migrations.len) {
            log.info("schema is up to date", .{});
            return;
        }

        // Apply pending migrations
        var version = current_version;
        while (version < migrations.len) : (version += 1) {
            log.info("applying migration {d}...", .{version + 1});

            // Run each migration in a transaction
            self.execSimple("BEGIN TRANSACTION;") catch |err| {
                log.err("failed to begin transaction for migration {d}", .{version + 1});
                return err;
            };

            self.execMulti(migrations[version]) catch |err| {
                log.err("migration {d} failed, rolling back", .{version + 1});
                self.execSimple("ROLLBACK;") catch {};
                return err;
            };

            // Update schema version
            self.setSchemaVersion(version + 1) catch |err| {
                log.err("failed to update schema version after migration {d}", .{version + 1});
                self.execSimple("ROLLBACK;") catch {};
                return err;
            };

            self.execSimple("COMMIT;") catch |err| {
                log.err("failed to commit migration {d}", .{version + 1});
                return err;
            };

            log.info("migration {d} applied successfully", .{version + 1});
        }

        log.info("all migrations applied, schema version is now {d}", .{migrations.len});
    }

    fn getSchemaVersion(self: Database) SqliteError!usize {
        const stmt = try self.prepare(
            "SELECT value FROM _meta WHERE key = 'schema_version';",
        );
        defer stmt.deinit();

        var iter = stmt.query();
        if (iter.next()) |row| {
            const val_text = row.text(0) orelse "0";
            return std.fmt.parseInt(usize, val_text, 10) catch 0;
        }
        return 0;
    }

    fn setSchemaVersion(self: Database, version: usize) SqliteError!void {
        const stmt = try self.prepare(
            "INSERT OR REPLACE INTO _meta (key, value) VALUES ('schema_version', ?);",
        );
        defer stmt.deinit();

        var buf: [20]u8 = undefined;
        const version_str = std.fmt.bufPrint(&buf, "{d}", .{version}) catch "0";
        try stmt.bindText(1, version_str);
        _ = try stmt.exec();
    }
};

// ============================================================
// Tests
// ============================================================

test "open and close in-memory database" {
    var db = try Database.open(":memory:");
    defer db.close();

    // Verify pragmas were applied by querying them
    {
        const stmt = try db.prepare("PRAGMA journal_mode;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            const mode = row.text(0) orelse "";
            // In-memory databases use "memory" journal mode, not "wal"
            try std.testing.expect(mode.len > 0);
        }
    }

    {
        const stmt = try db.prepare("PRAGMA busy_timeout;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 5000), row.int(0));
        }
    }

    {
        const stmt = try db.prepare("PRAGMA foreign_keys;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }
}

test "execSimple creates table" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.execSimple("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT);");
    try db.execSimple("INSERT INTO test (name) VALUES ('hello');");

    const stmt = try db.prepare("SELECT id, name FROM test;");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
        const name = row.text(1) orelse "";
        try std.testing.expectEqualStrings("hello", name);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "prepared statement with parameter binding" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.execSimple("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, score REAL);");

    // Insert with bound parameters
    {
        const stmt = try db.prepare("INSERT INTO test (name, score) VALUES (?, ?);");
        defer stmt.deinit();
        try stmt.bindText(1, "alice");
        try stmt.bindFloat(2, 95.5);
        _ = try stmt.exec();
    }

    // Query and verify
    {
        const stmt = try db.prepare("SELECT name, score FROM test WHERE name = ?;");
        defer stmt.deinit();
        try stmt.bindText(1, "alice");
        var iter = stmt.query();
        if (iter.next()) |row| {
            const name = row.text(0) orelse "";
            try std.testing.expectEqualStrings("alice", name);
            try std.testing.expectApproxEqAbs(@as(f64, 95.5), row.float(1), 0.001);
        } else {
            return error.TestUnexpectedResult;
        }
    }
}

test "null binding and detection" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.execSimple("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT);");

    {
        const stmt = try db.prepare("INSERT INTO test (name) VALUES (?);");
        defer stmt.deinit();
        try stmt.bindNull(1);
        _ = try stmt.exec();
    }

    {
        const stmt = try db.prepare("SELECT name FROM test;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expect(row.isNull(0));
            try std.testing.expectEqual(@as(?[]const u8, null), row.text(0));
        } else {
            return error.TestUnexpectedResult;
        }
    }
}

test "migration runner applies migrations in order" {
    var db = try Database.open(":memory:");
    defer db.close();

    const migrations = [_][]const u8{
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);",
        "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), title TEXT NOT NULL);",
        "CREATE INDEX idx_posts_user_id ON posts(user_id);",
    };

    try db.migrate(&migrations);

    // Verify tables exist
    {
        const stmt = try db.prepare("INSERT INTO users (name) VALUES ('test');");
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare("INSERT INTO posts (user_id, title) VALUES (1, 'hello');");
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify schema version
    {
        const stmt = try db.prepare("SELECT value FROM _meta WHERE key = 'schema_version';");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            const version = row.text(0) orelse "";
            try std.testing.expectEqualStrings("3", version);
        } else {
            return error.TestUnexpectedResult;
        }
    }
}

test "migration runner is idempotent" {
    var db = try Database.open(":memory:");
    defer db.close();

    const migrations = [_][]const u8{
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);",
    };

    // Run migrations twice - should not fail
    try db.migrate(&migrations);
    try db.migrate(&migrations);

    // Verify schema version is still 1
    {
        const stmt = try db.prepare("SELECT value FROM _meta WHERE key = 'schema_version';");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            const version = row.text(0) orelse "";
            try std.testing.expectEqualStrings("1", version);
        } else {
            return error.TestUnexpectedResult;
        }
    }
}

test "migration runner handles incremental migrations" {
    var db = try Database.open(":memory:");
    defer db.close();

    // First run: apply one migration
    const migrations_v1 = [_][]const u8{
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);",
    };
    try db.migrate(&migrations_v1);

    // Second run: add another migration
    const migrations_v2 = [_][]const u8{
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);",
        "ALTER TABLE users ADD COLUMN email TEXT;",
    };
    try db.migrate(&migrations_v2);

    // Verify both migrations applied
    {
        const stmt = try db.prepare("SELECT value FROM _meta WHERE key = 'schema_version';");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            const version = row.text(0) orelse "";
            try std.testing.expectEqualStrings("2", version);
        } else {
            return error.TestUnexpectedResult;
        }
    }

    // Verify email column exists
    {
        const stmt = try db.prepare("INSERT INTO users (name, email) VALUES ('test', 'test@example.com');");
        defer stmt.deinit();
        _ = try stmt.exec();
    }
}

test "lastInsertRowId returns correct id" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.execSimple("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT);");

    {
        const stmt = try db.prepare("INSERT INTO test (name) VALUES (?);");
        defer stmt.deinit();
        try stmt.bindText(1, "first");
        _ = try stmt.exec();
    }
    try std.testing.expectEqual(@as(i64, 1), db.lastInsertRowId());

    {
        const stmt = try db.prepare("INSERT INTO test (name) VALUES (?);");
        defer stmt.deinit();
        try stmt.bindText(1, "second");
        _ = try stmt.exec();
    }
    try std.testing.expectEqual(@as(i64, 2), db.lastInsertRowId());
}

test "statement reset allows reuse" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.execSimple("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT);");

    const stmt = try db.prepare("INSERT INTO test (name) VALUES (?);");
    defer stmt.deinit();

    try stmt.bindText(1, "first");
    _ = try stmt.exec();
    stmt.reset();

    try stmt.bindText(1, "second");
    _ = try stmt.exec();

    // Verify both rows exist
    const q = try db.prepare("SELECT COUNT(*) FROM test;");
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 2), row.int(0));
    } else {
        return error.TestUnexpectedResult;
    }
}
