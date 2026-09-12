const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const nemo_mel = @import("shared/nemo_mel.zig");
const nemotron_tokenizer = @import("shared/tokenizer.zig");
const ContextGraph = @import("shared/context_graph.zig").ContextGraph;
const backend = @import("backend/init.zig");
const pipeline_mod = @import("backend/pipeline.zig");
const Pipeline = pipeline_mod.Pipeline;
const server_mod = @import("shared/server.zig");
const Server = server_mod.Server;
const PipelineFactory = server_mod.PipelineFactory;
const TypeCallback = server_mod.TypeCallback;
const AudioCapture = @import("platform/audio.zig").AudioCapture;
const input_mod = @import("platform/input.zig");
const InputHandler = input_mod.InputHandler;
const utils = @import("shared/utils.zig");
const audio_detect = @import("platform/detect.zig");
const Recorder = @import("shared/recorder.zig").Recorder;
const config = @import("shared/config.zig");
const sink_mod = @import("platform/sink.zig");
const VirtualSink = sink_mod.VirtualSink;
const SinkWatch = sink_mod.SinkWatch;
const meeting_runner = @import("shared/meeting_runner.zig");
const session_server = @import("shared/session_server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer _ = gpa.deinit();
    var ts_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = gpa.allocator() };
    const allocator = ts_allocator.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Settings and the strings they point at live here for the whole run.
    // An arena because a parsed Config mixes allocated strings with the static
    // defaults of the fields the file left out, and only the arena can free
    // that mixture without knowing which is which.
    var cfg_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer cfg_arena_state.deinit();
    const cfg_arena = cfg_arena_state.allocator();

    // argv, minus the mutability the parser does not need.
    const argv: []const [:0]const u8 = @ptrCast(args);

    // The file is read first and the flags are applied over it, so a flag
    // always wins for one run. Finding --config therefore has to happen before
    // the general parse, which is why it gets its own scan.
    const explicit_config = config.configPathFromArgs(argv);
    var cfg = config.Config{};
    if (explicit_config orelse config.defaultPath(cfg_arena) catch null) |path| {
        if (config.load(cfg_arena, path)) |loaded| {
            if (loaded) |c| {
                cfg = c;
            } else if (explicit_config != null) {
                // Defaults are fine when nobody asked for a file, but a path
                // given explicitly and not there is a mistake.
                std.debug.print("Config file not found: {s}\n", .{path});
                std.process.exit(1);
            }
        } else |_| std.process.exit(1);
    }

    var cli = config.Cli{};
    if (config.parseArgs(&cfg, &cli, argv)) |arg_err| {
        config.reportArgError(arg_err);
        std.process.exit(1);
    }
    try cfg.expandPaths(cfg_arena);

    if (cli.show_version) {
        std.debug.print("capsper {s}\n", .{build_options.version});
        return;
    }

    // Channel names are platform-agnostic in the config and platform-specific
    // in the capture layer, so resolve once, here, and fail loudly rather than
    // carrying an unmappable name any further.
    const audio_channel = AudioCapture.parseChannelName(@tagName(cfg.audio.channel)) orelse {
        std.debug.print("Channel {s} is not available on this platform\n", .{@tagName(cfg.audio.channel)});
        return;
    };

    // Trigger key names are platform-agnostic in the config too, and unlike
    // channels some of them genuinely do not exist everywhere.
    const trigger_key: ?u16 = if (cfg.trigger.key) |k|
        input_mod.parseTriggerKey(@tagName(k)) orelse {
            std.debug.print("Trigger key {s} is not available on this platform\n", .{@tagName(k)});
            std.debug.print("Supported: capslock, scrolllock, numlock, " ++
                (if (builtin.os.tag == .linux) "pause, " else "") ++
                "f13-f20" ++
                (if (builtin.os.tag == .linux) ", f21-f24" else "") ++
                "\n", .{});
            return;
        }
    else
        null;

    // No arguments: show usage
    if (args.len == 1) {
        printUsage();
        return;
    }

    // Audio detect utility command (early exit, no model loading needed)
    if (cli.audio_detect) {
        audio_detect.detectChannel(allocator, cfg.audio.target, cfg.audio.detect_duration);
        return;
    }

    // Determine run mode from flags:
    // --audio-target (or --trigger which requires audio) → local capture
    // --port → TCP server
    // Both can be active simultaneously.
    const want_local = cfg.audio.target != null or trigger_key != null;
    const want_tcp = cfg.tcp_server.port != null;
    const want_meeting = cfg.meeting.enabled;

    if (!want_local and !want_tcp and !want_meeting and
        cli.stream == null and cli.transcribe == null and !cli.dry_run)
    {
        printUsage();
        return;
    }

    // The sink goes up before the model loads, so it is in the output picker
    // while the model is still being read rather than a minute later.
    var sink: ?VirtualSink = null;
    if (want_meeting and !cli.dry_run) {
        sink = VirtualSink.init(cfg.meeting.sink_name, "Capsper Call") catch |err| {
            std.debug.print("Failed to create virtual sink '{s}': {}\n", .{ cfg.meeting.sink_name, err });
            return;
        };
    }
    defer if (sink) |*s| s.deinit();

    // An unset model path means the copy shipped beside the binary, which is
    // what makes an unpacked dist tarball run without configuring anything.
    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
    defer if (exe_dir) |d| allocator.free(d);

    const resolved_model_path: [:0]const u8 = cfg.model orelse blk: {
        const d = exe_dir orelse break :blk "../models/nemotron";
        break :blk std.fs.path.joinZ(cfg_arena, &.{ d, "../models/nemotron" }) catch "../models/nemotron";
    };

    // Load Nemotron model
    std.debug.print("Loading Nemotron model from: {s}\n", .{resolved_model_path});

    // Load shared resources (filterbank, tokenizer, context graph)
    const fb_path = std.fs.path.joinZ(allocator, &.{ resolved_model_path, "filterbank.bin" }) catch {
        std.debug.print("Failed to build filterbank path\n", .{});
        return;
    };
    defer allocator.free(fb_path);
    const nemo_filterbank = nemo_mel.loadFilterbank(allocator, fb_path) catch |err| {
        std.debug.print("Failed to load filterbank: {}\n", .{err});
        return;
    };
    defer allocator.free(@as([*]u8, @ptrCast(@constCast(nemo_filterbank.ptr)))[0 .. nemo_filterbank.len * @sizeOf(f32)]);

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

    // Read drop terms file (newline-separated, one term per line)
    var drop_terms: []const []const u8 = &.{};
    if (cfg.drop_terms) |dpath| {
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
    defer if (nemo_context_graph) |cg| {
        cg.deinit();
        allocator.destroy(cg);
    };
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
            cfg.verbose,
        );
        nemo_context_graph = cg;
        std.debug.print("Context graph: {d} suppression phrases\n", .{drop_terms.len});
    }

    // Load ASR backend (selected at compile time via -Dbackend)
    var backend_state = backend.load(allocator, resolved_model_path, nemo_filterbank, &nemo_token_map, nemo_context_graph, cfg.verbose) orelse return;
    defer backend_state.deinit();
    const pipeline_factory = PipelineFactory{ .backend = backend_state };

    warmup(allocator, pipeline_factory);

    // --stream-wav: feed WAV through the streaming pipeline (no PTT, no VAD)
    if (cli.stream) |swf| {
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

        // Reading a file is not capturing audio, so the settings that only
        // describe a live microphone are forced off rather than inherited.
        var stream_cfg = cfg;
        stream_cfg.tcp_server.port = null;
        stream_cfg.audio.gain = 1.0;
        stream_cfg.audio.auto_gain = false;
        stream_cfg.trigger.low_latency = false;
        stream_cfg.audio.on_device_lost = .wait;

        var server2 = Server.init(allocator, pipeline_factory, .{
            .cfg = &stream_cfg,
            .audio_channel = audio_channel,
            .drop_terms = drop_terms,
        });
        server2.handleDataStream(file.handle, 1) catch |err| {
            std.debug.print("Stream error: {}\n", .{err});
        };
        file.close();
        return;
    }

    // --transcribe: feed WAV through the streaming pipeline, output plain text
    if (cli.transcribe) |tfile| {
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

        const pipeline = pipeline_factory.create(allocator) catch |err| {
            std.debug.print("Failed to create pipeline: {}\n", .{err});
            return;
        };
        defer {
            pipeline.deinit();
            allocator.destroy(pipeline);
        }

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

    if (!cli.dry_run) {
        if (trigger_key) |tkey| {
            std.debug.print("Initializing input handler (trigger=keycode {d})\n", .{tkey});
            input_handler = InputHandler.init(.{
                .trigger_key = tkey,
                .trigger_passthrough = cfg.trigger.passthrough,
                .type_delay_us = cfg.trigger.type_delay_us,
                .live_fn = &server_mod.setLive,
            }) catch |err| {
                std.debug.print("Failed to init input handler: {}\n", .{err});
                if (builtin.os.tag == .linux) {
                    std.debug.print("Check: is user in 'input' group? Is /dev/uinput accessible?\n", .{});
                }
                std.process.exit(1);
            };
            type_callback = .{
                .context = @ptrCast(&input_handler.?),
                .func = &InputHandler.typeTextCallback,
            };
        }

        // With trigger key: start not-live (trigger press goes live)
        // Without trigger key but with audio target: start live (always on)
        if (trigger_key != null) {
            server_mod.setLive(false);
        } else if (want_local) {
            server_mod.setLive(true);
        }
    }
    defer {
        if (input_handler != null) input_handler.?.deinit();
    }

    if (cli.dry_run) {
        std.debug.print("Dry run complete\n", .{});
        return;
    }

    // Create recorder if --record-dir specified
    var recorder_storage: Recorder = undefined;
    var recorder: ?*Recorder = null;
    if (cfg.debug_recording.dir) |rdir| {
        recorder_storage = Recorder.init(allocator, rdir, cfg.debug_recording.keep, build_options.version, switch (cfg.debug_recording.detail) {
            .minimal => .minimal,
            .debug => .debug,
        }) catch |err| {
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
    var server = Server.init(allocator, pipeline_factory, .{
        .cfg = &cfg,
        .audio_channel = audio_channel,
        .want_local = want_local,
        .type_callback = type_callback,
        .drop_terms = drop_terms,
        .recorder = recorder,
    });
    try server.run();

    // With nothing else enabled, the meeting loop is the thing that keeps the
    // process (and so the sink) alive.
    if (want_meeting and !want_local and !want_tcp) {
        if (cfg.meeting.http.port) |http_port| {
            session_server.start(allocator, .{
                .root = cfg.meeting.dir,
                .port = http_port,
                .bind = cfg.meeting.http.bind,
            }) catch {};
        }
        try meeting_runner.run(allocator, &cfg, audio_channel, pipeline_factory);
    }
}


/// Prime the pipeline on a short known file so the first real utterance does
/// not pay for CoreML ANE warm-up or CUDA kernel compilation. The file ships
/// beside the binary; if it is missing there is nothing to warm up and nothing
/// to say about it, so every failure here is silent by design.
fn warmup(allocator: std.mem.Allocator, factory: PipelineFactory) void {
    const bin_dir = std.fs.selfExeDirPathAlloc(allocator) catch return;
    defer allocator.free(bin_dir);
    const path = std.fs.path.joinZ(allocator, &.{ bin_dir, "jfk.wav" }) catch return;
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();
    const data = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch return;
    defer allocator.free(data);

    const header = utils.parseWavHeader(data) catch return;
    const samples = utils.wavToFloat(allocator, data, header) catch return;
    defer allocator.free(samples);

    const started = std.time.nanoTimestamp();
    const pipeline = factory.create(allocator) catch return;
    defer {
        pipeline.deinit();
        allocator.destroy(pipeline);
    }

    if (pipeline.transcribe(samples, true, null) catch null) |result| {
        allocator.free(result.text);
        allocator.free(result.words);
        allocator.free(result.tokens);
        allocator.free(result.token_frames);
    }

    const ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - started, 1_000_000));
    std.debug.print("Warmup complete ({d}.{d:0>1}s)\n", .{ ms / 1000, (ms % 1000) / 100 });
}

fn printUsage() void {
    std.debug.print(
        \\Usage: capsper <mode> [options]
        \\
        \\Modes (at least one required):
        \\  --audio-target NODE      Local audio capture (always-live without --trigger)
        \\  --trigger KEY             Enable push-to-talk (implies local capture)
        \\  --port PORT              Start TCP server (multiple concurrent clients)
        \\  --stream FILE            Stream WAV file through pipeline, output to stdout
        \\  --transcribe FILE        Transcribe WAV file in one shot, output to stdout
        \\  --audio-detect           Detect audio devices and channels, then exit
        \\
        \\Options:
        \\  --config PATH            Config file (default: $XDG_CONFIG_HOME/capsper/config.zon)
        \\  --model PATH             Model directory (default: ../models/nemotron)
        \\  --audio-channel CHANNEL  Audio channel: MONO, FL, FR, AUX0-AUX63
        \\  --audio-gain FACTOR      Initial gain multiplier
        \\  --no-auto-gain           Disable automatic gain adjustment
        \\  --on-device-lost MODE    exit or wait (default: wait)
        \\  --low-latency            Use cork/uncork instead of connect/disconnect
        \\  --trigger-passthrough    Pass trigger key through to applications
        \\  --type-delay MICROSECONDS Delay between injected keystrokes (default: 12000)
        \\  --drop-terms FILE        Filler words to suppress (one per line)
        \\  --record-dir DIR         Save audio recordings to directory
        \\  --record-keep N          Keep last N recordings (default: 10)
        \\  --detect-duration SECS   Audio detection duration (default: 5)
        \\  --verbose, -v            Verbose logging
        \\  --dry-run                Load model and exit (verify setup)
        \\  --version                Show version
        \\
        \\Examples:
        \\  capsper --trigger capslock --audio-target my-mic
        \\  capsper --trigger capslock --audio-target my-mic --port 43007
        \\  capsper --port 0
        \\  capsper --stream recording.wav
        \\
    , .{});
}
