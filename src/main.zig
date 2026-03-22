const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const ort_c = @import("ort_c.zig");
const nemo_mel = @import("nemo_mel.zig");
const nemotron_tokenizer = @import("tokenizer.zig");
const ContextGraph = @import("context_graph.zig").ContextGraph;
const asr_mod = @import("asr_backend.zig");
const AsrConfig = asr_mod.AsrConfig;
const AsrPipeline = asr_mod.AsrPipeline;
const server_mod = @import("server.zig");
const Server = server_mod.Server;
const InputMode = server_mod.InputMode;
const TypeCallback = server_mod.TypeCallback;
const AudioCapture = @import("audio_capture_platform.zig").AudioCapture;
const input_mod = @import("input_platform.zig");
const InputHandler = input_mod.InputHandler;
const utils = @import("utils.zig");
const audio_detect = @import("audio_detect_platform.zig");
const Recorder = @import("recorder.zig").Recorder;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var model_path: [:0]const u8 = "../models/nemotron";
    var model_path_is_default = true;
    var port: u16 = 43007;
    var input_mode: InputMode = .tcp;
    var pw_target: ?[:0]const u8 = null;
    var audio_channel: u32 = AudioCapture.default_channel;
    var verbose: bool = false;
    var trigger_key: ?u16 = null;
    var trigger_passthrough: bool = false;
    var type_delay_us: u64 = 12_000; // 12ms
    var dry_run: bool = false;
    var do_pw_detect: bool = false;
    var detect_duration: u32 = 5;
    var drop_terms_path: ?[:0]const u8 = null;
    var record_dir: ?[:0]const u8 = null;
    var record_keep: usize = 10;
    var stream_wav_file: ?[:0]const u8 = null;
    var transcribe_file: ?[:0]const u8 = null;
    var low_latency: bool = false;
    var pw_gain: f32 = 1.0;
    var no_auto_gain: bool = false;
    var no_cuda: bool = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("capsper {s}\n", .{build_options.version});
            return;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i < args.len) {
                model_path = args[i];
                model_path_is_default = false;
            }
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) port = std.fmt.parseInt(u16, args[i], 10) catch |err| blk: {
                std.log.warn("invalid --port value '{s}': {}, using default {d}", .{ args[i], err, 43007 });
                break :blk 43007;
            };
        } else if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "tcp")) {
                    input_mode = .tcp;
                } else if (std.mem.eql(u8, args[i], "local")) {
                    input_mode = .local;
                } else {
                    std.debug.print("Invalid --input value '{s}', expected 'tcp' or 'local'\n", .{args[i]});
                    return;
                }
            }
        } else if (std.mem.eql(u8, arg, "--pw-target")) {
            i += 1;
            if (i < args.len) pw_target = args[i];
        } else if (std.mem.eql(u8, arg, "--pw-channel") or std.mem.eql(u8, arg, "--audio-channel")) {
            i += 1;
            if (i < args.len) {
                audio_channel = AudioCapture.parseChannelName(args[i]) orelse {
                    std.debug.print("Invalid channel value '{s}'\n", .{args[i]});
                    std.debug.print("Expected: MONO, FL, FR, AUX0-AUX63\n", .{});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--trigger")) {
            i += 1;
            if (i < args.len) {
                trigger_key = input_mod.parseTriggerKey(args[i]) orelse {
                    std.debug.print("Unknown trigger key '{s}'\n", .{args[i]});
                    std.debug.print("Supported: capslock, f24, scrolllock, numlock, pause, f13-f20\n", .{});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--trigger-passthrough")) {
            trigger_passthrough = true;
        } else if (std.mem.eql(u8, arg, "--type-delay")) {
            i += 1;
            if (i < args.len) type_delay_us = std.fmt.parseInt(u64, args[i], 10) catch 12_000;
        } else if (std.mem.eql(u8, arg, "--pw-detect")) {
            do_pw_detect = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--detect-duration")) {
            i += 1;
            if (i < args.len) detect_duration = std.fmt.parseInt(u32, args[i], 10) catch 5;
        } else if (std.mem.eql(u8, arg, "--domain-terms")) {
            // Deprecated: accept and skip for backwards compatibility with existing service files.
            i += 1;
            std.debug.print("Warning: --domain-terms is no longer supported and will be ignored\n", .{});
        } else if (std.mem.eql(u8, arg, "--warmup-file")) {
            // Deprecated: Nemotron doesn't need warmup. Accept and skip for backwards compatibility.
            i += 1;
            std.debug.print("Warning: --warmup-file is no longer supported and will be ignored\n", .{});
        } else if (std.mem.eql(u8, arg, "--no-warmup")) {
            // Deprecated: no-op (warmup was removed).
        } else if (std.mem.eql(u8, arg, "--drop-terms")) {
            i += 1;
            if (i < args.len) drop_terms_path = args[i];
        } else if (std.mem.eql(u8, arg, "--record-dir")) {
            i += 1;
            if (i < args.len) record_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--record-keep")) {
            i += 1;
            if (i < args.len) record_keep = std.fmt.parseInt(usize, args[i], 10) catch 10;
        } else if (std.mem.eql(u8, arg, "--stream-wav")) {
            i += 1;
            if (i < args.len) stream_wav_file = args[i];
        } else if (std.mem.eql(u8, arg, "--transcribe")) {
            i += 1;
            if (i < args.len) transcribe_file = args[i];
        } else if (std.mem.eql(u8, arg, "--pw-gain")) {
            i += 1;
            if (i < args.len) pw_gain = std.fmt.parseFloat(f32, args[i]) catch 1.0;
        } else if (std.mem.eql(u8, arg, "--low-latency")) {
            low_latency = true;
        } else if (std.mem.eql(u8, arg, "--no-auto-gain")) {
            no_auto_gain = true;
        } else if (std.mem.eql(u8, arg, "--no-cuda")) {
            no_cuda = true;
        } else {
            printUsage();
            return;
        }
    }

    // No arguments: show usage
    if (args.len == 1) {
        printUsage();
        return;
    }

    // PipeWire utility commands (early exit, no model loading needed)
    if (do_pw_detect) {
        audio_detect.detectChannel(allocator, pw_target, detect_duration);
        return;
    }

    // --trigger implies --input local (PipeWire capture) and starts not-live (trigger key controls recording)
    if (trigger_key != null) {
        input_mode = .local;
    }

    // Resolve exe-relative paths (default paths are relative to the binary location)
    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
    defer if (exe_dir) |d| allocator.free(d);

    const resolved_model_path: [:0]const u8 = blk: {
        if (!model_path_is_default or std.fs.path.isAbsolute(model_path)) break :blk model_path;
        if (exe_dir) |d| {
            break :blk std.fs.path.joinZ(allocator, &.{ d, model_path }) catch break :blk model_path;
        }
        break :blk model_path;
    };
    defer if (resolved_model_path.ptr != model_path.ptr) allocator.free(resolved_model_path);

    // Load Nemotron model
    std.debug.print("Loading Nemotron model from: {s}\n", .{resolved_model_path});

    // --- Platform-specific model loading ---
    const is_macos = builtin.os.tag == .macos;

    // CoreML models (macOS only)
    const coreml = if (is_macos) @import("pipeline_coreml.zig") else struct {
        const CapsperCoreMLModels = opaque {};
    };
    const coreml_models: ?*coreml.CapsperCoreMLModels = if (is_macos) blk: {
        const capsper_coreml_load = @extern(*const fn ([*:0]const u8) callconv(.c) ?*coreml.CapsperCoreMLModels, .{ .name = "capsper_coreml_load" });
        const coreml_path = std.fs.path.joinZ(allocator, &.{ resolved_model_path, "../nemotron-coreml" }) catch {
            std.debug.print("Failed to build CoreML model path\n", .{});
            return;
        };
        defer allocator.free(coreml_path);
        const models = capsper_coreml_load(coreml_path.ptr);
        if (models == null) {
            std.debug.print("Failed to load CoreML models\n", .{});
            return;
        }
        std.debug.print("Nemotron: using CoreML (ANE + CPU)\n", .{});
        break :blk models;
    } else null;
    defer if (is_macos) {
        if (coreml_models) |m| {
            const capsper_coreml_release = @extern(*const fn (?*coreml.CapsperCoreMLModels) callconv(.c) void, .{ .name = "capsper_coreml_release" });
            capsper_coreml_release(m);
        }
    };

    // ONNX sessions (Linux only)
    const api = if (!is_macos) ort_c.getApi() else undefined;
    var nemo_env: ?*ort_c.OrtEnv = null;
    var nemo_enc_session: ?*ort_c.OrtSession = null;
    var nemo_dec_session: ?*ort_c.OrtSession = null;
    var nemo_mem_info: ?*ort_c.OrtMemoryInfo = null;
    var session_opts: ?*ort_c.OrtSessionOptions = null;

    if (!is_macos) {
        try ort_c.check(api, api.CreateEnv.?(ort_c.ORT_LOGGING_LEVEL_WARNING, "nemotron", @ptrCast(&nemo_env)));
        try ort_c.check(api, api.CreateSessionOptions.?(&session_opts));

        if (no_cuda) {
            std.debug.print("Nemotron: using CPU (--no-cuda)\n", .{});
        } else {
            var cuda_opts: ort_c.OrtCUDAProviderOptions = std.mem.zeroes(ort_c.OrtCUDAProviderOptions);
            const cuda_status = api.SessionOptionsAppendExecutionProvider_CUDA.?(session_opts.?, &cuda_opts);
            if (cuda_status) |s| {
                api.ReleaseStatus.?(s);
                std.debug.print("Nemotron: using CPU\n", .{});
            } else {
                std.debug.print("Nemotron: using CUDA\n", .{});
            }
        }

        const enc_path = std.fs.path.joinZ(allocator, &.{ resolved_model_path, "encoder_model.onnx" }) catch {
            std.debug.print("Failed to build encoder model path\n", .{});
            return;
        };
        defer allocator.free(enc_path);
        try ort_c.check(api, api.CreateSession.?(nemo_env.?, enc_path.ptr, session_opts.?, @ptrCast(&nemo_enc_session)));

        const dec_path = std.fs.path.joinZ(allocator, &.{ resolved_model_path, "decoder_model.onnx" }) catch {
            std.debug.print("Failed to build decoder model path\n", .{});
            return;
        };
        defer allocator.free(dec_path);
        try ort_c.check(api, api.CreateSession.?(nemo_env.?, dec_path.ptr, session_opts.?, @ptrCast(&nemo_dec_session)));

        try ort_c.check(api, api.CreateCpuMemoryInfo.?(0, 0, @ptrCast(&nemo_mem_info)));
    }
    defer if (!is_macos) {
        if (session_opts) |s| api.ReleaseSessionOptions.?(s);
        if (nemo_dec_session) |s| api.ReleaseSession.?(s);
        if (nemo_enc_session) |s| api.ReleaseSession.?(s);
        if (nemo_mem_info) |m| api.ReleaseMemoryInfo.?(m);
        if (nemo_env) |e| api.ReleaseEnv.?(e);
    };

    // Load filterbank
    const fb_path = std.fs.path.joinZ(allocator, &.{ resolved_model_path, "filterbank.bin" }) catch {
        std.debug.print("Failed to build filterbank path\n", .{});
        return;
    };
    defer allocator.free(fb_path);
    const nemo_filterbank = nemo_mel.loadFilterbank(allocator, fb_path) catch |err| {
        std.debug.print("Failed to load filterbank: {}\n", .{err});
        return;
    };

    // Load token map
    const tok_path = std.fs.path.joinZ(allocator, &.{ resolved_model_path, "tokens.txt" }) catch {
        std.debug.print("Failed to build tokens path\n", .{});
        return;
    };
    defer allocator.free(tok_path);
    const tok_file = std.fs.cwd().openFile(tok_path, .{}) catch |err| {
        std.debug.print("Failed to open tokens.txt: {}\n", .{err});
        return;
    };
    defer tok_file.close();
    const nemo_tokens_data = tok_file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read tokens.txt: {}\n", .{err});
        return;
    };
    defer allocator.free(nemo_tokens_data);
    var nemo_token_map = nemotron_tokenizer.loadTokenMap(nemo_tokens_data);

    std.debug.print("Nemotron model loaded successfully\n", .{});
    defer {
        // filterbank: reinterpreted from u8, free the u8 allocation
        allocator.free(@as([*]u8, @ptrCast(@constCast(nemo_filterbank.ptr)))[0 .. nemo_filterbank.len * @sizeOf(f32)]);
    }

    // Read drop terms file (newline-separated, one term per line)
    var drop_terms: []const []const u8 = &.{};
    if (drop_terms_path) |dpath| {
        const dt_file = std.fs.cwd().openFile(dpath, .{}) catch |err| {
            std.debug.print("Failed to open drop terms file '{s}': {}\n", .{ dpath, err });
            return;
        };
        defer dt_file.close();

        const dt_raw = dt_file.readToEndAlloc(allocator, 8192) catch |err| {
            std.debug.print("Failed to read drop terms file: {}\n", .{err});
            return;
        };
        defer allocator.free(dt_raw);

        var terms_list = std.ArrayListUnmanaged([]const u8){};
        var lines = std.mem.splitScalar(u8, dt_raw, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const duped = try allocator.dupe(u8, trimmed);
            try terms_list.append(allocator, duped);
        }
        drop_terms = try terms_list.toOwnedSlice(allocator);
        std.debug.print("Drop terms: {d} terms from {s}\n", .{ drop_terms.len, dpath });
    }
    defer {
        for (drop_terms) |term| allocator.free(term);
        if (drop_terms.len > 0) allocator.free(drop_terms);
    }

    // Build context graph for drop terms (filler suppression via negative bias)
    var nemo_context_graph: ?*ContextGraph = null;
    if (drop_terms.len > 0) {
        var bias_scores = std.ArrayListUnmanaged(f32){};
        defer bias_scores.deinit(allocator);
        for (0..drop_terms.len) |_| {
            try bias_scores.append(allocator, -4.0);
        }

        const cg = try allocator.create(ContextGraph);
        cg.* = try ContextGraph.init(
            allocator,
            &nemo_token_map,
            drop_terms,
            bias_scores.items,
            4.0, // context_score (base penalty magnitude)
            2.0, // depth_scaling (TurboBias recommended for RNNT)
            verbose,
        );
        nemo_context_graph = cg;
        std.debug.print("Context graph: {d} suppression phrases\n", .{drop_terms.len});
    }

    const asr_config: AsrConfig = if (is_macos) .{
        .models = coreml_models orelse {
            std.debug.print("Error: CoreML models failed to load\n", .{});
            return;
        },
        .filterbank = nemo_filterbank,
        .token_map = &nemo_token_map,
        .context_graph = nemo_context_graph,
    } else .{
        .api = api,
        .enc_session = nemo_enc_session orelse {
            std.debug.print("Error: nemotron encoder session failed to load\n", .{});
            return;
        },
        .dec_session = nemo_dec_session orelse {
            std.debug.print("Error: nemotron decoder session failed to load\n", .{});
            return;
        },
        .mem_info = nemo_mem_info orelse {
            std.debug.print("Error: nemotron memory info failed\n", .{});
            return;
        },
        .filterbank = nemo_filterbank,
        .token_map = &nemo_token_map,
        .context_graph = nemo_context_graph,
    };

    // --stream-wav: feed WAV through the streaming pipeline (no PTT, no VAD)
    if (stream_wav_file) |swf| {
        const file = std.fs.cwd().openFile(swf, .{}) catch |err| {
            std.debug.print("Failed to open WAV file '{s}': {}\n", .{ swf, err });
            return;
        };

        // Seek past standard 44-byte WAV header to the PCM data.
        file.seekTo(44) catch |err| {
            std.debug.print("Failed to seek in WAV file '{s}': {}\n", .{ swf, err });
            file.close();
            return;
        };

        var server2 = Server.init(allocator, asr_config, 0, .tcp, null, 0, verbose, false, null, drop_terms, null, 1.0, true);
        server_mod.is_live.store(true, .monotonic);
        server2.handleConnection(file.handle, 1, null) catch |err| {
            std.debug.print("Stream error: {}\n", .{err});
        };
        file.close();
        return;
    }

    // --transcribe: feed WAV through the streaming pipeline, output plain text
    if (transcribe_file) |tfile| {
        const file = std.fs.cwd().openFile(tfile, .{}) catch |err| {
            std.debug.print("Failed to open WAV file '{s}': {}\n", .{ tfile, err });
            return;
        };
        defer file.close();

        const data = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch |err| {
            std.debug.print("Failed to read WAV file: {}\n", .{err});
            return;
        };
        defer allocator.free(data);

        const header = utils.parseWavHeader(data) catch |err| {
            std.debug.print("Failed to parse WAV header: {}\n", .{err});
            return;
        };
        const samples = utils.wavToFloat(allocator, data, header) catch |err| {
            std.debug.print("Failed to convert WAV to float: {}\n", .{err});
            return;
        };
        defer allocator.free(samples);

        var pipeline = AsrPipeline.init(allocator, asr_config, verbose) catch |err| {
            std.debug.print("Failed to create pipeline: {}\n", .{err});
            return;
        };
        defer pipeline.deinit();

        if (pipeline.transcribe(samples, true, null) catch |err| {
            std.debug.print("Transcription failed: {}\n", .{err});
            return;
        }) |result| {
            defer allocator.free(result.text);
            defer allocator.free(result.words);
            defer allocator.free(result.tokens);
            defer allocator.free(result.token_frames);
            _ = std.posix.write(1, result.text) catch {};
            _ = std.posix.write(1, "\n") catch {};
        }
        return;
    }

    // Initialize input handler (if --trigger specified, skip in dry-run)
    var input_handler: ?InputHandler = null;
    var type_callback: ?TypeCallback = null;

    if (!dry_run) {
        if (trigger_key) |tkey| {
            std.debug.print("Initializing input handler (trigger=keycode {d})\n", .{tkey});
            input_handler = InputHandler.init(.{
                .trigger_key = tkey,
                .trigger_passthrough = trigger_passthrough,
                .type_delay_us = type_delay_us,
                .live_fn = &server_mod.setLive,
            }) catch |err| {
                std.debug.print("Failed to init input handler: {}\n", .{err});
                if (builtin.os.tag == .macos) {
                    std.debug.print("Check: is Accessibility permission granted in System Settings?\n", .{});
                } else {
                    std.debug.print("Check: is user in 'input' group? Is /dev/uinput accessible?\n", .{});
                }
                return;
            };
            type_callback = .{
                .context = @ptrCast(&input_handler.?),
                .func = &InputHandler.typeTextCallback,
            };
        }

        // With trigger key: start not-live (trigger press goes live)
        // Without trigger key in local mode: start live (always on)
        if (trigger_key != null) {
            server_mod.setLive(false);
        } else if (input_mode == .local) {
            server_mod.setLive(true);
        }
    }
    defer {
        if (input_handler != null) input_handler.?.deinit();
    }

    if (dry_run) {
        std.debug.print("Dry run complete\n", .{});
        return;
    }

    // Create recorder if --record-dir specified
    var recorder_storage: Recorder = undefined;
    var recorder: ?*Recorder = null;
    if (record_dir) |rdir| {
        recorder_storage = Recorder.init(allocator, rdir, record_keep, build_options.version) catch |err| {
            std.debug.print("Failed to open record directory '{s}': {}\n", .{ rdir, err });
            return;
        };
        recorder = &recorder_storage;
    }
    defer if (recorder) |rec| rec.deinit();

    // Start input handler thread (after warmup, before server)
    if (input_handler != null) {
        try input_handler.?.start();
    }

    // Start server
    var server = Server.init(allocator, asr_config, port, input_mode, pw_target, audio_channel, verbose, low_latency, type_callback, drop_terms, recorder, pw_gain, no_auto_gain);
    try server.run();
}

fn printUsage() void {
    std.debug.print("Usage: capsper [--model PATH] [--port PORT]\n", .{});
    std.debug.print("       [--verbose|-v] [--no-cuda]\n", .{});
    std.debug.print("       [--input tcp|local] [--pw-target NODE] [--pw-channel CHANNEL]\n", .{});
    std.debug.print("       [--trigger KEY] [--trigger-passthrough] [--type-delay MICROSECONDS]\n", .{});
    std.debug.print("       [--drop-terms FILE]\n", .{});
    std.debug.print("       [--record-dir DIR [--record-keep N]]\n", .{});
    std.debug.print("       [--transcribe FILE] [--stream-wav FILE]\n", .{});
    std.debug.print("       [--pw-gain FACTOR] [--no-auto-gain] [--low-latency]\n", .{});
    std.debug.print("       [--pw-detect [--detect-duration SECS]]\n", .{});
    std.debug.print("       [--dry-run] [--version]\n", .{});
}
