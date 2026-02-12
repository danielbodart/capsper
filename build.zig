const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Build whisper.cpp via CMake (shared libs) ---
    const cmake_build_dir = "whisper.cpp/build-zig";

    const cmake_configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "whisper.cpp",
        "-B",
        cmake_build_dir,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=ON",
        "-DGGML_CUDA=ON",
        "-DWHISPER_BUILD_TESTS=OFF",
        "-DWHISPER_BUILD_EXAMPLES=OFF",
        "-DWHISPER_BUILD_SERVER=OFF",
    });

    const cmake_build = b.addSystemCommand(&.{
        "cmake",
        "--build",
        cmake_build_dir,
        "--config",
        "Release",
        "-j",
    });
    cmake_build.step.dependOn(&cmake_configure.step);

    // --- Zig executable ---
    const exe = b.addExecutable(.{
        .name = "whisper-dictate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Include paths for whisper.h and ggml.h
    exe.root_module.addIncludePath(b.path("whisper.cpp/include"));
    exe.root_module.addIncludePath(b.path("whisper.cpp/ggml/include"));

    // Library paths for shared libs built by CMake
    exe.root_module.addLibraryPath(b.path(cmake_build_dir ++ "/src"));
    exe.root_module.addLibraryPath(b.path(cmake_build_dir ++ "/ggml/src"));
    exe.root_module.addLibraryPath(b.path(cmake_build_dir ++ "/ggml/src/ggml-cpu"));
    exe.root_module.addLibraryPath(b.path(cmake_build_dir ++ "/ggml/src/ggml-cuda"));

    // Runtime library search paths (so the binary can find .so files)
    exe.root_module.addRPath(b.path(cmake_build_dir ++ "/src"));
    exe.root_module.addRPath(b.path(cmake_build_dir ++ "/ggml/src"));
    exe.root_module.addRPath(b.path(cmake_build_dir ++ "/ggml/src/ggml-cpu"));
    exe.root_module.addRPath(b.path(cmake_build_dir ++ "/ggml/src/ggml-cuda"));

    // Link whisper.cpp and its dependencies
    exe.linkSystemLibrary("whisper");
    exe.linkSystemLibrary("ggml");
    exe.linkSystemLibrary("ggml-base");
    exe.linkSystemLibrary("ggml-cpu");
    exe.linkSystemLibrary("ggml-cuda");

    // System dependencies
    exe.linkLibC();

    // Ensure CMake runs before Zig compilation
    exe.step.dependOn(&cmake_build.step);

    b.installArtifact(exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run whisper-dictate");
    run_step.dependOn(&run_cmd.step);

    // --- Test step (pure Zig modules only, no C deps) ---
    const test_step = b.step("test", "Run unit tests");

    const utils_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_utils_tests = b.addRunArtifact(utils_tests);
    test_step.dependOn(&run_utils_tests.step);

    const alignatt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/alignatt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_alignatt_tests = b.addRunArtifact(alignatt_tests);
    test_step.dependOn(&run_alignatt_tests.step);

    // --- Property tests (minish-based, runs as executable) ---
    const prop_step = b.step("prop-test", "Run property-based tests (minish)");

    const minish_dep = b.dependency("minish", .{
        .target = target,
        .optimize = optimize,
    });

    const prop_exe = b.addExecutable(.{
        .name = "prop-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prop_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minish", .module = minish_dep.module("minish") },
                .{ .name = "utils.zig", .module = b.createModule(.{
                    .root_source_file = b.path("src/utils.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "alignatt.zig", .module = b.createModule(.{
                    .root_source_file = b.path("src/alignatt.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });

    const run_prop = b.addRunArtifact(prop_exe);
    prop_step.dependOn(&run_prop.step);

    // Also include prop tests in the main test step
    test_step.dependOn(&run_prop.step);
}
