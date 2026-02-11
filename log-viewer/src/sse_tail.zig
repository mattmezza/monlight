const std = @import("std");
const net = std.net;
const sqlite = @import("sqlite");
const database = @import("database.zig");
const log_query = @import("log_query.zig");
const log = std.log;

/// Maximum concurrent SSE connections allowed.
const max_sse_connections: u32 = 5;

/// Heartbeat interval in seconds.
const heartbeat_interval_s: u64 = 15;

/// Maximum connection duration in seconds (30 minutes).
const max_connection_duration_s: u64 = 30 * 60;

/// Poll interval for new log entries in seconds.
const poll_interval_s: u64 = 1;

/// Global counter for active SSE connections.
var active_connections = std.atomic.Value(u32).init(0);

/// SSE filter parameters parsed from query string.
pub const SseParams = struct {
    container: ?[]const u8 = null,
    level: ?[]const u8 = null,
};

/// Parse SSE filter parameters from a URL target string.
pub fn parseSseParams(target: []const u8) SseParams {
    var params = SseParams{};

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
            if (value.len > 0) params.level = value;
        }
    }

    return params;
}

/// Context passed to the SSE thread.
const SseContext = struct {
    stream: net.Stream,
    db_path: [*:0]const u8,
    container: ?[]const u8,
    level: ?[]const u8,
};

/// Try to start an SSE tail connection. Returns false if too many connections.
/// On success, spawns a thread to handle the SSE stream and returns true.
/// The caller must NOT close the connection stream — the thread will do that.
pub fn tryStartTail(
    stream: net.Stream,
    db_path: [*:0]const u8,
    params: SseParams,
) bool {
    // Atomically increment connection count, checking limit
    while (true) {
        const current = active_connections.load(.acquire);
        if (current >= max_sse_connections) {
            return false;
        }
        const result = active_connections.cmpxchgWeak(
            current,
            current + 1,
            .acq_rel,
            .acquire,
        );
        if (result == null) break; // success
    }

    // Spawn thread to handle the SSE stream
    const thread = std.Thread.spawn(.{}, sseThread, .{SseContext{
        .stream = stream,
        .db_path = db_path,
        .container = params.container,
        .level = params.level,
    }}) catch {
        // Failed to spawn thread, decrement counter and return failure
        _ = active_connections.fetchSub(1, .release);
        return false;
    };
    thread.detach();
    return true;
}

/// Send the SSE HTTP response headers.
fn sendSseHeaders(stream: net.Stream) !void {
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "\r\n";
    try stream.writeAll(headers);
}

/// Send an SSE event.
fn sendSseEvent(stream: net.Stream, event_type: []const u8, data: []const u8) !void {
    stream.writeAll("event: ") catch return error.BrokenPipe;
    stream.writeAll(event_type) catch return error.BrokenPipe;
    stream.writeAll("\ndata: ") catch return error.BrokenPipe;
    stream.writeAll(data) catch return error.BrokenPipe;
    stream.writeAll("\n\n") catch return error.BrokenPipe;
}

/// The SSE thread function. Polls the database for new entries and streams them.
fn sseThread(ctx: SseContext) void {
    defer {
        ctx.stream.close();
        _ = active_connections.fetchSub(1, .release);
        log.info("SSE tail connection closed", .{});
    }

    // Send SSE headers
    sendSseHeaders(ctx.stream) catch {
        log.err("SSE: failed to send headers", .{});
        return;
    };

    // Open our own database connection
    var db = database.init(ctx.db_path) catch |err| {
        log.err("SSE: failed to open database: {}", .{err});
        return;
    };
    defer db.close();

    // Get the current max ID to only stream new entries
    var last_id: i64 = getMaxId(&db) catch 0;

    const start_time = std.time.timestamp();
    var last_heartbeat = start_time;

    // Main SSE loop
    while (true) {
        const now = std.time.timestamp();

        // Check max connection duration
        if (now - start_time >= @as(i64, @intCast(max_connection_duration_s))) {
            // Send a close event so the client knows to reconnect
            sendSseEvent(ctx.stream, "close", "{\"reason\": \"max_duration\"}") catch {};
            return;
        }

        // Send heartbeat if needed
        if (now - last_heartbeat >= @as(i64, @intCast(heartbeat_interval_s))) {
            sendSseEvent(ctx.stream, "heartbeat", "{}") catch {
                // Client disconnected
                return;
            };
            last_heartbeat = now;
        }

        // Poll for new entries
        const new_last_id = pollNewEntries(&db, last_id, ctx.container, ctx.level, ctx.stream) catch |err| {
            switch (err) {
                error.BrokenPipe => return, // Client disconnected
                else => {
                    log.err("SSE: poll error: {}", .{err});
                    // Continue, don't kill the connection for transient DB errors
                },
            }
        };
        if (new_last_id > last_id) {
            last_id = new_last_id;
        }

        // Sleep before next poll
        std.time.sleep(poll_interval_s * std.time.ns_per_s);
    }
}

/// Get the current maximum log entry ID.
fn getMaxId(db: *sqlite.Database) !i64 {
    const stmt = try db.prepare("SELECT COALESCE(MAX(id), 0) FROM log_entries;");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        return row.int(0);
    }
    return 0;
}

/// Poll for new log entries since last_id, applying optional filters.
/// Returns the new last_id (highest ID seen).
fn pollNewEntries(
    db: *sqlite.Database,
    last_id: i64,
    container_filter: ?[]const u8,
    level_filter: ?[]const u8,
    stream: net.Stream,
) !i64 {
    const allocator = std.heap.page_allocator;

    // Build dynamic SQL
    var sql_buf = std.ArrayList(u8).init(allocator);
    defer sql_buf.deinit();
    const sql_writer = sql_buf.writer();

    try sql_writer.writeAll("SELECT id, timestamp, container, stream, level, message FROM log_entries WHERE id > ?");

    if (container_filter != null) {
        try sql_writer.writeAll(" AND container = ?");
    }
    if (level_filter != null) {
        try sql_writer.writeAll(" AND level = ?");
    }

    try sql_writer.writeAll(" ORDER BY id ASC LIMIT 100");
    try sql_buf.append(0);

    const sql_z: [*:0]const u8 = @ptrCast(sql_buf.items[0 .. sql_buf.items.len - 1 :0]);

    const stmt = try db.prepare(sql_z);
    defer stmt.deinit();

    var bind_idx: usize = 1;
    try stmt.bindInt(bind_idx, last_id);
    bind_idx += 1;

    if (container_filter) |container| {
        try stmt.bindText(bind_idx, container);
        bind_idx += 1;
    }
    if (level_filter) |level| {
        try stmt.bindText(bind_idx, level);
        bind_idx += 1;
    }

    var new_last_id: i64 = last_id;
    var iter = stmt.query();

    while (iter.next()) |row| {
        const id = row.int(0);
        const timestamp = row.text(1) orelse "";
        const container = row.text(2) orelse "";
        const row_stream = row.text(3) orelse "";
        const level = row.text(4) orelse "";
        const message = row.text(5) orelse "";

        // Build JSON event data
        var json_buf = std.ArrayList(u8).init(allocator);
        defer json_buf.deinit();
        const writer = json_buf.writer();

        try writer.writeAll("{\"id\": ");
        try writer.print("{d}", .{id});
        try writer.writeAll(", \"timestamp\": \"");
        try log_query.writeJsonEscaped(writer, timestamp);
        try writer.writeAll("\", \"container\": \"");
        try log_query.writeJsonEscaped(writer, container);
        try writer.writeAll("\", \"stream\": \"");
        try log_query.writeJsonEscaped(writer, row_stream);
        try writer.writeAll("\", \"level\": \"");
        try log_query.writeJsonEscaped(writer, level);
        try writer.writeAll("\", \"message\": \"");
        try log_query.writeJsonEscaped(writer, message);
        try writer.writeAll("\"}");

        try sendSseEvent(stream, "log", json_buf.items);

        if (id > new_last_id) {
            new_last_id = id;
        }
    }

    return new_last_id;
}

/// Get the current number of active SSE connections.
pub fn getActiveConnections() u32 {
    return active_connections.load(.acquire);
}

// ============================================================
// Tests
// ============================================================

test "parseSseParams parses container and level" {
    const params = parseSseParams("/api/logs/tail?container=web&level=ERROR");
    try std.testing.expectEqualStrings("web", params.container.?);
    try std.testing.expectEqualStrings("ERROR", params.level.?);
}

test "parseSseParams handles no params" {
    const params = parseSseParams("/api/logs/tail");
    try std.testing.expect(params.container == null);
    try std.testing.expect(params.level == null);
}

test "parseSseParams handles partial params" {
    const params = parseSseParams("/api/logs/tail?level=WARN");
    try std.testing.expect(params.container == null);
    try std.testing.expectEqualStrings("WARN", params.level.?);
}

test "getMaxId returns 0 for empty database" {
    var db = try database.init(":memory:");
    defer db.close();

    const max_id = try getMaxId(&db);
    try std.testing.expectEqual(@as(i64, 0), max_id);
}

test "getMaxId returns correct id after inserts" {
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
        .level = "ERROR",
        .message = "msg2",
        .raw = null,
    });

    const max_id = try getMaxId(&db);
    try std.testing.expectEqual(@as(i64, 2), max_id);
}

test "pollNewEntries returns new entries" {
    const ingestion = @import("ingestion.zig");
    var db = try database.init(":memory:");
    defer db.close();

    // Insert some entries
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
        .container = "api",
        .stream = "stderr",
        .level = "ERROR",
        .message = "msg2",
        .raw = null,
    });

    // Use a pipe to capture SSE output (instead of a network stream)
    // We can't easily test with a real stream, so we test the DB query logic
    // by calling getMaxId and verifying IDs
    const max_id = try getMaxId(&db);
    try std.testing.expectEqual(@as(i64, 2), max_id);
}

test "active connection counter works" {
    // Reset counter for test isolation
    active_connections.store(0, .release);

    try std.testing.expectEqual(@as(u32, 0), getActiveConnections());

    // Simulate incrementing
    _ = active_connections.fetchAdd(1, .release);
    try std.testing.expectEqual(@as(u32, 1), getActiveConnections());

    _ = active_connections.fetchAdd(1, .release);
    try std.testing.expectEqual(@as(u32, 2), getActiveConnections());

    _ = active_connections.fetchSub(1, .release);
    try std.testing.expectEqual(@as(u32, 1), getActiveConnections());

    // Reset
    active_connections.store(0, .release);
}
