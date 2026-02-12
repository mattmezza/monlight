const std = @import("std");
const log = std.log;

/// Configuration error types
pub const ConfigError = error{
    MissingRequired,
    InvalidValue,
};

/// Supported log levels (matching std.log.Level)
pub const LogLevel = enum {
    err,
    warn,
    info,
    debug,

    pub fn fromString(s: []const u8) ?LogLevel {
        const lower = blk: {
            var buf: [10]u8 = undefined;
            if (s.len > buf.len) break :blk s;
            for (s, 0..) |ch, i| {
                buf[i] = std.ascii.toLower(ch);
            }
            break :blk buf[0..s.len];
        };

        if (std.mem.eql(u8, lower, "error") or std.mem.eql(u8, lower, "err")) return .err;
        if (std.mem.eql(u8, lower, "warn") or std.mem.eql(u8, lower, "warning")) return .warn;
        if (std.mem.eql(u8, lower, "info")) return .info;
        if (std.mem.eql(u8, lower, "debug")) return .debug;
        return null;
    }

    pub fn toStdLevel(self: LogLevel) std.log.Level {
        return switch (self) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        };
    }
};

/// Global log level set by config. Services should reference this
/// to configure std.log scoped logging.
pub var global_log_level: LogLevel = .info;

/// Read a required string environment variable.
/// If missing, logs an error with the variable name and returns error.
pub fn getRequired(name: []const u8) ConfigError![]const u8 {
    return std.posix.getenv(name) orelse {
        // We use std.debug.print here instead of std.log because
        // this runs very early during startup and the log message
        // must be visible regardless of log level settings.
        std.debug.print("FATAL: required environment variable '{s}' is not set\n", .{name});
        return ConfigError.MissingRequired;
    };
}

/// Read an optional string environment variable with a default value.
pub fn getString(name: []const u8, default: []const u8) []const u8 {
    return std.posix.getenv(name) orelse default;
}

/// Read an optional integer environment variable with a default value.
/// If the value is present but not a valid integer, logs a warning and
/// returns the default.
pub fn getInt(name: []const u8, default: i64) i64 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(i64, val, 10) catch {
        std.debug.print("WARNING: environment variable '{s}' has invalid integer value '{s}', using default {d}\n", .{ name, val, default });
        return default;
    };
}

/// Read an optional boolean environment variable with a default value.
/// Accepts: "true", "1", "yes" (case-insensitive) as true.
/// Accepts: "false", "0", "no" (case-insensitive) as false.
/// Returns default for unrecognized values.
pub fn getBool(name: []const u8, default: bool) bool {
    const val = std.posix.getenv(name) orelse return default;

    // Lowercase for comparison
    var buf: [10]u8 = undefined;
    if (val.len > buf.len) return default;
    for (val, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    const lower = buf[0..val.len];

    if (std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "1") or std.mem.eql(u8, lower, "yes")) {
        return true;
    }
    if (std.mem.eql(u8, lower, "false") or std.mem.eql(u8, lower, "0") or std.mem.eql(u8, lower, "no")) {
        return false;
    }

    std.debug.print("WARNING: environment variable '{s}' has invalid boolean value '{s}', using default {}\n", .{ name, val, default });
    return default;
}

/// Read LOG_LEVEL env var and apply it globally.
/// Call this early in service startup.
/// Default: INFO
pub fn initLogLevel() void {
    const level_str = std.posix.getenv("LOG_LEVEL") orelse "info";
    if (LogLevel.fromString(level_str)) |level| {
        global_log_level = level;
    } else {
        std.debug.print("WARNING: invalid LOG_LEVEL '{s}', using default INFO\n", .{level_str});
        global_log_level = .info;
    }
}

/// Read an optional string environment variable.
/// Returns null if not set.
pub fn getOptional(name: []const u8) ?[]const u8 {
    return std.posix.getenv(name);
}

// ============================================================
// Tests
// ============================================================

// Note: Environment variable tests are limited because we can't easily
// set env vars in Zig tests. We test the parsing/conversion helpers instead.

test "LogLevel.fromString parses valid levels" {
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("error").?);
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("err").?);
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("ERROR").?);
    try std.testing.expectEqual(LogLevel.warn, LogLevel.fromString("warn").?);
    try std.testing.expectEqual(LogLevel.warn, LogLevel.fromString("warning").?);
    try std.testing.expectEqual(LogLevel.warn, LogLevel.fromString("WARN").?);
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString("info").?);
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString("INFO").?);
    try std.testing.expectEqual(LogLevel.debug, LogLevel.fromString("debug").?);
    try std.testing.expectEqual(LogLevel.debug, LogLevel.fromString("DEBUG").?);
}

test "LogLevel.fromString returns null for invalid levels" {
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.fromString("invalid"));
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.fromString(""));
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.fromString("trace"));
}

test "LogLevel.toStdLevel converts correctly" {
    try std.testing.expectEqual(std.log.Level.err, LogLevel.err.toStdLevel());
    try std.testing.expectEqual(std.log.Level.warn, LogLevel.warn.toStdLevel());
    try std.testing.expectEqual(std.log.Level.info, LogLevel.info.toStdLevel());
    try std.testing.expectEqual(std.log.Level.debug, LogLevel.debug.toStdLevel());
}

test "getRequired returns error for missing env var" {
    // This variable should not exist in the test environment
    const result = getRequired("MONLIGHT_TEST_NONEXISTENT_VAR_12345");
    try std.testing.expectError(ConfigError.MissingRequired, result);
}

test "getString returns default for missing env var" {
    const val = getString("MONLIGHT_TEST_NONEXISTENT_VAR_12345", "default_value");
    try std.testing.expectEqualStrings("default_value", val);
}

test "getInt returns default for missing env var" {
    const val = getInt("MONLIGHT_TEST_NONEXISTENT_VAR_12345", 42);
    try std.testing.expectEqual(@as(i64, 42), val);
}

test "getBool returns default for missing env var" {
    const val = getBool("MONLIGHT_TEST_NONEXISTENT_VAR_12345", true);
    try std.testing.expect(val);

    const val2 = getBool("MONLIGHT_TEST_NONEXISTENT_VAR_12345", false);
    try std.testing.expect(!val2);
}
