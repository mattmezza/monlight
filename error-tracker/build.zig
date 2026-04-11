const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared modules from ../shared/
    const sqlite_mod = b.createModule(.{ .root_source_file = b.path("../shared/sqlite.zig") });
    const config_mod = b.createModule(.{ .root_source_file = b.path("../shared/config.zig") });
    const auth_mod = b.createModule(.{ .root_source_file = b.path("../shared/auth.zig") });
    const rate_limit_mod = b.createModule(.{ .root_source_file = b.path("../shared/rate_limit.zig") });

    const all_imports: []const std.Build.Module.Import = &.{
        .{ .name = "sqlite", .module = sqlite_mod },
        .{ .name = "config", .module = config_mod },
        .{ .name = "auth", .module = auth_mod },
        .{ .name = "rate_limit", .module = rate_limit_mod },
    };
    const sqlite_import: []const std.Build.Module.Import = &.{
        .{ .name = "sqlite", .module = sqlite_mod },
    };
    const config_import: []const std.Build.Module.Import = &.{
        .{ .name = "config", .module = config_mod },
    };

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = all_imports,
    });
    exe_mod.linkSystemLibrary("sqlite3", .{});
    exe_mod.link_libc = true;

    const exe = b.addExecutable(.{ .name = "error-tracker", .root_module = exe_mod });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the error tracker server");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run all unit tests");

    const TestDef = struct { path: []const u8, imports: []const std.Build.Module.Import, sqlite: bool };
    const tests = [_]TestDef{
        .{ .path = "src/main.zig", .imports = all_imports, .sqlite = true },
        .{ .path = "src/database.zig", .imports = sqlite_import, .sqlite = true },
        .{ .path = "src/config.zig", .imports = config_import, .sqlite = false },
        .{ .path = "../shared/sqlite.zig", .imports = &.{}, .sqlite = true },
        .{ .path = "../shared/config.zig", .imports = &.{}, .sqlite = false },
        .{ .path = "../shared/auth.zig", .imports = &.{}, .sqlite = false },
        .{ .path = "../shared/rate_limit.zig", .imports = &.{}, .sqlite = false },
        .{ .path = "src/auth_test.zig", .imports = all_imports, .sqlite = true },
        .{ .path = "src/rate_limit_test.zig", .imports = all_imports, .sqlite = true },
        .{ .path = "src/fingerprint.zig", .imports = &.{}, .sqlite = false },
        .{ .path = "src/error_ingestion.zig", .imports = sqlite_import, .sqlite = true },
        .{ .path = "src/error_listing.zig", .imports = sqlite_import, .sqlite = true },
        .{ .path = "src/error_detail.zig", .imports = sqlite_import, .sqlite = true },
        .{ .path = "src/error_resolve.zig", .imports = sqlite_import, .sqlite = true },
        .{ .path = "src/projects_listing.zig", .imports = sqlite_import, .sqlite = true },
        .{ .path = "src/retention.zig", .imports = sqlite_import, .sqlite = true },
        .{ .path = "src/web_ui.zig", .imports = &.{}, .sqlite = false },
        .{ .path = "src/email_template.zig", .imports = &.{}, .sqlite = false },
    };

    for (tests) |t| {
        const mod = b.createModule(.{
            .root_source_file = b.path(t.path),
            .target = target,
            .optimize = optimize,
            .imports = t.imports,
        });
        if (t.sqlite) {
            mod.linkSystemLibrary("sqlite3", .{});
            mod.link_libc = true;
        }
        const run = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
        test_step.dependOn(&run.step);
    }
}
