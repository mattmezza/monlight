const std = @import("std");
const config_mod = @import("config");

/// Log Viewer configuration.
/// All fields are populated from environment variables at startup.
pub const Config = struct {
    /// Path to the SQLite database file.
    database_path: []const u8,

    /// API key for authenticating requests. Required.
    api_key: []const u8,

    /// Docker log sources directory (e.g., /var/lib/docker/containers).
    log_sources: []const u8,

    /// Comma-separated list of container names to watch. Required.
    containers: []const u8,

    /// Maximum number of log entries to retain (ring buffer).
    max_entries: i64,

    /// Polling interval in seconds for checking new log lines.
    poll_interval: i64,

    /// Number of bytes to read from end of file on first start (tail buffer).
    tail_buffer: i64,

    // Internal storage for the null-terminated database path
    _db_path_buf: [512]u8,

    /// Returns a null-terminated pointer to the database path.
    /// Must be called on a stable (non-temporary) Config instance,
    /// since the returned pointer borrows from `_db_path_buf`.
    pub fn dbPathZ(self: *const Config) [*:0]const u8 {
        return self._db_path_buf[0..self.database_path.len :0];
    }
};

/// Load log viewer configuration from environment variables.
/// Returns error if required variables are missing.
pub fn load() config_mod.ConfigError!Config {
    // Initialize global log level from LOG_LEVEL env var
    config_mod.initLogLevel();

    // Required variables
    const api_key = try config_mod.getRequired("API_KEY");
    const containers = try config_mod.getRequired("CONTAINERS");

    // Optional variables with defaults
    const database_path = config_mod.getString("DATABASE_PATH", "./data/logs.db");
    const log_sources = config_mod.getString("LOG_SOURCES", "/var/lib/docker/containers");
    const max_entries = config_mod.getInt("MAX_ENTRIES", 100_000);
    const poll_interval = config_mod.getInt("POLL_INTERVAL", 2);
    const tail_buffer = config_mod.getInt("TAIL_BUFFER", 65536);

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
        .log_sources = log_sources,
        .containers = containers,
        .max_entries = max_entries,
        .poll_interval = poll_interval,
        .tail_buffer = tail_buffer,
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
        // API_KEY is set — also need CONTAINERS to be set for log-viewer
        if (std.posix.getenv("CONTAINERS")) |_| {
            const cfg = try load();
            try std.testing.expect(cfg.api_key.len > 0);
        } else {
            // CONTAINERS missing — verify that error
            const result = load();
            try std.testing.expectError(config_mod.ConfigError.MissingRequired, result);
        }
    } else {
        // API_KEY is not set — verify the expected error
        const result = load();
        try std.testing.expectError(config_mod.ConfigError.MissingRequired, result);
    }
}
