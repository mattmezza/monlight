const std = @import("std");
const config_mod = @import("config");

/// Error Tracker configuration.
/// All fields are populated from environment variables at startup.
pub const Config = struct {
    /// Path to the SQLite database file.
    database_path: []const u8,

    /// API key for authenticating requests. Required.
    api_key: []const u8,

    /// Postmark API token for sending alert emails. Optional.
    postmark_api_token: ?[]const u8,

    /// Sender email address for alerts.
    postmark_from_email: []const u8,

    /// Comma-separated list of alert recipient emails. Optional.
    alert_emails: ?[]const u8,

    /// Number of days to retain resolved errors before deletion.
    retention_days: i64,

    /// Base URL of the error tracker dashboard (used in alert emails).
    base_url: []const u8,

    /// Null-terminated copy of database_path for SQLite C API.
    db_path_z: [*:0]const u8,

    // Internal storage for the null-terminated path
    _db_path_buf: [512]u8,
};

/// Load error tracker configuration from environment variables.
/// Returns error if required variables are missing.
pub fn load() config_mod.ConfigError!Config {
    // Initialize global log level from LOG_LEVEL env var
    config_mod.initLogLevel();

    // Required variables
    const api_key = try config_mod.getRequired("API_KEY");

    // Optional variables with defaults
    const database_path = config_mod.getString("DATABASE_PATH", "./data/errors.db");
    const postmark_api_token = config_mod.getOptional("POSTMARK_API_TOKEN");
    const postmark_from_email = config_mod.getString("POSTMARK_FROM_EMAIL", "errors@example.com");
    const alert_emails = config_mod.getOptional("ALERT_EMAILS");
    const retention_days = config_mod.getInt("RETENTION_DAYS", 90);
    const base_url = config_mod.getString("BASE_URL", "http://localhost:5010");

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
        .postmark_api_token = postmark_api_token,
        .postmark_from_email = postmark_from_email,
        .alert_emails = alert_emails,
        .retention_days = retention_days,
        .base_url = base_url,
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
