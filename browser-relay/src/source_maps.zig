const std = @import("std");
const log = std.log;
const sqlite = @import("sqlite");

/// Maximum source map content size (5MB).
const max_source_map_size = 5 * 1024 * 1024;

/// Handle POST /api/source-maps — Upload a source map.
/// Expects JSON body: {"project": "...", "release": "...", "file_url": "...", "map_content": "..."}
/// Validates source map JSON has version, sources, mappings fields.
/// Upserts on (project, release, file_url).
/// Returns 201 with {"status": "uploaded", "project": "...", "release": "...", "file_url": "..."}
pub fn handleUploadSourceMap(
    request: *std.http.Server.Request,
    db: *sqlite.Database,
) !void {
    if (request.head.method != .POST) {
        try sendJsonResponse(request, .method_not_allowed, "{\"detail\": \"Method not allowed\"}");
        return;
    }

    // Read request body — source maps can be large
    const reader = try request.reader();
    var body_buf: [max_source_map_size]u8 = undefined;
    const body_len = reader.readAll(&body_buf) catch {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Failed to read request body\"}");
        return;
    };
    const body = body_buf[0..body_len];

    if (body_len == 0) {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Empty request body\"}");
        return;
    }

    // Parse outer JSON
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

    // Required fields
    const project = getStringField(obj, "project") orelse {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Missing required field: project\"}");
        return;
    };
    if (project.len == 0 or project.len > 100) {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Field 'project' must be 1-100 characters\"}");
        return;
    }

    const release = getStringField(obj, "release") orelse {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Missing required field: release\"}");
        return;
    };
    if (release.len == 0 or release.len > 100) {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Field 'release' must be 1-100 characters\"}");
        return;
    }

    const file_url = getStringField(obj, "file_url") orelse {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Missing required field: file_url\"}");
        return;
    };
    if (file_url.len == 0 or file_url.len > 500) {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Field 'file_url' must be 1-500 characters\"}");
        return;
    }

    const map_content = getStringField(obj, "map_content") orelse {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Missing required field: map_content\"}");
        return;
    };

    // Validate source map format: must be valid JSON with version, sources, mappings
    if (!validateSourceMap(map_content)) {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Invalid source map format\"}");
        return;
    }

    // Upsert: INSERT OR REPLACE on (project, release, file_url)
    const stmt = db.prepare(
        "INSERT OR REPLACE INTO source_maps (project, release, file_url, map_content) VALUES (?, ?, ?, ?);",
    ) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    defer stmt.deinit();

    stmt.bindText(1, project) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    stmt.bindText(2, release) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    stmt.bindText(3, file_url) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    stmt.bindText(4, map_content) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };

    _ = stmt.exec() catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };

    // Build response
    var resp_buf: [1024]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"status\": \"uploaded\", \"project\": \"{s}\", \"release\": \"{s}\", \"file_url\": \"{s}\"}}", .{ project, release, file_url }) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Failed to build response\"}");
        return;
    };

    try sendJsonResponse(request, .created, resp_json);
}

/// Handle GET /api/source-maps — List source maps (metadata only).
/// Optional query parameter: ?project=... to filter by project.
/// Returns 200 with {"source_maps": [...], "total": N}
pub fn handleListSourceMaps(
    request: *std.http.Server.Request,
    db: *sqlite.Database,
) !void {
    if (request.head.method != .GET) {
        try sendJsonResponse(request, .method_not_allowed, "{\"detail\": \"Method not allowed\"}");
        return;
    }

    // Extract optional project filter from query string
    const project_filter = getQueryParam(request.head.target, "project");

    // Build JSON response
    var resp_buf: [65536]u8 = undefined;
    var stream = std.io.fixedBufferStream(&resp_buf);
    const writer = stream.writer();

    writer.writeAll("{\"source_maps\": [") catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Response too large\"}");
        return;
    };

    if (project_filter) |proj| {
        const stmt = db.prepare(
            "SELECT id, project, release, file_url, uploaded_at FROM source_maps WHERE project = ? ORDER BY id;",
        ) catch {
            try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
            return;
        };
        defer stmt.deinit();

        stmt.bindText(1, proj) catch {
            try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
            return;
        };

        const count = writeSourceMapRows(writer, stmt) catch {
            try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Response too large\"}");
            return;
        };

        std.fmt.format(writer, "], \"total\": {d}}}", .{count}) catch {
            try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Response too large\"}");
            return;
        };
    } else {
        const stmt = db.prepare(
            "SELECT id, project, release, file_url, uploaded_at FROM source_maps ORDER BY id;",
        ) catch {
            try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
            return;
        };
        defer stmt.deinit();

        const count = writeSourceMapRows(writer, stmt) catch {
            try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Response too large\"}");
            return;
        };

        std.fmt.format(writer, "], \"total\": {d}}}", .{count}) catch {
            try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Response too large\"}");
            return;
        };
    }

    try sendJsonResponse(request, .ok, resp_buf[0..stream.pos]);
}

/// Handle DELETE /api/source-maps/{id} — Delete a source map.
/// Returns 200 with {"status": "deleted"} or 404.
pub fn handleDeleteSourceMap(
    request: *std.http.Server.Request,
    db: *sqlite.Database,
    path: []const u8,
) !void {
    if (request.head.method != .DELETE) {
        try sendJsonResponse(request, .method_not_allowed, "{\"detail\": \"Method not allowed\"}");
        return;
    }

    const prefix = "/api/source-maps/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Invalid path\"}");
        return;
    }

    const id_str = path[prefix.len..];
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        try sendJsonResponse(request, .bad_request, "{\"detail\": \"Invalid ID\"}");
        return;
    };

    // Check if source map exists
    const check_stmt = db.prepare(
        "SELECT id FROM source_maps WHERE id = ?;",
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
        try sendJsonResponse(request, .not_found, "{\"detail\": \"Source map not found\"}");
        return;
    }

    // Delete
    const del_stmt = db.prepare(
        "DELETE FROM source_maps WHERE id = ?;",
    ) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };
    defer del_stmt.deinit();

    del_stmt.bindInt(1, id) catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };

    _ = del_stmt.exec() catch {
        try sendJsonResponse(request, .internal_server_error, "{\"detail\": \"Database error\"}");
        return;
    };

    try sendJsonResponse(request, .ok, "{\"status\": \"deleted\"}");
}

/// Validate that the source map content is valid JSON with required fields:
/// version (number), sources (array), mappings (string).
fn validateSourceMap(content: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, std.heap.page_allocator, content, .{}) catch return false;

    const obj = switch (value) {
        .object => |o| o,
        else => return false,
    };

    // Check version field (should be 3)
    const version = obj.get("version") orelse return false;
    switch (version) {
        .integer => {},
        .float => {},
        else => return false,
    }

    // Check sources field (should be an array)
    const sources = obj.get("sources") orelse return false;
    switch (sources) {
        .array => {},
        else => return false,
    }

    // Check mappings field (should be a string)
    const mappings = obj.get("mappings") orelse return false;
    switch (mappings) {
        .string => {},
        else => return false,
    }

    return true;
}

/// Extract a query parameter value from a URL target.
/// Returns null if not found.
fn getQueryParam(target: []const u8, param_name: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var query = target[qmark + 1 ..];

    while (query.len > 0) {
        // Find end of current parameter
        const amp = std.mem.indexOfScalar(u8, query, '&') orelse query.len;
        const pair = query[0..amp];

        // Split key=value
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            const key = pair[0..eq];
            const val = pair[eq + 1 ..];
            if (std.mem.eql(u8, key, param_name)) {
                return val;
            }
        }

        // Move to next parameter
        if (amp < query.len) {
            query = query[amp + 1 ..];
        } else {
            break;
        }
    }

    return null;
}

/// Write source map rows as JSON array elements.
fn writeSourceMapRows(writer: anytype, stmt: anytype) !usize {
    var iter = stmt.query();
    var count: usize = 0;
    while (iter.next()) |row| {
        if (count > 0) try writer.writeByte(',');

        const id = row.int(0);
        const project_name = row.text(1) orelse "";
        const release_name = row.text(2) orelse "";
        const file_url_val = row.text(3) orelse "";
        const uploaded_at = row.text(4) orelse "";

        try std.fmt.format(writer, "{{\"id\": {d}, \"project\": \"{s}\", \"release\": \"{s}\", \"file_url\": \"{s}\", \"uploaded_at\": \"{s}\"}}", .{
            id,
            project_name,
            release_name,
            file_url_val,
            uploaded_at,
        });

        count += 1;
    }
    return count;
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

test "validateSourceMap accepts valid source map" {
    const valid =
        \\{"version": 3, "sources": ["src/app.ts"], "mappings": "AAAA,SAAS"}
    ;
    try std.testing.expect(validateSourceMap(valid));
}

test "validateSourceMap rejects invalid JSON" {
    try std.testing.expect(!validateSourceMap("not json"));
}

test "validateSourceMap rejects non-object" {
    try std.testing.expect(!validateSourceMap("[1, 2, 3]"));
}

test "validateSourceMap rejects missing version" {
    const no_version =
        \\{"sources": ["app.ts"], "mappings": "AAAA"}
    ;
    try std.testing.expect(!validateSourceMap(no_version));
}

test "validateSourceMap rejects missing sources" {
    const no_sources =
        \\{"version": 3, "mappings": "AAAA"}
    ;
    try std.testing.expect(!validateSourceMap(no_sources));
}

test "validateSourceMap rejects missing mappings" {
    const no_mappings =
        \\{"version": 3, "sources": ["app.ts"]}
    ;
    try std.testing.expect(!validateSourceMap(no_mappings));
}

test "validateSourceMap rejects wrong field types" {
    const bad_sources =
        \\{"version": 3, "sources": "not array", "mappings": "AAAA"}
    ;
    try std.testing.expect(!validateSourceMap(bad_sources));

    const bad_mappings =
        \\{"version": 3, "sources": ["app.ts"], "mappings": 123}
    ;
    try std.testing.expect(!validateSourceMap(bad_mappings));
}

test "getQueryParam extracts parameter" {
    try std.testing.expectEqualStrings("myproj", getQueryParam("/api/source-maps?project=myproj", "project").?);
    try std.testing.expectEqualStrings("val", getQueryParam("/api/source-maps?a=1&project=val&b=2", "project").?);
    try std.testing.expect(getQueryParam("/api/source-maps", "project") == null);
    try std.testing.expect(getQueryParam("/api/source-maps?other=val", "project") == null);
}

test "source map upload and list via database" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert
    {
        const stmt = try db.prepare("INSERT INTO source_maps (project, release, file_url, map_content) VALUES (?, ?, ?, ?);");
        defer stmt.deinit();
        try stmt.bindText(1, "proj");
        try stmt.bindText(2, "1.0.0");
        try stmt.bindText(3, "/static/app.min.js");
        try stmt.bindText(4, "{\"version\":3,\"sources\":[\"app.ts\"],\"mappings\":\"AAAA\"}");
        _ = try stmt.exec();
    }

    // List
    {
        const stmt = try db.prepare("SELECT id, project, release, file_url, uploaded_at FROM source_maps ORDER BY id;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
            try std.testing.expectEqualStrings("proj", row.text(1) orelse "");
            try std.testing.expectEqualStrings("1.0.0", row.text(2) orelse "");
            try std.testing.expectEqualStrings("/static/app.min.js", row.text(3) orelse "");
        } else {
            return error.TestUnexpectedResult;
        }
    }
}

test "source map upsert replaces on conflict" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert first version
    {
        const stmt = try db.prepare("INSERT INTO source_maps (project, release, file_url, map_content) VALUES (?, ?, ?, ?);");
        defer stmt.deinit();
        try stmt.bindText(1, "proj");
        try stmt.bindText(2, "1.0");
        try stmt.bindText(3, "/app.js");
        try stmt.bindText(4, "old content");
        _ = try stmt.exec();
    }

    // Upsert
    {
        const stmt = try db.prepare("INSERT OR REPLACE INTO source_maps (project, release, file_url, map_content) VALUES (?, ?, ?, ?);");
        defer stmt.deinit();
        try stmt.bindText(1, "proj");
        try stmt.bindText(2, "1.0");
        try stmt.bindText(3, "/app.js");
        try stmt.bindText(4, "new content");
        _ = try stmt.exec();
    }

    // Verify content was replaced
    {
        const stmt = try db.prepare("SELECT map_content FROM source_maps WHERE project = 'proj' AND release = '1.0' AND file_url = '/app.js';");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqualStrings("new content", row.text(0) orelse "");
        } else {
            return error.TestUnexpectedResult;
        }
    }

    // Verify only one row
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM source_maps;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }
}

test "source map delete" {
    var db = try database.init(":memory:");
    defer db.close();

    // Insert
    {
        const stmt = try db.prepare("INSERT INTO source_maps (project, release, file_url, map_content) VALUES ('proj', '1.0', '/app.js', 'content');");
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Delete
    {
        const stmt = try db.prepare("DELETE FROM source_maps WHERE id = 1;");
        defer stmt.deinit();
        _ = try stmt.exec();
    }

    // Verify deleted
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM source_maps;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 0), row.int(0));
        }
    }
}
