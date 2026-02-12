const std = @import("std");
const sqlite = @import("sqlite");
const fingerprint_mod = @import("fingerprint.zig");
const log = std.log;

/// Maximum number of occurrences to keep per error group.
const max_occurrences: i64 = 5;

/// Error report parsed from the JSON request body.
pub const ErrorReport = struct {
    project: []const u8,
    environment: []const u8,
    exception_type: []const u8,
    message: []const u8,
    traceback: []const u8,
    request_url: ?[]const u8,
    request_method: ?[]const u8,
    request_headers: ?[]const u8, // stored as JSON string
    user_id: ?[]const u8,
    extra: ?[]const u8, // stored as JSON string
};

/// Result of ingesting an error report.
pub const IngestResult = struct {
    status: Status,
    id: i64,
    count: ?i64,
    fingerprint: ?[32]u8,
    is_new: bool, // true if this is a brand new fingerprint (triggers alert)

    pub const Status = enum {
        created,
        incremented,
        reopened,
    };
};

/// Validation error detail.
pub const ValidationError = struct {
    detail: []const u8,
};

/// Parse and validate a JSON request body into an ErrorReport.
/// Returns null and sets `validation_err` if validation fails.
/// The caller must free the returned allocations via the arena allocator.
pub fn parseAndValidate(
    allocator: std.mem.Allocator,
    body: []const u8,
    validation_err: *ValidationError,
) ?ErrorReport {
    return parseAndValidateInner(allocator, body, validation_err);
}

fn parseAndValidateInner(
    allocator: std.mem.Allocator,
    body: []const u8,
    validation_err: *ValidationError,
) ?ErrorReport {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        validation_err.detail = "Invalid JSON";
        return null;
    };

    // Must be an object
    const obj = switch (value) {
        .object => |o| o,
        else => {
            validation_err.detail = "Request body must be a JSON object";
            return null;
        },
    };

    // Required fields
    const project = getStringField(obj, "project") orelse {
        validation_err.detail = "Missing required field: project";
        return null;
    };
    const exception_type = getStringField(obj, "exception_type") orelse {
        validation_err.detail = "Missing required field: exception_type";
        return null;
    };
    const message = getStringField(obj, "message") orelse {
        validation_err.detail = "Missing required field: message";
        return null;
    };
    const traceback = getStringField(obj, "traceback") orelse {
        validation_err.detail = "Missing required field: traceback";
        return null;
    };

    // Field length limits
    if (project.len > 100) {
        validation_err.detail = "Field 'project' exceeds maximum length of 100 characters";
        return null;
    }
    if (exception_type.len > 200) {
        validation_err.detail = "Field 'exception_type' exceeds maximum length of 200 characters";
        return null;
    }

    // Optional fields
    const environment = getStringField(obj, "environment") orelse "prod";
    const request_url = getStringField(obj, "request_url");
    const request_method = getStringField(obj, "request_method");
    const user_id = getStringField(obj, "user_id");

    // request_headers and extra are JSON objects — serialize them back to string
    const request_headers = serializeJsonField(allocator, obj, "request_headers");
    const extra = serializeJsonField(allocator, obj, "extra");

    return ErrorReport{
        .project = project,
        .environment = environment,
        .exception_type = exception_type,
        .message = message,
        .traceback = traceback,
        .request_url = request_url,
        .request_method = request_method,
        .request_headers = request_headers,
        .user_id = user_id,
        .extra = extra,
    };
}

/// Extract a string field from a JSON object map, returning null if missing or wrong type.
fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Serialize a JSON field (object or array) back to a JSON string.
/// Returns null if the field is missing or null.
fn serializeJsonField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .null => null,
        else => {
            var buf = std.ArrayList(u8).init(allocator);
            std.json.stringify(val, .{}, buf.writer()) catch return null;
            return buf.toOwnedSlice() catch null;
        },
    };
}

/// Ingest an error report into the database.
/// Computes fingerprint, upserts the error, and creates an occurrence record.
/// Returns the result indicating whether the error was created, incremented, or reopened.
pub fn ingest(db: *sqlite.Database, report: *const ErrorReport) !IngestResult {
    // Step 1: Compute fingerprint
    const fp = fingerprint_mod.generate(
        report.project,
        report.exception_type,
        report.traceback,
    );
    const fp_str: []const u8 = &fp;

    // Step 2: Look up existing error with same fingerprint
    const existing = try findByFingerprint(db, fp_str);

    if (existing) |err_record| {
        if (err_record.resolved) {
            // Reopen resolved error
            try reopenError(db, err_record.id);
            try createOccurrence(db, err_record.id, report);
            try trimOccurrences(db, err_record.id);
            return IngestResult{
                .status = .reopened,
                .id = err_record.id,
                .count = err_record.count + 1,
                .fingerprint = fp,
                .is_new = false,
            };
        } else {
            // Increment existing unresolved error
            const new_count = try incrementError(db, err_record.id);
            try createOccurrence(db, err_record.id, report);
            try trimOccurrences(db, err_record.id);
            return IngestResult{
                .status = .incremented,
                .id = err_record.id,
                .count = new_count,
                .fingerprint = null,
                .is_new = false,
            };
        }
    } else {
        // Create new error
        const new_id = try createError(db, report, fp_str);
        try createOccurrence(db, new_id, report);
        return IngestResult{
            .status = .created,
            .id = new_id,
            .count = null,
            .fingerprint = fp,
            .is_new = true,
        };
    }
}

/// Existing error record (minimal fields needed for ingestion logic).
const ExistingError = struct {
    id: i64,
    resolved: bool,
    count: i64,
};

/// Find an existing error by fingerprint (checks both resolved and unresolved).
/// Returns the first match, preferring unresolved.
fn findByFingerprint(db: *sqlite.Database, fingerprint: []const u8) !?ExistingError {
    // First try to find an unresolved error
    {
        const stmt = try db.prepare(
            "SELECT id, resolved, count FROM errors WHERE fingerprint = ? AND resolved = 0 LIMIT 1;",
        );
        defer stmt.deinit();
        try stmt.bindText(1, fingerprint);
        var iter = stmt.query();
        if (iter.next()) |row| {
            return ExistingError{
                .id = row.int(0),
                .resolved = false,
                .count = row.int(2),
            };
        }
    }

    // Then check for a resolved error
    {
        const stmt = try db.prepare(
            "SELECT id, resolved, count FROM errors WHERE fingerprint = ? AND resolved = 1 ORDER BY last_seen DESC LIMIT 1;",
        );
        defer stmt.deinit();
        try stmt.bindText(1, fingerprint);
        var iter = stmt.query();
        if (iter.next()) |row| {
            return ExistingError{
                .id = row.int(0),
                .resolved = true,
                .count = row.int(2),
            };
        }
    }

    return null;
}

/// Increment an existing unresolved error's count and update last_seen.
fn incrementError(db: *sqlite.Database, error_id: i64) !i64 {
    const stmt = try db.prepare(
        "UPDATE errors SET count = count + 1, last_seen = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?;",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);
    _ = try stmt.exec();

    // Read back the new count
    const q = try db.prepare("SELECT count FROM errors WHERE id = ?;");
    defer q.deinit();
    try q.bindInt(1, error_id);
    var iter = q.query();
    if (iter.next()) |row| {
        return row.int(0);
    }
    return 0;
}

/// Reopen a resolved error: set resolved=false, clear resolved_at, increment count, update last_seen.
fn reopenError(db: *sqlite.Database, error_id: i64) !void {
    const stmt = try db.prepare(
        "UPDATE errors SET resolved = 0, resolved_at = NULL, count = count + 1, " ++
            "last_seen = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?;",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);
    _ = try stmt.exec();
}

/// Create a new error record.
fn createError(db: *sqlite.Database, report: *const ErrorReport, fingerprint: []const u8) !i64 {
    const stmt = try db.prepare(
        "INSERT INTO errors (fingerprint, project, environment, exception_type, message, traceback) " ++
            "VALUES (?, ?, ?, ?, ?, ?);",
    );
    defer stmt.deinit();
    try stmt.bindText(1, fingerprint);
    try stmt.bindText(2, report.project);
    try stmt.bindText(3, report.environment);
    try stmt.bindText(4, report.exception_type);
    try stmt.bindText(5, report.message);
    try stmt.bindText(6, report.traceback);
    _ = try stmt.exec();
    return db.lastInsertRowId();
}

/// Create an occurrence record for an error.
fn createOccurrence(db: *sqlite.Database, error_id: i64, report: *const ErrorReport) !void {
    const stmt = try db.prepare(
        "INSERT INTO error_occurrences (error_id, traceback, request_url, request_method, request_headers, user_id, extra) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?);",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, error_id);
    try stmt.bindText(2, report.traceback);
    if (report.request_url) |url| {
        try stmt.bindText(3, url);
    } else {
        try stmt.bindNull(3);
    }
    if (report.request_method) |method| {
        try stmt.bindText(4, method);
    } else {
        try stmt.bindNull(4);
    }
    if (report.request_headers) |headers| {
        try stmt.bindText(5, headers);
    } else {
        try stmt.bindNull(5);
    }
    if (report.user_id) |uid| {
        try stmt.bindText(6, uid);
    } else {
        try stmt.bindNull(6);
    }
    if (report.extra) |extra_val| {
        try stmt.bindText(7, extra_val);
    } else {
        try stmt.bindNull(7);
    }
    _ = try stmt.exec();
}

/// Trim occurrences for an error to keep only the most recent `max_occurrences`.
fn trimOccurrences(db: *sqlite.Database, error_id: i64) !void {
    // Count current occurrences
    const count_stmt = try db.prepare(
        "SELECT COUNT(*) FROM error_occurrences WHERE error_id = ?;",
    );
    defer count_stmt.deinit();
    try count_stmt.bindInt(1, error_id);
    var count_iter = count_stmt.query();
    const count: i64 = if (count_iter.next()) |row| row.int(0) else 0;

    if (count <= max_occurrences) return;

    // Delete the oldest occurrences beyond the limit
    const del_stmt = try db.prepare(
        "DELETE FROM error_occurrences WHERE id IN (" ++
            "SELECT id FROM error_occurrences WHERE error_id = ? ORDER BY timestamp ASC, id ASC LIMIT ?" ++
            ");",
    );
    defer del_stmt.deinit();
    try del_stmt.bindInt(1, error_id);
    try del_stmt.bindInt(2, count - max_occurrences);
    _ = try del_stmt.exec();
}

/// Format the ingestion result as a JSON response body.
/// Uses the provided buffer for formatting.
pub fn formatResponse(result: *const IngestResult, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    switch (result.status) {
        .created => {
            try writer.print(
                "{{\"status\": \"created\", \"id\": {d}, \"fingerprint\": \"{s}\"}}",
                .{ result.id, @as([]const u8, &result.fingerprint.?) },
            );
        },
        .incremented => {
            try writer.print(
                "{{\"status\": \"incremented\", \"id\": {d}, \"count\": {d}}}",
                .{ result.id, result.count.? },
            );
        },
        .reopened => {
            // Reopened errors return 201 with same format as incremented
            try writer.print(
                "{{\"status\": \"reopened\", \"id\": {d}, \"count\": {d}}}",
                .{ result.id, result.count.? },
            );
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

test "parseAndValidate accepts valid request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"project": "flowrent", "exception_type": "ValueError", "message": "invalid input", "traceback": "Traceback...", "environment": "prod"}
    ;
    var err: ValidationError = .{ .detail = "" };
    const report = parseAndValidate(allocator, body, &err);
    try std.testing.expect(report != null);
    try std.testing.expectEqualStrings("flowrent", report.?.project);
    try std.testing.expectEqualStrings("ValueError", report.?.exception_type);
    try std.testing.expectEqualStrings("invalid input", report.?.message);
    try std.testing.expectEqualStrings("Traceback...", report.?.traceback);
    try std.testing.expectEqualStrings("prod", report.?.environment);
}

test "parseAndValidate rejects invalid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var err: ValidationError = .{ .detail = "" };
    const report = parseAndValidate(allocator, "not json{{{", &err);
    try std.testing.expect(report == null);
    try std.testing.expectEqualStrings("Invalid JSON", err.detail);
}

test "parseAndValidate rejects missing required fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Missing project
    {
        var err: ValidationError = .{ .detail = "" };
        const report = parseAndValidate(allocator,
            \\{"exception_type": "ValueError", "message": "msg", "traceback": "tb"}
        , &err);
        try std.testing.expect(report == null);
        try std.testing.expect(std.mem.indexOf(u8, err.detail, "project") != null);
    }

    // Missing exception_type
    {
        var err: ValidationError = .{ .detail = "" };
        const report = parseAndValidate(allocator,
            \\{"project": "test", "message": "msg", "traceback": "tb"}
        , &err);
        try std.testing.expect(report == null);
        try std.testing.expect(std.mem.indexOf(u8, err.detail, "exception_type") != null);
    }

    // Missing message
    {
        var err: ValidationError = .{ .detail = "" };
        const report = parseAndValidate(allocator,
            \\{"project": "test", "exception_type": "Err", "traceback": "tb"}
        , &err);
        try std.testing.expect(report == null);
        try std.testing.expect(std.mem.indexOf(u8, err.detail, "message") != null);
    }

    // Missing traceback
    {
        var err: ValidationError = .{ .detail = "" };
        const report = parseAndValidate(allocator,
            \\{"project": "test", "exception_type": "Err", "message": "msg"}
        , &err);
        try std.testing.expect(report == null);
        try std.testing.expect(std.mem.indexOf(u8, err.detail, "traceback") != null);
    }
}

test "parseAndValidate enforces field length limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Project > 100 chars
    {
        var long_project: [101]u8 = undefined;
        @memset(&long_project, 'a');
        var json_buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&json_buf, "{{\"project\": \"{s}\", \"exception_type\": \"Err\", \"message\": \"msg\", \"traceback\": \"tb\"}}", .{@as([]const u8, &long_project)}) catch unreachable;
        var err: ValidationError = .{ .detail = "" };
        const report = parseAndValidate(allocator, json, &err);
        try std.testing.expect(report == null);
        try std.testing.expect(std.mem.indexOf(u8, err.detail, "project") != null);
    }

    // exception_type > 200 chars
    {
        var long_type: [201]u8 = undefined;
        @memset(&long_type, 'a');
        var json_buf: [700]u8 = undefined;
        const json = std.fmt.bufPrint(&json_buf, "{{\"project\": \"test\", \"exception_type\": \"{s}\", \"message\": \"msg\", \"traceback\": \"tb\"}}", .{@as([]const u8, &long_type)}) catch unreachable;
        var err: ValidationError = .{ .detail = "" };
        const report = parseAndValidate(allocator, json, &err);
        try std.testing.expect(report == null);
        try std.testing.expect(std.mem.indexOf(u8, err.detail, "exception_type") != null);
    }
}

test "parseAndValidate defaults environment to prod" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"project": "test", "exception_type": "Err", "message": "msg", "traceback": "tb"}
    ;
    var err: ValidationError = .{ .detail = "" };
    const report = parseAndValidate(allocator, body, &err);
    try std.testing.expect(report != null);
    try std.testing.expectEqualStrings("prod", report.?.environment);
}

test "parseAndValidate handles optional fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"project": "test", "exception_type": "Err", "message": "msg", "traceback": "tb", "request_url": "/api/test", "request_method": "POST", "request_headers": {"User-Agent": "test"}, "user_id": "u42", "extra": {"key": "val"}}
    ;
    var err: ValidationError = .{ .detail = "" };
    const report = parseAndValidate(allocator, body, &err);
    try std.testing.expect(report != null);
    try std.testing.expectEqualStrings("/api/test", report.?.request_url.?);
    try std.testing.expectEqualStrings("POST", report.?.request_method.?);
    try std.testing.expectEqualStrings("u42", report.?.user_id.?);
    try std.testing.expect(report.?.request_headers != null);
    try std.testing.expect(report.?.extra != null);
}

test "ingest creates new error" {
    var db = try setupTestDb();
    defer db.close();

    const report = ErrorReport{
        .project = "flowrent",
        .environment = "prod",
        .exception_type = "ValueError",
        .message = "invalid input",
        .traceback = "Traceback (most recent call last):\n  File \"/app/main.py\", line 42\nValueError: invalid input",
        .request_url = "/api/bookings",
        .request_method = "POST",
        .request_headers = "{\"User-Agent\": \"test\"}",
        .user_id = "user42",
        .extra = "{\"key\": \"val\"}",
    };

    const result = try ingest(&db, &report);
    try std.testing.expect(result.status == .created);
    try std.testing.expect(result.id > 0);
    try std.testing.expect(result.fingerprint != null);
    try std.testing.expect(result.is_new);

    // Verify the error was created in the database
    const stmt = try db.prepare("SELECT project, exception_type, message, count, resolved FROM errors WHERE id = ?;");
    defer stmt.deinit();
    try stmt.bindInt(1, result.id);
    var iter = stmt.query();
    if (iter.next()) |row| {
        const proj = row.text(0) orelse "";
        try std.testing.expectEqualStrings("flowrent", proj);
        const exc = row.text(1) orelse "";
        try std.testing.expectEqualStrings("ValueError", exc);
        try std.testing.expectEqual(@as(i64, 1), row.int(3)); // count
        try std.testing.expectEqual(@as(i64, 0), row.int(4)); // resolved
    } else {
        return error.TestUnexpectedResult;
    }

    // Verify occurrence was created
    const occ_stmt = try db.prepare("SELECT COUNT(*) FROM error_occurrences WHERE error_id = ?;");
    defer occ_stmt.deinit();
    try occ_stmt.bindInt(1, result.id);
    var occ_iter = occ_stmt.query();
    if (occ_iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
    }
}

test "ingest increments existing unresolved error" {
    var db = try setupTestDb();
    defer db.close();

    const report = ErrorReport{
        .project = "flowrent",
        .environment = "prod",
        .exception_type = "ValueError",
        .message = "invalid input",
        .traceback = "Traceback (most recent call last):\n  File \"/app/main.py\", line 42\nValueError: invalid input",
        .request_url = null,
        .request_method = null,
        .request_headers = null,
        .user_id = null,
        .extra = null,
    };

    // First ingestion: creates
    const result1 = try ingest(&db, &report);
    try std.testing.expect(result1.status == .created);
    try std.testing.expect(result1.is_new);

    // Second ingestion: increments
    const result2 = try ingest(&db, &report);
    try std.testing.expect(result2.status == .incremented);
    try std.testing.expectEqual(result1.id, result2.id);
    try std.testing.expectEqual(@as(i64, 2), result2.count.?);
    try std.testing.expect(!result2.is_new);

    // Third ingestion: increments again
    const result3 = try ingest(&db, &report);
    try std.testing.expect(result3.status == .incremented);
    try std.testing.expectEqual(@as(i64, 3), result3.count.?);

    // Verify 3 occurrences
    const stmt = try db.prepare("SELECT COUNT(*) FROM error_occurrences WHERE error_id = ?;");
    defer stmt.deinit();
    try stmt.bindInt(1, result1.id);
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 3), row.int(0));
    }
}

test "ingest reopens resolved error" {
    var db = try setupTestDb();
    defer db.close();

    const report = ErrorReport{
        .project = "flowrent",
        .environment = "prod",
        .exception_type = "ValueError",
        .message = "invalid input",
        .traceback = "Traceback (most recent call last):\n  File \"/app/main.py\", line 42\nValueError: invalid input",
        .request_url = null,
        .request_method = null,
        .request_headers = null,
        .user_id = null,
        .extra = null,
    };

    // Create the error
    const result1 = try ingest(&db, &report);
    try std.testing.expect(result1.status == .created);

    // Resolve it
    {
        const stmt = try db.prepare(
            "UPDATE errors SET resolved = 1, resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = ?;",
        );
        defer stmt.deinit();
        try stmt.bindInt(1, result1.id);
        _ = try stmt.exec();
    }

    // Ingest again: should reopen
    const result2 = try ingest(&db, &report);
    try std.testing.expect(result2.status == .reopened);
    try std.testing.expectEqual(result1.id, result2.id);
    try std.testing.expectEqual(@as(i64, 2), result2.count.?);
    try std.testing.expect(!result2.is_new);

    // Verify error is no longer resolved
    {
        const stmt = try db.prepare("SELECT resolved, resolved_at FROM errors WHERE id = ?;");
        defer stmt.deinit();
        try stmt.bindInt(1, result1.id);
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 0), row.int(0)); // not resolved
            try std.testing.expect(row.isNull(1)); // resolved_at cleared
        } else {
            return error.TestUnexpectedResult;
        }
    }
}

test "ingest trims occurrences to max 5" {
    var db = try setupTestDb();
    defer db.close();

    const report = ErrorReport{
        .project = "flowrent",
        .environment = "prod",
        .exception_type = "ValueError",
        .message = "invalid input",
        .traceback = "Traceback (most recent call last):\n  File \"/app/main.py\", line 42\nValueError: invalid input",
        .request_url = null,
        .request_method = null,
        .request_headers = null,
        .user_id = null,
        .extra = null,
    };

    // Ingest 7 times
    var first_id: i64 = 0;
    for (0..7) |i| {
        const result = try ingest(&db, &report);
        if (i == 0) first_id = result.id;
    }

    // Should only have 5 occurrences
    const stmt = try db.prepare("SELECT COUNT(*) FROM error_occurrences WHERE error_id = ?;");
    defer stmt.deinit();
    try stmt.bindInt(1, first_id);
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqual(@as(i64, 5), row.int(0));
    }
}

test "ingest stores occurrence context" {
    var db = try setupTestDb();
    defer db.close();

    const report = ErrorReport{
        .project = "flowrent",
        .environment = "prod",
        .exception_type = "ValueError",
        .message = "invalid input",
        .traceback = "Traceback...",
        .request_url = "/api/bookings",
        .request_method = "POST",
        .request_headers = "{\"User-Agent\": \"test\"}",
        .user_id = "user42",
        .extra = "{\"key\": \"val\"}",
    };

    const result = try ingest(&db, &report);

    // Verify occurrence has all the context
    const stmt = try db.prepare(
        "SELECT request_url, request_method, request_headers, user_id, extra, traceback " ++
            "FROM error_occurrences WHERE error_id = ?;",
    );
    defer stmt.deinit();
    try stmt.bindInt(1, result.id);
    var iter = stmt.query();
    if (iter.next()) |row| {
        const url = row.text(0) orelse "";
        try std.testing.expectEqualStrings("/api/bookings", url);
        const method = row.text(1) orelse "";
        try std.testing.expectEqualStrings("POST", method);
        const headers = row.text(2) orelse "";
        try std.testing.expectEqualStrings("{\"User-Agent\": \"test\"}", headers);
        const uid = row.text(3) orelse "";
        try std.testing.expectEqualStrings("user42", uid);
        const extra_val = row.text(4) orelse "";
        try std.testing.expectEqualStrings("{\"key\": \"val\"}", extra_val);
        const tb = row.text(5) orelse "";
        try std.testing.expectEqualStrings("Traceback...", tb);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "formatResponse for created status" {
    const result = IngestResult{
        .status = .created,
        .id = 42,
        .count = null,
        .fingerprint = fingerprint_mod.generate("test", "Err", "tb"),
        .is_new = true,
    };

    var buf: [512]u8 = undefined;
    const json = try formatResponse(&result, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"created\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\": 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fingerprint\"") != null);
}

test "formatResponse for incremented status" {
    const result = IngestResult{
        .status = .incremented,
        .id = 42,
        .count = 5,
        .fingerprint = null,
        .is_new = false,
    };

    var buf: [512]u8 = undefined;
    const json = try formatResponse(&result, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"incremented\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\": 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\": 5") != null);
}
