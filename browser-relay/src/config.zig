const std = @import("std");
const config_mod = @import("config");

/// Browser Relay configuration.
/// All fields are populated from environment variables at startup.
pub const Config = struct {
    /// Path to the SQLite database file.
    database_path: []const u8,

    /// Admin API key for management endpoints (source maps, DSN keys). Required.
    admin_api_key: []const u8,

    /// Error Tracker service URL. Required.
    error_tracker_url: []const u8,

    /// Error Tracker API key for forwarding errors. Required.
    error_tracker_api_key: []const u8,

    /// Metrics Collector service URL. Required.
    metrics_collector_url: []const u8,

    /// Metrics Collector API key for forwarding metrics. Required.
    metrics_collector_api_key: []const u8,

    /// Comma-separated list of allowed CORS origins. Optional.
    cors_origins: ?[]const u8,

    /// Maximum request body size in bytes.
    max_body_size: usize,

    /// Rate limit: max requests per minute per public key.
    rate_limit: usize,

    /// Number of days to retain source maps before deletion.
    retention_days: i64,

    /// Null-terminated copy of database_path for SQLite C API.
    db_path_z: [*:0]const u8,

    // Internal storage for the null-terminated path
    _db_path_buf: [512]u8,
};

/// Load browser relay configuration from environment variables.
/// Returns error if required variables are missing.
pub fn load() config_mod.ConfigError!Config {
    // Initialize global log level from LOG_LEVEL env var
    config_mod.initLogLevel();

    // Required variables
    const admin_api_key = try config_mod.getRequired("ADMIN_API_KEY");
    const error_tracker_url = try config_mod.getRequired("ERROR_TRACKER_URL");
    const error_tracker_api_key = try config_mod.getRequired("ERROR_TRACKER_API_KEY");
    const metrics_collector_url = try config_mod.getRequired("METRICS_COLLECTOR_URL");
    const metrics_collector_api_key = try config_mod.getRequired("METRICS_COLLECTOR_API_KEY");

    // Optional variables with defaults
    const database_path = config_mod.getString("DATABASE_PATH", "./data/browser-relay.db");
    const cors_origins = config_mod.getOptional("CORS_ORIGINS");
    const max_body_size: usize = @intCast(config_mod.getInt("MAX_BODY_SIZE", 64 * 1024));
    const rate_limit_val: usize = @intCast(config_mod.getInt("RATE_LIMIT", 300));
    const retention_days = config_mod.getInt("RETENTION_DAYS", 90);

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
        .admin_api_key = admin_api_key,
        .error_tracker_url = error_tracker_url,
        .error_tracker_api_key = error_tracker_api_key,
        .metrics_collector_url = metrics_collector_url,
        .metrics_collector_api_key = metrics_collector_api_key,
        .cors_origins = cors_origins,
        .max_body_size = max_body_size,
        .rate_limit = rate_limit_val,
        .retention_days = retention_days,
        .db_path_z = db_path_buf[0..database_path.len :0],
        ._db_path_buf = db_path_buf,
    };
}

// ============================================================
// Tests
// ============================================================

test "load fails when ADMIN_API_KEY is missing" {
    // This test can only verify the error when required vars are not set.
    // If ADMIN_API_KEY is set (e.g., for integration tests), verify load succeeds instead.
    if (std.posix.getenv("ADMIN_API_KEY")) |_| {
        // ADMIN_API_KEY is set — verify load succeeds (other required vars must also be set)
        const cfg = load() catch {
            // If a required var is missing, that's expected in this test env
            return;
        };
        try std.testing.expect(cfg.admin_api_key.len > 0);
    } else {
        // ADMIN_API_KEY is not set — verify the expected error
        const result = load();
        try std.testing.expectError(config_mod.ConfigError.MissingRequired, result);
    }
}
