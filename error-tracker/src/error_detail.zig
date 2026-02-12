const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// Extract the numeric ID from a path like "/api/errors/42" or "/api/errors/42?...".
/// Returns null if the path doesn't match or the ID is not a valid positive integer.
pub fn extractId(target: []const u8) ?i64 {
    const prefix = "/api/errors/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;

    const rest = target[prefix.len..];
    if (rest.len == 0) return null;

    // The ID is everything up to a '?' (query string) or end of string
    const id_str = if (std.mem.indexOf(u8, rest, "?")) |q| rest[0..q] else rest;
    if (id_str.len == 0) return null;

    const id = std.fmt.parseInt(i64, id_str, 10) catch return null;
    if (id <= 0) return null;
    return id;
}

/// Query a single error by ID and format the full detail JSON response (including occurrences).
/// Returns the JSON string allocated from the provided allocator, or null if not found.
pub fn queryAndFormat(allocator: std.mem.Allocator, db: *sqlite.Database, error_id: i64) !?[]const u8 {
    // Step 1: Query the error group record
    const stmt = try db.prepare(
        "SELECT id, fingerprint, project, environment, exception_type, message, traceback, " ++
            "count, first_seen, last_seen, resolved, resolved_at " ++
            "FROM errors WHERE id = ?;",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);

    var iter = stmt.query();
    const row = iter.next() orelse return null; // Not found

    // Extract all fields from the error row
    const id = row.int(0);
    const fingerprint = row.text(1) orelse "";
    const project = row.text(2) orelse "";
    const environment = row.text(3) orelse "";
    const exception_type = row.text(4) orelse "";
    const message = row.text(5) orelse "";
    const traceback = row.text(6) orelse "";
    const count = row.int(7);
    const first_seen = row.text(8) orelse "";
    const last_seen = row.text(9) orelse "";
    const resolved_int = row.int(10);
    const resolved_at = row.text(11); // nullable

    // Step 2: Build JSON response
    var json_buf = std.ArrayList(u8).init(allocator);
    const writer = json_buf.writer();

    try writer.writeAll("{\"id\": ");
    try writer.print("{d}", .{id});
    try writer.writeAll(", \"fingerprint\": \"");
    try writeJsonEscaped(writer, fingerprint);
    try writer.writeAll("\", \"project\": \"");
    try writeJsonEscaped(writer, project);
    try writer.writeAll("\", \"environment\": \"");
    try writeJsonEscaped(writer, environment);
    try writer.writeAll("\", \"exception_type\": \"");
    try writeJsonEscaped(writer, exception_type);
    try writer.writeAll("\", \"message\": \"");
    try writeJsonEscaped(writer, message);
    try writer.writeAll("\", \"traceback\": \"");
    try writeJsonEscaped(writer, traceback);
    try writer.writeAll("\", \"count\": ");
    try writer.print("{d}", .{count});
    try writer.writeAll(", \"first_seen\": \"");
    try writeJsonEscaped(writer, first_seen);
    try writer.writeAll("\", \"last_seen\": \"");
    try writeJsonEscaped(writer, last_seen);
    try writer.writeAll("\", \"resolved\": ");
    if (resolved_int != 0) {
        try writer.writeAll("true");
    } else {
        try writer.writeAll("false");
    }
    try writer.writeAll(", \"resolved_at\": ");
    if (resolved_at) |ra| {
        try writer.writeByte('"');
        try writeJsonEscaped(writer, ra);
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }

    // Step 3: Query occurrences (last 5, ordered by timestamp descending)
    try writer.writeAll(", \"occurrences\": [");

    const occ_stmt = try db.prepare(
        "SELECT id, timestamp, request_url, request_method, request_headers, user_id, extra, traceback " ++
            "FROM error_occurrences WHERE error_id = ? ORDER BY timestamp DESC, id DESC LIMIT 5;",
    );
    defer occ_stmt.deinit();
    try occ_stmt.bindInt(1, error_id);

    var occ_iter = occ_stmt.query();
    var first = true;
    while (occ_iter.next()) |occ_row| {
        if (!first) {
            try writer.writeByte(',');
        }
        first = false;

        const occ_id = occ_row.int(0);
        const occ_timestamp = occ_row.text(1) orelse "";
        const occ_request_url = occ_row.text(2); // nullable
        const occ_request_method = occ_row.text(3); // nullable
        const occ_request_headers = occ_row.text(4); // nullable (JSON string)
        const occ_user_id = occ_row.text(5); // nullable
        const occ_extra = occ_row.text(6); // nullable (JSON string)
        const occ_traceback = occ_row.text(7) orelse "";

        try writer.writeAll("{\"id\": ");
        try writer.print("{d}", .{occ_id});
        try writer.writeAll(", \"timestamp\": \"");
        try writeJsonEscaped(writer, occ_timestamp);

        // request_url — nullable string
        try writer.writeAll("\", \"request_url\": ");
        if (occ_request_url) |url| {
            try writer.writeByte('"');
            try writeJsonEscaped(writer, url);
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }

        // request_method — nullable string
        try writer.writeAll(", \"request_method\": ");
        if (occ_request_method) |method| {
            try writer.writeByte('"');
            try writeJsonEscaped(writer, method);
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }

        // request_headers — nullable JSON object (already stored as JSON string)
        try writer.writeAll(", \"request_headers\": ");
        if (occ_request_headers) |headers| {
            // Write raw JSON — it was stored as a JSON string already
            try writer.writeAll(headers);
        } else {
            try writer.writeAll("null");
        }

        // user_id — nullable string
        try writer.writeAll(", \"user_id\": ");
        if (occ_user_id) |uid| {
            try writer.writeByte('"');
            try writeJsonEscaped(writer, uid);
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }

        // extra — nullable JSON object (already stored as JSON string)
        try writer.writeAll(", \"extra\": ");
        if (occ_extra) |extra_val| {
            // Write raw JSON — it was stored as a JSON string already
            try writer.writeAll(extra_val);
        } else {
            try writer.writeAll("null");
        }

        // traceback — string
        try writer.writeAll(", \"traceback\": \"");
        try writeJsonEscaped(writer, occ_traceback);
        try writer.writeAll("\"}");
    }

    try writer.writeAll("]}");

    const result: []const u8 = try json_buf.toOwnedSlice();
    return result;
}

/// Write a string with JSON escaping (escapes backslash, double-quote, newline, tab, etc.)
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

const database = @import("database.zig");

fn setupTestDb() !sqlite.Database {
    return database.init(":memory:");
}

/// Helper to insert a test error into the database with explicit timestamps.
fn insertTestError(db: *sqlite.Database, project: []const u8, environment: []const u8, exception_type: []const u8, message: []const u8, traceback_text: []const u8, resolved: bool) !i64 {
    const stmt = try db.prepare(
        "INSERT INTO errors (fingerprint, project, environment, exception_type, message, traceback, count, resolved) " ++
            "VALUES (?, ?, ?, ?, ?, ?, 1, ?);",
    );
    defer stmt.deinit();
    var fp_buf: [64]u8 = undefined;
    const fp = std.fmt.bufPrint(&fp_buf, "fp_{s}_{s}_{s}", .{ project, environment, exception_type }) catch "fp_default";
    try stmt.bindText(1, fp);
    try stmt.bindText(2, project);
    try stmt.bindText(3, environment);
    try stmt.bindText(4, exception_type);
    try stmt.bindText(5, message);
    try stmt.bindText(6, traceback_text);
    try stmt.bindInt(7, if (resolved) 1 else 0);
    _ = try stmt.exec();
    return db.lastInsertRowId();
}

/// Helper to insert a test occurrence.
fn insertTestOccurrence(db: *sqlite.Database, error_id: i64, request_url: ?[]const u8, request_method: ?[]const u8, request_headers: ?[]const u8, user_id: ?[]const u8, extra: ?[]const u8, traceback_text: []const u8) !i64 {
    const stmt = try db.prepare(
        "INSERT INTO error_occurrences (error_id, traceback, request_url, request_method, request_headers, user_id, extra) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?);",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);
    try stmt.bindText(2, traceback_text);
    if (request_url) |url| {
        try stmt.bindText(3, url);
    } else {
        try stmt.bindNull(3);
    }
    if (request_method) |method| {
        try stmt.bindText(4, method);
    } else {
        try stmt.bindNull(4);
    }
    if (request_headers) |headers| {
        try stmt.bindText(5, headers);
    } else {
        try stmt.bindNull(5);
    }
    if (user_id) |uid| {
        try stmt.bindText(6, uid);
    } else {
        try stmt.bindNull(6);
    }
    if (extra) |extra_val| {
        try stmt.bindText(7, extra_val);
    } else {
        try stmt.bindNull(7);
    }
    _ = try stmt.exec();
    return db.lastInsertRowId();
}

test "extractId parses valid paths" {
    try std.testing.expectEqual(@as(?i64, 42), extractId("/api/errors/42"));
    try std.testing.expectEqual(@as(?i64, 1), extractId("/api/errors/1"));
    try std.testing.expectEqual(@as(?i64, 99999), extractId("/api/errors/99999"));
}

test "extractId handles query strings" {
    try std.testing.expectEqual(@as(?i64, 42), extractId("/api/errors/42?foo=bar"));
}

test "extractId rejects invalid paths" {
    try std.testing.expectEqual(@as(?i64, null), extractId("/api/errors/"));
    try std.testing.expectEqual(@as(?i64, null), extractId("/api/errors/abc"));
    try std.testing.expectEqual(@as(?i64, null), extractId("/api/errors"));
    try std.testing.expectEqual(@as(?i64, null), extractId("/api/errors/0"));
    try std.testing.expectEqual(@as(?i64, null), extractId("/api/errors/-1"));
    try std.testing.expectEqual(@as(?i64, null), extractId("/other/path/42"));
}

test "queryAndFormat returns null for non-existent ID" {
    var db = try setupTestDb();
    defer db.close();

    const result = try queryAndFormat(std.testing.allocator, &db, 999);
    try std.testing.expect(result == null);
}

test "queryAndFormat returns full error details" {
    var db = try setupTestDb();
    defer db.close();

    const error_id = try insertTestError(
        &db,
        "flowrent",
        "prod",
        "ValueError",
        "invalid input",
        "Traceback (most recent call last):\n  File \"/app/main.py\", line 42\nValueError: invalid input",
        false,
    );

    const json = (try queryAndFormat(std.testing.allocator, &db, error_id)).?;
    defer std.testing.allocator.free(json);

    // Verify all group-level fields are present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fingerprint\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"project\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"environment\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"exception_type\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"message\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"traceback\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"first_seen\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"last_seen\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resolved\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resolved_at\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"occurrences\":") != null);

    // Verify specific values
    try std.testing.expect(std.mem.indexOf(u8, json, "\"flowrent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ValueError\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"invalid input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resolved\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resolved_at\": null") != null);
}

test "queryAndFormat includes occurrences with request context" {
    var db = try setupTestDb();
    defer db.close();

    const error_id = try insertTestError(&db, "flowrent", "prod", "ValueError", "msg", "tb", false);

    // Insert occurrences with context
    _ = try insertTestOccurrence(
        &db,
        error_id,
        "/api/bookings",
        "POST",
        "{\"User-Agent\": \"test\"}",
        "user42",
        "{\"booking_id\": 456}",
        "Traceback occurrence 1",
    );
    _ = try insertTestOccurrence(
        &db,
        error_id,
        "/api/users",
        "GET",
        null,
        "user99",
        null,
        "Traceback occurrence 2",
    );

    const json = (try queryAndFormat(std.testing.allocator, &db, error_id)).?;
    defer std.testing.allocator.free(json);

    // Verify occurrences array has content
    try std.testing.expect(std.mem.indexOf(u8, json, "\"occurrences\": [") != null);

    // Verify occurrence fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"/api/bookings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"POST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"booking_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Traceback occurrence 1") != null);

    // Second occurrence
    try std.testing.expect(std.mem.indexOf(u8, json, "\"/api/users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"GET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user99\"") != null);
}

test "queryAndFormat returns empty occurrences array when no occurrences exist" {
    var db = try setupTestDb();
    defer db.close();

    const error_id = try insertTestError(&db, "flowrent", "prod", "ValueError", "msg", "tb", false);

    const json = (try queryAndFormat(std.testing.allocator, &db, error_id)).?;
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"occurrences\": []") != null);
}

test "queryAndFormat handles resolved error with resolved_at" {
    var db = try setupTestDb();
    defer db.close();

    const error_id = try insertTestError(&db, "flowrent", "prod", "ValueError", "msg", "tb", true);

    // Set resolved_at
    const upd = try db.prepare(
        "UPDATE errors SET resolved_at = '2025-01-23T15:30:00Z' WHERE id = ?;",
    );
    defer upd.deinit();
    try upd.bindInt(1, error_id);
    _ = try upd.exec();

    const json = (try queryAndFormat(std.testing.allocator, &db, error_id)).?;
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"resolved\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resolved_at\": \"2025-01-23T15:30:00Z\"") != null);
}

test "queryAndFormat handles null optional occurrence fields" {
    var db = try setupTestDb();
    defer db.close();

    const error_id = try insertTestError(&db, "flowrent", "prod", "ValueError", "msg", "tb", false);

    // Insert occurrence with all nullable fields as null
    _ = try insertTestOccurrence(&db, error_id, null, null, null, null, null, "tb_occ");

    const json = (try queryAndFormat(std.testing.allocator, &db, error_id)).?;
    defer std.testing.allocator.free(json);

    // Verify null fields are rendered as JSON null
    try std.testing.expect(std.mem.indexOf(u8, json, "\"request_url\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"request_method\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"request_headers\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user_id\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extra\": null") != null);
}
