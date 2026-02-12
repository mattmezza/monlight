const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared SQLite module from ../shared/
    const sqlite_mod = b.addModule("sqlite", .{
        .root_source_file = b.path("../shared/sqlite.zig"),
    });

    // Shared config module from ../shared/
    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("../shared/config.zig"),
    });

    // Shared auth module from ../shared/
    const auth_mod = b.addModule("auth", .{
        .root_source_file = b.path("../shared/auth.zig"),
    });

    // Shared rate limiting module from ../shared/
    const rate_limit_mod = b.addModule("rate_limit", .{
        .root_source_file = b.path("../shared/rate_limit.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "browser-relay",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add shared modules
    exe.root_module.addImport("sqlite", sqlite_mod);
    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("auth", auth_mod);
    exe.root_module.addImport("rate_limit", rate_limit_mod);

    // Link SQLite C library
    exe.linkSystemLibrary("sqlite3");
    exe.linkLibC();

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
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.root_module.addImport("sqlite", sqlite_mod);
    main_tests.root_module.addImport("config", config_mod);
    main_tests.root_module.addImport("auth", auth_mod);
    main_tests.root_module.addImport("rate_limit", rate_limit_mod);
    main_tests.linkSystemLibrary("sqlite3");
    main_tests.linkLibC();

    const run_main_tests = b.addRunArtifact(main_tests);

    // Test step — tests for config.zig
    const config_tests = b.addTest(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_tests.root_module.addImport("config", config_mod);

    const run_config_tests = b.addRunArtifact(config_tests);

    // Test step — tests for database.zig
    const db_tests = b.addTest(.{
        .root_source_file = b.path("src/database.zig"),
        .target = target,
        .optimize = optimize,
    });
    db_tests.root_module.addImport("sqlite", sqlite_mod);
    db_tests.linkSystemLibrary("sqlite3");
    db_tests.linkLibC();

    const run_db_tests = b.addRunArtifact(db_tests);

    // Test step — tests for dsn_auth.zig
    const dsn_auth_tests = b.addTest(.{
        .root_source_file = b.path("src/dsn_auth.zig"),
        .target = target,
        .optimize = optimize,
    });
    dsn_auth_tests.root_module.addImport("sqlite", sqlite_mod);
    dsn_auth_tests.linkSystemLibrary("sqlite3");
    dsn_auth_tests.linkLibC();

    const run_dsn_auth_tests = b.addRunArtifact(dsn_auth_tests);

    // Test step — integration tests for DSN auth and admin auth (dsn_auth_test.zig)
    const dsn_auth_integration_tests = b.addTest(.{
        .root_source_file = b.path("src/dsn_auth_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dsn_auth_integration_tests.root_module.addImport("sqlite", sqlite_mod);
    dsn_auth_integration_tests.root_module.addImport("config", config_mod);
    dsn_auth_integration_tests.root_module.addImport("auth", auth_mod);
    dsn_auth_integration_tests.root_module.addImport("rate_limit", rate_limit_mod);
    dsn_auth_integration_tests.linkSystemLibrary("sqlite3");
    dsn_auth_integration_tests.linkLibC();

    const run_dsn_auth_integration_tests = b.addRunArtifact(dsn_auth_integration_tests);

    // Test step — tests for cors.zig
    const cors_tests = b.addTest(.{
        .root_source_file = b.path("src/cors.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_cors_tests = b.addRunArtifact(cors_tests);

    // Test step — integration tests for CORS (cors_test.zig)
    const cors_integration_tests = b.addTest(.{
        .root_source_file = b.path("src/cors_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cors_integration_tests.root_module.addImport("sqlite", sqlite_mod);
    cors_integration_tests.root_module.addImport("config", config_mod);
    cors_integration_tests.root_module.addImport("auth", auth_mod);
    cors_integration_tests.root_module.addImport("rate_limit", rate_limit_mod);
    cors_integration_tests.linkSystemLibrary("sqlite3");
    cors_integration_tests.linkLibC();

    const run_cors_integration_tests = b.addRunArtifact(cors_integration_tests);

    // Test step — unit tests for browser_errors.zig
    const browser_errors_tests = b.addTest(.{
        .root_source_file = b.path("src/browser_errors.zig"),
        .target = target,
        .optimize = optimize,
    });
    browser_errors_tests.root_module.addImport("sqlite", sqlite_mod);
    browser_errors_tests.linkSystemLibrary("sqlite3");
    browser_errors_tests.linkLibC();

    const run_browser_errors_tests = b.addRunArtifact(browser_errors_tests);

    // Test step — unit tests for browser_metrics.zig
    const browser_metrics_tests = b.addTest(.{
        .root_source_file = b.path("src/browser_metrics.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_browser_metrics_tests = b.addRunArtifact(browser_metrics_tests);

    // Test step — unit tests for dsn_keys.zig
    const dsn_keys_tests = b.addTest(.{
        .root_source_file = b.path("src/dsn_keys.zig"),
        .target = target,
        .optimize = optimize,
    });
    dsn_keys_tests.root_module.addImport("sqlite", sqlite_mod);
    dsn_keys_tests.linkSystemLibrary("sqlite3");
    dsn_keys_tests.linkLibC();

    const run_dsn_keys_tests = b.addRunArtifact(dsn_keys_tests);

    // Test step — unit tests for source_maps.zig
    const source_maps_tests = b.addTest(.{
        .root_source_file = b.path("src/source_maps.zig"),
        .target = target,
        .optimize = optimize,
    });
    source_maps_tests.root_module.addImport("sqlite", sqlite_mod);
    source_maps_tests.linkSystemLibrary("sqlite3");
    source_maps_tests.linkLibC();

    const run_source_maps_tests = b.addRunArtifact(source_maps_tests);

    // Test step — unit tests for sourcemap.zig (deobfuscation module)
    const sourcemap_tests = b.addTest(.{
        .root_source_file = b.path("src/sourcemap.zig"),
        .target = target,
        .optimize = optimize,
    });
    sourcemap_tests.root_module.addImport("sqlite", sqlite_mod);
    sourcemap_tests.linkSystemLibrary("sqlite3");
    sourcemap_tests.linkLibC();

    const run_sourcemap_tests = b.addRunArtifact(sourcemap_tests);

    // Test step — unit tests for retention.zig
    const retention_tests = b.addTest(.{
        .root_source_file = b.path("src/retention.zig"),
        .target = target,
        .optimize = optimize,
    });
    retention_tests.root_module.addImport("sqlite", sqlite_mod);
    retention_tests.linkSystemLibrary("sqlite3");
    retention_tests.linkLibC();

    const run_retention_tests = b.addRunArtifact(retention_tests);

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
}
