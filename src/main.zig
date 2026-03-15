const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const c = @import("whisper_c.zig");
const vad_mod = @import("vad.zig");
const SileroVad = vad_mod.SileroVad;
const TenVadGgml = vad_mod.TenVadGgml;
const TenVadNative = vad_mod.TenVadNative;
const VadBackend = vad_mod.VadBackend;
const VadFilter = vad_mod.VadFilter;
const Pipeline = @import("pipeline.zig").Pipeline;
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

    var model_path: [:0]const u8 = "../models/ggml-large-v3-turbo-q5_0.bin";
    var model_path_is_default = true;
    const VadChoice = enum { ten, silero, ten_native };
    var vad_choice: VadChoice = .silero;
    var port: u16 = 43007;
    var warmup_file: ?[:0]const u8 = "jfk.wav";
    var warmup_file_is_default = true;
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
    var domain_terms_path: ?[:0]const u8 = null;
    var drop_terms_path: ?[:0]const u8 = null;
    var record_dir: ?[:0]const u8 = null;
    var record_keep: usize = 10;
    var transcribe_file: ?[:0]const u8 = null;
    var stream_wav_file: ?[:0]const u8 = null;
    var low_latency: bool = false;
    var pw_gain: f32 = 1.0;
    var vad_threshold: ?f32 = null;
    var vad_threshold_off: ?f32 = null;
    var min_silence_ms: ?u32 = null;
    var no_auto_gain: bool = false;
    var max_tokens_per_second: usize = 15;

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
        } else if (std.mem.eql(u8, arg, "--warmup-file")) {
            i += 1;
            if (i < args.len) {
                warmup_file = args[i];
                warmup_file_is_default = false;
            }
        } else if (std.mem.eql(u8, arg, "--no-warmup")) {
            warmup_file = null;
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
            i += 1;
            if (i < args.len) domain_terms_path = args[i];
        } else if (std.mem.eql(u8, arg, "--drop-terms")) {
            i += 1;
            if (i < args.len) drop_terms_path = args[i];
        } else if (std.mem.eql(u8, arg, "--record-dir")) {
            i += 1;
            if (i < args.len) record_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--record-keep")) {
            i += 1;
            if (i < args.len) record_keep = std.fmt.parseInt(usize, args[i], 10) catch 10;
        } else if (std.mem.eql(u8, arg, "--transcribe")) {
            i += 1;
            if (i < args.len) transcribe_file = args[i];
        } else if (std.mem.eql(u8, arg, "--stream-wav")) {
            i += 1;
            if (i < args.len) stream_wav_file = args[i];
        } else if (std.mem.eql(u8, arg, "--pw-gain")) {
            i += 1;
            if (i < args.len) pw_gain = std.fmt.parseFloat(f32, args[i]) catch 1.0;
        } else if (std.mem.eql(u8, arg, "--low-latency")) {
            low_latency = true;
        } else if (std.mem.eql(u8, arg, "--vad-threshold")) {
            i += 1;
            if (i < args.len) vad_threshold = std.fmt.parseFloat(f32, args[i]) catch null;
        } else if (std.mem.eql(u8, arg, "--vad-threshold-off")) {
            i += 1;
            if (i < args.len) vad_threshold_off = std.fmt.parseFloat(f32, args[i]) catch null;
        } else if (std.mem.eql(u8, arg, "--min-silence-ms")) {
            i += 1;
            if (i < args.len) min_silence_ms = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--no-auto-gain")) {
            no_auto_gain = true;
        } else if (std.mem.eql(u8, arg, "--max-tokens-per-sec")) {
            i += 1;
            if (i < args.len) max_tokens_per_second = std.fmt.parseInt(usize, args[i], 10) catch 15;
        } else if (std.mem.eql(u8, arg, "--vad")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "ten")) {
                    vad_choice = .ten;
                } else if (std.mem.eql(u8, args[i], "silero")) {
                    vad_choice = .silero;
                } else if (std.mem.eql(u8, args[i], "ten-native")) {
                    vad_choice = .ten_native;
                } else {
                    std.debug.print("Invalid --vad value '{s}', expected 'ten', 'silero', or 'ten-native'\n", .{args[i]});
                    return;
                }
            }
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

    // Load whisper model
    std.debug.print("Loading model: {s}\n", .{resolved_model_path});
    var cparams = c.whisper_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = false;
    cparams.dtw_token_timestamps = true;
    cparams.dtw_aheads_preset = c.WHISPER_AHEADS_LARGE_V3_TURBO;

    const ctx = c.whisper_init_from_file_with_params(resolved_model_path.ptr, cparams) orelse {
        std.debug.print("Failed to load model\n", .{});
        return;
    };
    defer c.whisper_free(ctx);

    if (!requireGpu()) std.process.exit(1);

    // Load VAD backend
    var silero_vad: SileroVad = undefined;
    var ten_vad_ggml: TenVadGgml = undefined;
    var ten_vad_native: TenVadNative = undefined;
    var vad_backend: VadBackend = undefined;

    switch (vad_choice) {
        .ten => {
            const vad_rel_path: [:0]const u8 = "../models/ten-vad-ggml.bin";
            const vad_path: [:0]const u8 = blk: {
                if (exe_dir) |d| {
                    break :blk std.fs.path.joinZ(allocator, &.{ d, vad_rel_path }) catch break :blk vad_rel_path;
                }
                break :blk vad_rel_path;
            };
            defer if (vad_path.ptr != vad_rel_path.ptr) allocator.free(vad_path);
            std.debug.print("Loading VAD model (ten-vad): {s}\n", .{vad_path});
            ten_vad_ggml = TenVadGgml.init(allocator, vad_path) catch |err| {
                std.debug.print("Failed to init TEN-VAD: {}\n", .{err});
                return;
            };
            vad_backend = .{ .ten_vad_ggml = &ten_vad_ggml };
        },
        .silero => {
            const vad_rel_path: [:0]const u8 = "../models/ggml-silero-v5.1.2.bin";
            const vad_path: [:0]const u8 = blk: {
                if (exe_dir) |d| {
                    break :blk std.fs.path.joinZ(allocator, &.{ d, vad_rel_path }) catch break :blk vad_rel_path;
                }
                break :blk vad_rel_path;
            };
            defer if (vad_path.ptr != vad_rel_path.ptr) allocator.free(vad_path);
            std.debug.print("Loading VAD model (silero): {s}\n", .{vad_path});
            silero_vad = SileroVad.init(vad_path) catch |err| {
                std.debug.print("Failed to init Silero VAD: {}\n", .{err});
                return;
            };
            vad_backend = .{ .silero = &silero_vad };
        },
        .ten_native => {
            std.debug.print("Loading VAD (ten-native): prebuilt libten_vad.so (with pitch)\n", .{});
            ten_vad_native = TenVadNative.init() catch |err| {
                std.debug.print("Failed to init TEN-VAD native: {}\n", .{err});
                return;
            };
            vad_backend = .{ .ten_native = &ten_vad_native };
        },
    }
    defer switch (vad_choice) {
        .ten => ten_vad_ggml.deinit(),
        .silero => silero_vad.deinit(),
        .ten_native => ten_vad_native.deinit(),
    };

    // Tokenize domain terms (requires whisper context)
    var prompt_tokens: []c.whisper_token = &.{};
    if (domain_terms_path) |dpath| {
        const terms_file = std.fs.cwd().openFile(dpath, .{}) catch |err| {
            std.debug.print("Failed to open domain terms file '{s}': {}\n", .{ dpath, err });
            return;
        };
        defer terms_file.close();

        const terms_raw = terms_file.readToEndAlloc(allocator, 8192) catch |err| {
            std.debug.print("Failed to read domain terms file: {}\n", .{err});
            return;
        };
        defer allocator.free(terms_raw);

        // Null-terminate for whisper_tokenize (C API)
        const terms_text = try allocator.dupeZ(u8, terms_raw);
        defer allocator.free(terms_text);

        var token_buf: [224]c.whisper_token = undefined;
        const n_tokens = c.whisper_tokenize(ctx, terms_text.ptr, &token_buf, token_buf.len);
        if (n_tokens < 0) {
            std.debug.print("Failed to tokenize domain terms (file may be too long or contain invalid text)\n", .{});
            return;
        }
        prompt_tokens = try allocator.dupe(c.whisper_token, token_buf[0..@intCast(n_tokens)]);
        std.debug.print("Domain terms: {d} tokens from {s}\n", .{ n_tokens, dpath });
    }
    defer if (prompt_tokens.len > 0) allocator.free(prompt_tokens);

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

    // --transcribe: batch transcription using whisper_full (non-streaming) and exit
    if (transcribe_file) |tfile| {
        const samples = loadWav(allocator, tfile) catch |err| {
            std.debug.print("Failed to load WAV file '{s}': {}\n", .{ tfile, err });
            return;
        };
        defer allocator.free(samples);

        var params = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
        params.language = "en";
        params.n_threads = 4;
        params.no_timestamps = true;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_special = false;
        params.print_timestamps = false;

        if (c.whisper_full(ctx, params, samples.ptr, @intCast(samples.len)) != 0) {
            std.debug.print("Transcription failed\n", .{});
            return;
        }

        const n_segments = c.whisper_full_n_segments(ctx);
        var seg: c_int = 0;
        while (seg < n_segments) : (seg += 1) {
            const text = c.whisper_full_get_segment_text(ctx, seg);
            if (text != null) {
                _ = std.posix.write(1, std.mem.span(text)) catch {};
            }
        }
        _ = std.posix.write(1, "\n") catch {};
        return;
    }

    // --stream-wav: feed WAV through the streaming pipeline (VAD → speech_buf → transcribe → trim)
    // Same code path as live PipeWire/TCP but with deterministic byte-for-byte audio delivery.
    // Opens the WAV file directly and seeks past the header — the ChunkedReader reads
    // 1024-byte chunks from the file fd identically to how it reads from a socket or pipe.
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

        // Resolve VAD thresholds
        const defaults = vad_backend.defaultThresholds();
        const resolved_threshold2 = vad_threshold orelse defaults.onset;
        const resolved_threshold_off2 = vad_threshold_off orelse defaults.offset;
        const resolved_min_silence_ms2 = min_silence_ms orelse defaults.min_silence_ms;
        const resolved_min_silence_bytes2: usize = @as(usize, resolved_min_silence_ms2) * 32000 / 1000;

        var server2 = Server.init(allocator, ctx, vad_backend, 0, .tcp, null, 0, verbose, false, null, prompt_tokens, drop_terms, null, 1.0, true, resolved_threshold2, resolved_threshold_off2, resolved_min_silence_bytes2, max_tokens_per_second);
        server_mod.setLive(true);
        server2.handleConnection(file.handle, 1, null) catch |err| {
            std.debug.print("Stream error: {}\n", .{err});
        };
        file.close();
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

    // Warmup
    if (warmup_file) |wf| warmup: {
        // Default warmup file lives next to the binary; user-provided paths resolve from CWD
        const resolved_path = blk: {
            if (!warmup_file_is_default or std.fs.path.isAbsolute(wf)) break :blk wf;
            if (exe_dir) |d| {
                break :blk std.fs.path.joinZ(allocator, &.{ d, wf }) catch break :blk wf;
            }
            break :blk wf;
        };
        defer if (resolved_path.ptr != wf.ptr) allocator.free(resolved_path);

        if (builtin.os.tag == .macos) {
            std.debug.print("Warming up with: {s} (first run may be slow due to Metal shader compilation)\n", .{resolved_path});
        } else {
            std.debug.print("Warming up with: {s} (first run may be slow due to CUDA kernel compilation)\n", .{resolved_path});
        }
        const warmup_start = std.time.nanoTimestamp();
        const samples = loadWav(allocator, resolved_path) catch |err| {
            std.debug.print("Warning: warmup file not found ({s}), skipping warmup: {}\n", .{ resolved_path, err });
            break :warmup;
        };
        defer allocator.free(samples);

        var pipeline = try Pipeline.init(allocator, ctx, .{}, 4, verbose, prompt_tokens);
        defer pipeline.deinit();

        if (try pipeline.transcribe(samples, true, null)) |result| {
            std.debug.print("Warmup result: \"{s}\"\n", .{result.text});
            allocator.free(result.text);
            allocator.free(result.words);
            allocator.free(result.tokens);
            allocator.free(result.token_frames);
        }
        const warmup_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - warmup_start, 1_000_000));
        std.debug.print("Warmup complete ({d}.{d:0>1}s)\n", .{ warmup_ms / 1000, (warmup_ms % 1000) / 100 });
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

    // Start server — resolve VAD thresholds from backend defaults if not explicitly set
    const defaults = vad_backend.defaultThresholds();
    const resolved_threshold = vad_threshold orelse defaults.onset;
    const resolved_threshold_off = vad_threshold_off orelse defaults.offset;
    const resolved_min_silence_ms = min_silence_ms orelse defaults.min_silence_ms;
    const resolved_min_silence_bytes: usize = @as(usize, resolved_min_silence_ms) * 32000 / 1000;
    std.debug.print("VAD: backend={s}  onset={d:.2}  offset={d:.2}  min_silence={d}ms\n", .{
        vad_backend.name(), resolved_threshold, resolved_threshold_off, resolved_min_silence_ms,
    });
    var server = Server.init(allocator, ctx, vad_backend, port, input_mode, pw_target, audio_channel, verbose, low_latency, type_callback, prompt_tokens, drop_terms, recorder, pw_gain, no_auto_gain, resolved_threshold, resolved_threshold_off, resolved_min_silence_bytes, max_tokens_per_second);
    try server.run();
}

fn requireGpu() bool {
    const dev_count = c.ggml_backend_dev_count();
    var i: usize = 0;
    while (i < dev_count) : (i += 1) {
        const dev = c.ggml_backend_dev_get(i);
        if (c.ggml_backend_dev_type(dev) == c.GGML_BACKEND_DEVICE_TYPE_GPU) {
            std.debug.print("GPU: {s} ({s})\n", .{
                std.mem.span(c.ggml_backend_dev_description(dev)),
                std.mem.span(c.ggml_backend_dev_name(dev)),
            });
            return true;
        }
    }
    std.debug.print("GPU: none\n", .{});
    if (builtin.os.tag == .macos) {
        std.debug.print("ERROR: No Metal GPU detected. Capsper requires a Metal-capable GPU.\n", .{});
    } else {
        std.debug.print("ERROR: No CUDA GPU detected. Capsper requires a CUDA-capable GPU.\n", .{});
    }
    std.debug.print("CPU inference is too slow for real-time dictation.\n", .{});
    return false;
}

fn printUsage() void {
    std.debug.print("Usage: capsper [--model PATH] [--port PORT]\n", .{});
    std.debug.print("       [--warmup-file PATH] [--no-warmup] [--verbose|-v]\n", .{});
    std.debug.print("       [--input tcp|local] [--pw-target NODE] [--pw-channel CHANNEL]\n", .{});
    std.debug.print("       [--trigger KEY] [--trigger-passthrough] [--type-delay MICROSECONDS]\n", .{});
    std.debug.print("       [--domain-terms FILE] [--drop-terms FILE]\n", .{});
    std.debug.print("       [--record-dir DIR [--record-keep N]]\n", .{});
    std.debug.print("       [--transcribe FILE] [--stream-wav FILE]\n", .{});
    std.debug.print("       [--pw-gain FACTOR] [--no-auto-gain] [--max-tokens-per-sec N]\n", .{});
    std.debug.print("       [--vad ten|silero|ten-native] [--vad-threshold F] [--vad-threshold-off F] [--min-silence-ms MS]\n", .{});
    std.debug.print("       [--pw-detect [--detect-duration SECS]]\n", .{});
    std.debug.print("       [--dry-run] [--version]\n", .{});
}

pub fn loadWav(allocator: std.mem.Allocator, path: [:0]const u8) ![]f32 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(data);

    const header = try utils.parseWavHeader(data);
    return utils.wavToFloat(allocator, data, header);
}
