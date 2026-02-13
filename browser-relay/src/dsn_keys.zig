const std = @import("std");
const log = std.log;
const sqlite = @import("sqlite");

/// Maximum project name length.
const max_project_len = 100;

/// DSN public key length in bytes (16 bytes = 32 hex chars).
const key_bytes = 16;

/// Handle POST /api/dsn-keys — Create a new DSN key.
/// Expects JSON body: {"project": "..."}
/// Returns 201 with {"public_key": "...", "project": "..."}
pub fn handleCreateDsnKey(
    request: *std.http.Server.Request,
    db: *sqlite.Database,
) !void {
    // Only POST is allowed
    if (request.head.method != .POST) {
        try sendJsonResponse(request, .method_not_allowed, "{\"detail\": \"Method not allowed\"}");
        return;
    }

    // Read request body
    const reader = try request.reader();
    var body_buf: [4096]u8 = undefined;
    const body_len = reader.readAll(&body_buf) catch {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Failed to read request body\"}");
        return;
    };
    const body = body_buf[0..body_len];

    if (body_len == 0) {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Empty request body\"}");
        return;
    }

    // Parse JSON
    const value = std.json.parseFromSliceLeaky(std.json.Value, std.heap.page_allocator, body, .{}) catch {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Invalid JSON\"}");
        return;
    };

    const obj = switch (value) {
        .object => |o| o,
        else => {
            try sendJsonResponse(request, .bad_request, "{\"detail\": \"Request body must be a JSON object\"}");
            return;
        },
    };

    // Required: project
    const project = getStringField(obj, "project") orelse {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Missing required field: project\"}");
        return;
    };

    if (project.len == 0 or project.len > max_project_len) {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Field 'project' must be 1-100 characters\"}");
        return;
    }

    // Generate random 32-character hex public key
    var random_bytes: [key_bytes]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var hex_buf: [key_bytes * 2]u8 = undefined;
    const hex_key = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)}) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Failed to generate key\"}");
        return;
    };

    // Insert into database
    const stmt = db.prepare(
        "INSERT INTO dsn_keys (public_key, project) VALUES (?, ?);",
    ) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    defer stmt.deinit();

    stmt.bindText(1, hex_key) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    stmt.bindText(2, project) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };

    _ = stmt.exec() catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };

    // Build response
    var resp_buf: [512]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"public_key\": \"{s}\", \"project\": \"{s}\"}}", .{ hex_key, project }) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Failed to build response\"}");
        return;
    };

    try sendJsonResponse(request, .created, resp_json);
}

/// Handle GET /api/dsn-keys — List all DSN keys.
/// Returns 200 with {"keys": [...]}
pub fn handleListDsnKeys(
    request: *std.http.Server.Request,
    db: *sqlite.Database,
) !void {
    // Only GET is allowed
    if (request.head.method != .GET) {
        try sendJsonResponse(request, .method_not_allowed, "{\"detail\": \"Method not allowed\"}");
        return;
    }

    const stmt = db.prepare(
        "SELECT id, public_key, project, active, created_at FROM dsn_keys ORDER BY id;",
    ) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    defer stmt.deinit();

    // Build JSON response
    var resp_buf: [32768]u8 = undefined;
    var stream = std.io.fixedBufferStream(&resp_buf);
    const writer = stream.writer();

    writer.writeAll("{\"keys\": [") catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Response too large\"}");
        return;
    };

    var iter = stmt.query();
    var count: usize = 0;
    while (iter.next()) |row| {
        if (count > 0) writer.writeByte(',') catch break;

        const id = row.int(0);
        const public_key = row.text(1) orelse "";
        const project_name = row.text(2) orelse "";
        const active = row.int(3) == 1;
        const created_at = row.text(4) orelse "";

        std.fmt.format(writer, "{{\"id\": {d}, \"public_key\": \"{s}\", \"project\": \"{s}\", \"active\": {s}, \"created_at\": \"{s}\"}}", .{
            id,
            public_key,
            project_name,
            if (active) "true" else "false",
            created_at,
        }) catch break;

        count += 1;
    }

    writer.writeAll("]}") catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Response too large\"}");
        return;
    };

    try sendJsonResponse(request, .ok, resp_buf[0..stream.pos]);
}

/// Handle DELETE /api/dsn-keys/{id} — Deactivate a DSN key (soft delete).
/// Returns 200 with {"status": "deactivated"} or 404.
pub fn handleDeleteDsnKey(
    request: *std.http.Server.Request,
    db: *sqlite.Database,
    path: []const u8,
) !void {
    // Only DELETE is allowed
    if (request.head.method != .DELETE) {
        try sendJsonResponse(request, .method_not_allowed, "{\"detail\": \"Method not allowed\"}");
        return;
    }

    // Extract ID from path: /api/dsn-keys/{id}
    const prefix = "/api/dsn-keys/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Invalid path\"}");
        return;
    }

    const id_str = path[prefix.len..];
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Invalid ID\"}");
        return;
    };

    // Check if the key exists
    const check_stmt = db.prepare(
        "SELECT id FROM dsn_keys WHERE id = ?;",
    ) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    defer check_stmt.deinit();

    check_stmt.bindInt(1, id) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };

    var check_iter = check_stmt.query();
    if (check_iter.next() == null) {
        try sendJsonResponse(request, .not_found, "{\"detail\": \"DSN key not found\"}");
        return;
    }

    // Soft delete: set active=false
    const update_stmt = db.prepare(
        "UPDATE dsn_keys SET active = 0 WHERE id = ?;",
    ) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    defer update_stmt.deinit();

    update_stmt.bindInt(1, id) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };

    _ = update_stmt.exec() catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };

    try sendJsonResponse(request, .ok, "{\"status\": \"deactivated\"}");
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn sendJsonResponse(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
) !void {
    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch |err| {
        log.err("Failed to send response: {}", .{err});
        return err;
    };
}

// ============================================================
// Unit Tests
// ============================================================

const database = @import("database.zig");

test "handleCreateDsnKey creates a key" {
    // This test just verifies database operations directly,
    // since the HTTP handler requires a real connection.
    var db = try database.init(":memory:");
    defer db.close();

    // Generate key bytes
    var random_bytes: [key_bytes]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var hex_buf: [key_bytes * 2]u8 = undefined;
    const hex_key = try std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)});

    // Insert
    const stmt = try db.prepare("INSERT INTO dsn_keys (public_key, project) VALUES (?, ?);");
    defer stmt.deinit();
    try stmt.bindText(1, hex_key);
    try stmt.bindText(2, "testproject");
    _ = try stmt.exec();

    // Verify
    const q = try db.prepare("SELECT public_key, project, active FROM dsn_keys WHERE id = 1;");
    defer q.deinit();
    var iter = q.query();
    if (iter.next()) |row| {
        const pk = row.text(0) orelse "";
        try std.testing.expectEqual(@as(usize, 32), pk.len);
        try std.testing.expectEqualStrings("testproject", row.text(1) orelse "");
        try std.testing.expectEqual(@as(i64, 1), row.int(2)); // active
    } else {
        return error.TestUnexpectedResult;
    }
}

test "DSN key deactivation (soft delete)" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert a key
    {
        const stmt = try db.prepare("INSERT INTO dsn_keys (public_key, project) VALUES ('testkey123456789012345678901234', 'proj');");
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify active
    {
        const stmt = try db.prepare("SELECT active FROM dsn_keys WHERE id = 1;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }

    // Deactivate
    {
        const stmt = try db.prepare("UPDATE dsn_keys SET active = 0 WHERE id = 1;");
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify deactivated
    {
        const stmt = try db.prepare("SELECT active FROM dsn_keys WHERE id = 1;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 0), row.int(0));
        }
    }
}

test "list DSN keys returns all keys" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert multiple keys
    {
        const stmt = try db.prepare("INSERT INTO dsn_keys (public_key, project) VALUES ('key1_pad_to_32_chars_00000000000', 'proj_a');");
        defer stmt.deinit();
        _ = try stmt.exec();
    }
    {
        const stmt = try db.prepare("INSERT INTO dsn_keys (public_key, project) VALUES ('key2_pad_to_32_chars_00000000000', 'proj_b');");
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Count
    const stmt = try db.prepare("SELECT COUNT(*) FROM dsn_keys;");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 2), row.int(0));
    }
}

test "hex key generation produces 32 char string" {
    var random_bytes: [key_bytes]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var hex_buf: [key_bytes * 2]u8 = undefined;
    const hex_key = try std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)});

    try std.testing.expectEqual(@as(usize, 32), hex_key.len);

    // Verify all chars are hex
    for (hex_key) |ch| {
        try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }
}

test "generated keys are unique" {
    var key1_bytes: [key_bytes]u8 = undefined;
    var key2_bytes: [key_bytes]u8 = undefined;
    std.crypto.random.bytes(&key1_bytes);
    std.crypto.random.bytes(&key2_bytes);

    var hex1: [key_bytes * 2]u8 = undefined;
    var hex2: [key_bytes * 2]u8 = undefined;
    const k1 = try std.fmt.bufPrint(&hex1, "{s}", .{std.fmt.fmtSliceHexLower(&key1_bytes)});
    const k2 = try std.fmt.bufPrint(&hex2, "{s}", .{std.fmt.fmtSliceHexLower(&key2_bytes)});

    try std.testing.expect(!std.mem.eql(u8, k1, k2));
}
