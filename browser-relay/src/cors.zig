const std = @import("std");
const log = std.log;

/// Maximum number of CORS origins to support.
const max_origins = 32;
/// Maximum length of a single origin string.
const max_origin_len = 256;

/// Parsed CORS configuration.
pub const CorsConfig = struct {
    /// Parsed allowed origins (stored inline, no heap allocation).
    origins: [max_origins][max_origin_len]u8,
    /// Lengths of each origin in the origins array.
    origin_lens: [max_origins]usize,
    /// Number of parsed origins.
    count: usize,
};

/// Result of CORS check — tells the caller what to do.
pub const CorsAction = enum {
    /// Origin is allowed — CORS headers have been noted, continue processing.
    allowed,
    /// Preflight OPTIONS request handled — 204 response already sent.
    preflight_handled,
    /// Origin is not allowed or not present — no CORS headers, continue processing.
    /// (Browsers will block the response, but we still process the request.)
    no_cors,
};

/// Parse a comma-separated list of allowed origins into a CorsConfig.
/// Returns a config with count=0 if the input is null or empty.
pub fn parseCorsOrigins(origins_str: ?[]const u8) CorsConfig {
    var config = CorsConfig{
        .origins = undefined,
        .origin_lens = [_]usize{0} ** max_origins,
        .count = 0,
    };

    const raw = origins_str orelse return config;
    if (raw.len == 0) return config;

    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |part| {
        if (config.count >= max_origins) break;

        // Trim whitespace
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed.len > max_origin_len) {
            log.warn("CORS origin too long ({d} bytes, max {d}), skipping", .{ trimmed.len, max_origin_len });
            continue;
        }

        @memcpy(config.origins[config.count][0..trimmed.len], trimmed);
        config.origin_lens[config.count] = trimmed.len;
        config.count += 1;
    }

    return config;
}

/// Check if the request origin is in the allowed origins list.
/// Returns the origin to use in the Access-Control-Allow-Origin header, or null.
/// For exact matches, returns the stored origin. For wildcard matches (e.g.
/// `https://*.example.com`), returns the request origin (CORS spec requires
/// echoing the actual origin, not the pattern).
fn findAllowedOrigin(cors_config: *const CorsConfig, request_origin: []const u8) ?[]const u8 {
    for (0..cors_config.count) |i| {
        const allowed = cors_config.origins[i][0..cors_config.origin_lens[i]];
        if (std.mem.eql(u8, request_origin, allowed)) {
            return allowed;
        }
        if (wildcardMatch(allowed, request_origin)) {
            return request_origin;
        }
    }
    return null;
}

/// Check if a wildcard origin pattern matches a request origin.
/// Supports patterns like `https://*.example.com` where `*` matches
/// one or more characters in the hostname (no slashes, no colons).
fn wildcardMatch(pattern: []const u8, origin: []const u8) bool {
    const star = std.mem.indexOf(u8, pattern, "*") orelse return false;
    const prefix = pattern[0..star]; // e.g. "https://"
    const suffix = pattern[star + 1..]; // e.g. ".example.com"

    if (!std.mem.startsWith(u8, origin, prefix)) return false;
    if (!std.mem.endsWith(u8, origin, suffix)) return false;

    // The matched wildcard portion (between prefix and suffix)
    if (origin.len < prefix.len + suffix.len) return false;
    const matched = origin[prefix.len .. origin.len - suffix.len];

    // Wildcard must match at least one character, and must not contain
    // scheme separators (no slashes, colons, or @ signs)
    if (matched.len == 0) return false;
    for (matched) |c| {
        if (c == '/' or c == ':' or c == '@') return false;
    }
    return true;
}

/// Extract the Origin header value from a request.
fn getOriginHeader(request: *std.http.Server.Request) ?[]const u8 {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (asciiEqlIgnoreCase(header.name, "origin")) {
            return header.value;
        }
    }
    return null;
}

/// Handle CORS for browser ingestion endpoints.
///
/// This function:
/// 1. Checks for the `Origin` header
/// 2. If present and in the allowed list, adds CORS headers to the response
/// 3. If the request is an OPTIONS preflight, sends a 204 and returns `.preflight_handled`
/// 4. If the origin is not allowed, returns `.no_cors` (no CORS headers)
///
/// For non-preflight requests with an allowed origin, returns `.allowed` and the
/// caller should include CORS headers in their response via `addCorsHeaders`.
pub fn handleCors(
    request: *std.http.Server.Request,
    cors_config: *const CorsConfig,
) CorsAction {
    // If no CORS origins configured, skip CORS handling entirely
    if (cors_config.count == 0) return .no_cors;

    // Get the Origin header
    const origin = getOriginHeader(request) orelse return .no_cors;
    if (origin.len == 0) return .no_cors;

    // Check if origin is allowed
    const allowed_origin = findAllowedOrigin(cors_config, origin) orelse return .no_cors;

    // Check if this is a preflight OPTIONS request
    if (request.head.method == .OPTIONS) {
        sendPreflightResponse(request, allowed_origin);
        return .preflight_handled;
    }

    // For normal requests, the caller should include CORS headers
    // We return .allowed so the caller knows to add them
    return .allowed;
}

/// Send a 204 No Content response with CORS headers for preflight requests.
fn sendPreflightResponse(request: *std.http.Server.Request, origin: []const u8) void {
    request.respond("", .{
        .status = .no_content,
        .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = origin },
            .{ .name = "access-control-allow-methods", .value = "POST, OPTIONS" },
            .{ .name = "access-control-allow-headers", .value = "X-Monlight-Key, Content-Type" },
            .{ .name = "access-control-max-age", .value = "86400" },
        },
    }) catch |err| {
        log.err("Failed to send CORS preflight response: {}", .{err});
    };
}

/// Get CORS response headers for a given request.
/// Returns the headers array to include in the response, or null if no CORS headers needed.
/// The caller must pass these to `sendJsonResponse` or equivalent.
pub fn getCorsHeaders(
    request: *std.http.Server.Request,
    cors_config: *const CorsConfig,
) ?CorsHeaders {
    if (cors_config.count == 0) return null;

    const origin = getOriginHeader(request) orelse return null;
    if (origin.len == 0) return null;

    const allowed_origin = findAllowedOrigin(cors_config, origin) orelse return null;

    return CorsHeaders{
        .origin = allowed_origin,
    };
}

/// CORS headers to include in a response.
pub const CorsHeaders = struct {
    origin: []const u8,
};

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

test "parseCorsOrigins with null returns empty config" {
    const config = parseCorsOrigins(null);
    try std.testing.expectEqual(@as(usize, 0), config.count);
}

test "parseCorsOrigins with empty string returns empty config" {
    const config = parseCorsOrigins("");
    try std.testing.expectEqual(@as(usize, 0), config.count);
}

test "parseCorsOrigins with single origin" {
    const config = parseCorsOrigins("https://example.com");
    try std.testing.expectEqual(@as(usize, 1), config.count);
    try std.testing.expectEqualStrings("https://example.com", config.origins[0][0..config.origin_lens[0]]);
}

test "parseCorsOrigins with multiple origins" {
    const config = parseCorsOrigins("https://example.com,https://other.com,http://localhost:3000");
    try std.testing.expectEqual(@as(usize, 3), config.count);
    try std.testing.expectEqualStrings("https://example.com", config.origins[0][0..config.origin_lens[0]]);
    try std.testing.expectEqualStrings("https://other.com", config.origins[1][0..config.origin_lens[1]]);
    try std.testing.expectEqualStrings("http://localhost:3000", config.origins[2][0..config.origin_lens[2]]);
}

test "parseCorsOrigins trims whitespace" {
    const config = parseCorsOrigins("  https://example.com , https://other.com  ");
    try std.testing.expectEqual(@as(usize, 2), config.count);
    try std.testing.expectEqualStrings("https://example.com", config.origins[0][0..config.origin_lens[0]]);
    try std.testing.expectEqualStrings("https://other.com", config.origins[1][0..config.origin_lens[1]]);
}

test "parseCorsOrigins skips empty entries" {
    const config = parseCorsOrigins("https://example.com,,https://other.com,");
    try std.testing.expectEqual(@as(usize, 2), config.count);
    try std.testing.expectEqualStrings("https://example.com", config.origins[0][0..config.origin_lens[0]]);
    try std.testing.expectEqualStrings("https://other.com", config.origins[1][0..config.origin_lens[1]]);
}

test "findAllowedOrigin matches exact origin" {
    const config = parseCorsOrigins("https://example.com,https://other.com");
    try std.testing.expect(findAllowedOrigin(&config, "https://example.com") != null);
    try std.testing.expectEqualStrings("https://example.com", findAllowedOrigin(&config, "https://example.com").?);
}

test "findAllowedOrigin returns null for non-matching origin" {
    const config = parseCorsOrigins("https://example.com,https://other.com");
    try std.testing.expect(findAllowedOrigin(&config, "https://evil.com") == null);
}

test "findAllowedOrigin is case-sensitive for origins" {
    // Origins are case-sensitive per the spec (scheme and host are lowercase by convention)
    const config = parseCorsOrigins("https://example.com");
    try std.testing.expect(findAllowedOrigin(&config, "https://Example.com") == null);
    try std.testing.expect(findAllowedOrigin(&config, "https://example.com") != null);
}

test "findAllowedOrigin with empty config returns null" {
    const config = parseCorsOrigins(null);
    try std.testing.expect(findAllowedOrigin(&config, "https://example.com") == null);
}

test "findAllowedOrigin matches wildcard subdomain" {
    const config = parseCorsOrigins("https://*.flowrent.app");
    const result = findAllowedOrigin(&config, "https://app.flowrent.app");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("https://app.flowrent.app", result.?);
}

test "findAllowedOrigin wildcard matches different subdomains" {
    const config = parseCorsOrigins("https://*.example.com");
    try std.testing.expect(findAllowedOrigin(&config, "https://foo.example.com") != null);
    try std.testing.expect(findAllowedOrigin(&config, "https://bar.example.com") != null);
    try std.testing.expect(findAllowedOrigin(&config, "https://a.b.example.com") != null);
}

test "findAllowedOrigin wildcard rejects bare domain" {
    const config = parseCorsOrigins("https://*.example.com");
    // "*.example.com" should not match "example.com" (no subdomain)
    try std.testing.expect(findAllowedOrigin(&config, "https://example.com") == null);
}

test "findAllowedOrigin wildcard rejects different scheme" {
    const config = parseCorsOrigins("https://*.example.com");
    try std.testing.expect(findAllowedOrigin(&config, "http://foo.example.com") == null);
}

test "findAllowedOrigin wildcard rejects path injection" {
    const config = parseCorsOrigins("https://*.example.com");
    try std.testing.expect(findAllowedOrigin(&config, "https://evil.com/.example.com") == null);
}

test "findAllowedOrigin mixed exact and wildcard" {
    const config = parseCorsOrigins("https://exact.com,https://*.wildcard.com");
    try std.testing.expect(findAllowedOrigin(&config, "https://exact.com") != null);
    try std.testing.expect(findAllowedOrigin(&config, "https://foo.wildcard.com") != null);
    try std.testing.expect(findAllowedOrigin(&config, "https://evil.com") == null);
}

test "asciiEqlIgnoreCase for header names" {
    try std.testing.expect(asciiEqlIgnoreCase("origin", "Origin"));
    try std.testing.expect(asciiEqlIgnoreCase("ORIGIN", "origin"));
    try std.testing.expect(asciiEqlIgnoreCase("Origin", "origin"));
    try std.testing.expect(!asciiEqlIgnoreCase("origin", "origins"));
    try std.testing.expect(!asciiEqlIgnoreCase("origin", "referer"));
}
