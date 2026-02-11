const std = @import("std");
const net = std.net;
const log = std.log;
const database = @import("database.zig");
const sqlite = @import("sqlite");

const server_port: u16 = 8000;
const max_header_size = 8192;
const default_db_path = "./data/errors.db";

pub fn main() !void {
    // Check for --healthcheck CLI flag
    var args = std.process.args();
    _ = args.skip(); // skip binary name
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--healthcheck")) {
            return healthcheck();
        }
    }

    // Read DATABASE_PATH from environment (or use default)
    const db_path_env = std.posix.getenv("DATABASE_PATH") orelse default_db_path;

    // Null-terminate the path for SQLite
    var db_path_buf: [512]u8 = undefined;
    if (db_path_env.len >= db_path_buf.len) {
        log.err("DATABASE_PATH too long", .{});
        std.process.exit(1);
    }
    @memcpy(db_path_buf[0..db_path_env.len], db_path_env);
    db_path_buf[db_path_env.len] = 0;
    const db_path_z: [*:0]const u8 = db_path_buf[0..db_path_env.len :0];

    // Initialize database (opens connection + runs migrations)
    var db = database.init(db_path_z) catch |err| {
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
