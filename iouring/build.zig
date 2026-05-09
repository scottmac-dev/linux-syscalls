const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Library module ---
    const lib_module = b.addModule("zuring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Fileserver example ---
    const fs_module = b.addModule("fileserver", .{
        .root_source_file = b.path("examples/fileserver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zuring", .module = lib_module },
        },
    });
    const fs_exe = b.addExecutable(.{
        .name = "fileserver",
        .root_module = fs_module,
    });
    b.installArtifact(fs_exe);

    // --- Run steps ---
    const run_fileserver = b.addRunArtifact(fs_exe);
    const fs_step = b.step("fileserver", "Run the fileserver example");
    fs_step.dependOn(&run_fileserver.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_fileserver.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_fileserver.addArgs(args);
    }

    // --- Tests ---
    const lib_tests = b.addTest(.{
        .root_module = lib_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
