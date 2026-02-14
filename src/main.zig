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

    // --trigger implies --input local (PipeWire capture) and starts paused (trigger key controls recording)
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
                .pause_fn = &server_mod.setPaused,
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

        // Start paused when using trigger key (evdev controls pause directly)
        if (trigger_key != null) {
            server_mod.setPaused(true);
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

        std.debug.print("Warming up with: {s}\n", .{resolved_path});
        const samples = loadWav(allocator, resolved_path) catch |err| {
            std.debug.print("Warning: warmup file not found ({s}), skipping warmup: {}\n", .{ resolved_path, err });
            break :warmup;
        };
        defer allocator.free(samples);

        var pipeline = try Pipeline.init(allocator, ctx, .{}, 4, verbose);
        defer pipeline.deinit();

        if (try pipeline.transcribe(samples, true)) |result| {
            std.debug.print("Warmup result: \"{s}\"\n", .{result.text});
            allocator.free(result.text);
        }
        std.debug.print("Warmup complete\n", .{});
    }

    if (dry_run) {
        std.debug.print("Dry run complete\n", .{});
        return;
    }

    // Start input handler thread (after warmup, before server)
    if (input_handler != null) {
        try input_handler.?.start();
    }

    // Start server
    var server = Server.init(allocator, ctx, vad, port, input_mode, pw_target, pw_channel, verbose, type_callback);
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
