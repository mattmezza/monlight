const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared modules from ../shared/
    const sqlite_mod = b.createModule(.{
        .root_source_file = b.path("../shared/sqlite.zig"),
    });

    const config_mod = b.createModule(.{
        .root_source_file = b.path("../shared/config.zig"),
    });

    const auth_mod = b.createModule(.{
        .root_source_file = b.path("../shared/auth.zig"),
    });

    const rate_limit_mod = b.createModule(.{
        .root_source_file = b.path("../shared/rate_limit.zig"),
    });

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "auth", .module = auth_mod },
            .{ .name = "rate_limit", .module = rate_limit_mod },
        },
    });
    exe_mod.linkSystemLibrary("sqlite3", .{});
    exe_mod.link_libc = true;

    const exe = b.addExecutable(.{ .name = "browser-relay", .root_module = exe_mod });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the browser relay server");
    run_step.dependOn(&run_cmd.step);

    // Test step — tests for main.zig
    const main_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "auth", .module = auth_mod },
            .{ .name = "rate_limit", .module = rate_limit_mod },
        },
    });
    main_test_mod.linkSystemLibrary("sqlite3", .{});
    main_test_mod.link_libc = true;
    const main_tests = b.addTest(.{ .root_module = main_test_mod });
    const run_main_tests = b.addRunArtifact(main_tests);

    // Test step — tests for config.zig
    const config_test_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });
    const config_tests = b.addTest(.{ .root_module = config_test_mod });
    const run_config_tests = b.addRunArtifact(config_tests);

    // Test step — tests for database.zig
    const db_test_mod = b.createModule(.{
        .root_source_file = b.path("src/database.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    db_test_mod.linkSystemLibrary("sqlite3", .{});
    db_test_mod.link_libc = true;
    const db_tests = b.addTest(.{ .root_module = db_test_mod });
    const run_db_tests = b.addRunArtifact(db_tests);

    // Test step — tests for dsn_auth.zig
    const dsn_auth_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dsn_auth.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    dsn_auth_test_mod.linkSystemLibrary("sqlite3", .{});
    dsn_auth_test_mod.link_libc = true;
    const dsn_auth_tests = b.addTest(.{ .root_module = dsn_auth_test_mod });
    const run_dsn_auth_tests = b.addRunArtifact(dsn_auth_tests);

    // Test step — integration tests for DSN auth and admin auth (dsn_auth_test.zig)
    const dsn_auth_integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dsn_auth_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "auth", .module = auth_mod },
            .{ .name = "rate_limit", .module = rate_limit_mod },
        },
    });
    dsn_auth_integration_test_mod.linkSystemLibrary("sqlite3", .{});
    dsn_auth_integration_test_mod.link_libc = true;
    const dsn_auth_integration_tests = b.addTest(.{ .root_module = dsn_auth_integration_test_mod });
    const run_dsn_auth_integration_tests = b.addRunArtifact(dsn_auth_integration_tests);

    // Test step — tests for cors.zig
    const cors_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cors.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cors_tests = b.addTest(.{ .root_module = cors_test_mod });
    const run_cors_tests = b.addRunArtifact(cors_tests);

    // Test step — integration tests for CORS (cors_test.zig)
    const cors_integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cors_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "auth", .module = auth_mod },
            .{ .name = "rate_limit", .module = rate_limit_mod },
        },
    });
    cors_integration_test_mod.linkSystemLibrary("sqlite3", .{});
    cors_integration_test_mod.link_libc = true;
    const cors_integration_tests = b.addTest(.{ .root_module = cors_integration_test_mod });
    const run_cors_integration_tests = b.addRunArtifact(cors_integration_tests);

    // Test step — unit tests for browser_errors.zig
    const browser_errors_test_mod = b.createModule(.{
        .root_source_file = b.path("src/browser_errors.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    browser_errors_test_mod.linkSystemLibrary("sqlite3", .{});
    browser_errors_test_mod.link_libc = true;
    const browser_errors_tests = b.addTest(.{ .root_module = browser_errors_test_mod });
    const run_browser_errors_tests = b.addRunArtifact(browser_errors_tests);

    // Test step — unit tests for browser_metrics.zig
    const browser_metrics_test_mod = b.createModule(.{
        .root_source_file = b.path("src/browser_metrics.zig"),
        .target = target,
        .optimize = optimize,
    });
    const browser_metrics_tests = b.addTest(.{ .root_module = browser_metrics_test_mod });
    const run_browser_metrics_tests = b.addRunArtifact(browser_metrics_tests);

    // Test step — unit tests for dsn_keys.zig
    const dsn_keys_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dsn_keys.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    dsn_keys_test_mod.linkSystemLibrary("sqlite3", .{});
    dsn_keys_test_mod.link_libc = true;
    const dsn_keys_tests = b.addTest(.{ .root_module = dsn_keys_test_mod });
    const run_dsn_keys_tests = b.addRunArtifact(dsn_keys_tests);

    // Test step — unit tests for source_maps.zig
    const source_maps_test_mod = b.createModule(.{
        .root_source_file = b.path("src/source_maps.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    source_maps_test_mod.linkSystemLibrary("sqlite3", .{});
    source_maps_test_mod.link_libc = true;
    const source_maps_tests = b.addTest(.{ .root_module = source_maps_test_mod });
    const run_source_maps_tests = b.addRunArtifact(source_maps_tests);

    // Test step — unit tests for sourcemap.zig (deobfuscation module)
    const sourcemap_test_mod = b.createModule(.{
        .root_source_file = b.path("src/sourcemap.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    sourcemap_test_mod.linkSystemLibrary("sqlite3", .{});
    sourcemap_test_mod.link_libc = true;
    const sourcemap_tests = b.addTest(.{ .root_module = sourcemap_test_mod });
    const run_sourcemap_tests = b.addRunArtifact(sourcemap_tests);

    // Test step — unit tests for retention.zig
    const retention_test_mod = b.createModule(.{
        .root_source_file = b.path("src/retention.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    retention_test_mod.linkSystemLibrary("sqlite3", .{});
    retention_test_mod.link_libc = true;
    const retention_tests = b.addTest(.{ .root_module = retention_test_mod });
    const run_retention_tests = b.addRunArtifact(retention_tests);

    // Test step — integration tests for upstream forwarding failures (forward_test.zig)
    const forward_test_mod = b.createModule(.{
        .root_source_file = b.path("src/forward_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "auth", .module = auth_mod },
            .{ .name = "rate_limit", .module = rate_limit_mod },
        },
    });
    forward_test_mod.linkSystemLibrary("sqlite3", .{});
    forward_test_mod.link_libc = true;
    const forward_tests = b.addTest(.{ .root_module = forward_test_mod });
    const run_forward_tests = b.addRunArtifact(forward_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_dsn_auth_tests.step);
    test_step.dependOn(&run_dsn_auth_integration_tests.step);
    test_step.dependOn(&run_cors_tests.step);
    test_step.dependOn(&run_cors_integration_tests.step);
    test_step.dependOn(&run_browser_errors_tests.step);
    test_step.dependOn(&run_browser_metrics_tests.step);
    test_step.dependOn(&run_dsn_keys_tests.step);
    test_step.dependOn(&run_source_maps_tests.step);
    test_step.dependOn(&run_sourcemap_tests.step);
    test_step.dependOn(&run_retention_tests.step);
    test_step.dependOn(&run_forward_tests.step);

    // Separate step for forward tests only (for debugging)
    const forward_test_step = b.step("test-forward", "Run upstream forwarding tests only");
    forward_test_step.dependOn(&run_forward_tests.step);
}
