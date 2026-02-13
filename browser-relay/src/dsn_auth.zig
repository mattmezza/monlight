const std = @import("std");
const log = std.log;
const sqlite = @import("sqlite");

/// Maximum project name length (matches VARCHAR(100) in schema).
const max_project_len = 100;

/// Result of a DSN public key authentication check.
pub const DsnAuthResult = struct {
    /// Whether the request was authenticated.
    authenticated: bool,
    /// The resolved project name (valid only if authenticated is true).
    project_buf: [max_project_len]u8,
    /// Length of the project name in project_buf.
    project_len: usize,

    /// Get the project name as a slice (valid only if authenticated is true).
    pub fn project(self: *const DsnAuthResult) []const u8 {
        return self.project_buf[0..self.project_len];
    }
};

/// Authenticate a browser ingestion request by checking the `X-Monlight-Key` header
/// against the `dsn_keys` table.
///
/// If the key is valid and active, returns an authenticated result with the project name.
/// If the key is missing, invalid, or deactivated, sends a 401 response and returns
/// an unauthenticated result.
pub fn authenticateDsn(
    request: *std.http.Server.Request,
    db: *sqlite.Database,
) DsnAuthResult {
    // Extract the X-Monlight-Key header
    const public_key = getMonlightKeyHeader(request) orelse {
        sendDsnUnauthorized(request);
        return .{ .authenticated = false, .project_buf = undefined, .project_len = 0 };
    };

    if (public_key.len == 0) {
        sendDsnUnauthorized(request);
        return .{ .authenticated = false, .project_buf = undefined, .project_len = 0 };
    }

    // Look up the key in the dsn_keys table
    var result = DsnAuthResult{
        .authenticated = false,
        .project_buf = undefined,
        .project_len = 0,
    };

    if (lookupProject(db, public_key, &result.project_buf)) |project_name| {
        result.authenticated = true;
        result.project_len = project_name.len;
    } else {
        sendDsnUnauthorized(request);
    }

    return result;
}

/// Look up a public key in the dsn_keys table and copy the project name into the output buffer.
/// Returns a slice of the output buffer containing the project name, or null if not found/inactive.
pub fn lookupProject(
    db: *sqlite.Database,
    public_key: []const u8,
    out_buf: *[max_project_len]u8,
) ?[]const u8 {
    const stmt = db.prepare(
        "SELECT project FROM dsn_keys WHERE public_key = ? AND active = 1;",
    ) catch {
        log.err("Failed to prepare DSN key lookup query", .{});
        return null;
    };
    defer stmt.deinit();

    stmt.bindText(1, public_key) catch {
        log.err("Failed to bind DSN key parameter", .{});
        return null;
    };

    var iter = stmt.query();
    if (iter.next()) |row| {
        const project_text = row.text(0) orelse return null;
        if (project_text.len > max_project_len) {
            log.err("Project name too long: {d} bytes", .{project_text.len});
            return null;
        }
        @memcpy(out_buf[0..project_text.len], project_text);
        return out_buf[0..project_text.len];
    }

    return null;
}

/// Extract the X-Monlight-Key header value from a request.
/// Header names are compared case-insensitively.
fn getMonlightKeyHeader(request: *std.http.Server.Request) ?[]const u8 {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (asciiEqlIgnoreCase(header.name, "x-monlight-key")) {
            return header.value;
        }
    }
    return null;
}

/// Send a 401 Unauthorized JSON response for DSN auth failures.
fn sendDsnUnauthorized(request: *std.http.Server.Request) void {
    const body =
        \\{"detail": "Invalid DSN key"}
    ;
    request.respond(body, .{
        .status = .unauthorized,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch |err| {
        log.err("Failed to send 401 DSN response: {}", .{err});
    };
}

/// Case-insensitive ASCII string comparison.
fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_byte, b_byte| {
        if (std.ascii.toLower(a_byte) != std.ascii.toLower(b_byte)) return false;
    }
    return true;
}

// ============================================================
// Tests
// ============================================================

const database = @import("database.zig");

/// Helper: insert a DSN key into the database for testing.
fn insertTestKey(db: *sqlite.Database, public_key: []const u8, project_name: []const u8, active: bool) !void {
    const stmt = try db.prepare(
        "INSERT INTO dsn_keys (public_key, project, active) VALUES (?, ?, ?);",
    );
    defer stmt.deinit();
    try stmt.bindText(1, public_key);
    try stmt.bindText(2, project_name);
    try stmt.bindInt(3, if (active) 1 else 0);
    _ = try stmt.exec();
}

test "lookupProject returns project for valid active key" {
    var db = try database.init(":memory:");
    defer db.close();

    try insertTestKey(&db, "abc123def456", "flowrent", true);

    var buf: [max_project_len]u8 = undefined;
    const project = lookupProject(&db, "abc123def456", &buf);
    try std.testing.expect(project != null);
    try std.testing.expectEqualStrings("flowrent", project.?);
}

test "lookupProject returns null for nonexistent key" {
    var db = try database.init(":memory:");
    defer db.close();

    var buf: [max_project_len]u8 = undefined;
    const project = lookupProject(&db, "nonexistent_key", &buf);
    try std.testing.expect(project == null);
}

test "lookupProject returns null for deactivated key" {
    var db = try database.init(":memory:");
    defer db.close();

    try insertTestKey(&db, "deactivated_key", "testproject", false);

    var buf: [max_project_len]u8 = undefined;
    const project = lookupProject(&db, "deactivated_key", &buf);
    try std.testing.expect(project == null);
}

test "lookupProject resolves correct project from multiple keys" {
    var db = try database.init(":memory:");
    defer db.close();

    try insertTestKey(&db, "key_alpha", "project_alpha", true);
    try insertTestKey(&db, "key_beta", "project_beta", true);
    try insertTestKey(&db, "key_gamma", "project_gamma", true);

    var buf: [max_project_len]u8 = undefined;

    const alpha = lookupProject(&db, "key_alpha", &buf);
    try std.testing.expect(alpha != null);
    try std.testing.expectEqualStrings("project_alpha", alpha.?);

    const beta = lookupProject(&db, "key_beta", &buf);
    try std.testing.expect(beta != null);
    try std.testing.expectEqualStrings("project_beta", beta.?);

    const gamma = lookupProject(&db, "key_gamma", &buf);
    try std.testing.expect(gamma != null);
    try std.testing.expectEqualStrings("project_gamma", gamma.?);
}

test "lookupProject distinguishes active and inactive keys" {
    var db = try database.init(":memory:");
    defer db.close();

    try insertTestKey(&db, "active_key", "active_project", true);
    try insertTestKey(&db, "inactive_key", "inactive_project", false);

    var buf: [max_project_len]u8 = undefined;

    const active = lookupProject(&db, "active_key", &buf);
    try std.testing.expect(active != null);
    try std.testing.expectEqualStrings("active_project", active.?);

    const inactive = lookupProject(&db, "inactive_key", &buf);
    try std.testing.expect(inactive == null);
}

test "lookupProject returns null for empty key" {
    var db = try database.init(":memory:");
    defer db.close();

    var buf: [max_project_len]u8 = undefined;
    const project = lookupProject(&db, "", &buf);
    try std.testing.expect(project == null);
}

test "asciiEqlIgnoreCase works for header names" {
    try std.testing.expect(asciiEqlIgnoreCase("x-monlight-key", "X-Monlight-Key"));
    try std.testing.expect(asciiEqlIgnoreCase("X-MONLIGHT-KEY", "x-monlight-key"));
    try std.testing.expect(asciiEqlIgnoreCase("x-monlight-key", "x-monlight-key"));
    try std.testing.expect(!asciiEqlIgnoreCase("x-monlight-key", "x-api-key"));
    try std.testing.expect(!asciiEqlIgnoreCase("x-monlight-key", "x-monlight-keys"));
}

test "DsnAuthResult project method returns correct slice" {
    var result = DsnAuthResult{
        .authenticated = true,
        .project_buf = undefined,
        .project_len = 8,
    };
    @memcpy(result.project_buf[0..8], "flowrent");
    try std.testing.expectEqualStrings("flowrent", result.project());
}
