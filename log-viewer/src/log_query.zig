const std = @import("std");
const sqlite = @import("sqlite");
const log = std.log;
const log_level = @import("log_level.zig");

/// Percent-decode a URL-encoded string in place (result is always <= input length).
/// Returns the decoded slice. Only supports ASCII percent-encoded sequences.
pub fn percentDecode(buf: []u8, input: []const u8) []const u8 {
    var i: usize = 0;
    var out: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                buf[out] = input[i];
                out += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                buf[out] = input[i];
                out += 1;
                i += 1;
                continue;
            };
            buf[out] = (hi << 4) | lo;
            out += 1;
            i += 3;
        } else if (input[i] == '+') {
            buf[out] = ' ';
            out += 1;
            i += 1;
        } else {
            buf[out] = input[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

/// Query parameters for the log listing endpoint.
pub const LogQueryParams = struct {
    container: ?[]const u8 = null,
    level: ?[]const u8 = null,
    search: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    limit: u32 = 100,
    offset: u32 = 0,
    /// Internal buffer for decoded level value.
    level_buf: [32]u8 = undefined,
};

/// Parse query parameters from a URL target string.
pub fn parseQueryParams(target: []const u8) LogQueryParams {
    var params = LogQueryParams{};

    const query_start = std.mem.indexOf(u8, target, "?") orelse return params;
    const query_string = target[query_start + 1 ..];

    var pairs = std.mem.splitScalar(u8, query_string, '&');
    while (pairs.next()) |pair| {
        const eq_pos = std.mem.indexOf(u8, pair, "=") orelse continue;
        const key = pair[0..eq_pos];
        const value = pair[eq_pos + 1 ..];

        if (std.mem.eql(u8, key, "container")) {
            if (value.len > 0) params.container = value;
        } else if (std.mem.eql(u8, key, "level")) {
            if (value.len > 0) {
                if (value.len <= params.level_buf.len) {
                    params.level = percentDecode(&params.level_buf, value);
                } else {
                    params.level = value;
                }
            }
        } else if (std.mem.eql(u8, key, "search") or std.mem.eql(u8, key, "q")) {
            if (value.len > 0) params.search = value;
        } else if (std.mem.eql(u8, key, "since")) {
            if (value.len > 0) params.since = value;
        } else if (std.mem.eql(u8, key, "until")) {
            if (value.len > 0) params.until = value;
        } else if (std.mem.eql(u8, key, "limit")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch continue;
            params.limit = if (parsed > 500) 500 else if (parsed == 0) 100 else parsed;
        } else if (std.mem.eql(u8, key, "offset")) {
            params.offset = std.fmt.parseInt(u32, value, 10) catch 0;
        }
    }

    return params;
}

/// Build and execute the log query, returning a JSON response body.
pub fn queryLogs(db: *sqlite.Database, params: LogQueryParams) ![]const u8 {
    const allocator = std.heap.page_allocator;

    // Build SQL dynamically based on which parameters are present
    var sql_buf: std.ArrayList(u8) = .{};
    defer sql_buf.deinit(allocator);
    const sql_writer = sql_buf.writer(allocator);

    var count_sql_buf: std.ArrayList(u8) = .{};
    defer count_sql_buf.deinit(allocator);
    const count_writer = count_sql_buf.writer(allocator);

    // Base query
    try sql_writer.writeAll("SELECT id, timestamp, container, stream, level, message FROM log_entries");
    try count_writer.writeAll("SELECT COUNT(*) FROM log_entries");

    // Track which conditions we've added
    var where_added = false;

    // FTS search uses a JOIN
    if (params.search != null) {
        try sql_writer.writeAll(" WHERE id IN (SELECT rowid FROM log_entries_fts WHERE log_entries_fts MATCH ?)");
        try count_writer.writeAll(" WHERE id IN (SELECT rowid FROM log_entries_fts WHERE log_entries_fts MATCH ?)");
        where_added = true;
    }

    if (params.container != null) {
        const conj = if (where_added) " AND" else " WHERE";
        try sql_writer.writeAll(conj);
        try sql_writer.writeAll(" container = ?");
        try count_writer.writeAll(conj);
        try count_writer.writeAll(" container = ?");
        where_added = true;
    }

    if (params.level) |level_val| {
        const conj = if (where_added) " AND" else " WHERE";
        if (log_level.isHierarchical(level_val)) {
            const base = log_level.hierarchicalBase(level_val);
            // in_clause is a compile-time string literal from a switch on Level enum,
            // not derived from user input — safe to inline in SQL.
            if (log_level.levelsAtOrAbove(base)) |in_clause| {
                try sql_writer.writeAll(conj);
                try sql_writer.writeAll(" level IN ");
                try sql_writer.writeAll(in_clause);
                try count_writer.writeAll(conj);
                try count_writer.writeAll(" level IN ");
                try count_writer.writeAll(in_clause);
            } else {
                // Unrecognized level after >=, treat as exact match on full value
                try sql_writer.writeAll(conj);
                try sql_writer.writeAll(" level = ?");
                try count_writer.writeAll(conj);
                try count_writer.writeAll(" level = ?");
            }
        } else {
            try sql_writer.writeAll(conj);
            try sql_writer.writeAll(" level = ?");
            try count_writer.writeAll(conj);
            try count_writer.writeAll(" level = ?");
        }
        where_added = true;
    }

    if (params.since != null) {
        const conj = if (where_added) " AND" else " WHERE";
        try sql_writer.writeAll(conj);
        try sql_writer.writeAll(" timestamp >= ?");
        try count_writer.writeAll(conj);
        try count_writer.writeAll(" timestamp >= ?");
        where_added = true;
    }

    if (params.until != null) {
        const conj = if (where_added) " AND" else " WHERE";
        try sql_writer.writeAll(conj);
        try sql_writer.writeAll(" timestamp <= ?");
        try count_writer.writeAll(conj);
        try count_writer.writeAll(" timestamp <= ?");
    }

    try sql_writer.writeAll(" ORDER BY timestamp DESC LIMIT ? OFFSET ?");

    // Null-terminate SQL strings
    try sql_buf.append(allocator, 0);
    try count_sql_buf.append(allocator, 0);

    const sql_z: [*:0]const u8 = @ptrCast(sql_buf.items[0 .. sql_buf.items.len - 1 :0]);
    const count_sql_z: [*:0]const u8 = @ptrCast(count_sql_buf.items[0 .. count_sql_buf.items.len - 1 :0]);

    // Execute count query first
    const count_stmt = try db.prepare(count_sql_z);
    defer count_stmt.deinit();

    var bind_idx: usize = 1;
    if (params.search) |search| {
        try count_stmt.bindText(bind_idx, search);
        bind_idx += 1;
    }
    if (params.container) |container| {
        try count_stmt.bindText(bind_idx, container);
        bind_idx += 1;
    }
    if (params.level) |level_val| {
        if (log_level.needsLevelBind(level_val)) {
            try count_stmt.bindText(bind_idx, level_val);
            bind_idx += 1;
        }
    }
    if (params.since) |since| {
        try count_stmt.bindText(bind_idx, since);
        bind_idx += 1;
    }
    if (params.until) |until| {
        try count_stmt.bindText(bind_idx, until);
        bind_idx += 1;
    }

    var count_iter = count_stmt.query();
    const total: i64 = blk: {
        if (count_iter.next()) |row| {
            break :blk row.int(0);
        }
        break :blk 0;
    };

    // Execute main query
    const stmt = try db.prepare(sql_z);
    defer stmt.deinit();

    bind_idx = 1;
    if (params.search) |search| {
        try stmt.bindText(bind_idx, search);
        bind_idx += 1;
    }
    if (params.container) |container| {
        try stmt.bindText(bind_idx, container);
        bind_idx += 1;
    }
    if (params.level) |level_val| {
        const is_hier = log_level.isHierarchical(level_val);
        const hier_recognized = is_hier and log_level.levelsAtOrAbove(log_level.hierarchicalBase(level_val)) != null;
        if (!hier_recognized) {
            try stmt.bindText(bind_idx, level_val);
            bind_idx += 1;
        }
    }
    if (params.since) |since| {
        try stmt.bindText(bind_idx, since);
        bind_idx += 1;
    }
    if (params.until) |until| {
        try stmt.bindText(bind_idx, until);
        bind_idx += 1;
    }
    try stmt.bindInt(bind_idx, @as(i64, params.limit));
    bind_idx += 1;
    try stmt.bindInt(bind_idx, @as(i64, params.offset));

    // Build JSON response
    var json_buf: std.ArrayList(u8) = .{};
    const writer = json_buf.writer(allocator);

    try writer.writeAll("{\"logs\": [");

    var query_iter = stmt.query();
    var first = true;
    while (query_iter.next()) |row| {
        if (!first) {
            try writer.writeByte(',');
        }
        first = false;

        const id = row.int(0);
        const timestamp = row.text(1) orelse "";
        const container = row.text(2) orelse "";
        const stream = row.text(3) orelse "";
        const level = row.text(4) orelse "";
        const message = row.text(5) orelse "";

        try writer.writeAll("{\"id\": ");
        try writer.print("{d}", .{id});
        try writer.writeAll(", \"timestamp\": \"");
        try writeJsonEscaped(writer, timestamp);
        try writer.writeAll("\", \"container\": \"");
        try writeJsonEscaped(writer, container);
        try writer.writeAll("\", \"stream\": \"");
        try writeJsonEscaped(writer, stream);
        try writer.writeAll("\", \"level\": \"");
        try writeJsonEscaped(writer, level);
        try writer.writeAll("\", \"message\": \"");
        try writeJsonEscaped(writer, message);
        try writer.writeAll("\"}");
    }

    try writer.writeAll("], \"total\": ");
    try writer.print("{d}", .{total});
    try writer.writeAll(", \"limit\": ");
    try writer.print("{d}", .{params.limit});
    try writer.writeAll(", \"offset\": ");
    try writer.print("{d}", .{params.offset});
    try writer.writeByte('}');

    return json_buf.toOwnedSlice(allocator);
}

/// Build containers listing JSON response.
pub fn queryContainers(db: *sqlite.Database) ![]const u8 {
    const allocator = std.heap.page_allocator;

    const stmt = try db.prepare(
        "SELECT container, COUNT(*) as log_count FROM log_entries GROUP BY container ORDER BY container;",
    );
    defer stmt.deinit();

    var json_buf: std.ArrayList(u8) = .{};
    const writer = json_buf.writer(allocator);

    try writer.writeAll("{\"containers\": [");

    var iter = stmt.query();
    var first = true;
    while (iter.next()) |row| {
        if (!first) {
            try writer.writeByte(',');
        }
        first = false;

        const container = row.text(0) orelse continue;
        const log_count = row.int(1);

        try writer.writeAll("{\"name\": \"");
        try writeJsonEscaped(writer, container);
        try writer.writeAll("\", \"log_count\": ");
        try writer.print("{d}", .{log_count});
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");

    return json_buf.toOwnedSlice(allocator);
}

/// Build stats JSON response.
pub fn queryStats(db: *sqlite.Database) ![]const u8 {
    const allocator = std.heap.page_allocator;

    var json_buf: std.ArrayList(u8) = .{};
    const writer = json_buf.writer(allocator);

    try writer.writeAll("{");

    // Total logs
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM log_entries;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try writer.writeAll("\"total_logs\": ");
            try writer.print("{d}", .{row.int(0)});
        }
    }

    // Oldest and newest log timestamps
    {
        const stmt = try db.prepare("SELECT MIN(timestamp), MAX(timestamp) FROM log_entries;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try writer.writeAll(", \"oldest_log\": ");
            if (row.text(0)) |oldest| {
                try writer.writeByte('"');
                try writeJsonEscaped(writer, oldest);
                try writer.writeByte('"');
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(", \"newest_log\": ");
            if (row.text(1)) |newest| {
                try writer.writeByte('"');
                try writeJsonEscaped(writer, newest);
                try writer.writeByte('"');
            } else {
                try writer.writeAll("null");
            }
        }
    }

    // By level
    {
        const stmt = try db.prepare("SELECT level, COUNT(*) FROM log_entries GROUP BY level ORDER BY level;");
        defer stmt.deinit();
        try writer.writeAll(", \"by_level\": {");
        var iter = stmt.query();
        var first = true;
        while (iter.next()) |row| {
            if (!first) {
                try writer.writeByte(',');
            }
            first = false;
            const level = row.text(0) orelse continue;
            try writer.writeByte('"');
            try writeJsonEscaped(writer, level);
            try writer.writeAll("\": ");
            try writer.print("{d}", .{row.int(1)});
        }
        try writer.writeByte('}');
    }

    // By container
    {
        const stmt = try db.prepare("SELECT container, COUNT(*) FROM log_entries GROUP BY container ORDER BY container;");
        defer stmt.deinit();
        try writer.writeAll(", \"by_container\": {");
        var iter = stmt.query();
        var first = true;
        while (iter.next()) |row| {
            if (!first) {
                try writer.writeByte(',');
            }
            first = false;
            const container = row.text(0) orelse continue;
            try writer.writeByte('"');
            try writeJsonEscaped(writer, container);
            try writer.writeAll("\": ");
            try writer.print("{d}", .{row.int(1)});
        }
        try writer.writeByte('}');
    }

    try writer.writeByte('}');

    return json_buf.toOwnedSlice(allocator);
}

/// Build enhanced health JSON response.
pub fn queryHealth(db: *sqlite.Database) ![]const u8 {
    const allocator = std.heap.page_allocator;

    var json_buf: std.ArrayList(u8) = .{};
    const writer = json_buf.writer(allocator);

    try writer.writeAll("{\"status\": \"ok\"");

    // logs_indexed count
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM log_entries;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try writer.writeAll(", \"logs_indexed\": ");
            try writer.print("{d}", .{row.int(0)});
        }
    }

    // last_ingest timestamp
    {
        const stmt = try db.prepare("SELECT MAX(timestamp) FROM log_entries;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try writer.writeAll(", \"last_ingest\": ");
            if (row.text(0)) |ts| {
                try writer.writeByte('"');
                try writeJsonEscaped(writer, ts);
                try writer.writeByte('"');
            } else {
                try writer.writeAll("null");
            }
        }
    }

    try writer.writeByte('}');

    return json_buf.toOwnedSlice(allocator);
}

/// Escape a string for JSON output.
pub fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
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

test "parseQueryParams parses all parameters" {
    const params = parseQueryParams("/api/logs?container=web&level=ERROR&search=database&since=2025-01-20T00:00:00Z&until=2025-01-21T00:00:00Z&limit=50&offset=10");
    try std.testing.expectEqualStrings("web", params.container.?);
    try std.testing.expectEqualStrings("ERROR", params.level.?);
    try std.testing.expectEqualStrings("database", params.search.?);
    try std.testing.expectEqualStrings("2025-01-20T00:00:00Z", params.since.?);
    try std.testing.expectEqualStrings("2025-01-21T00:00:00Z", params.until.?);
    try std.testing.expectEqual(@as(u32, 50), params.limit);
    try std.testing.expectEqual(@as(u32, 10), params.offset);
}

test "parseQueryParams accepts q as alias for search" {
    const params = parseQueryParams("/api/logs?q=retention");
    try std.testing.expectEqualStrings("retention", params.search.?);
}

test "parseQueryParams uses defaults for missing params" {
    const params = parseQueryParams("/api/logs");
    try std.testing.expect(params.container == null);
    try std.testing.expect(params.level == null);
    try std.testing.expect(params.search == null);
    try std.testing.expect(params.since == null);
    try std.testing.expect(params.until == null);
    try std.testing.expectEqual(@as(u32, 100), params.limit);
    try std.testing.expectEqual(@as(u32, 0), params.offset);
}

test "parseQueryParams decodes percent-encoded level >=WARNING" {
    const params = parseQueryParams("/api/logs?level=%3E%3DWARNING");
    try std.testing.expectEqualStrings(">=WARNING", params.level.?);
}

test "parseQueryParams clamps limit to max 500" {
    const params = parseQueryParams("/api/logs?limit=1000");
    try std.testing.expectEqual(@as(u32, 500), params.limit);
}

test "queryLogs returns empty result for empty database" {
    const database = @import("database.zig");
    var db = try database.init(":memory:");
    defer db.close();

    const params = LogQueryParams{};
    const result = try queryLogs(&db, params);
    defer std.heap.page_allocator.free(result);

    // Should contain empty logs array
    try std.testing.expect(std.mem.indexOf(u8, result, "\"logs\": []") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\": 0") != null);
}

test "queryLogs filters by container" {
    const database = @import("database.zig");
    const ingestion = @import("ingestion.zig");
    var db = try database.init(":memory:");
    defer db.close();

    // Insert entries for different containers
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:00:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "web message",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:01:00Z",
        .container = "api",
        .stream = "stdout",
        .level = "INFO",
        .message = "api message",
        .raw = null,
    });

    const params = LogQueryParams{ .container = "web" };
    const result = try queryLogs(&db, params);
    defer std.heap.page_allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "web message") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "api message") == null);
}

test "queryLogs filters by level" {
    const database = @import("database.zig");
    const ingestion = @import("ingestion.zig");
    var db = try database.init(":memory:");
    defer db.close();

    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:00:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "info message",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:01:00Z",
        .container = "web",
        .stream = "stderr",
        .level = "ERROR",
        .message = "error message",
        .raw = null,
    });

    const params = LogQueryParams{ .level = "ERROR" };
    const result = try queryLogs(&db, params);
    defer std.heap.page_allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "error message") != null);
}

test "queryLogs hierarchical level filter >=WARNING" {
    const database = @import("database.zig");
    const ingestion = @import("ingestion.zig");
    var db = try database.init(":memory:");
    defer db.close();

    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:00:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "DEBUG",
        .message = "debug message",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:01:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "info message",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:02:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "WARNING",
        .message = "warning message",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:03:00Z",
        .container = "web",
        .stream = "stderr",
        .level = "ERROR",
        .message = "error message",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:04:00Z",
        .container = "web",
        .stream = "stderr",
        .level = "CRITICAL",
        .message = "critical message",
        .raw = null,
    });

    const params = LogQueryParams{ .level = ">=WARNING" };
    const result = try queryLogs(&db, params);
    defer std.heap.page_allocator.free(result);

    // Should match WARNING + ERROR + CRITICAL = 3
    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\": 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "warning message") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "error message") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "critical message") != null);
    // Should NOT contain debug or info
    try std.testing.expect(std.mem.indexOf(u8, result, "debug message") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "info message") == null);
}

test "queryLogs hierarchical level filter >=ERROR" {
    const database = @import("database.zig");
    const ingestion = @import("ingestion.zig");
    var db = try database.init(":memory:");
    defer db.close();

    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:00:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "info message",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:01:00Z",
        .container = "web",
        .stream = "stderr",
        .level = "ERROR",
        .message = "error message",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:02:00Z",
        .container = "web",
        .stream = "stderr",
        .level = "CRITICAL",
        .message = "critical message",
        .raw = null,
    });

    const params = LogQueryParams{ .level = ">=ERROR" };
    const result = try queryLogs(&db, params);
    defer std.heap.page_allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "error message") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "critical message") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "info message") == null);
}

test "queryLogs hierarchical level filter combined with container" {
    const database = @import("database.zig");
    const ingestion = @import("ingestion.zig");
    var db = try database.init(":memory:");
    defer db.close();

    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:00:00Z",
        .container = "web",
        .stream = "stderr",
        .level = "ERROR",
        .message = "web error",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:01:00Z",
        .container = "api",
        .stream = "stderr",
        .level = "ERROR",
        .message = "api error",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:02:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "web info",
        .raw = null,
    });

    const params = LogQueryParams{ .level = ">=ERROR", .container = "web" };
    const result = try queryLogs(&db, params);
    defer std.heap.page_allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "web error") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "api error") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "web info") == null);
}

test "queryLogs full-text search works" {
    const database = @import("database.zig");
    const ingestion = @import("ingestion.zig");
    var db = try database.init(":memory:");
    defer db.close();

    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:00:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "Connection established to database",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:01:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "User login successful",
        .raw = null,
    });

    const params = LogQueryParams{ .search = "database" };
    const result = try queryLogs(&db, params);
    defer std.heap.page_allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"total\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Connection established to database") != null);
}

test "queryContainers returns container list with counts" {
    const database = @import("database.zig");
    const ingestion = @import("ingestion.zig");
    var db = try database.init(":memory:");
    defer db.close();

    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:00:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "msg1",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:01:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "msg2",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:02:00Z",
        .container = "api",
        .stream = "stdout",
        .level = "INFO",
        .message = "msg3",
        .raw = null,
    });

    const result = try queryContainers(&db);
    defer std.heap.page_allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\": \"api\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\": \"web\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"log_count\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"log_count\": 1") != null);
}

test "queryStats returns statistics" {
    const database = @import("database.zig");
    const ingestion = @import("ingestion.zig");
    var db = try database.init(":memory:");
    defer db.close();

    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T10:00:00Z",
        .container = "web",
        .stream = "stdout",
        .level = "INFO",
        .message = "msg1",
        .raw = null,
    });
    try ingestion.insertLogEntry(&db, &.{
        .timestamp = "2025-01-20T11:00:00Z",
        .container = "web",
        .stream = "stderr",
        .level = "ERROR",
        .message = "msg2",
        .raw = null,
    });

    const result = try queryStats(&db);
    defer std.heap.page_allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"total_logs\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"oldest_log\": \"2025-01-20T10:00:00Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"newest_log\": \"2025-01-20T11:00:00Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"by_level\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"by_container\"") != null);
}

test "queryHealth returns health with logs count" {
    const database = @import("database.zig");
    var db = try database.init(":memory:");
    defer db.close();

    const result = try queryHealth(&db);
    defer std.heap.page_allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\": \"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"logs_indexed\": 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"last_ingest\": null") != null);
}
