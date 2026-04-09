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

    const exe = b.addExecutable(.{ .name = "log-viewer", .root_module = exe_mod });

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

    // Test step — tests for log_level.zig
    const log_level_test_mod = b.createModule(.{
        .root_source_file = b.path("src/log_level.zig"),
        .target = target,
        .optimize = optimize,
    });

    const log_level_tests = b.addTest(.{ .root_module = log_level_test_mod });
    const run_log_level_tests = b.addRunArtifact(log_level_tests);

    // Test step — tests for ingestion.zig
    const ingestion_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ingestion.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    ingestion_test_mod.linkSystemLibrary("sqlite3", .{});
    ingestion_test_mod.link_libc = true;

    const ingestion_tests = b.addTest(.{ .root_module = ingestion_test_mod });
    const run_ingestion_tests = b.addRunArtifact(ingestion_tests);

    // Test step — tests for log_query.zig
    const log_query_test_mod = b.createModule(.{
        .root_source_file = b.path("src/log_query.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    log_query_test_mod.linkSystemLibrary("sqlite3", .{});
    log_query_test_mod.link_libc = true;

    const log_query_tests = b.addTest(.{ .root_module = log_query_test_mod });
    const run_log_query_tests = b.addRunArtifact(log_query_tests);

    // Test step — tests for sse_tail.zig
    const sse_tail_test_mod = b.createModule(.{
        .root_source_file = b.path("src/sse_tail.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
        },
    });
    sse_tail_test_mod.linkSystemLibrary("sqlite3", .{});
    sse_tail_test_mod.link_libc = true;

    const sse_tail_tests = b.addTest(.{ .root_module = sse_tail_test_mod });
    const run_sse_tail_tests = b.addRunArtifact(sse_tail_tests);

    // Test step — tests for web_ui.zig
    const web_ui_test_mod = b.createModule(.{
        .root_source_file = b.path("src/web_ui.zig"),
        .target = target,
        .optimize = optimize,
    });

    const web_ui_tests = b.addTest(.{ .root_module = web_ui_test_mod });
    const run_web_ui_tests = b.addRunArtifact(web_ui_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_log_level_tests.step);
    test_step.dependOn(&run_ingestion_tests.step);
    test_step.dependOn(&run_log_query_tests.step);
    test_step.dependOn(&run_sse_tail_tests.step);
    test_step.dependOn(&run_web_ui_tests.step);
}
