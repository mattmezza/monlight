const std = @import("std");
const config_mod = @import("config");

/// Metrics Collector configuration.
/// All fields are populated from environment variables at startup.
pub const Config = struct {
    /// Path to the SQLite database file.
    database_path: []const u8,

    /// API key for authenticating requests. Required.
    api_key: []const u8,

    /// Retention period for raw metrics in hours (default: 1).
    retention_raw: i64,

    /// Retention period for minute aggregates in hours (default: 24).
    retention_minute: i64,

    /// Retention period for hourly aggregates in days (default: 30).
    retention_hourly: i64,

    /// Aggregation interval in seconds (default: 60).
    aggregation_interval: i64,

    /// Null-terminated copy of database_path for SQLite C API.
    db_path_z: [*:0]const u8,

    // Internal storage for the null-terminated path
    _db_path_buf: [512]u8,
};

/// Load metrics collector configuration from environment variables.
/// Returns error if required variables are missing.
pub fn load() config_mod.ConfigError!Config {
    // Initialize global log level from LOG_LEVEL env var
    config_mod.initLogLevel();

    // Required variables
    const api_key = try config_mod.getRequired("API_KEY");

    // Optional variables with defaults
    const database_path = config_mod.getString("DATABASE_PATH", "./data/metrics.db");
    const retention_raw = config_mod.getInt("RETENTION_RAW", 1);
    const retention_minute = config_mod.getInt("RETENTION_MINUTE", 24);
    const retention_hourly = config_mod.getInt("RETENTION_HOURLY", 30);
    const aggregation_interval = config_mod.getInt("AGGREGATION_INTERVAL", 60);

    // Create null-terminated copy of database path for SQLite
    var db_path_buf: [512]u8 = undefined;
    if (database_path.len >= db_path_buf.len) {
        std.debug.print("FATAL: DATABASE_PATH too long ({d} bytes, max {d})\n", .{ database_path.len, db_path_buf.len - 1 });
        return config_mod.ConfigError.InvalidValue;
    }
    @memcpy(db_path_buf[0..database_path.len], database_path);
    db_path_buf[database_path.len] = 0;

    return Config{
        .database_path = database_path,
        .api_key = api_key,
        .retention_raw = retention_raw,
        .retention_minute = retention_minute,
        .retention_hourly = retention_hourly,
        .aggregation_interval = aggregation_interval,
        .db_path_z = db_path_buf[0..database_path.len :0],
        ._db_path_buf = db_path_buf,
    };
}

// ============================================================
// Tests
// ============================================================

test "load fails when API_KEY is missing" {
    // This test can only verify the error when API_KEY is not set in the environment.
    // If API_KEY is set (e.g., for integration tests), verify load succeeds instead.
    if (std.posix.getenv("API_KEY")) |_| {
        // API_KEY is set — verify load succeeds
        const cfg = try load();
        try std.testing.expect(cfg.api_key.len > 0);
    } else {
        // API_KEY is not set — verify the expected error
        const result = load();
        try std.testing.expectError(config_mod.ConfigError.MissingRequired, result);
    }
}
