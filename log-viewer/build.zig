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
        .name = "log-viewer",
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
    const run_step = b.step("run", "Run the log viewer server");
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

    // Test step — tests for config.zig
    const config_tests = b.addTest(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_tests.root_module.addImport("config", config_mod);

    const run_config_tests = b.addRunArtifact(config_tests);

    // Test step — tests for log_level.zig
    const log_level_tests = b.addTest(.{
        .root_source_file = b.path("src/log_level.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_log_level_tests = b.addRunArtifact(log_level_tests);

    // Test step — tests for ingestion.zig
    const ingestion_tests = b.addTest(.{
        .root_source_file = b.path("src/ingestion.zig"),
        .target = target,
        .optimize = optimize,
    });
    ingestion_tests.root_module.addImport("sqlite", sqlite_mod);
    ingestion_tests.linkSystemLibrary("sqlite3");
    ingestion_tests.linkLibC();

    const run_ingestion_tests = b.addRunArtifact(ingestion_tests);

    // Test step — tests for log_query.zig
    const log_query_tests = b.addTest(.{
        .root_source_file = b.path("src/log_query.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_query_tests.root_module.addImport("sqlite", sqlite_mod);
    log_query_tests.linkSystemLibrary("sqlite3");
    log_query_tests.linkLibC();

    const run_log_query_tests = b.addRunArtifact(log_query_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_log_level_tests.step);
    test_step.dependOn(&run_ingestion_tests.step);
    test_step.dependOn(&run_log_query_tests.step);
}
