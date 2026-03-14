const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;

    // --- Build options ---
    const version_str = b.option([]const u8, "version", "Version string") orelse "0.0.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version_str);

    // --- Shared build config ---
    const ten_vad_flags: []const []const u8 = &.{};

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
    addWhisperIncludes(b, exe);
    addTenVad(b, exe, ten_vad_flags);
    addPlatformDeps(b, exe, is_macos);
    addWhisperLibs(b, exe, is_macos);
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
    addWhisperIncludes(b, vad_filter_test_exe);
    addTenVad(b, vad_filter_test_exe, ten_vad_flags);
    addLibPath(b, vad_filter_test_exe, is_macos);
    addWhisperLibsNoGpu(b, vad_filter_test_exe);
    vad_filter_test_exe.linkLibC();
    b.installArtifact(vad_filter_test_exe);

    // --- VAD compare test tool ---
    const vad_compare_exe = b.addExecutable(.{
        .name = "vad-compare-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vad_compare_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addWhisperIncludes(b, vad_compare_exe);
    addTenVad(b, vad_compare_exe, ten_vad_flags);
    addLibPath(b, vad_compare_exe, is_macos);
    addWhisperLibsNoGpu(b, vad_compare_exe);
    vad_compare_exe.linkLibC();
    b.installArtifact(vad_compare_exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run capsper");
    run_step.dependOn(&run_cmd.step);

    // --- Test step ---
    const test_step = b.step("test", "Run unit tests");

    // Pure Zig tests (no C deps, no platform deps)
    inline for (.{
        "src/utils.zig",
        "src/alignatt.zig",
        "src/mel.zig",
        "src/auto_gain.zig",
        "src/dsp.zig",
        "src/conv.zig",
    }) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // vad.zig tests — needs whisper linked
    const vad_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vad.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addWhisperIncludes(b, vad_tests);
    addTenVad(b, vad_tests, ten_vad_flags);
    addLibPath(b, vad_tests, is_macos);
    addWhisperLibsNoGpu(b, vad_tests);
    vad_tests.linkLibC();
    test_step.dependOn(&b.addRunArtifact(vad_tests).step);

    // input tests — platform-specific source file
    if (!is_macos) {
        // Linux: input.zig tests need libc for @cImport of linux/input-event-codes.h
        const input_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/input.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        input_tests.linkLibC();
        test_step.dependOn(&b.addRunArtifact(input_tests).step);
    }
    // TODO: macOS input tests once input_macos.zig has real implementation

    // pitch_est.zig tests — needs fftw.c + ten-vad includes + libc
    const pitch_est_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pitch_est.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addTenVad(b, pitch_est_tests, ten_vad_flags);
    pitch_est_tests.linkLibC();
    test_step.dependOn(&b.addRunArtifact(pitch_est_tests).step);

    // --- Property tests (minish-based, runs as executable) ---
    const prop_step = b.step("prop-test", "Run property-based tests (minish)");

    const minish_dep = b.dependency("minish", .{
        .target = target,
        .optimize = optimize,
    });

    const prop_imports: []const std.Build.Module.Import = if (is_macos)
        &.{
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
                .root_source_file = b.path("src/input_macos.zig"),
                .target = target,
                .optimize = optimize,
            }) },
            .{ .name = "dsp.zig", .module = b.createModule(.{
                .root_source_file = b.path("src/dsp.zig"),
                .target = target,
                .optimize = optimize,
            }) },
            .{ .name = "conv.zig", .module = b.createModule(.{
                .root_source_file = b.path("src/conv.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        }
    else
        &.{
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
            .{ .name = "dsp.zig", .module = b.createModule(.{
                .root_source_file = b.path("src/dsp.zig"),
                .target = target,
                .optimize = optimize,
            }) },
            .{ .name = "conv.zig", .module = b.createModule(.{
                .root_source_file = b.path("src/conv.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        };

    const prop_exe = b.addExecutable(.{
        .name = "prop-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prop_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = prop_imports,
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

    // --- Rebuild whisper.cpp shared libs (cmake → dist/lib/ or dist/lib-macos/) ---
    const rebuild_step = b.step("rebuild-libs", "Rebuild whisper.cpp shared libs");

    const cmake_build_dir = if (is_macos) ".zig-cache/cmake-macos" else ".zig-cache/cmake";
    const abs_dist_lib = b.pathJoin(&.{
        b.build_root.path orelse ".",
        if (is_macos) "dist/lib-macos" else "dist/lib",
    });

    const cmake_configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "whisper.cpp",
        "-B",
        cmake_build_dir,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=ON",
        "-DWHISPER_BUILD_TESTS=OFF",
        "-DWHISPER_BUILD_EXAMPLES=OFF",
        "-DWHISPER_BUILD_SERVER=OFF",
        "-DGGML_NATIVE=OFF",
    });
    cmake_configure.addArg(b.fmt("-DCMAKE_LIBRARY_OUTPUT_DIRECTORY={s}", .{abs_dist_lib}));
    cmake_configure.addArg("-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON");

    if (is_macos) {
        cmake_configure.addArg("-DGGML_METAL=ON");
        cmake_configure.addArg("-DGGML_METAL_EMBED_LIBRARY=ON");
        cmake_configure.addArg("-DCMAKE_INSTALL_RPATH=@loader_path");
    } else {
        cmake_configure.addArg("-DGGML_CUDA=ON");
        cmake_configure.addArg("-DCMAKE_CUDA_ARCHITECTURES=75-virtual;86-virtual;89-virtual;120a-virtual");
        cmake_configure.addArg("-DCMAKE_INSTALL_RPATH=$ORIGIN");
    }

    const cmake_build = b.addSystemCommand(&.{
        "cmake",
        "--build",
        cmake_build_dir,
        "--config",
        "Release",
        "--parallel",
    });

    if (!is_macos) {
        // Use a disk-backed temp dir for nvcc intermediate files.
        // Default /tmp is tmpfs (RAM-backed) and nvcc can fill 16GB+ during CUDA kernel compilation.
        const nvcc_tmp = b.fmt("{s}/{s}/tmp", .{ b.build_root.path orelse ".", cmake_build_dir });
        const mkdir_nvcc_tmp = b.addSystemCommand(&.{ "mkdir", "-p", nvcc_tmp });
        mkdir_nvcc_tmp.step.dependOn(&cmake_configure.step);
        cmake_build.setEnvironmentVariable("TMPDIR", nvcc_tmp);
        cmake_build.step.dependOn(&mkdir_nvcc_tmp.step);
    } else {
        cmake_build.step.dependOn(&cmake_configure.step);
    }

    rebuild_step.dependOn(&cmake_build.step);
}

// ─── Helper functions to reduce duplication ─────────────────────────────────

const Exe = std.Build.Step.Compile;

fn addWhisperIncludes(b: *std.Build, exe: *Exe) void {
    exe.root_module.addIncludePath(b.path("whisper.cpp/include"));
    exe.root_module.addIncludePath(b.path("whisper.cpp/ggml/include"));
}

fn addTenVad(b: *std.Build, exe: *Exe, flags: []const []const u8) void {
    exe.root_module.addIncludePath(b.path("ten-vad/src"));
    exe.root_module.addCSourceFile(.{ .file = b.path("ten-vad/src/fftw.c"), .flags = flags });
}

fn addLibPath(b: *std.Build, exe: *Exe, is_macos: bool) void {
    if (is_macos) {
        exe.root_module.addLibraryPath(b.path("dist/lib-macos"));
        exe.root_module.addRPathSpecial("@loader_path/../lib-macos");
    } else {
        exe.root_module.addLibraryPath(b.path("dist/lib"));
        exe.root_module.addRPathSpecial("$ORIGIN/../lib");
    }
}

fn addWhisperLibsNoGpu(_: *std.Build, exe: *Exe) void {
    exe.linkSystemLibrary("whisper");
    exe.linkSystemLibrary("ggml");
    exe.linkSystemLibrary("ggml-base");
    exe.linkSystemLibrary("ggml-cpu");
}

fn addWhisperLibs(b: *std.Build, exe: *Exe, is_macos: bool) void {
    addWhisperLibsNoGpu(b, exe);
    if (is_macos) {
        exe.linkSystemLibrary("ggml-metal");
        exe.linkSystemLibrary("ggml-blas");
    } else {
        exe.linkSystemLibrary("ggml-cuda");
    }
}

fn addPlatformDeps(b: *std.Build, exe: *Exe, is_macos: bool) void {
    addLibPath(b, exe, is_macos);
    exe.each_lib_rpath = false;

    if (is_macos) {
        exe.linkFramework("AudioToolbox");
        exe.linkFramework("CoreAudio");
        exe.linkFramework("CoreFoundation");
        exe.linkFramework("ApplicationServices");
        exe.linkFramework("AVFoundation");
        // Objective-C helper for microphone permission (AVCaptureDevice)
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/mic_permission_macos.m"),
            .flags = &.{"-fobjc-arc"},
        });
    } else {
        exe.linkSystemLibrary("libpipewire-0.3");
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/pw_helpers.c"),
            .flags = &.{
                "-I/usr/include/pipewire-0.3",
                "-I/usr/include/spa-0.2",
            },
        });
    }
}
