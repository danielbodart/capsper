const std = @import("std");
const build_options = @import("build_options");
const c = @import("whisper_c.zig");
const pw = @import("pipewire_c.zig");
const Vad = @import("vad.zig").Vad;
const Pipeline = @import("pipeline.zig").Pipeline;
const server_mod = @import("server.zig");
const Server = server_mod.Server;
const InputMode = server_mod.InputMode;
const TypeCallback = server_mod.TypeCallback;
const InputHandler = @import("input.zig").InputHandler;
const input_mod = @import("input.zig");
const utils = @import("utils.zig");
const pw_detect = @import("pw_detect.zig");
const Recorder = @import("recorder.zig").Recorder;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var model_path: [:0]const u8 = "whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin";
    var vad_model_path: [:0]const u8 = "whisper.cpp/models/ggml-silero-v5.1.2.bin";
    var port: u16 = 43007;
    var warmup_file: ?[:0]const u8 = "jfk.wav";
    var warmup_file_is_default = true;
    var input_mode: InputMode = .tcp;
    var pw_target: ?[:0]const u8 = null;
    var pw_channel: u32 = pw.SPA_AUDIO_CHANNEL_FL;
    var verbose: bool = false;
    var trigger_key: ?u16 = null;
    var trigger_passthrough: bool = false;
    var type_delay_us: u64 = 12_000; // 12ms
    var dry_run: bool = false;
    var do_pw_list: bool = false;
    var do_pw_detect: bool = false;
    var detect_duration: u32 = 5;
    var domain_terms_path: ?[:0]const u8 = null;
    var record_dir: ?[:0]const u8 = null;
    var record_keep: usize = 50;
    var transcribe_file: ?[:0]const u8 = null;

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
            if (i < args.len) model_path = args[i];
        } else if (std.mem.eql(u8, arg, "--vad-model")) {
            i += 1;
            if (i < args.len) vad_model_path = args[i];
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
        } else if (std.mem.eql(u8, arg, "--pw-channel")) {
            i += 1;
            if (i < args.len) {
                pw_channel = parseChannelName(args[i]) orelse {
                    std.debug.print("Invalid --pw-channel value '{s}'\n", .{args[i]});
                    std.debug.print("Expected: MONO, FL, AUX0-AUX63\n", .{});
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
        } else if (std.mem.eql(u8, arg, "--pw-list")) {
            do_pw_list = true;
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
        } else if (std.mem.eql(u8, arg, "--record-dir")) {
            i += 1;
            if (i < args.len) record_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--record-keep")) {
            i += 1;
            if (i < args.len) record_keep = std.fmt.parseInt(usize, args[i], 10) catch 50;
        } else if (std.mem.eql(u8, arg, "--transcribe")) {
            i += 1;
            if (i < args.len) transcribe_file = args[i];
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
    if (do_pw_list) {
        pw_detect.listSources();
        return;
    }
    if (do_pw_detect) {
        pw_detect.detectChannel(allocator, pw_target, detect_duration);
        return;
    }

    // --trigger implies --input local (PipeWire capture) and starts not-live (trigger key controls recording)
    if (trigger_key != null) {
        input_mode = .local;
    }

    // Load whisper model
    std.debug.print("Loading model: {s}\n", .{model_path});
    var cparams = c.whisper_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = false;
    cparams.dtw_token_timestamps = true;
    cparams.dtw_aheads_preset = c.WHISPER_AHEADS_LARGE_V3_TURBO;

    const ctx = c.whisper_init_from_file_with_params(model_path.ptr, cparams) orelse {
        std.debug.print("Failed to load model\n", .{});
        return;
    };
    defer c.whisper_free(ctx);

    if (!requireGpu()) std.process.exit(1);

    // Load VAD model
    std.debug.print("Loading VAD model: {s}\n", .{vad_model_path});
    var vad = Vad.init(vad_model_path) catch |err| {
        std.debug.print("Failed to init VAD: {}\n", .{err});
        return;
    };
    defer vad.deinit();

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
    // zwanzig-disable-next-line: store-violations-engine
    defer if (prompt_tokens.len > 0) allocator.free(prompt_tokens);

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

    // Initialize evdev input handler (if --trigger specified, skip in dry-run)
    var input_handler: ?InputHandler = null;
    var type_callback: ?TypeCallback = null;

    if (!dry_run) {
        if (trigger_key) |tkey| {
            std.debug.print("Initializing evdev input handler (trigger=keycode {d})\n", .{tkey});
            input_handler = InputHandler.init(.{
                .trigger_key = tkey,
                .trigger_passthrough = trigger_passthrough,
                .type_delay_us = type_delay_us,
                .live_fn = &server_mod.setLive,
            }) catch |err| {
                std.debug.print("Failed to init input handler: {}\n", .{err});
                std.debug.print("Check: is user in 'input' group? Is /dev/uinput accessible?\n", .{});
                return;
            };
            type_callback = .{
                .context = @ptrCast(&input_handler.?),
                .func = &InputHandler.typeTextCallback,
            };
        }

        // Start not-live when using trigger key (trigger press goes live)
        if (trigger_key != null) {
            server_mod.setLive(false);
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
            const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch break :blk wf;
            defer allocator.free(exe_dir);
            const joined = std.fs.path.joinZ(allocator, &.{ exe_dir, wf }) catch break :blk wf;
            break :blk joined;
        };
        defer if (resolved_path.ptr != wf.ptr) allocator.free(resolved_path);

        std.debug.print("Warming up with: {s} (first run may be slow due to CUDA kernel compilation)\n", .{resolved_path});
        const warmup_start = std.time.nanoTimestamp();
        const samples = loadWav(allocator, resolved_path) catch |err| {
            std.debug.print("Warning: warmup file not found ({s}), skipping warmup: {}\n", .{ resolved_path, err });
            break :warmup;
        };
        defer allocator.free(samples);

        var pipeline = try Pipeline.init(allocator, ctx, .{}, 4, verbose, prompt_tokens);
        defer pipeline.deinit();

        if (try pipeline.transcribe(samples, true)) |result| {
            std.debug.print("Warmup result: \"{s}\"\n", .{result.text});
            allocator.free(result.text);
            allocator.free(result.words);
            allocator.free(result.tokens);
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

    // Start server
    var server = Server.init(allocator, ctx, vad, port, input_mode, pw_target, pw_channel, verbose, type_callback, prompt_tokens, recorder);
    try server.run();
}

/// Parse a channel name string to a SPA audio channel position constant.
/// Supports MONO, FL, and AUX0-AUX63.
fn parseChannelName(name: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(name, "MONO")) return pw.SPA_AUDIO_CHANNEL_MONO;
    if (std.ascii.eqlIgnoreCase(name, "FL")) return pw.SPA_AUDIO_CHANNEL_FL;
    // Parse AUXn (case-insensitive prefix, numeric suffix)
    if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[0..3], "AUX")) {
        const n = std.fmt.parseInt(u32, name[3..], 10) catch return null;
        if (n <= 63) return pw.spaAudioChannelAux(n);
    }
    return null;
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
    std.debug.print("ERROR: No CUDA GPU detected. Capsper requires a CUDA-capable GPU.\n", .{});
    std.debug.print("CPU inference is too slow for real-time dictation.\n", .{});
    return false;
}

fn printUsage() void {
    std.debug.print("Usage: capsper [--model PATH] [--vad-model PATH] [--port PORT]\n", .{});
    std.debug.print("       [--warmup-file PATH] [--no-warmup] [--verbose|-v]\n", .{});
    std.debug.print("       [--input tcp|local] [--pw-target NODE] [--pw-channel CHANNEL]\n", .{});
    std.debug.print("       [--trigger KEY] [--trigger-passthrough] [--type-delay MICROSECONDS]\n", .{});
    std.debug.print("       [--domain-terms FILE]\n", .{});
    std.debug.print("       [--record-dir DIR [--record-keep N]]\n", .{});
    std.debug.print("       [--transcribe FILE]\n", .{});
    std.debug.print("       [--pw-list] [--pw-detect [--detect-duration SECS]]\n", .{});
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
