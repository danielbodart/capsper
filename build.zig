const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Build whisper.cpp via CMake (shared libs) ---
    const cmake_build_dir = "whisper.cpp/build-zig";

    // Auto-skip CMake if shared libs already exist (CUDA compilation is expensive).
    // Use -Dforce-cmake to rebuild, or run `./run.ts clean` to start fresh.
    const force_cmake = b.option(bool, "force-cmake", "Force CMake rebuild even if shared libs exist") orelse false;
    const libs_exist = if (std.fs.cwd().statFile(cmake_build_dir ++ "/ggml/src/ggml-cuda/libggml-cuda.so")) |_| true else |_| false;
    const run_cmake = force_cmake or !libs_exist;

    // Use a disk-backed temp dir for nvcc intermediate files.
    // Default /tmp is tmpfs (RAM-backed) and nvcc can fill 16GB+ during CUDA kernel compilation.
    const nvcc_tmp = b.fmt("{s}/{s}/tmp", .{ b.build_root.path orelse ".", cmake_build_dir });

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

    const mkdir_nvcc_tmp = b.addSystemCommand(&.{ "mkdir", "-p", nvcc_tmp });
    mkdir_nvcc_tmp.step.dependOn(&cmake_configure.step);

    const cmake_jobs = b.option([]const u8, "cmake-jobs", "Limit CMake build parallelism (e.g. '2')");
    const cmake_build = b.addSystemCommand(&.{
        "cmake",
        "--build",
        cmake_build_dir,
        "--config",
        "Release",
        "-j",
    });
    if (cmake_jobs) |jobs| cmake_build.addArg(jobs);
    cmake_build.setEnvironmentVariable("TMPDIR", nvcc_tmp);
    cmake_build.step.dependOn(&mkdir_nvcc_tmp.step);

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

    // PipeWire: pkg-config provides include paths for both pipewire-0.3 and spa-0.2
    exe.linkSystemLibrary("libpipewire-0.3");

    // C helper for PipeWire SPA format building (variadic macros that Zig can't handle)
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/pw_helpers.c"),
        .flags = &.{
            "-I/usr/include/pipewire-0.3",
            "-I/usr/include/spa-0.2",
        },
    });

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

    // Ensure CMake runs before Zig compilation (unless libs already built)
    if (run_cmake) {
        exe.step.dependOn(&cmake_build.step);
    }

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

    // input.zig tests need libc for @cImport of linux/input-event-codes.h
    const input_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/input.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    input_tests.linkLibC();
    const run_input_tests = b.addRunArtifact(input_tests);
    test_step.dependOn(&run_input_tests.step);

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
                .{ .name = "input.zig", .module = b.createModule(.{
                    .root_source_file = b.path("src/input.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }) },
            },
        }),
    });

    const run_prop = b.addRunArtifact(prop_exe);
    prop_step.dependOn(&run_prop.step);

    // Also include prop tests in the main test step
    test_step.dependOn(&run_prop.step);
}
