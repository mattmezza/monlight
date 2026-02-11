const std = @import("std");

/// Recognized log levels.
pub const Level = enum {
    DEBUG,
    INFO,
    WARNING,
    ERROR,
    CRITICAL,

    pub fn string(self: Level) []const u8 {
        return switch (self) {
            .DEBUG => "DEBUG",
            .INFO => "INFO",
            .WARNING => "WARNING",
            .ERROR => "ERROR",
            .CRITICAL => "CRITICAL",
        };
    }
};

/// Extract the log level from a log message.
///
/// Tries these patterns in order:
///   1. JSON format: `{"level": "INFO", ...}` or `{"ts":..., "level":..., "msg":...}`
///   2. `[LEVEL]` pattern (e.g., `[INFO]`, `[ERROR]`)
///   3. `level=LEVEL` pattern (e.g., `level=info`)
///   4. `LEVEL:` at start (e.g., `INFO: message`)
///   5. Uvicorn format (e.g., `INFO:     127.0.0.1...`)
///
/// Falls back to `default_level` if no pattern matches.
pub fn extract(message: []const u8, stream: []const u8) Level {
    // Try JSON format first
    if (extractFromJson(message)) |level| return level;

    // Try bracket pattern: [INFO], [ERROR], etc.
    if (extractBracketPattern(message)) |level| return level;

    // Try key=value pattern: level=info
    if (extractKeyValuePattern(message)) |level| return level;

    // Try LEVEL: at start or Uvicorn format (LEVEL: with spaces)
    if (extractColonPattern(message)) |level| return level;

    // Default: ERROR for stderr, INFO for stdout
    if (std.mem.eql(u8, stream, "stderr")) return .ERROR;
    return .INFO;
}

/// Try to extract level from a JSON-formatted log line.
/// Looks for `"level":"VALUE"` or `"level": "VALUE"` pattern.
fn extractFromJson(message: []const u8) ?Level {
    // Quick check: must start with '{' (trimmed)
    const trimmed = std.mem.trimLeft(u8, message, " \t");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;

    // Look for "level" key
    const key = "\"level\"";
    const key_pos = std.mem.indexOf(u8, trimmed, key) orelse return null;
    var rest = trimmed[key_pos + key.len ..];

    // Skip whitespace and colon
    rest = std.mem.trimLeft(u8, rest, " \t");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = rest[1..];
    rest = std.mem.trimLeft(u8, rest, " \t");

    // Extract quoted value
    if (rest.len < 2 or rest[0] != '"') return null;
    rest = rest[1..];
    const end_quote = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const value = rest[0..end_quote];

    return parseLevel(value);
}

/// Try to extract level from [LEVEL] pattern anywhere in the message.
fn extractBracketPattern(message: []const u8) ?Level {
    var i: usize = 0;
    while (i < message.len) {
        if (message[i] == '[') {
            const start = i + 1;
            const end = std.mem.indexOfScalarPos(u8, message, start, ']') orelse return null;
            const content = message[start..end];
            if (content.len >= 3 and content.len <= 8) {
                if (parseLevel(content)) |level| return level;
            }
            i = end + 1;
        } else {
            i += 1;
        }
    }
    return null;
}

/// Try to extract level from level=VALUE pattern.
fn extractKeyValuePattern(message: []const u8) ?Level {
    const patterns = [_][]const u8{ "level=", "LEVEL=", "Level=" };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, message, pattern)) |pos| {
            const start = pos + pattern.len;
            // Value ends at space, comma, or end of string
            var end = start;
            while (end < message.len and message[end] != ' ' and message[end] != ',' and message[end] != '\t' and message[end] != '"') {
                end += 1;
            }
            if (end > start) {
                if (parseLevel(message[start..end])) |level| return level;
            }
        }
    }
    return null;
}

/// Try to extract level from LEVEL: at the start of the message.
/// Also handles Uvicorn format: `INFO:     127.0.0.1...`
fn extractColonPattern(message: []const u8) ?Level {
    const trimmed = std.mem.trimLeft(u8, message, " \t");
    // Look for LEVEL: pattern at the start (level word followed by colon)
    const colon_pos = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    if (colon_pos > 8 or colon_pos < 3) return null; // Level names are 3-8 chars

    const candidate = trimmed[0..colon_pos];
    return parseLevel(candidate);
}

/// Parse a level string (case-insensitive) to a Level enum.
fn parseLevel(s: []const u8) ?Level {
    if (s.len < 3 or s.len > 8) return null;

    // Convert to uppercase for comparison
    var buf: [8]u8 = undefined;
    for (s, 0..) |ch, i| {
        buf[i] = std.ascii.toUpper(ch);
    }
    const upper = buf[0..s.len];

    if (std.mem.eql(u8, upper, "DEBUG")) return .DEBUG;
    if (std.mem.eql(u8, upper, "INFO")) return .INFO;
    if (std.mem.eql(u8, upper, "WARN") or std.mem.eql(u8, upper, "WARNING")) return .WARNING;
    if (std.mem.eql(u8, upper, "ERROR") or std.mem.eql(u8, upper, "ERR")) return .ERROR;
    if (std.mem.eql(u8, upper, "CRITICAL") or std.mem.eql(u8, upper, "FATAL") or std.mem.eql(u8, upper, "CRIT")) return .CRITICAL;
    return null;
}

// ============================================================
// Tests
// ============================================================

test "extract from bracket pattern [INFO]" {
    try std.testing.expectEqual(Level.INFO, extract("2025-01-20 [INFO] Server started", "stdout"));
    try std.testing.expectEqual(Level.ERROR, extract("[ERROR] Something failed", "stdout"));
    try std.testing.expectEqual(Level.WARNING, extract("[WARNING] Disk usage high", "stdout"));
    try std.testing.expectEqual(Level.DEBUG, extract("[DEBUG] Variable x = 42", "stdout"));
}

test "extract from key=value pattern" {
    try std.testing.expectEqual(Level.INFO, extract("ts=2025-01-20 level=info msg=hello", "stdout"));
    try std.testing.expectEqual(Level.ERROR, extract("level=error component=db", "stdout"));
    try std.testing.expectEqual(Level.WARNING, extract("level=warn message=slow query", "stdout"));
}

test "extract from colon pattern (LEVEL: message)" {
    try std.testing.expectEqual(Level.INFO, extract("INFO: Server started on port 8000", "stdout"));
    try std.testing.expectEqual(Level.ERROR, extract("ERROR: Connection refused", "stdout"));
    try std.testing.expectEqual(Level.WARNING, extract("WARNING: deprecated function called", "stdout"));
}

test "extract from Uvicorn format" {
    try std.testing.expectEqual(Level.INFO, extract("INFO:     127.0.0.1:45678 - \"GET / HTTP/1.1\" 200", "stdout"));
    try std.testing.expectEqual(Level.ERROR, extract("ERROR:    Application startup failed", "stdout"));
}

test "extract from JSON format" {
    try std.testing.expectEqual(Level.INFO, extract("{\"ts\": \"2025-01-20\", \"level\": \"info\", \"msg\": \"hello\"}", "stdout"));
    try std.testing.expectEqual(Level.ERROR, extract("{\"level\":\"error\",\"message\":\"failed\"}", "stdout"));
    try std.testing.expectEqual(Level.DEBUG, extract("{\"level\": \"DEBUG\", \"msg\": \"trace\"}", "stdout"));
}

test "default to INFO for stdout when no level detected" {
    try std.testing.expectEqual(Level.INFO, extract("Just a plain message", "stdout"));
    try std.testing.expectEqual(Level.INFO, extract("12345 some data", "stdout"));
}

test "default to ERROR for stderr when no level detected" {
    try std.testing.expectEqual(Level.ERROR, extract("Just a plain message", "stderr"));
    try std.testing.expectEqual(Level.ERROR, extract("Traceback (most recent call last):", "stderr"));
}

test "parseLevel handles case insensitivity" {
    try std.testing.expectEqual(Level.INFO, parseLevel("info").?);
    try std.testing.expectEqual(Level.INFO, parseLevel("INFO").?);
    try std.testing.expectEqual(Level.INFO, parseLevel("Info").?);
    try std.testing.expectEqual(Level.WARNING, parseLevel("warn").?);
    try std.testing.expectEqual(Level.WARNING, parseLevel("WARNING").?);
    try std.testing.expectEqual(Level.CRITICAL, parseLevel("FATAL").?);
    try std.testing.expectEqual(Level.CRITICAL, parseLevel("CRIT").?);
    try std.testing.expect(parseLevel("unknown") == null);
    try std.testing.expect(parseLevel("") == null);
}
