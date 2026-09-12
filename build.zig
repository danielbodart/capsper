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

    // libopus is compiled from the vendored source and linked in statically,
    // so a released tarball gains no runtime dependency and dist gains no
    // second shared object. A package manager that already has libopus (Nix)
    // links its copy instead -- the same arrangement as onnxruntime above, and
    // it means the Nix build needs no git submodule.
    const system_opus = b.option(bool, "system-opus", "Link the system libopus instead of the vendored source") orelse false;

    // --- Settings documentation ---
    //
    // The prose describing each setting lives beside it, as its doc comment in
    // src/shared/config.zig. `@typeInfo` cannot see a doc comment, so this
    // parses the source and hands them back as data -- see
    // build/gen_config_docs.zig for why that is a parse and not a grep, and
    // src/shared/config_docs.zig for what reads the result.
    //
    // Built for the host rather than the target: it runs here, during the
    // build, and never ships.
    const config_docs = blk: {
        const gen = b.addExecutable(.{
            .name = "gen-config-docs",
            .root_module = b.createModule(.{
                .root_source_file = b.path("build/gen_config_docs.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        const run = b.addRunArtifact(gen);
        run.addFileArg(b.path("src/shared/config.zig"));
        break :blk run.addOutputFileArg("config_field_docs.zig");
    };

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
    exe.root_module.addAnonymousImport("config_field_docs", .{ .root_source_file = config_docs });
    addBackendDeps(b, exe, backend, ort_include);
    addOpus(b, exe, system_opus);
    addPlatformDeps(b, exe, is_macos, ort_lib);
    for (extra_rpaths) |dir| exe.root_module.addRPathSpecial(dir);
    exe.linkLibC();
    b.installArtifact(exe);

    // Install warmup file next to the binary (e.g. dist/macos/bin/jfk.wav)
    b.installFile("test/jfk.wav", "bin/jfk.wav");

    // The voice activity model, in the models directory beside the ASR one.
    // Two megabytes and fixed, so it ships in the tarball rather than being
    // downloaded on first run like the big one.
    b.installFile("models/silero_vad.onnx", "models/silero_vad.onnx");

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
        "src/shared/config_docs.zig",
        "src/shared/meeting.zig",
        "src/shared/webvtt.zig",
        "src/shared/session_server.zig",
        "src/shared/source.zig",
        "src/shared/vad.zig",
        "src/shared/recorder.zig",
    }) |src| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        // Only config_docs.zig imports it, but an unused import costs nothing
        // and singling one file out of the loop would cost a branch.
        t.root_module.addAnonymousImport("config_field_docs", .{ .root_source_file = config_docs });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // opus tests — need libopus's headers and the library itself, so they
    // cannot join the pure-Zig loop above.
    {
        const opus_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/shared/opus.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        addOpus(b, opus_tests, system_opus);
        opus_tests.linkLibC();
        test_step.dependOn(&b.addRunArtifact(opus_tests).step);
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

/// libopus, built from the vendored source and linked into the binary.
///
/// Static rather than a system library so a released tarball has no new
/// runtime dependency and dist gains no second shared object. It is plain
/// portable C with no generated headers, so there is nothing to configure --
/// the defines below are what `configure` would have produced.
///
/// The file list is upstream's own, from the `*_sources.mk` files in the
/// submodule. Regenerate after a version bump with:
///
///     sed -n '/= *\\/,/^$/p' vendor/libopus/*_sources.mk | grep -oP '^\K[A-Za-z0-9_/]+\.c'
///
/// Only the encoder's dependencies are here: the DNN extensions (deep PLC,
/// DRED, OSCE) are off by default upstream and nothing capsper does needs them.
fn addOpus(b: *std.Build, exe: *Exe, system: bool) void {
    if (system) {
        exe.linkSystemLibrary("opus");
        return;
    }

    exe.root_module.addIncludePath(b.path("vendor/libopus/include"));
    exe.root_module.addIncludePath(b.path("vendor/libopus/celt"));
    exe.root_module.addIncludePath(b.path("vendor/libopus/silk"));
    exe.root_module.addIncludePath(b.path("vendor/libopus/silk/float"));

    exe.root_module.addCSourceFiles(.{
        .root = b.path("vendor/libopus"),
        .files = &opus_sources,
        .flags = &.{
            "-DOPUS_BUILD",
            // C99 variable-length arrays rather than alloca: portable, and
            // upstream's own default when neither is forced.
            "-DVAR_ARRAYS",
            "-DHAVE_LRINT",
            "-DHAVE_LRINTF",
            // Only read by `opus_get_version_string`, which nothing calls.
            "-DPACKAGE_VERSION=\"1.6.1\"",
            "-std=c99",
        },
    });
}

const opus_sources = [_][]const u8{
    "celt/bands.c",
    "celt/celt.c",
    "celt/celt_decoder.c",
    "celt/celt_encoder.c",
    "celt/celt_lpc.c",
    "celt/celt_tx_tables.c",
    "celt/cwrs.c",
    "celt/entcode.c",
    "celt/entdec.c",
    "celt/entenc.c",
    "celt/kiss_fft.c",
    "celt/laplace.c",
    "celt/mathops.c",
    "celt/mdct.c",
    "celt/mdct_pfa.c",
    "celt/modes.c",
    "celt/pitch.c",
    "celt/quant_bands.c",
    "celt/rate.c",
    "celt/vq.c",
    "silk/A2NLSF.c",
    "silk/ana_filt_bank_1.c",
    "silk/biquad_alt.c",
    "silk/bwexpander_32.c",
    "silk/bwexpander.c",
    "silk/check_control_input.c",
    "silk/CNG.c",
    "silk/code_signs.c",
    "silk/control_audio_bandwidth.c",
    "silk/control_codec.c",
    "silk/control_SNR.c",
    "silk/debug.c",
    "silk/dec_API.c",
    "silk/decode_core.c",
    "silk/decode_frame.c",
    "silk/decode_indices.c",
    "silk/decode_parameters.c",
    "silk/decode_pitch.c",
    "silk/decode_pulses.c",
    "silk/decoder_set_fs.c",
    "silk/enc_API.c",
    "silk/encode_indices.c",
    "silk/encode_pulses.c",
    "silk/float/apply_sine_window_FLP.c",
    "silk/float/autocorrelation_FLP.c",
    "silk/float/burg_modified_FLP.c",
    "silk/float/bwexpander_FLP.c",
    "silk/float/corrMatrix_FLP.c",
    "silk/float/encode_frame_FLP.c",
    "silk/float/energy_FLP.c",
    "silk/float/find_LPC_FLP.c",
    "silk/float/find_LTP_FLP.c",
    "silk/float/find_pitch_lags_FLP.c",
    "silk/float/find_pred_coefs_FLP.c",
    "silk/float/inner_product_FLP.c",
    "silk/float/k2a_FLP.c",
    "silk/float/LPC_analysis_filter_FLP.c",
    "silk/float/LPC_inv_pred_gain_FLP.c",
    "silk/float/LTP_analysis_filter_FLP.c",
    "silk/float/LTP_scale_ctrl_FLP.c",
    "silk/float/noise_shape_analysis_FLP.c",
    "silk/float/pitch_analysis_core_FLP.c",
    "silk/float/process_gains_FLP.c",
    "silk/float/regularize_correlations_FLP.c",
    "silk/float/residual_energy_FLP.c",
    "silk/float/scale_copy_vector_FLP.c",
    "silk/float/scale_vector_FLP.c",
    "silk/float/schur_FLP.c",
    "silk/float/sort_FLP.c",
    "silk/float/warped_autocorrelation_FLP.c",
    "silk/float/wrappers_FLP.c",
    "silk/gain_quant.c",
    "silk/HP_variable_cutoff.c",
    "silk/init_decoder.c",
    "silk/init_encoder.c",
    "silk/inner_prod_aligned.c",
    "silk/interpolate.c",
    "silk/lin2log.c",
    "silk/log2lin.c",
    "silk/LPC_analysis_filter.c",
    "silk/LPC_fit.c",
    "silk/LPC_inv_pred_gain.c",
    "silk/LP_variable_cutoff.c",
    "silk/NLSF2A.c",
    "silk/NLSF_decode.c",
    "silk/NLSF_del_dec_quant.c",
    "silk/NLSF_encode.c",
    "silk/NLSF_stabilize.c",
    "silk/NLSF_unpack.c",
    "silk/NLSF_VQ.c",
    "silk/NLSF_VQ_weights_laroia.c",
    "silk/NSQ.c",
    "silk/NSQ_del_dec.c",
    "silk/pitch_est_tables.c",
    "silk/PLC.c",
    "silk/process_NLSFs.c",
    "silk/quant_LTP_gains.c",
    "silk/resampler.c",
    "silk/resampler_down2_3.c",
    "silk/resampler_down2.c",
    "silk/resampler_private_AR2.c",
    "silk/resampler_private_down_FIR.c",
    "silk/resampler_private_IIR_FIR.c",
    "silk/resampler_private_up2_HQ.c",
    "silk/resampler_rom.c",
    "silk/shell_coder.c",
    "silk/sigm_Q15.c",
    "silk/sort.c",
    "silk/stereo_decode_pred.c",
    "silk/stereo_encode_pred.c",
    "silk/stereo_find_predictor.c",
    "silk/stereo_LR_to_MS.c",
    "silk/stereo_MS_to_LR.c",
    "silk/stereo_quant_pred.c",
    "silk/sum_sqr_shift.c",
    "silk/table_LSF_cos.c",
    "silk/tables_gain.c",
    "silk/tables_LTP.c",
    "silk/tables_NLSF_CB_NB_MB.c",
    "silk/tables_NLSF_CB_WB.c",
    "silk/tables_other.c",
    "silk/tables_pitch_lag.c",
    "silk/tables_pulses_per_block.c",
    "silk/VAD.c",
    "silk/VQ_WMat_EC.c",
    "src/analysis.c",
    "src/extensions.c",
    "src/mapping_matrix.c",
    "src/mlp.c",
    "src/mlp_data.c",
    "src/opus.c",
    "src/opus_decoder.c",
    "src/opus_encoder.c",
    "src/opus_multistream.c",
    "src/opus_multistream_decoder.c",
    "src/opus_multistream_encoder.c",
    "src/opus_projection_decoder.c",
    "src/opus_projection_encoder.c",
    "src/repacketizer.c",
};
