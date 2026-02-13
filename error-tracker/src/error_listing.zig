const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;

/// Query parameters for the error listing endpoint.
pub const ListParams = struct {
    project: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    source: ?[]const u8 = null, // "browser", "server", or null (all)
    session_id: ?[]const u8 = null, // filter by session_id in occurrence extra JSON
    resolved: bool = false,
    limit: u32 = 50,
    offset: u32 = 0,
};

/// Parse query parameters from a URL target string (e.g., "/api/errors?project=flowrent&limit=10").
/// Returns parsed ListParams or null if the path doesn't match /api/errors.
pub fn parseQueryParams(target: []const u8) ListParams {
    var params = ListParams{};

    // Find the query string after '?'
    const query_start = std.mem.indexOf(u8, target, "?") orelse return params;
    const query_string = target[query_start + 1 ..];

    // Parse key=value pairs separated by '&'
    var pairs = std.mem.splitScalar(u8, query_string, '&');
    while (pairs.next()) |pair| {
        const eq_pos = std.mem.indexOf(u8, pair, "=") orelse continue;
        const key = pair[0..eq_pos];
        const value = pair[eq_pos + 1 ..];

        if (std.mem.eql(u8, key, "project")) {
            if (value.len > 0) params.project = value;
        } else if (std.mem.eql(u8, key, "environment")) {
            if (value.len > 0) params.environment = value;
        } else if (std.mem.eql(u8, key, "source")) {
            if (std.mem.eql(u8, value, "browser") or std.mem.eql(u8, value, "server")) {
                params.source = value;
            }
        } else if (std.mem.eql(u8, key, "session_id")) {
            if (value.len > 0) params.session_id = value;
        } else if (std.mem.eql(u8, key, "resolved")) {
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
                params.resolved = true;
            } else {
                params.resolved = false;
            }
        } else if (std.mem.eql(u8, key, "limit")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch continue;
            params.limit = if (parsed > 200) 200 else if (parsed == 0) 50 else parsed;
        } else if (std.mem.eql(u8, key, "offset")) {
            params.offset = std.fmt.parseInt(u32, value, 10) catch 0;
        }
    }

    return params;
}

/// Error entry for the listing response.
const ErrorEntry = struct {
    id: i64,
    fingerprint: []const u8,
    project: []const u8,
    environment: []const u8,
    exception_type: []const u8,
    message: []const u8,
    count: i64,
    first_seen: []const u8,
    last_seen: []const u8,
    resolved: bool,
};

/// Build a WHERE clause into a stack buffer based on active filters.
/// Returns the number of bind parameters used (excluding resolved, which is always param 1).
const WhereResult = struct {
    buf: [512]u8,
    len: usize,
    bind_count: usize,
};

fn buildWhereClause(params: *const ListParams) WhereResult {
    var result = WhereResult{ .buf = undefined, .len = 0, .bind_count = 0 };
    const base = "WHERE resolved = ?";
    @memcpy(result.buf[0..base.len], base);
    result.len = base.len;

    if (params.project != null) {
        const frag = " AND project = ?";
        @memcpy(result.buf[result.len .. result.len + frag.len], frag);
        result.len += frag.len;
        result.bind_count += 1;
    }
    if (params.environment != null) {
        const frag = " AND environment = ?";
        @memcpy(result.buf[result.len .. result.len + frag.len], frag);
        result.len += frag.len;
        result.bind_count += 1;
    }
    if (params.source) |src| {
        if (std.mem.eql(u8, src, "browser")) {
            const frag = " AND id IN (SELECT error_id FROM error_occurrences WHERE request_method = 'BROWSER')";
            @memcpy(result.buf[result.len .. result.len + frag.len], frag);
            result.len += frag.len;
        } else if (std.mem.eql(u8, src, "server")) {
            const frag = " AND id NOT IN (SELECT error_id FROM error_occurrences WHERE request_method = 'BROWSER')";
            @memcpy(result.buf[result.len .. result.len + frag.len], frag);
            result.len += frag.len;
        }
        // source filter uses literal values in SQL, no bind params needed
    }
    if (params.session_id != null) {
        const frag = " AND id IN (SELECT error_id FROM error_occurrences WHERE json_extract(extra, '$.session_id') = ?)";
        @memcpy(result.buf[result.len .. result.len + frag.len], frag);
        result.len += frag.len;
        result.bind_count += 1;
    }

    return result;
}

fn whereSlice(result: *const WhereResult) []const u8 {
    return result.buf[0..result.len];
}

/// Bind the filter parameters to a statement. Resolved is bound at position 1,
/// then project, environment, and session_id follow in order.
fn bindFilterParams(stmt: sqlite.Statement, params: *const ListParams) !void {
    const resolved_val: i64 = if (params.resolved) 1 else 0;
    try stmt.bindInt(1, resolved_val);
    var pos: usize = 2;
    if (params.project) |proj| {
        try stmt.bindText(pos, proj);
        pos += 1;
    }
    if (params.environment) |env| {
        try stmt.bindText(pos, env);
        pos += 1;
    }
    if (params.session_id) |sid| {
        try stmt.bindText(pos, sid);
        pos += 1;
    }
}

/// Query the total count of errors matching the given filters.
fn queryTotalCount(db: *sqlite.Database, params: *const ListParams) !i64 {
    const where = buildWhereClause(params);
    // Build null-terminated SQL in a stack buffer
    var sql_buf: [600]u8 = undefined;
    const prefix = "SELECT COUNT(*) FROM errors ";
    const suffix = ";";
    const ws = whereSlice(&where);
    const total_len = prefix.len + ws.len + suffix.len;
    @memcpy(sql_buf[0..prefix.len], prefix);
    @memcpy(sql_buf[prefix.len .. prefix.len + ws.len], ws);
    @memcpy(sql_buf[prefix.len + ws.len .. total_len], suffix);
    sql_buf[total_len] = 0;
    const sql: [*:0]const u8 = sql_buf[0..total_len :0];

    const stmt = try db.prepare(sql);
    defer stmt.deinit();
    try bindFilterParams(stmt, params);
    var iter = stmt.query();
    if (iter.next()) |row| return row.int(0);
    return 0;
}

/// Query errors matching the given filters with pagination.
/// Returns the JSON response body as a slice allocated from the provided allocator.
pub fn queryAndFormat(allocator: std.mem.Allocator, db: *sqlite.Database, params: *const ListParams) ![]const u8 {
    // Get total count first
    const total = try queryTotalCount(db, params);

    const limit_val: i64 = @intCast(params.limit);
    const offset_val: i64 = @intCast(params.offset);

    const where = buildWhereClause(params);
    // Build null-terminated SQL in a stack buffer
    var sql_buf: [800]u8 = undefined;
    const prefix = "SELECT id, fingerprint, project, environment, exception_type, message, count, first_seen, last_seen, resolved FROM errors ";
    const ws = whereSlice(&where);
    const suffix = " ORDER BY last_seen DESC LIMIT ? OFFSET ?;";
    const total_len = prefix.len + ws.len + suffix.len;
    @memcpy(sql_buf[0..prefix.len], prefix);
    @memcpy(sql_buf[prefix.len .. prefix.len + ws.len], ws);
    @memcpy(sql_buf[prefix.len + ws.len .. total_len], suffix);
    sql_buf[total_len] = 0;
    const sql: [*:0]const u8 = sql_buf[0..total_len :0];

    const stmt = try db.prepare(sql);
    defer stmt.deinit();
    try bindFilterParams(stmt, params);

    // Bind LIMIT and OFFSET after filter params
    const limit_pos: usize = 2 + where.bind_count;
    try stmt.bindInt(limit_pos, limit_val);
    try stmt.bindInt(limit_pos + 1, offset_val);

    // Build JSON response
    var json_buf = std.ArrayList(u8).init(allocator);
    const writer = json_buf.writer();

    try writer.writeAll("{\"errors\": [");

    var iter = stmt.query();
    var first = true;
    while (iter.next()) |row| {
        if (!first) {
            try writer.writeByte(',');
        }
        first = false;

        const id = row.int(0);
        const fingerprint = row.text(1) orelse "";
        const project = row.text(2) orelse "";
        const environment = row.text(3) orelse "";
        const exception_type = row.text(4) orelse "";
        const message = row.text(5) orelse "";
        const count = row.int(6);
        const first_seen = row.text(7) orelse "";
        const last_seen = row.text(8) orelse "";
        const resolved_int = row.int(9);

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
        try writer.writeByte('}');
    }

    try writer.writeAll("], \"total\": ");
    try writer.print("{d}", .{total});
    try writer.writeAll(", \"limit\": ");
    try writer.print("{d}", .{params.limit});
    try writer.writeAll(", \"offset\": ");
    try writer.print("{d}", .{params.offset});
    try writer.writeByte('}');

    return json_buf.toOwnedSlice();
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

/// Helper to insert a test error into the database.
fn insertTestError(db: *sqlite.Database, project: []const u8, environment: []const u8, exception_type: []const u8, message: []const u8, resolved: bool) !i64 {
    const stmt = try db.prepare(
        "INSERT INTO errors (fingerprint, project, environment, exception_type, message, traceback, count, resolved) " ++
            "VALUES (?, ?, ?, ?, ?, 'traceback...', 1, ?);",
    );
    defer stmt.deinit();
    // Use a unique fingerprint based on the fields
    var fp_buf: [64]u8 = undefined;
    const fp = std.fmt.bufPrint(&fp_buf, "fp_{s}_{s}_{s}", .{ project, environment, exception_type }) catch "fp_default";
    try stmt.bindText(1, fp);
    try stmt.bindText(2, project);
    try stmt.bindText(3, environment);
    try stmt.bindText(4, exception_type);
    try stmt.bindText(5, message);
    try stmt.bindInt(6, if (resolved) 1 else 0);
    _ = try stmt.exec();
    return db.lastInsertRowId();
}

test "parseQueryParams with no query string" {
    const params = parseQueryParams("/api/errors");
    try std.testing.expect(params.project == null);
    try std.testing.expect(params.environment == null);
    try std.testing.expect(!params.resolved);
    try std.testing.expectEqual(@as(u32, 50), params.limit);
    try std.testing.expectEqual(@as(u32, 0), params.offset);
}

test "parseQueryParams with all parameters" {
    const params = parseQueryParams("/api/errors?project=flowrent&environment=prod&resolved=true&limit=10&offset=20");
    try std.testing.expectEqualStrings("flowrent", params.project.?);
    try std.testing.expectEqualStrings("prod", params.environment.?);
    try std.testing.expect(params.resolved);
    try std.testing.expectEqual(@as(u32, 10), params.limit);
    try std.testing.expectEqual(@as(u32, 20), params.offset);
}

test "parseQueryParams limits max to 200" {
    const params = parseQueryParams("/api/errors?limit=500");
    try std.testing.expectEqual(@as(u32, 200), params.limit);
}

test "parseQueryParams resolved defaults to false" {
    const params = parseQueryParams("/api/errors?resolved=false");
    try std.testing.expect(!params.resolved);
}

test "parseQueryParams resolved=1 works" {
    const params = parseQueryParams("/api/errors?resolved=1");
    try std.testing.expect(params.resolved);
}

test "parseQueryParams handles empty values" {
    const params = parseQueryParams("/api/errors?project=&limit=abc");
    try std.testing.expect(params.project == null);
    try std.testing.expectEqual(@as(u32, 50), params.limit); // falls back to default
}

test "queryAndFormat returns empty errors array when no data" {
    var db = try setupTestDb();
    defer db.close();

    const params = ListParams{};
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    // Verify it contains the expected structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"errors\": []") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"limit\": 50") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"offset\": 0") != null);
}

test "queryAndFormat returns unresolved errors by default" {
    var db = try setupTestDb();
    defer db.close();

    _ = try insertTestError(&db, "flowrent", "prod", "ValueError", "bad input", false);
    _ = try insertTestError(&db, "flowrent", "prod", "TypeError", "type error", true); // resolved

    const params = ListParams{};
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    // Should contain only the unresolved error
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") == null);
}

test "queryAndFormat filters by project" {
    var db = try setupTestDb();
    defer db.close();

    _ = try insertTestError(&db, "flowrent", "prod", "ValueError", "err1", false);
    _ = try insertTestError(&db, "other-app", "prod", "TypeError", "err2", false);

    var params = ListParams{};
    params.project = "flowrent";
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") == null);
}

test "queryAndFormat filters by environment" {
    var db = try setupTestDb();
    defer db.close();

    _ = try insertTestError(&db, "flowrent", "prod", "ValueError", "err1", false);
    _ = try insertTestError(&db, "flowrent", "dev", "TypeError", "err2", false);

    var params = ListParams{};
    params.environment = "prod";
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") == null);
}

test "queryAndFormat pagination works correctly" {
    var db = try setupTestDb();
    defer db.close();

    // Insert 5 errors
    for (0..5) |i| {
        var et_buf: [32]u8 = undefined;
        const et = std.fmt.bufPrint(&et_buf, "Error{d}", .{i}) catch "Error";
        var fp_buf: [64]u8 = undefined;
        const fp = std.fmt.bufPrint(&fp_buf, "fp_unique_{d}", .{i}) catch "fp";
        const stmt = try db.prepare(
            "INSERT INTO errors (fingerprint, project, environment, exception_type, message, traceback, count, resolved) " ++
                "VALUES (?, 'flowrent', 'prod', ?, 'msg', 'tb', 1, 0);",
        );
        defer stmt.deinit();
        try stmt.bindText(1, fp);
        try stmt.bindText(2, et);
        _ = try stmt.exec();
    }

    // Get first page (limit=2, offset=0)
    var params1 = ListParams{};
    params1.limit = 2;
    params1.offset = 0;
    const json1 = try queryAndFormat(std.testing.allocator, &db, &params1);
    defer std.testing.allocator.free(json1);

    try std.testing.expect(std.mem.indexOf(u8, json1, "\"total\": 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json1, "\"limit\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json1, "\"offset\": 0") != null);

    // Get second page (limit=2, offset=2)
    var params2 = ListParams{};
    params2.limit = 2;
    params2.offset = 2;
    const json2 = try queryAndFormat(std.testing.allocator, &db, &params2);
    defer std.testing.allocator.free(json2);

    try std.testing.expect(std.mem.indexOf(u8, json2, "\"total\": 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"limit\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"offset\": 2") != null);

    // Get page past the end (offset=10)
    var params3 = ListParams{};
    params3.limit = 2;
    params3.offset = 10;
    const json3 = try queryAndFormat(std.testing.allocator, &db, &params3);
    defer std.testing.allocator.free(json3);

    // Total should still be 5, but errors array should be empty
    try std.testing.expect(std.mem.indexOf(u8, json3, "\"total\": 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json3, "\"errors\": []") != null);
}

test "queryAndFormat response shape matches spec" {
    var db = try setupTestDb();
    defer db.close();

    _ = try insertTestError(&db, "flowrent", "prod", "ValueError", "invalid input", false);

    const params = ListParams{};
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    // Verify all expected fields are present in each error entry
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fingerprint\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"project\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"environment\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"exception_type\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"message\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"first_seen\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"last_seen\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"resolved\":") != null);

    // Verify top-level pagination fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"limit\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"offset\":") != null);
}

test "queryAndFormat shows resolved errors when resolved=true" {
    var db = try setupTestDb();
    defer db.close();

    _ = try insertTestError(&db, "flowrent", "prod", "ValueError", "err1", false);
    _ = try insertTestError(&db, "flowrent", "prod", "TypeError", "err2", true);

    var params = ListParams{};
    params.resolved = true;
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") == null);
}

test "queryAndFormat filters by project and environment combined" {
    var db = try setupTestDb();
    defer db.close();

    _ = try insertTestError(&db, "flowrent", "prod", "ValueError", "err1", false);
    _ = try insertTestError(&db, "flowrent", "dev", "TypeError", "err2", false);
    _ = try insertTestError(&db, "other-app", "prod", "KeyError", "err3", false);

    var params = ListParams{};
    params.project = "flowrent";
    params.environment = "prod";
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "KeyError") == null);
}

/// Helper to insert an error_occurrence for a given error_id with a specific request_method.
fn insertTestOccurrence(db: *sqlite.Database, error_id: i64, request_method: []const u8) !void {
    const stmt = try db.prepare(
        "INSERT INTO error_occurrences (error_id, request_method, traceback) VALUES (?, ?, 'traceback...');",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);
    try stmt.bindText(2, request_method);
    _ = try stmt.exec();
}

/// Helper to insert an error_occurrence with extra JSON context.
fn insertTestOccurrenceWithExtra(db: *sqlite.Database, error_id: i64, request_method: []const u8, extra: ?[]const u8) !void {
    const stmt = try db.prepare(
        "INSERT INTO error_occurrences (error_id, request_method, extra, traceback) VALUES (?, ?, ?, 'traceback...');",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);
    try stmt.bindText(2, request_method);
    if (extra) |e| {
        try stmt.bindText(3, e);
    } else {
        try stmt.bindNull(3);
    }
    _ = try stmt.exec();
}

test "parseQueryParams parses source=browser" {
    const params = parseQueryParams("/api/errors?source=browser");
    try std.testing.expectEqualStrings("browser", params.source.?);
}

test "parseQueryParams parses source=server" {
    const params = parseQueryParams("/api/errors?source=server");
    try std.testing.expectEqualStrings("server", params.source.?);
}

test "parseQueryParams rejects invalid source values" {
    const params = parseQueryParams("/api/errors?source=invalid");
    try std.testing.expect(params.source == null);
}

test "queryAndFormat filters by source=browser" {
    var db = try setupTestDb();
    defer db.close();

    // Insert two errors: one with BROWSER occurrence, one with GET occurrence
    const browser_id = try insertTestError(&db, "myapp", "prod", "TypeError", "browser error", false);
    const server_id = try insertTestError(&db, "myapp", "prod", "ValueError", "server error", false);
    try insertTestOccurrence(&db, browser_id, "BROWSER");
    try insertTestOccurrence(&db, server_id, "GET");

    var params = ListParams{};
    params.source = "browser";
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    // Should only contain the browser error
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") == null);
}

test "queryAndFormat filters by source=server" {
    var db = try setupTestDb();
    defer db.close();

    // Insert two errors: one with BROWSER occurrence, one with GET occurrence
    const browser_id = try insertTestError(&db, "myapp", "prod", "TypeError", "browser error", false);
    const server_id = try insertTestError(&db, "myapp", "prod", "ValueError", "server error", false);
    try insertTestOccurrence(&db, browser_id, "BROWSER");
    try insertTestOccurrence(&db, server_id, "GET");

    var params = ListParams{};
    params.source = "server";
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    // Should only contain the server error
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") == null);
}

test "queryAndFormat with no source filter returns all errors" {
    var db = try setupTestDb();
    defer db.close();

    const browser_id = try insertTestError(&db, "myapp", "prod", "TypeError", "browser error", false);
    const server_id = try insertTestError(&db, "myapp", "prod", "ValueError", "server error", false);
    try insertTestOccurrence(&db, browser_id, "BROWSER");
    try insertTestOccurrence(&db, server_id, "GET");

    // No source filter — should return both
    const params = ListParams{};
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") != null);
}

test "queryAndFormat source filter combined with project filter" {
    var db = try setupTestDb();
    defer db.close();

    // myapp: one browser, one server error
    const b1 = try insertTestError(&db, "myapp", "prod", "TypeError", "browser error", false);
    const s1 = try insertTestError(&db, "myapp", "prod", "ValueError", "server error", false);
    try insertTestOccurrence(&db, b1, "BROWSER");
    try insertTestOccurrence(&db, s1, "GET");

    // otherapp: one browser error
    const b2 = try insertTestError(&db, "otherapp", "prod", "KeyError", "other browser error", false);
    try insertTestOccurrence(&db, b2, "BROWSER");

    // Filter: source=browser AND project=myapp — should only return myapp's browser error
    var params = ListParams{};
    params.source = "browser";
    params.project = "myapp";
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "KeyError") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") == null);
}

test "parseQueryParams parses session_id" {
    const params = parseQueryParams("/api/errors?session_id=abc-123-def");
    try std.testing.expectEqualStrings("abc-123-def", params.session_id.?);
}

test "parseQueryParams ignores empty session_id" {
    const params = parseQueryParams("/api/errors?session_id=");
    try std.testing.expect(params.session_id == null);
}

test "queryAndFormat filters by session_id" {
    var db = try setupTestDb();
    defer db.close();

    // Insert two errors: one with session_id in extra, one without
    const err1 = try insertTestError(&db, "myapp", "prod", "TypeError", "browser error", false);
    const err2 = try insertTestError(&db, "myapp", "prod", "ValueError", "server error", false);
    try insertTestOccurrenceWithExtra(&db, err1, "BROWSER", "{\"session_id\": \"sess-abc-123\"}");
    try insertTestOccurrenceWithExtra(&db, err2, "GET", null);

    var params = ListParams{};
    params.session_id = "sess-abc-123";
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    // Should only contain the error with matching session_id
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") == null);
}

test "queryAndFormat session_id filter returns multiple errors from same session" {
    var db = try setupTestDb();
    defer db.close();

    const err1 = try insertTestError(&db, "myapp", "prod", "TypeError", "error 1", false);
    const err2 = try insertTestError(&db, "myapp", "prod", "ReferenceError", "error 2", false);
    const err3 = try insertTestError(&db, "myapp", "prod", "ValueError", "other session", false);
    try insertTestOccurrenceWithExtra(&db, err1, "BROWSER", "{\"session_id\": \"sess-shared\"}");
    try insertTestOccurrenceWithExtra(&db, err2, "BROWSER", "{\"session_id\": \"sess-shared\"}");
    try insertTestOccurrenceWithExtra(&db, err3, "BROWSER", "{\"session_id\": \"sess-different\"}");

    var params = ListParams{};
    params.session_id = "sess-shared";
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    // Should return both errors from sess-shared
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "TypeError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ReferenceError") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ValueError") == null);
}

test "queryAndFormat session_id with no matching errors returns empty" {
    var db = try setupTestDb();
    defer db.close();

    const err1 = try insertTestError(&db, "myapp", "prod", "TypeError", "error 1", false);
    try insertTestOccurrenceWithExtra(&db, err1, "BROWSER", "{\"session_id\": \"sess-abc\"}");

    var params = ListParams{};
    params.session_id = "sess-nonexistent";
    const json = try queryAndFormat(std.testing.allocator, &db, &params);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"total\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"errors\": []") != null);
}
