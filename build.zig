const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Build options ---
    const version_str = b.option([]const u8, "version", "Version string") orelse "0.0.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version_str);

    // --- Zig executable ---
    const exe = b.addExecutable(.{
        .name = "capsper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);

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

    // TEN-VAD GGML reimplementation
    exe.root_module.addIncludePath(b.path("src"));
    const ten_vad_flags: []const []const u8 = &.{};
    exe.root_module.addCSourceFile(.{ .file = b.path("src/ten_vad_ggml.c"), .flags = ten_vad_flags });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/ten_vad_fft.c"), .flags = ten_vad_flags });

    // TEN-VAD native (prebuilt .so with pitch support)
    exe.root_module.addIncludePath(b.path("ten-vad/include"));
    exe.linkSystemLibrary("ten_vad");

    // Link from pre-built shared libs in dist/lib/ (committed via Git LFS)
    exe.root_module.addLibraryPath(b.path("dist/lib"));
    exe.root_module.addRPathSpecial("$ORIGIN/../lib");
    exe.each_lib_rpath = false;

    // Link whisper.cpp and its dependencies
    exe.linkSystemLibrary("whisper");
    exe.linkSystemLibrary("ggml");
    exe.linkSystemLibrary("ggml-base");
    exe.linkSystemLibrary("ggml-cpu");
    exe.linkSystemLibrary("ggml-cuda");

    // System dependencies
    exe.linkLibC();

    b.installArtifact(exe);

    // Install warmup file next to the binary (dist/bin/jfk.wav)
    b.installFile("test/jfk.wav", "bin/jfk.wav");

    // --- VAD filter test tool ---
    const vad_filter_test_exe = b.addExecutable(.{
        .name = "vad-filter-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vad_filter_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    vad_filter_test_exe.root_module.addIncludePath(b.path("whisper.cpp/include"));
    vad_filter_test_exe.root_module.addIncludePath(b.path("whisper.cpp/ggml/include"));
    vad_filter_test_exe.root_module.addIncludePath(b.path("src"));
    vad_filter_test_exe.root_module.addIncludePath(b.path("ten-vad/include"));
    vad_filter_test_exe.root_module.addLibraryPath(b.path("dist/lib"));
    vad_filter_test_exe.root_module.addRPathSpecial("$ORIGIN/../lib");
    vad_filter_test_exe.each_lib_rpath = false;
    vad_filter_test_exe.linkSystemLibrary("whisper");
    vad_filter_test_exe.linkSystemLibrary("ggml");
    vad_filter_test_exe.linkSystemLibrary("ggml-base");
    vad_filter_test_exe.linkSystemLibrary("ggml-cpu");
    vad_filter_test_exe.linkSystemLibrary("ten_vad");
    vad_filter_test_exe.root_module.addCSourceFile(.{ .file = b.path("src/ten_vad_ggml.c"), .flags = ten_vad_flags });
    vad_filter_test_exe.root_module.addCSourceFile(.{ .file = b.path("src/ten_vad_fft.c"), .flags = ten_vad_flags });
    vad_filter_test_exe.linkLibC();
    b.installArtifact(vad_filter_test_exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run capsper");
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

    const mel_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_mel_tests = b.addRunArtifact(mel_tests);
    test_step.dependOn(&run_mel_tests.step);

    const auto_gain_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/auto_gain.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_auto_gain_tests = b.addRunArtifact(auto_gain_tests);
    test_step.dependOn(&run_auto_gain_tests.step);

    // vad.zig tests need whisper linked (imports whisper_c.zig at compile time,
    // but unit tests only exercise processChunkProb which is pure Zig)
    const vad_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vad.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    vad_tests.root_module.addIncludePath(b.path("whisper.cpp/include"));
    vad_tests.root_module.addIncludePath(b.path("whisper.cpp/ggml/include"));
    vad_tests.root_module.addIncludePath(b.path("src"));
    vad_tests.root_module.addIncludePath(b.path("ten-vad/include"));
    vad_tests.root_module.addLibraryPath(b.path("dist/lib"));
    vad_tests.linkSystemLibrary("whisper");
    vad_tests.linkSystemLibrary("ggml");
    vad_tests.linkSystemLibrary("ggml-base");
    vad_tests.linkSystemLibrary("ggml-cpu");
    vad_tests.linkSystemLibrary("ten_vad");
    vad_tests.root_module.addCSourceFile(.{ .file = b.path("src/ten_vad_ggml.c"), .flags = ten_vad_flags });
    vad_tests.root_module.addCSourceFile(.{ .file = b.path("src/ten_vad_fft.c"), .flags = ten_vad_flags });
    vad_tests.linkLibC();
    const run_vad_tests = b.addRunArtifact(vad_tests);
    test_step.dependOn(&run_vad_tests.step);

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

    // --- Static analysis step (zwanzig) ---
    const analyze_step = b.step("analyze", "Run zwanzig static analyzer on src/");
    const zwanzig_dep = b.dependency("zwanzig", .{
        .target = target,
        .optimize = optimize,
    });
    const zwanzig_exe = zwanzig_dep.artifact("zwanzig");
    const zwanzig_run = b.addRunArtifact(zwanzig_exe);
    // Only run safety-relevant engines (skip style/lint warnings)
    zwanzig_run.addArgs(&.{ "--do", "store-violations-engine" });
    zwanzig_run.addArgs(&.{ "--do", "stack-escape-engine" });
    zwanzig_run.addArgs(&.{ "--do", "unreachable-code-engine" });
    zwanzig_run.addDirectoryArg(b.path("src"));
    analyze_step.dependOn(&zwanzig_run.step);

    // --- Rebuild whisper.cpp shared libs (cmake → dist/lib/) ---
    const rebuild_step = b.step("rebuild-libs", "Rebuild whisper.cpp shared libs into dist/lib/");

    const cmake_build_dir = ".zig-cache/cmake";
    const abs_dist_lib = b.pathJoin(&.{ b.build_root.path orelse ".", "dist/lib" });

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
        "-DCMAKE_CUDA_ARCHITECTURES=75-virtual;86-virtual;89-virtual;120a-virtual",
        "-DWHISPER_BUILD_TESTS=OFF",
        "-DWHISPER_BUILD_EXAMPLES=OFF",
        "-DWHISPER_BUILD_SERVER=OFF",
        "-DGGML_NATIVE=OFF",
    });
    cmake_configure.addArg(b.fmt("-DCMAKE_LIBRARY_OUTPUT_DIRECTORY={s}", .{abs_dist_lib}));
    // Ensure shared libs use $ORIGIN RPATH so they find each other when installed
    // anywhere, not just the build directory.
    cmake_configure.addArg("-DCMAKE_INSTALL_RPATH=$ORIGIN");
    cmake_configure.addArg("-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON");

    const mkdir_nvcc_tmp = b.addSystemCommand(&.{ "mkdir", "-p", nvcc_tmp });
    mkdir_nvcc_tmp.step.dependOn(&cmake_configure.step);

    const cmake_build = b.addSystemCommand(&.{
        "cmake",
        "--build",
        cmake_build_dir,
        "--config",
        "Release",
        "--parallel",
    });
    cmake_build.setEnvironmentVariable("TMPDIR", nvcc_tmp);
    cmake_build.step.dependOn(&mkdir_nvcc_tmp.step);

    rebuild_step.dependOn(&cmake_build.step);
}
