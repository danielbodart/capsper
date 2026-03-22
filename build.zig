const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;

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
    exe.root_module.addIncludePath(b.path("dist/include/onnxruntime"));
    exe.linkSystemLibrary("onnxruntime");
    addPlatformDeps(b, exe, is_macos);
    exe.linkLibC();
    b.installArtifact(exe);

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
        "src/auto_gain.zig",
        "src/nemo_mel.zig",
        "src/tokenizer.zig",
        "src/context_graph.zig",
        "src/nemo_mel_state.zig",
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
            .{ .name = "input.zig", .module = b.createModule(.{
                .root_source_file = b.path("src/input_macos.zig"),
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
            .{ .name = "input.zig", .module = b.createModule(.{
                .root_source_file = b.path("src/input.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
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
}

// ─── Helper functions ────────────────────────────────────────────────────────

const Exe = std.Build.Step.Compile;

fn addLibPath(b: *std.Build, exe: *Exe, is_macos: bool) void {
    if (is_macos) {
        exe.root_module.addLibraryPath(b.path("dist/lib-macos"));
        exe.root_module.addRPathSpecial("@loader_path/../lib");
    } else {
        exe.root_module.addLibraryPath(b.path("dist/lib"));
        exe.root_module.addRPathSpecial("$ORIGIN/../lib");
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
        // C helper for CGEventTap/CGEventPost keyboard input
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/input_helpers_macos.c"),
            .flags = &.{},
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
