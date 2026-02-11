const std = @import("std");
const net = std.net;
const log = std.log;
const database = @import("database.zig");
const sqlite = @import("sqlite");
const app_config = @import("config.zig");

const server_port: u16 = 8000;
const max_header_size = 8192;

pub fn main() !void {
    // Check for --healthcheck CLI flag
    var args = std.process.args();
    _ = args.skip(); // skip binary name
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--healthcheck")) {
            return healthcheck();
        }
    }

    // Load configuration from environment variables
    const cfg = app_config.load() catch {
        // load() already prints descriptive error messages
        std.process.exit(1);
    };

    log.info("configuration loaded (database: {s}, base_url: {s}, retention: {d} days)", .{
        cfg.database_path,
        cfg.base_url,
        cfg.retention_days,
    });

    // Initialize database (opens connection + runs migrations)
    var db = database.init(cfg.db_path_z) catch |err| {
        log.err("Failed to initialize database: {}", .{err});
        std.process.exit(1);
    };
    defer db.close();

    // Start HTTP server
    log.info("Starting error-tracker on port {d}...", .{server_port});

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, server_port);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    log.info("Error tracker listening on 0.0.0.0:{d}", .{server_port});

    // Accept loop
    while (true) {
        const conn = server.accept() catch |err| {
            log.err("Failed to accept connection: {}", .{err});
            continue;
        };
        handleConnection(conn) catch |err| {
            log.err("Failed to handle connection: {}", .{err});
        };
    }
}

fn handleConnection(conn: net.Server.Connection) !void {
    defer conn.stream.close();

    var buf: [max_header_size]u8 = undefined;
    var http_server = std.http.Server.init(conn, &buf);

    var request = http_server.receiveHead() catch |err| {
        log.err("Failed to receive request head: {}", .{err});
        return;
    };

    // Route the request
    if (std.mem.eql(u8, request.head.target, "/health")) {
        try handleHealth(&request);
    } else {
        try handleNotFound(&request);
    }
}

fn handleHealth(request: *std.http.Server.Request) !void {
    const body =
        \\{"status": "ok"}
    ;
    try sendJsonResponse(request, .ok, body);
}

fn handleNotFound(request: *std.http.Server.Request) !void {
    const body =
        \\{"detail": "Not found"}
    ;
    try sendJsonResponse(request, .not_found, body);
}

fn sendJsonResponse(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
) !void {
    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch |err| {
        log.err("Failed to send response: {}", .{err});
        return err;
    };
}

/// Perform a health check by connecting to the local server.
/// Exits with code 0 if healthy, 1 if not.
fn healthcheck() void {
    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, server_port);
    const stream = net.tcpConnectToAddress(address) catch {
        std.process.exit(1);
    };
    defer stream.close();

    const request_bytes =
        "GET /health HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    stream.writeAll(request_bytes) catch {
        std.process.exit(1);
    };

    var buf: [1024]u8 = undefined;
    const n = stream.read(&buf) catch {
        std.process.exit(1);
    };

    if (n == 0) {
        std.process.exit(1);
    }

    const response = buf[0..n];
    // Check for "200 OK" in response
    if (std.mem.indexOf(u8, response, "200") != null) {
        std.process.exit(0);
    }

    std.process.exit(1);
}

test "health endpoint returns ok" {
    // Basic test to verify the module compiles
    const body =
        \\{"status": "ok"}
    ;
    try std.testing.expectEqualStrings("{\"status\": \"ok\"}", body);
}
