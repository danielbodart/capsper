const std = @import("std");

pub const Backend = enum { coreml, ort_cuda, ort_cpu };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;

    // --- Build options ---
    const version_str = b.option([]const u8, "version", "Version string") orelse "0.0.0";
    const default_backend: Backend = if (is_macos) .coreml else .ort_cuda;
    const backend = b.option(Backend, "backend", "ASR backend") orelse default_backend;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version_str);
    options.addOption(Backend, "backend", backend);

    // Where to find onnxruntime. Defaults to the copies vendored under dist/,
    // which is what the tarball build uses. A package manager that supplies its
    // own onnxruntime (Nix) points these at it instead -- the vendored copies
    // are Git LFS objects and are not present in a source tarball anyway.
    const ort_include = b.option([]const u8, "ort-include", "onnxruntime include directory");
    const ort_lib = b.option([]const u8, "ort-lib", "onnxruntime library directory");

    // Extra RPATH entries, repeatable. `each_lib_rpath` is deliberately off so
    // that a dist build does not bake the build machine's /usr/lib paths into
    // the released binary; a package manager that installs libraries at
    // absolute store paths passes them here instead of relying on that.
    const extra_rpaths = b.option([]const []const u8, "rpath", "Additional RPATH entry (repeatable)") orelse &.{};

    // --- Binary name ---
    const exe_name: []const u8 = switch (backend) {
        .coreml => "capsper",
        .ort_cuda => "capsper-cuda",
        .ort_cpu => "capsper-cpu",
    };

    // --- Zig executable ---
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    addBackendDeps(b, exe, backend, ort_include);
    addPlatformDeps(b, exe, is_macos, ort_lib);
    for (extra_rpaths) |dir| exe.root_module.addRPathSpecial(dir);
    exe.linkLibC();
    b.installArtifact(exe);

    // Install warmup file next to the binary (e.g. dist/macos/bin/jfk.wav)
    b.installFile("test/jfk.wav", "bin/jfk.wav");

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
        "src/shared/utils.zig",
        "src/shared/auto_gain.zig",
        "src/shared/nemo_mel.zig",
        "src/shared/tokenizer.zig",
        "src/shared/context_graph.zig",
        "src/shared/nemo_mel_state.zig",
        "src/shared/session.zig",
        "src/shared/config.zig",
        "src/shared/meeting.zig",
        "src/shared/webvtt.zig",
        "src/shared/session_server.zig",
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
                .root_source_file = b.path("src/platform/linux/input.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        input_tests.linkLibC();
        test_step.dependOn(&b.addRunArtifact(input_tests).step);
    }

    // --- Property tests (minish-based, runs as executable) ---
    const prop_step = b.step("prop-test", "Run property-based tests (minish)");

    // minish is the only external dependency and only the property tests use
    // it. `-Dprop-tests=false` drops it entirely, which is what lets a
    // sandboxed package build (Nix) produce the binary with no network access
    // at all -- marking it `.lazy` in build.zig.zon is not enough on its own,
    // because merely asking for the dependency here is what triggers a fetch.
    const prop_tests = b.option(bool, "prop-tests", "Build the minish property tests") orelse true;

    if (prop_tests) if (b.lazyDependency("minish", .{
        .target = target,
        .optimize = optimize,
    })) |minish_dep| {
        const prop_imports: []const std.Build.Module.Import = if (is_macos)
            &.{
                .{ .name = "minish", .module = minish_dep.module("minish") },
                .{ .name = "utils.zig", .module = b.createModule(.{
                    .root_source_file = b.path("src/shared/utils.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "input.zig", .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/macos/input.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            }
        else
            &.{
                .{ .name = "minish", .module = minish_dep.module("minish") },
                .{ .name = "utils.zig", .module = b.createModule(.{
                    .root_source_file = b.path("src/shared/utils.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
                .{ .name = "input.zig", .module = b.createModule(.{
                    .root_source_file = b.path("src/platform/linux/input.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }) },
            };

        const prop_exe = b.addExecutable(.{
            .name = "prop-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/shared/prop_tests.zig"),
                .target = target,
                .optimize = optimize,
                .imports = prop_imports,
            }),
        });

        const run_prop = b.addRunArtifact(prop_exe);
        prop_step.dependOn(&run_prop.step);

        // Also include prop tests in the main test step
        test_step.dependOn(&run_prop.step);
    };
}

// ─── Helper functions ────────────────────────────────────────────────────────

const Exe = std.Build.Step.Compile;

fn addLibPath(b: *std.Build, exe: *Exe, is_macos: bool, ort_lib: ?[]const u8) void {
    if (is_macos) return;

    if (ort_lib) |dir| {
        // An external onnxruntime (Nix) lives at an absolute path, so link
        // against it there and record it in the RPATH -- there is no
        // ../lib beside the binary to fall back on.
        exe.root_module.addLibraryPath(.{ .cwd_relative = dir });
        exe.root_module.addRPathSpecial(dir);
    } else {
        exe.root_module.addLibraryPath(b.path("dist/linux/lib"));
        exe.root_module.addRPathSpecial("$ORIGIN/../lib");
    }
}

fn addBackendDeps(b: *std.Build, exe: *Exe, backend: Backend, ort_include: ?[]const u8) void {
    switch (backend) {
        .coreml => {
            exe.linkFramework("CoreML");
            exe.linkFramework("Foundation");
            exe.root_module.addCSourceFile(.{
                .file = b.path("src/backend/coreml/helpers.m"),
                .flags = &.{"-fobjc-arc"},
            });
        },
        .ort_cuda, .ort_cpu => {
            if (ort_include) |dir| {
                exe.root_module.addIncludePath(.{ .cwd_relative = dir });
            } else {
                exe.root_module.addIncludePath(b.path("dist/linux/include/onnxruntime"));
            }
            // Not via pkg-config: onnxruntime's .pc file is named
            // `libonnxruntime`, so a pkg-config lookup for `onnxruntime`
            // misses it. The library directory is already on the search path.
            exe.linkSystemLibrary2("onnxruntime", .{ .use_pkg_config = .no });
        },
    }
}

fn addPlatformDeps(b: *std.Build, exe: *Exe, is_macos: bool, ort_lib: ?[]const u8) void {
    addLibPath(b, exe, is_macos, ort_lib);
    exe.each_lib_rpath = false;

    if (is_macos) {
        exe.linkFramework("AudioToolbox");
        exe.linkFramework("CoreAudio");
        exe.linkFramework("CoreFoundation");
        exe.linkFramework("ApplicationServices");
        exe.linkFramework("AVFoundation");
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/mic_permission.m"),
            .flags = &.{"-fobjc-arc"},
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos/input_helpers.c"),
            .flags = &.{},
        });
    } else {
        // pkg-config supplies both the link flags and the pipewire/spa include
        // directories, so pw_helpers.c needs no hardcoded -I of its own. (It
        // used to carry /usr/include paths, which are simply absent on distros
        // that do not use the FHS.)
        exe.linkSystemLibrary("libpipewire-0.3");
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/platform/linux/pw_helpers.c"),
            .flags = &.{},
        });
    }
}
