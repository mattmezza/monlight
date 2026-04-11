const std = @import("std");
const sqlite = @import("sqlite");
const log_level = @import("log_level.zig");
const log = std.log;

// ============================================================
// Docker JSON log line parser
// ============================================================

/// Parsed Docker JSON log line.
/// Docker writes one JSON object per line:
///   {"log": "message\n", "stream": "stdout", "time": "2025-01-20T10:00:00.123456789Z"}
pub const DockerLogLine = struct {
    message: []const u8,
    stream: []const u8,
    time: []const u8,
};

/// Parse a single Docker JSON log line.
/// Returns null if the line is malformed.
/// All returned slices point into the original `line` buffer — no allocation needed.
/// Docker JSON log format: {"log":"message\n","stream":"stdout","time":"2025-01-20T10:00:00.123Z"}
pub fn parseDockerLine(line: []const u8) ?DockerLogLine {
    const trimmed = std.mem.trimRight(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] != '{') return null;

    // Extract fields by finding quoted string values after known keys.
    const message_raw = extractJsonStringValue(trimmed, "\"log\"") orelse return null;
    const stream = extractJsonStringValue(trimmed, "\"stream\"") orelse "stdout";
    const time = extractJsonStringValue(trimmed, "\"time\"") orelse "";

    // Strip trailing literal \n from log message.
    // In the raw JSON source, a newline is the two-character escape sequence \n.
    // Our parser returns the raw bytes between quotes, so \n appears as '\' followed by 'n'.
    const message = if (message_raw.len >= 2 and
        message_raw[message_raw.len - 2] == '\\' and
        message_raw[message_raw.len - 1] == 'n')
        message_raw[0 .. message_raw.len - 2]
    else
        message_raw;

    return DockerLogLine{
        .message = message,
        .stream = stream,
        .time = time,
    };
}

/// Find a JSON string value for a given key in raw JSON text.
/// Searches for `"key"` followed by `:` (with optional whitespace), then `"value"`.
/// Returns the slice of characters between the opening and closing quotes of the value.
/// Handles escaped characters (e.g., `\"`, `\\`) when finding the closing quote.
fn extractJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (search_from < json.len) {
        const key_pos = std.mem.indexOfPos(u8, json, search_from, key) orelse return null;
        var i = key_pos + key.len;

        // Skip whitespace after key
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

        // Expect colon
        if (i >= json.len or json[i] != ':') {
            search_from = key_pos + 1;
            continue;
        }
        i += 1;

        // Skip whitespace after colon
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

        // Expect opening quote
        if (i >= json.len or json[i] != '"') {
            search_from = key_pos + 1;
            continue;
        }
        i += 1;
        const value_start = i;

        // Find closing quote (skip escaped characters)
        while (i < json.len) {
            if (json[i] == '\\') {
                i += 2; // skip escape sequence
                continue;
            }
            if (json[i] == '"') {
                return json[value_start..i];
            }
            i += 1;
        }
        return null; // unclosed string
    }
    return null;
}

// ============================================================
// Multiline log reassembly
// ============================================================

/// A buffered log entry being reassembled from multiple Docker JSON lines.
pub const BufferedEntry = struct {
    /// Accumulated message lines
    lines: std.ArrayList(u8),
    /// Allocator for lines
    allocator: std.mem.Allocator,
    /// Stream (stdout/stderr)
    stream: [16]u8,
    stream_len: usize,
    /// Timestamp of the first line
    timestamp: [64]u8,
    timestamp_len: usize,
    /// When the first line was buffered (for timeout flush)
    first_line_ns: i128,

    pub fn init(allocator: std.mem.Allocator) BufferedEntry {
        return .{
            .lines = .{},
            .allocator = allocator,
            .stream = undefined,
            .stream_len = 0,
            .timestamp = undefined,
            .timestamp_len = 0,
            .first_line_ns = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *BufferedEntry) void {
        self.lines.deinit(self.allocator);
    }

    pub fn setStream(self: *BufferedEntry, stream: []const u8) void {
        const len = @min(stream.len, self.stream.len);
        @memcpy(self.stream[0..len], stream[0..len]);
        self.stream_len = len;
    }

    pub fn getStream(self: *const BufferedEntry) []const u8 {
        return self.stream[0..self.stream_len];
    }

    pub fn setTimestamp(self: *BufferedEntry, ts: []const u8) void {
        const len = @min(ts.len, self.timestamp.len);
        @memcpy(self.timestamp[0..len], ts[0..len]);
        self.timestamp_len = len;
    }

    pub fn getTimestamp(self: *const BufferedEntry) []const u8 {
        return self.timestamp[0..self.timestamp_len];
    }

    pub fn appendLine(self: *BufferedEntry, line: []const u8) !void {
        if (self.lines.items.len > 0) {
            try self.lines.append(self.allocator, '\n');
        }
        try self.lines.appendSlice(self.allocator, line);
    }

    pub fn getMessage(self: *const BufferedEntry) []const u8 {
        return self.lines.items;
    }

    pub fn isEmpty(self: *const BufferedEntry) bool {
        return self.lines.items.len == 0;
    }
};

/// Check if a log line looks like the start of a new log entry.
/// Detects patterns like:
///   - Timestamp at start: 2025-01-20T10:00:00 or 2025-01-20 10:00:00
///   - Log level at start: INFO:, [ERROR], level=info
///   - Python traceback continuation lines do NOT match (they start with spaces or "Traceback")
pub fn isNewEntryStart(line: []const u8) bool {
    if (line.len == 0) return false;

    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len == 0) return false;

    // Continuation lines: start with whitespace (traceback frames, multiline strings)
    if (line[0] == ' ' or line[0] == '\t') return false;

    // "Traceback (most recent call last):" is a continuation of the ERROR that precedes it
    if (std.mem.startsWith(u8, trimmed, "Traceback (most recent call last)")) return false;

    // Lines starting with "File " or "    " are traceback frames
    if (std.mem.startsWith(u8, trimmed, "File \"")) return false;

    // Detect timestamp at start: YYYY-MM-DD
    if (trimmed.len >= 10 and
        isDigit(trimmed[0]) and isDigit(trimmed[1]) and isDigit(trimmed[2]) and isDigit(trimmed[3]) and
        trimmed[4] == '-' and isDigit(trimmed[5]) and isDigit(trimmed[6]) and
        trimmed[7] == '-' and isDigit(trimmed[8]) and isDigit(trimmed[9]))
    {
        return true;
    }

    // Detect log level at start: INFO:, ERROR:, WARNING:, DEBUG:
    if (log_level.extract(trimmed, "stdout") != .INFO or
        std.mem.startsWith(u8, trimmed, "INFO"))
    {
        // If a level was detected (not the default), it's a new entry
        return true;
    }

    // Detect [LEVEL] pattern
    if (trimmed[0] == '[') return true;

    // Detect JSON log line
    if (trimmed[0] == '{') return true;

    // Default: treat as new entry if it doesn't look like a continuation
    return true;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// ============================================================
// Log entry insertion
// ============================================================

/// A complete log entry ready for database insertion.
pub const LogEntry = struct {
    timestamp: []const u8,
    container: []const u8,
    stream: []const u8,
    level: []const u8,
    message: []const u8,
    raw: ?[]const u8,
};

/// Insert a log entry into the database.
pub fn insertLogEntry(db: *sqlite.Database, entry: *const LogEntry) !void {
    const stmt = try db.prepare(
        "INSERT INTO log_entries (timestamp, container, stream, level, message, raw) " ++
            "VALUES (?, ?, ?, ?, ?, ?);",
    );
    defer stmt.deinit();

    try stmt.bindText(1, entry.timestamp);
    try stmt.bindText(2, entry.container);
    try stmt.bindText(3, entry.stream);
    try stmt.bindText(4, entry.level);
    try stmt.bindText(5, entry.message);
    if (entry.raw) |raw| {
        try stmt.bindText(6, raw);
    } else {
        try stmt.bindNull(6);
    }
    _ = try stmt.exec();
}

// ============================================================
// Cursor tracking
// ============================================================

/// Saved cursor state for a container's log file.
pub const CursorState = struct {
    position: i64,
    inode: i64,
    file_path: [512]u8,
    file_path_len: usize,

    pub fn getFilePath(self: *const CursorState) []const u8 {
        return self.file_path[0..self.file_path_len];
    }
};

/// Load cursor state for a container from the database.
pub fn loadCursor(db: *sqlite.Database, container_id: []const u8) !?CursorState {
    const stmt = try db.prepare(
        "SELECT file_path, position, inode FROM cursors WHERE container_id = ?;",
    );
    defer stmt.deinit();
    try stmt.bindText(1, container_id);

    var iter = stmt.query();
    if (iter.next()) |row| {
        const fp = row.text(0) orelse return null;
        var state = CursorState{
            .position = row.int(1),
            .inode = row.int(2),
            .file_path = undefined,
            .file_path_len = fp.len,
        };
        const len = @min(fp.len, state.file_path.len);
        @memcpy(state.file_path[0..len], fp[0..len]);
        state.file_path_len = len;
        return state;
    }
    return null;
}

/// Save or update cursor state for a container in the database.
pub fn saveCursor(db: *sqlite.Database, container_id: []const u8, file_path: []const u8, position: i64, inode: i64) !void {
    const stmt = try db.prepare(
        "INSERT INTO cursors (container_id, file_path, position, inode, updated_at) " ++
            "VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) " ++
            "ON CONFLICT(container_id) DO UPDATE SET " ++
            "file_path = excluded.file_path, " ++
            "position = excluded.position, " ++
            "inode = excluded.inode, " ++
            "updated_at = excluded.updated_at;",
    );
    defer stmt.deinit();

    try stmt.bindText(1, container_id);
    try stmt.bindText(2, file_path);
    try stmt.bindInt(3, position);
    try stmt.bindInt(4, inode);
    _ = try stmt.exec();
}

// ============================================================
// Ring buffer cleanup
// ============================================================

/// Delete oldest log entries if total count exceeds max_entries.
/// Returns the number of entries deleted.
pub fn cleanupOldEntries(db: *sqlite.Database, max_entries: i64) !usize {
    // First check current count
    const count_stmt = try db.prepare("SELECT COUNT(*) FROM log_entries;");
    defer count_stmt.deinit();
    var count_iter = count_stmt.query();
    const current_count: i64 = blk: {
        if (count_iter.next()) |row| {
            break :blk row.int(0);
        }
        break :blk 0;
    };

    if (current_count <= max_entries) return 0;

    const excess = current_count - max_entries;

    // Delete the oldest entries (smallest id values)
    const del_stmt = try db.prepare(
        "DELETE FROM log_entries WHERE id IN (" ++
            "SELECT id FROM log_entries ORDER BY id ASC LIMIT ?" ++
            ");",
    );
    defer del_stmt.deinit();
    try del_stmt.bindInt(1, excess);
    const deleted = try del_stmt.exec();

    if (deleted > 0) {
        log.info("ring buffer cleanup: deleted {d} oldest entries (was {d}, max {d})", .{ deleted, current_count, max_entries });
    }

    return deleted;
}

// ============================================================
// Container directory scanning
// ============================================================

/// Find the log file for a Docker container.
/// Docker stores logs at: {log_sources}/{container_id}/{container_id}-json.log
/// We scan the log_sources directory for directories whose name starts with
/// one of the configured container names (Docker Compose prefixes container names).
///
/// Returns the path to the log file if found, or null.
pub fn findContainerLogFile(
    allocator: std.mem.Allocator,
    log_sources: []const u8,
    container_name: []const u8,
) !?[]const u8 {
    // Docker stores container logs at:
    //   /var/lib/docker/containers/<full-container-id>/<full-container-id>-json.log
    //
    // We need to find the container directory that matches the container name.
    // Docker Compose creates containers named like: project_service_1 or project-service-1
    // The directory name is the full container ID (a long hex string).
    //
    // Strategy: We can't directly map name -> ID from the filesystem alone.
    // Instead, look for config.v2.json or hostconfig.json which contain the name.
    // But simpler approach: scan all container dirs and check the container name in config.

    var dir = std.fs.openDirAbsolute(log_sources, .{ .iterate = true }) catch |err| {
        log.err("failed to open log sources directory '{s}': {}", .{ log_sources, err });
        return null;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Check config.v2.json for the container name
        const config_path = try std.fmt.allocPrint(allocator, "{s}/{s}/config.v2.json", .{ log_sources, entry.name });
        defer allocator.free(config_path);

        const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch continue;
        defer allocator.free(config_content);

        // Look for "Name":"/<container_name>" in the config JSON
        // Docker stores the name with a leading slash: "Name":"/web-app"
        const name_pattern = try std.fmt.allocPrint(allocator, "\"Name\":\"/{s}\"", .{container_name});
        defer allocator.free(name_pattern);

        // Also try with spaces around the colon
        const name_pattern2 = try std.fmt.allocPrint(allocator, "\"Name\": \"/{s}\"", .{container_name});
        defer allocator.free(name_pattern2);

        if (std.mem.indexOf(u8, config_content, name_pattern) != null or
            std.mem.indexOf(u8, config_content, name_pattern2) != null or
            wildcardMatchContainer(container_name, config_content))
        {
            // Found the container! Build the log file path.
            const log_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}-json.log", .{ log_sources, entry.name, entry.name });
            return log_path;
        }
    }

    return null;
}

/// Check if a wildcard container pattern matches a name found in Docker config JSON.
/// Only used when the pattern contains `*`. Extracts the container name from
/// `"Name":"/<name>"` in the config content and does a glob match.
fn wildcardMatchContainer(pattern: []const u8, config_content: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "*") == null) return false;

    // Extract name from "Name":"/<name>" or "Name": "/<name>"
    const name = extractDockerName(config_content) orelse return false;
    return globMatch(pattern, name);
}

/// One concrete container that matched a CONTAINERS pattern.
/// Both `name` and `log_path` are owned by the caller's allocator.
pub const ResolvedContainer = struct {
    name: []const u8,
    log_path: []const u8,
};

/// Resolve a CONTAINERS pattern into the list of concrete containers it matches.
/// - Patterns without `*` resolve to at most one container (exact name match).
/// - Patterns with `*` resolve to every container whose Docker name matches the
///   glob, so each is ingested under its real name (not the pattern).
///
/// Caller owns the returned slice and each entry's `name` / `log_path`.
pub fn findContainerLogFiles(
    allocator: std.mem.Allocator,
    log_sources: []const u8,
    pattern: []const u8,
) ![]ResolvedContainer {
    var results: std.ArrayList(ResolvedContainer) = .{};
    errdefer {
        for (results.items) |r| {
            allocator.free(r.name);
            allocator.free(r.log_path);
        }
        results.deinit(allocator);
    }

    var dir = std.fs.openDirAbsolute(log_sources, .{ .iterate = true }) catch |err| {
        log.err("failed to open log sources directory '{s}': {}", .{ log_sources, err });
        return try results.toOwnedSlice(allocator);
    };
    defer dir.close();

    const has_wildcard = std.mem.indexOf(u8, pattern, "*") != null;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const config_path = try std.fmt.allocPrint(allocator, "{s}/{s}/config.v2.json", .{ log_sources, entry.name });
        defer allocator.free(config_path);

        const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch continue;
        defer allocator.free(config_content);

        const docker_name = extractDockerName(config_content) orelse continue;

        const matches = if (has_wildcard)
            globMatch(pattern, docker_name)
        else
            std.mem.eql(u8, pattern, docker_name);

        if (!matches) continue;

        const name_owned = try allocator.dupe(u8, docker_name);
        errdefer allocator.free(name_owned);
        const log_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}-json.log", .{ log_sources, entry.name, entry.name });
        errdefer allocator.free(log_path);

        try results.append(allocator, .{ .name = name_owned, .log_path = log_path });

        // Exact (non-wildcard) match: stop after the first hit.
        if (!has_wildcard) break;
    }

    return try results.toOwnedSlice(allocator);
}

/// Extract container name from Docker config.v2.json content.
/// Looks for "Name":"/<name>" and returns <name> (without the leading slash).
fn extractDockerName(content: []const u8) ?[]const u8 {
    const markers = [_][]const u8{ "\"Name\":\"/", "\"Name\": \"/" };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, content, marker)) |start| {
            const name_start = start + marker.len;
            if (std.mem.indexOfScalar(u8, content[name_start..], '"')) |end| {
                return content[name_start .. name_start + end];
            }
        }
    }
    return null;
}

/// Simple glob match supporting `*` as a wildcard for zero or more characters.
fn globMatch(pattern: []const u8, str: []const u8) bool {
    const star = std.mem.indexOf(u8, pattern, "*") orelse {
        return std.mem.eql(u8, pattern, str);
    };
    const prefix = pattern[0..star];
    const suffix = pattern[star + 1..];

    if (!std.mem.startsWith(u8, str, prefix)) return false;
    if (!std.mem.endsWith(u8, str, suffix)) return false;
    return str.len >= prefix.len + suffix.len;
}

/// Get the inode number of a file.
pub fn getFileInode(path: []const u8) !i64 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return @intCast(stat.inode);
}

/// Get the file size in bytes.
pub fn getFileSize(path: []const u8) !i64 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return @intCast(stat.size);
}

// ============================================================
// Ingestion loop (background thread)
// ============================================================

/// Parse comma-separated container names into a list.
pub fn parseContainerNames(allocator: std.mem.Allocator, containers_str: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .{};
    var iter = std.mem.splitScalar(u8, containers_str, ',');
    while (iter.next()) |name| {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len > 0) {
            try list.append(allocator, trimmed);
        }
    }
    return list;
}

/// Ingest new log lines from a single container's log file.
/// Reads from the saved cursor position (or tail_buffer bytes from end on first run).
/// Returns the new file position after reading.
pub fn ingestContainerLogs(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    container_name: []const u8,
    log_file_path: []const u8,
    cursor: ?CursorState,
    tail_buffer: i64,
) !i64 {
    const file = std.fs.cwd().openFile(log_file_path, .{}) catch |err| {
        log.err("failed to open log file '{s}': {}", .{ log_file_path, err });
        return if (cursor) |c| c.position else 0;
    };
    defer file.close();

    const stat = try file.stat();
    const file_size: i64 = @intCast(stat.size);
    const file_inode: i64 = @intCast(stat.inode);

    // Determine start position
    var start_pos: i64 = 0;
    if (cursor) |c| {
        if (c.inode == file_inode) {
            // Same file, resume from saved position
            if (c.position <= file_size) {
                start_pos = c.position;
            }
            // If saved position > file_size, file was truncated; start from beginning
        }
        // If inode changed, file was rotated; start from beginning (start_pos = 0)
    } else {
        // First run: read from tail_buffer bytes before end
        if (file_size > tail_buffer) {
            start_pos = file_size - tail_buffer;
            // Advance to the next complete line
            try file.seekTo(@intCast(start_pos));
            var skip_buf: [4096]u8 = undefined;
            const n = try file.read(&skip_buf);
            if (n > 0) {
                if (std.mem.indexOfScalar(u8, skip_buf[0..n], '\n')) |newline_pos| {
                    start_pos += @as(i64, @intCast(newline_pos)) + 1;
                }
            }
        }
    }

    if (start_pos >= file_size) {
        // No new data
        return file_size;
    }

    // Seek to start position and read new data
    try file.seekTo(@intCast(start_pos));

    // Read the file in chunks and process line by line
    var buffer = BufferedEntry.init(allocator);
    defer buffer.deinit();

    var line_buf: [65536]u8 = undefined;
    var reader = file.deprecatedReader();
    var entries_inserted: usize = 0;

    while (true) {
        const line = reader.readUntilDelimiter(&line_buf, '\n') catch |err| {
            if (err == error.EndOfStream) break;
            log.err("error reading log file: {}", .{err});
            break;
        };

        // Parse Docker JSON line
        const parsed = parseDockerLine(line) orelse continue;

        // Check if this is a new entry or continuation
        if (isNewEntryStart(parsed.message)) {
            // Flush any buffered entry first
            if (!buffer.isEmpty()) {
                flushBufferedEntry(db, &buffer, container_name) catch |err| {
                    log.err("failed to flush buffered entry: {}", .{err});
                };
                buffer.lines.clearRetainingCapacity();
            }
            // Start new entry
            buffer.setTimestamp(parsed.time);
            buffer.setStream(parsed.stream);
            buffer.first_line_ns = std.time.nanoTimestamp();
            try buffer.appendLine(parsed.message);
        } else {
            // Continuation line
            if (buffer.isEmpty()) {
                // No previous entry to append to; treat as new
                buffer.setTimestamp(parsed.time);
                buffer.setStream(parsed.stream);
                buffer.first_line_ns = std.time.nanoTimestamp();
            }
            try buffer.appendLine(parsed.message);
        }
        entries_inserted += 1;
    }

    // Flush remaining buffered entry
    if (!buffer.isEmpty()) {
        flushBufferedEntry(db, &buffer, container_name) catch |err| {
            log.err("failed to flush final buffered entry: {}", .{err});
        };
    }

    // Save cursor
    const new_pos = file_size;
    saveCursor(db, container_name, log_file_path, new_pos, file_inode) catch |err| {
        log.err("failed to save cursor for '{s}': {}", .{ container_name, err });
    };

    if (entries_inserted > 0) {
        log.info("ingested {d} lines from container '{s}'", .{ entries_inserted, container_name });
    }

    return new_pos;
}

/// Flush a buffered multiline entry into the database.
fn flushBufferedEntry(db: *sqlite.Database, buffer: *BufferedEntry, container_name: []const u8) !void {
    const message = buffer.getMessage();
    if (message.len == 0) return;

    const stream = buffer.getStream();
    const level = log_level.extract(message, stream);

    // Normalize timestamp: Docker uses RFC3339Nano, we want ISO8601
    const ts = buffer.getTimestamp();
    var ts_normalized: [32]u8 = undefined;
    var ts_len: usize = 0;
    if (ts.len >= 19) {
        // Take YYYY-MM-DDTHH:MM:SSZ
        @memcpy(ts_normalized[0..19], ts[0..19]);
        ts_normalized[19] = 'Z';
        ts_len = 20;
    } else if (ts.len > 0) {
        const copy_len = @min(ts.len, ts_normalized.len);
        @memcpy(ts_normalized[0..copy_len], ts[0..copy_len]);
        ts_len = copy_len;
    }

    const entry = LogEntry{
        .timestamp = if (ts_len > 0) ts_normalized[0..ts_len] else "1970-01-01T00:00:00Z",
        .container = container_name,
        .stream = stream,
        .level = level.string(),
        .message = message,
        .raw = null,
    };

    try insertLogEntry(db, &entry);
}

// ============================================================
// Main ingestion thread
// ============================================================

/// Background thread that polls Docker log files for new entries.
pub fn ingestionThread(
    db_path_z: [*:0]const u8,
    log_sources: []const u8,
    containers_str: []const u8,
    poll_interval_s: i64,
    tail_buffer: i64,
    max_entries: i64,
    stop: *std.atomic.Value(bool),
) void {
    var db = sqlite.Database.open(db_path_z) catch |err| {
        log.err("ingestion thread: failed to open database: {}", .{err});
        return;
    };
    defer db.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CONTAINERS into the list of patterns to watch (each entry may be an
    // exact name or a glob like `myapp_*`).
    var container_patterns = parseContainerNames(allocator, containers_str) catch |err| {
        log.err("ingestion thread: failed to parse container patterns: {}", .{err});
        return;
    };
    defer container_patterns.deinit(allocator);

    log.info("ingestion thread started: watching {d} container pattern(s), poll interval {d}s", .{
        container_patterns.items.len,
        poll_interval_s,
    });

    // Active containers: resolved real name -> log file path. Both keys and
    // values are owned by `allocator`. Patterns are expanded into this map at
    // startup and re-expanded periodically so newly-started matching containers
    // are picked up automatically.
    var active = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = active.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        active.deinit();
    }

    const poll_interval_ns: u64 = @intCast(poll_interval_s * std.time.ns_per_s);
    // Re-scan log_sources every 30s to discover new matches for wildcard patterns.
    const rescan_interval_ns: i128 = 30 * std.time.ns_per_s;
    var last_rescan_ns: i128 = 0;

    while (!stop.load(.acquire)) {
        const now_ns: i128 = std.time.nanoTimestamp();
        const should_rescan = last_rescan_ns == 0 or (now_ns - last_rescan_ns) >= rescan_interval_ns;
        if (should_rescan) {
            for (container_patterns.items) |pattern| {
                const matches = findContainerLogFiles(allocator, log_sources, pattern) catch |err| {
                    log.err("failed to discover containers for pattern '{s}': {}", .{ pattern, err });
                    continue;
                };
                defer allocator.free(matches);
                for (matches) |m| {
                    if (active.contains(m.name)) {
                        // Already tracked — drop the duplicate copies.
                        allocator.free(m.name);
                        allocator.free(m.log_path);
                        continue;
                    }
                    active.put(m.name, m.log_path) catch |err| {
                        log.err("failed to track container '{s}': {}", .{ m.name, err });
                        allocator.free(m.name);
                        allocator.free(m.log_path);
                        continue;
                    };
                    log.info("discovered container '{s}' (pattern '{s}'): {s}", .{ m.name, pattern, m.log_path });
                }
            }
            last_rescan_ns = now_ns;
        }

        // Iterate active containers. Collect entries whose log file disappeared
        // for removal after the loop (mutating a hashmap during iteration is
        // unsafe).
        var to_remove: std.ArrayList([]const u8) = .{};
        defer to_remove.deinit(allocator);

        var act_iter = active.iterator();
        while (act_iter.next()) |entry| {
            if (stop.load(.acquire)) break;
            const container_name = entry.key_ptr.*;
            const log_path = entry.value_ptr.*;

            // Verify the log file still exists; if not, mark for removal so
            // the next rescan can re-discover the container if it comes back.
            std.fs.cwd().access(log_path, .{}) catch {
                log.info("container '{s}' log file disappeared, dropping from active set", .{container_name});
                to_remove.append(allocator, container_name) catch {};
                continue;
            };

            // Load cursor
            const cursor = loadCursor(&db, container_name) catch |err| {
                log.err("failed to load cursor for '{s}': {}", .{ container_name, err });
                continue;
            };

            // Check for rotation (inode change)
            if (cursor) |c| {
                const current_inode = getFileInode(log_path) catch |err| {
                    log.err("failed to get inode for '{s}': {}", .{ log_path, err });
                    continue;
                };
                if (c.inode != 0 and c.inode != current_inode) {
                    log.info("log rotation detected for container '{s}' (inode {d} -> {d})", .{
                        container_name, c.inode, current_inode,
                    });
                    // Reset cursor — will start from beginning of new file
                    _ = ingestContainerLogs(allocator, &db, container_name, log_path, null, tail_buffer) catch |err| {
                        log.err("failed to ingest after rotation for '{s}': {}", .{ container_name, err });
                    };
                    continue;
                }
            }

            // Ingest new log lines
            _ = ingestContainerLogs(allocator, &db, container_name, log_path, cursor, tail_buffer) catch |err| {
                log.err("failed to ingest logs for '{s}': {}", .{ container_name, err });
            };
        }

        // Drop entries whose log file disappeared.
        for (to_remove.items) |name| {
            if (active.fetchRemove(name)) |kv| {
                allocator.free(kv.key);
                allocator.free(kv.value);
            }
        }

        // Ring buffer cleanup after each poll cycle
        _ = cleanupOldEntries(&db, max_entries) catch |err| {
            log.err("ring buffer cleanup failed: {}", .{err});
        };

        // Sleep in 1-second chunks so stop flag is checked promptly
        var slept: u64 = 0;
        while (slept < poll_interval_ns and !stop.load(.acquire)) {
            const sleep_chunk = @min(std.time.ns_per_s, poll_interval_ns - slept);
            std.Thread.sleep(sleep_chunk);
            slept += sleep_chunk;
        }
    }

    log.info("ingestion thread stopped", .{});
}

// ============================================================
// Tests
// ============================================================

test "parseDockerLine parses valid JSON log line" {
    const line = "{\"log\":\"INFO: Server started on port 8000\\n\",\"stream\":\"stdout\",\"time\":\"2025-01-20T10:00:00.123456789Z\"}";
    const parsed = parseDockerLine(line) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("INFO: Server started on port 8000", parsed.message);
    try std.testing.expectEqualStrings("stdout", parsed.stream);
    try std.testing.expectEqualStrings("2025-01-20T10:00:00.123456789Z", parsed.time);
}

test "parseDockerLine strips trailing newline from message" {
    const line = "{\"log\":\"Hello world\\n\",\"stream\":\"stdout\",\"time\":\"2025-01-20T10:00:00Z\"}";
    const parsed = parseDockerLine(line) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Hello world", parsed.message);
}

test "parseDockerLine handles stderr stream" {
    const line = "{\"log\":\"Error occurred\\n\",\"stream\":\"stderr\",\"time\":\"2025-01-20T10:00:00Z\"}";
    const parsed = parseDockerLine(line) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("stderr", parsed.stream);
}

test "parseDockerLine returns null for malformed JSON" {
    try std.testing.expect(parseDockerLine("not json at all") == null);
    try std.testing.expect(parseDockerLine("") == null);
    try std.testing.expect(parseDockerLine("{\"no_log_field\":true}") == null);
    try std.testing.expect(parseDockerLine("{\"log\":123}") == null); // log is not a string
}

test "parseDockerLine defaults stream to stdout when missing" {
    const line = "{\"log\":\"test message\\n\",\"time\":\"2025-01-20T10:00:00Z\"}";
    const parsed = parseDockerLine(line) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("stdout", parsed.stream);
}

test "isNewEntryStart detects timestamp patterns" {
    try std.testing.expect(isNewEntryStart("2025-01-20T10:00:00Z Something happened"));
    try std.testing.expect(isNewEntryStart("2025-01-20 10:00:00 Something happened"));
}

test "isNewEntryStart detects continuation lines" {
    // Indented lines are continuations
    try std.testing.expect(!isNewEntryStart("  File \"/app/main.py\", line 42"));
    try std.testing.expect(!isNewEntryStart("\t  in function_name"));
    try std.testing.expect(!isNewEntryStart("    raise ValueError(\"bad\")"));
    // Traceback header is a continuation (follows the ERROR line)
    try std.testing.expect(!isNewEntryStart("Traceback (most recent call last):"));
}

test "isNewEntryStart detects log level patterns" {
    try std.testing.expect(isNewEntryStart("INFO: Server started"));
    try std.testing.expect(isNewEntryStart("ERROR: Connection refused"));
    try std.testing.expect(isNewEntryStart("[INFO] Request handled"));
    try std.testing.expect(isNewEntryStart("{\"level\":\"info\",\"msg\":\"test\"}"));
}

test "multiline reassembly with BufferedEntry" {
    const allocator = std.testing.allocator;
    var buffer = BufferedEntry.init(allocator);
    defer buffer.deinit();

    try std.testing.expect(buffer.isEmpty());

    try buffer.appendLine("ERROR: ValueError: invalid input");
    try std.testing.expect(!buffer.isEmpty());

    try buffer.appendLine("Traceback (most recent call last):");
    try buffer.appendLine("  File \"/app/main.py\", line 42, in handler");
    try buffer.appendLine("    process(data)");

    const msg = buffer.getMessage();
    try std.testing.expect(std.mem.indexOf(u8, msg, "ERROR: ValueError: invalid input") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Traceback (most recent call last):") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "  File \"/app/main.py\", line 42, in handler") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "    process(data)") != null);
}

test "insertLogEntry writes to database" {
    const database = @import("database.zig");
    var db = try database.init(":memory:");
    defer db.close();

    const entry = LogEntry{
        .timestamp = "2025-01-20T10:00:00Z",
        .container = "web-app",
        .stream = "stdout",
        .level = "INFO",
        .message = "Server started on port 8000",
        .raw = null,
    };
    try insertLogEntry(&db, &entry);

    // Verify
    const stmt = try db.prepare("SELECT timestamp, container, stream, level, message FROM log_entries WHERE id = 1;");
    defer stmt.deinit();
    var iter = stmt.query();
    if (iter.next()) |row| {
        try std.testing.expectEqualStrings("2025-01-20T10:00:00Z", row.text(0) orelse "");
        try std.testing.expectEqualStrings("web-app", row.text(1) orelse "");
        try std.testing.expectEqualStrings("stdout", row.text(2) orelse "");
        try std.testing.expectEqualStrings("INFO", row.text(3) orelse "");
        try std.testing.expectEqualStrings("Server started on port 8000", row.text(4) orelse "");
    } else {
        return error.TestUnexpectedResult;
    }
}

test "cursor save and load roundtrip" {
    const database = @import("database.zig");
    var db = try database.init(":memory:");
    defer db.close();

    // Initially no cursor
    const initial = try loadCursor(&db, "web-app");
    try std.testing.expect(initial == null);

    // Save cursor
    try saveCursor(&db, "web-app", "/var/lib/docker/containers/abc/abc-json.log", 1024, 12345);

    // Load cursor
    const loaded = (try loadCursor(&db, "web-app")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1024), loaded.position);
    try std.testing.expectEqual(@as(i64, 12345), loaded.inode);
    try std.testing.expectEqualStrings("/var/lib/docker/containers/abc/abc-json.log", loaded.getFilePath());

    // Update cursor (upsert)
    try saveCursor(&db, "web-app", "/var/lib/docker/containers/abc/abc-json.log", 2048, 12345);
    const updated = (try loadCursor(&db, "web-app")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 2048), updated.position);
}

test "cleanupOldEntries removes oldest entries when over limit" {
    const database = @import("database.zig");
    var db = try database.init(":memory:");
    defer db.close();

    // Insert 10 entries
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const entry = LogEntry{
            .timestamp = "2025-01-20T10:00:00Z",
            .container = "web",
            .stream = "stdout",
            .level = "INFO",
            .message = "test message",
            .raw = null,
        };
        try insertLogEntry(&db, &entry);
    }

    // Verify 10 entries
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM log_entries;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 10), row.int(0));
        }
    }

    // Cleanup with max 5 entries
    const deleted = try cleanupOldEntries(&db, 5);
    try std.testing.expectEqual(@as(usize, 5), deleted);

    // Verify 5 remaining
    {
        const stmt = try db.prepare("SELECT COUNT(*) FROM log_entries;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 5), row.int(0));
        }
    }

    // Verify oldest were removed (IDs 6-10 should remain)
    {
        const stmt = try db.prepare("SELECT MIN(id) FROM log_entries;");
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 6), row.int(0));
        }
    }
}

test "cleanupOldEntries does nothing when under limit" {
    const database = @import("database.zig");
    var db = try database.init(":memory:");
    defer db.close();

    // Insert 3 entries
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const entry = LogEntry{
            .timestamp = "2025-01-20T10:00:00Z",
            .container = "web",
            .stream = "stdout",
            .level = "INFO",
            .message = "test",
            .raw = null,
        };
        try insertLogEntry(&db, &entry);
    }

    const deleted = try cleanupOldEntries(&db, 10);
    try std.testing.expectEqual(@as(usize, 0), deleted);
}

test "cleanupOldEntries keeps FTS index consistent" {
    const database = @import("database.zig");
    var db = try database.init(":memory:");
    defer db.close();

    // Insert entries with distinct messages
    const messages = [_][]const u8{
        "alpha connection established",
        "beta connection established",
        "gamma connection established",
        "delta connection established",
        "epsilon connection established",
    };
    for (messages) |msg| {
        const entry = LogEntry{
            .timestamp = "2025-01-20T10:00:00Z",
            .container = "web",
            .stream = "stdout",
            .level = "INFO",
            .message = msg,
            .raw = null,
        };
        try insertLogEntry(&db, &entry);
    }

    // Cleanup: keep max 3 (should delete alpha and beta)
    const deleted = try cleanupOldEntries(&db, 3);
    try std.testing.expectEqual(@as(usize, 2), deleted);

    // FTS search for "alpha" should return 0 results
    {
        const stmt = try db.prepare(
            "SELECT COUNT(*) FROM log_entries WHERE id IN (SELECT rowid FROM log_entries_fts WHERE log_entries_fts MATCH 'alpha');",
        );
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 0), row.int(0));
        }
    }

    // FTS search for "gamma" should return 1 result
    {
        const stmt = try db.prepare(
            "SELECT COUNT(*) FROM log_entries WHERE id IN (SELECT rowid FROM log_entries_fts WHERE log_entries_fts MATCH 'gamma');",
        );
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 1), row.int(0));
        }
    }

    // FTS search for "connection" should return 3 results (gamma, delta, epsilon)
    {
        const stmt = try db.prepare(
            "SELECT COUNT(*) FROM log_entries WHERE id IN (SELECT rowid FROM log_entries_fts WHERE log_entries_fts MATCH 'connection');",
        );
        defer stmt.deinit();
        var iter = stmt.query();
        if (iter.next()) |row| {
            try std.testing.expectEqual(@as(i64, 3), row.int(0));
        }
    }
}

test "parseContainerNames splits comma-separated list" {
    const allocator = std.testing.allocator;
    var names = try parseContainerNames(allocator, "web, api, worker");
    defer names.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("web", names.items[0]);
    try std.testing.expectEqualStrings("api", names.items[1]);
    try std.testing.expectEqualStrings("worker", names.items[2]);
}

test "parseContainerNames handles single container" {
    const allocator = std.testing.allocator;
    var names = try parseContainerNames(allocator, "web");
    defer names.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("web", names.items[0]);
}

test "parseContainerNames handles empty and whitespace" {
    const allocator = std.testing.allocator;
    var names = try parseContainerNames(allocator, "");
    defer names.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), names.items.len);
}

test "globMatch exact" {
    try std.testing.expect(globMatch("myapp_web", "myapp_web"));
    try std.testing.expect(!globMatch("myapp_web", "myapp_worker"));
}

test "globMatch prefix wildcard" {
    try std.testing.expect(globMatch("myapp_*", "myapp_web"));
    try std.testing.expect(globMatch("myapp_*", "myapp_worker"));
    try std.testing.expect(globMatch("myapp_*", "myapp_"));
    try std.testing.expect(!globMatch("myapp_*", "other_web"));
}

test "globMatch suffix wildcard" {
    try std.testing.expect(globMatch("*_web", "myapp_web"));
    try std.testing.expect(globMatch("*_web", "myapp_web"));
    try std.testing.expect(!globMatch("*_web", "myapp_worker"));
}

test "globMatch middle wildcard" {
    try std.testing.expect(globMatch("my*app", "myapp_app"));
    try std.testing.expect(globMatch("my*app", "myapp"));
    try std.testing.expect(!globMatch("my*app", "myapp_web"));
}

test "extractDockerName parses config JSON" {
    try std.testing.expectEqualStrings("myapp_web", extractDockerName(
        \\{"ID":"abc","Name":"/myapp_web","State":{}}
    ).?);
    try std.testing.expectEqualStrings("my-app", extractDockerName(
        \\{"Name": "/my-app"}
    ).?);
    try std.testing.expect(extractDockerName("no name here") == null);
}

test "wildcardMatchContainer matches pattern against docker config" {
    const config =
        \\{"ID":"abc123","Name":"/myapp_web","State":{"Running":true}}
    ;
    try std.testing.expect(wildcardMatchContainer("myapp_*", config));
    try std.testing.expect(!wildcardMatchContainer("other_*", config));
    try std.testing.expect(!wildcardMatchContainer("myapp_web", config)); // no wildcard, uses exact path
}

test "findContainerLogFiles expands wildcard into all matching containers" {
    const allocator = std.testing.allocator;

    // Build a fake `log_sources` directory with three "container" subdirs.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixtures = [_]struct { dir: []const u8, name: []const u8 }{
        .{ .dir = "id_web", .name = "myapp_web" },
        .{ .dir = "id_worker", .name = "myapp_worker" },
        .{ .dir = "id_other", .name = "other_app" },
    };
    for (fixtures) |f| {
        var sub = try tmp.dir.makeOpenPath(f.dir, .{});
        defer sub.close();
        const json = try std.fmt.allocPrint(allocator, "{{\"ID\":\"abc\",\"Name\":\"/{s}\"}}", .{f.name});
        defer allocator.free(json);
        try sub.writeFile(.{ .sub_path = "config.v2.json", .data = json });
        // Touch the json log file too so the discovered path is valid on disk.
        const log_name = try std.fmt.allocPrint(allocator, "{s}-json.log", .{f.dir});
        defer allocator.free(log_name);
        try sub.writeFile(.{ .sub_path = log_name, .data = "" });
    }

    const log_sources = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(log_sources);

    // Wildcard should resolve to two real container names.
    const wild = try findContainerLogFiles(allocator, log_sources, "myapp_*");
    defer {
        for (wild) |r| {
            allocator.free(r.name);
            allocator.free(r.log_path);
        }
        allocator.free(wild);
    }
    try std.testing.expectEqual(@as(usize, 2), wild.len);

    var saw_web = false;
    var saw_worker = false;
    for (wild) |r| {
        if (std.mem.eql(u8, r.name, "myapp_web")) saw_web = true;
        if (std.mem.eql(u8, r.name, "myapp_worker")) saw_worker = true;
        // log_path must point at the per-id-json log inside the matching dir.
        try std.testing.expect(std.mem.endsWith(u8, r.log_path, "-json.log"));
    }
    try std.testing.expect(saw_web);
    try std.testing.expect(saw_worker);

    // Exact match should resolve to exactly one entry.
    const exact = try findContainerLogFiles(allocator, log_sources, "other_app");
    defer {
        for (exact) |r| {
            allocator.free(r.name);
            allocator.free(r.log_path);
        }
        allocator.free(exact);
    }
    try std.testing.expectEqual(@as(usize, 1), exact.len);
    try std.testing.expectEqualStrings("other_app", exact[0].name);

    // Pattern with no matches returns empty.
    const none = try findContainerLogFiles(allocator, log_sources, "nope_*");
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}
