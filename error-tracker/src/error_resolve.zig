const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// Extract the numeric ID from a path like "/api/errors/42/resolve" or "/api/errors/42/resolve?...".
/// Returns null if the path doesn't match or the ID is not a valid positive integer.
pub fn extractResolveId(target: []const u8) ?i64 {
    const prefix = "/api/errors/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;

    const rest = target[prefix.len..];
    if (rest.len == 0) return null;

    // Find the "/resolve" suffix
    const slash_pos = std.mem.indexOf(u8, rest, "/") orelse return null;
    const id_str = rest[0..slash_pos];
    const after_id = rest[slash_pos..];

    // Must be exactly "/resolve" (possibly followed by "?" query string)
    if (std.mem.startsWith(u8, after_id, "/resolve")) {
        const after_resolve = after_id["/resolve".len..];
        if (after_resolve.len == 0 or after_resolve[0] == '?') {
            // Valid resolve path
        } else {
            return null; // e.g., "/api/errors/42/resolvefoo"
        }
    } else {
        return null;
    }

    if (id_str.len == 0) return null;

    const id = std.fmt.parseInt(i64, id_str, 10) catch return null;
    if (id <= 0) return null;
    return id;
}

/// Resolve an error by ID. Sets resolved=true and resolved_at to current timestamp.
/// Returns the result as a tagged union.
pub const ResolveResult = union(enum) {
    resolved: i64, // the error ID
    not_found: void,
};

pub fn resolve(db: *sqlite.Database, error_id: i64) !ResolveResult {
    // Check if the error exists
    const check_stmt = try db.prepare("SELECT id, resolved FROM errors WHERE id = ?;");
    defer check_stmt.deinit();
    try check_stmt.bindInt(1, error_id);
    var check_iter = check_stmt.query();

    if (check_iter.next()) |row| {
        const resolved_int = row.int(1);
        if (resolved_int != 0) {
            // Already resolved — idempotent, just return success
            return ResolveResult{ .resolved = error_id };
        }
    } else {
        return ResolveResult{ .not_found = {} };
    }

    // Mark as resolved
    const update_stmt = try db.prepare(
        "UPDATE errors SET resolved = 1, resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?;",
    );
    defer update_stmt.deinit();
    try update_stmt.bindInt(1, error_id);
    _ = try update_stmt.exec();

    return ResolveResult{ .resolved = error_id };
}

/// Format the resolve response as JSON into the provided buffer.
pub fn formatResponse(result: *const ResolveResult, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    switch (result.*) {
        .resolved => |id| {
            try writer.print("{{\"status\": \"resolved\", \"id\": {d}}}", .{id});
        },
        .not_found => {
            try writer.writeAll("{\"detail\": \"Error not found\"}");
        },
    }

    return stream.getWritten();
}

// ============================================================
// Tests
// ============================================================

const database = @import("database.zig");

fn setupTestDb() !sqlite.Database {
    return database.init(":memory:");
}

/// Helper to insert a test error into the database.
fn insertTestError(db: *sqlite.Database, resolved: bool) !i64 {
    const stmt = try db.prepare(
        "INSERT INTO errors (fingerprint, project, environment, exception_type, message, traceback, count, resolved) " ++
            "VALUES ('fp_test', 'flowrent', 'prod', 'ValueError', 'test msg', 'test tb', 1, ?);",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, if (resolved) 1 else 0);
    _ = try stmt.exec();
    return db.lastInsertRowId();
}

test "extractResolveId parses valid resolve paths" {
    try std.testing.expectEqual(@as(?i64, 42), extractResolveId("/api/errors/42/resolve"));
    try std.testing.expectEqual(@as(?i64, 1), extractResolveId("/api/errors/1/resolve"));
    try std.testing.expectEqual(@as(?i64, 99999), extractResolveId("/api/errors/99999/resolve"));
}

test "extractResolveId handles query strings" {
    try std.testing.expectEqual(@as(?i64, 42), extractResolveId("/api/errors/42/resolve?foo=bar"));
}

test "extractResolveId rejects invalid paths" {
    try std.testing.expectEqual(@as(?i64, null), extractResolveId("/api/errors/42"));
    try std.testing.expectEqual(@as(?i64, null), extractResolveId("/api/errors/42/"));
    try std.testing.expectEqual(@as(?i64, null), extractResolveId("/api/errors/42/resolvefoo"));
    try std.testing.expectEqual(@as(?i64, null), extractResolveId("/api/errors/abc/resolve"));
    try std.testing.expectEqual(@as(?i64, null), extractResolveId("/api/errors/0/resolve"));
    try std.testing.expectEqual(@as(?i64, null), extractResolveId("/api/errors/-1/resolve"));
    try std.testing.expectEqual(@as(?i64, null), extractResolveId("/api/errors//resolve"));
    try std.testing.expectEqual(@as(?i64, null), extractResolveId("/other/path/42/resolve"));
}

test "resolve marks unresolved error as resolved" {
    var db = try setupTestDb();
    defer db.close();

    const error_id = try insertTestError(&db, false);
    const result = try resolve(&db, error_id);

    switch (result) {
        .resolved => |id| try std.testing.expectEqual(error_id, id),
        .not_found => return error.TestUnexpectedResult,
    }

    // Verify the error is now resolved in the DB
    const stmt = try db.prepare("SELECT resolved, resolved_at FROM errors WHERE id = ?;");
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0)); // resolved = true
        try std.testing.expect(!row.isNull(1)); // resolved_at is set
    } else {
        return error.TestUnexpectedResult;
    }
}

test "resolve is idempotent for already-resolved error" {
    var db = try setupTestDb();
    defer db.close();

    const error_id = try insertTestError(&db, true);

    // Set resolved_at so we can verify it doesn't change
    {
        const upd = try db.prepare(
            "UPDATE errors SET resolved_at = '2025-01-20T10:00:00Z' WHERE id = ?;",
        );
        defer upd.deinit();
        try upd.bindInt(1, error_id);
        _ = try upd.exec();
    }

    const result = try resolve(&db, error_id);

    switch (result) {
        .resolved => |id| try std.testing.expectEqual(error_id, id),
        .not_found => return error.TestUnexpectedResult,
    }

    // Verify resolved_at was NOT updated (idempotent)
    const stmt = try db.prepare("SELECT resolved, resolved_at FROM errors WHERE id = ?;");
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0)); // still resolved
        const resolved_at = row.text(1) orelse "";
        try std.testing.expectEqualStrings("2025-01-20T10:00:00Z", resolved_at); // unchanged
    } else {
        return error.TestUnexpectedResult;
    }
}

test "resolve returns not_found for non-existent ID" {
    var db = try setupTestDb();
    defer db.close();

    const result = try resolve(&db, 999);

    switch (result) {
        .not_found => {}, // expected
        .resolved => return error.TestUnexpectedResult,
    }
}

test "formatResponse for resolved status" {
    const result = ResolveResult{ .resolved = 42 };
    var buf: [256]u8 = undefined;
    const json = try formatResponse(&result, &buf);
    try std.testing.expectEqualStrings("{\"status\": \"resolved\", \"id\": 42}", json);
}

test "formatResponse for not_found status" {
    const result = ResolveResult{ .not_found = {} };
    var buf: [256]u8 = undefined;
    const json = try formatResponse(&result, &buf);
    try std.testing.expectEqualStrings("{\"detail\": \"Error not found\"}", json);
}
