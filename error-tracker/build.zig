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

    const exe = b.addExecutable(.{
        .name = "error-tracker",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add shared modules
    exe.root_module.addImport("sqlite", sqlite_mod);
    exe.root_module.addImport("config", config_mod);
    exe.root_module.addImport("auth", auth_mod);

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
    const run_step = b.step("run", "Run the error tracker server");
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

    // Test step — tests for shared sqlite module
    const sqlite_tests = b.addTest(.{
        .root_source_file = b.path("../shared/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_tests.linkSystemLibrary("sqlite3");
    sqlite_tests.linkLibC();

    const run_sqlite_tests = b.addRunArtifact(sqlite_tests);

    // Test step — tests for shared config module
    const shared_config_tests = b.addTest(.{
        .root_source_file = b.path("../shared/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_shared_config_tests = b.addRunArtifact(shared_config_tests);

    // Test step — tests for shared auth module
    const auth_tests = b.addTest(.{
        .root_source_file = b.path("../shared/auth.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_auth_tests = b.addRunArtifact(auth_tests);

    // Test step — integration tests for auth (auth_test.zig)
    const auth_integration_tests = b.addTest(.{
        .root_source_file = b.path("src/auth_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    auth_integration_tests.root_module.addImport("sqlite", sqlite_mod);
    auth_integration_tests.root_module.addImport("config", config_mod);
    auth_integration_tests.root_module.addImport("auth", auth_mod);
    auth_integration_tests.linkSystemLibrary("sqlite3");
    auth_integration_tests.linkLibC();

    const run_auth_integration_tests = b.addRunArtifact(auth_integration_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_sqlite_tests.step);
    test_step.dependOn(&run_shared_config_tests.step);
    test_step.dependOn(&run_auth_tests.step);
    test_step.dependOn(&run_auth_integration_tests.step);
}
