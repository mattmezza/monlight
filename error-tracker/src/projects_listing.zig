const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// Query the database for distinct project names and format the JSON response.
/// Returns a JSON string like: {"projects": ["flowrent", "other-app"]}
/// Caller owns the returned memory (allocated via the provided allocator).
pub fn queryAndFormat(allocator: std.mem.Allocator, db: *sqlite.Database) ![]const u8 {
    const sql = "SELECT DISTINCT project FROM errors ORDER BY project ASC";
    var stmt = try db.prepare(sql);
    defer stmt.deinit();

    var iter = stmt.query();
    // Note: do NOT call iter.deinit() — stmt.deinit() already finalizes the underlying statement

    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"projects\": [");

    var first = true;
    while (iter.next()) |row| {
        const project = row.text(0) orelse continue;
        if (!first) {
            try writer.writeAll(", ");
        }
        first = false;
        try writer.writeByte('"');
        try writeJsonEscaped(writer, project);
        try writer.writeByte('"');
    }

    try writer.writeAll("]}");

    return buf.toOwnedSlice();
}

/// Write a string with JSON escaping.
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

// ============================================================
// Tests
// ============================================================

test "queryAndFormat returns empty projects list" {
    // Open in-memory database and create the errors table
    var db = try sqlite.Database.open(":memory:");
    defer db.close();

    try db.execSimple(
        \\CREATE TABLE errors (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  fingerprint VARCHAR(32),
        \\  project VARCHAR(100),
        \\  environment VARCHAR(20) DEFAULT 'prod',
        \\  exception_type VARCHAR(200),
        \\  message TEXT,
        \\  traceback TEXT,
        \\  count INTEGER DEFAULT 1,
        \\  first_seen DATETIME,
        \\  last_seen DATETIME,
        \\  resolved BOOLEAN DEFAULT 0,
        \\  resolved_at DATETIME
        \\);
    );

    const json = try queryAndFormat(std.testing.allocator, &db);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{\"projects\": []}", json);
}

test "queryAndFormat returns distinct project names sorted" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();

    try db.execSimple(
        \\CREATE TABLE errors (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  fingerprint VARCHAR(32),
        \\  project VARCHAR(100),
        \\  environment VARCHAR(20) DEFAULT 'prod',
        \\  exception_type VARCHAR(200),
        \\  message TEXT,
        \\  traceback TEXT,
        \\  count INTEGER DEFAULT 1,
        \\  first_seen DATETIME,
        \\  last_seen DATETIME,
        \\  resolved BOOLEAN DEFAULT 0,
        \\  resolved_at DATETIME
        \\);
    );

    // Insert errors for multiple projects (with duplicates)
    try db.execSimple("INSERT INTO errors (fingerprint, project, exception_type, message, traceback, first_seen, last_seen) VALUES ('fp1', 'flowrent', 'ValueError', 'msg', 'tb', '2025-01-01', '2025-01-01');");
    try db.execSimple("INSERT INTO errors (fingerprint, project, exception_type, message, traceback, first_seen, last_seen) VALUES ('fp2', 'flowrent', 'TypeError', 'msg2', 'tb2', '2025-01-02', '2025-01-02');");
    try db.execSimple("INSERT INTO errors (fingerprint, project, exception_type, message, traceback, first_seen, last_seen) VALUES ('fp3', 'other-app', 'KeyError', 'msg3', 'tb3', '2025-01-03', '2025-01-03');");
    try db.execSimple("INSERT INTO errors (fingerprint, project, exception_type, message, traceback, first_seen, last_seen) VALUES ('fp4', 'alpha-service', 'RuntimeError', 'msg4', 'tb4', '2025-01-04', '2025-01-04');");

    const json = try queryAndFormat(std.testing.allocator, &db);
    defer std.testing.allocator.free(json);

    // Projects should be sorted alphabetically and deduplicated
    try std.testing.expectEqualStrings("{\"projects\": [\"alpha-service\", \"flowrent\", \"other-app\"]}", json);
}

test "queryAndFormat handles single project" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();

    try db.execSimple(
        \\CREATE TABLE errors (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  fingerprint VARCHAR(32),
        \\  project VARCHAR(100),
        \\  environment VARCHAR(20) DEFAULT 'prod',
        \\  exception_type VARCHAR(200),
        \\  message TEXT,
        \\  traceback TEXT,
        \\  count INTEGER DEFAULT 1,
        \\  first_seen DATETIME,
        \\  last_seen DATETIME,
        \\  resolved BOOLEAN DEFAULT 0,
        \\  resolved_at DATETIME
        \\);
    );

    try db.execSimple("INSERT INTO errors (fingerprint, project, exception_type, message, traceback, first_seen, last_seen) VALUES ('fp1', 'flowrent', 'ValueError', 'msg', 'tb', '2025-01-01', '2025-01-01');");

    const json = try queryAndFormat(std.testing.allocator, &db);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{\"projects\": [\"flowrent\"]}", json);
}
