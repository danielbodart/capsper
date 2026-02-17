const std = @import("std");
const c = @import("whisper_c.zig");
const Vad = @import("vad.zig").Vad;
const Pipeline = @import("pipeline.zig").Pipeline;
const AudioCapture = @import("audio_capture.zig").AudioCapture;
const utils = @import("utils.zig");
const recorder_mod = @import("recorder.zig");
const Recorder = recorder_mod.Recorder;
const EndReason = recorder_mod.EndReason;

const posix = std.posix;
const net = std.net;

// Global live state (module-level so input handler can access it via setLive).
// Default live (TCP mode always processes audio). main.zig calls setLive(false)
// at startup when --trigger is used, then trigger key toggles it.
pub var is_live = std.atomic.Value(bool).init(true);

// Global capture pointer — set by runLocal so setLive can toggle the PipeWire stream.
// When non-null, setLive also activates/deactivates the stream so the desktop
// microphone indicator only appears during active recording.
var capture_ptr = std.atomic.Value(?*AudioCapture).init(null);

pub fn setLive(live: bool) void {
    is_live.store(live, .monotonic);
    if (capture_ptr.load(.monotonic)) |cap| {
        cap.setActive(live);
    }
}

/// Type-erased callback for injecting text (used by evdev/uinput mode).
pub const TypeCallback = struct {
    context: *anyopaque,
    func: *const fn (*anyopaque, []const u8) void,

    pub fn call(self: TypeCallback, text: []const u8) void {
        self.func(self.context, text);
    }
};

// Streaming constants (byte counts for S16_LE at 16kHz = 32000 bytes/sec)
const transcribe_interval_bytes: usize = 32000; // 1s — re-transcribe cadence during speech
const vad_window_bytes: usize = 16000; // 0.5s — VAD lookback window
const idle_keep_bytes: usize = 128000; // 4s — audio retained while idle (gives first transcription more context)
const silence_timeout_bytes: usize = 64000; // 2s — silence before utterance flush
const max_buffer_bytes: usize = 896000; // 28s — sliding window cap (must stay under 30s whisper limit)
const min_transcribe_bytes: usize = 16000; // 0.5s — minimum audio worth transcribing

const State = union(enum) {
    idle,
    speaking,
    trailing_silence: struct {
        silence_start_pos: usize,
        transcribe_done: bool,
    },
};

pub const InputMode = enum { tcp, local };

pub const Server = struct {
    allocator: std.mem.Allocator,
    ctx: *c.whisper_context,
    vad: Vad,
    port: u16,
    input_mode: InputMode,
    pw_target: ?[:0]const u8,
    pw_channel: u32,
    verbose: bool,
    type_callback: ?TypeCallback,
    prompt_tokens: []const c.whisper_token,
    recorder: ?*Recorder,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *c.whisper_context,
        vad: Vad,
        port: u16,
        input_mode: InputMode,
        pw_target: ?[:0]const u8,
        pw_channel: u32,
        verbose: bool,
        type_callback: ?TypeCallback,
        prompt_tokens: []const c.whisper_token,
        recorder: ?*Recorder,
    ) Server {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .vad = vad,
            .port = port,
            .input_mode = input_mode,
            .pw_target = pw_target,
            .pw_channel = pw_channel,
            .verbose = verbose,
            .type_callback = type_callback,
            .prompt_tokens = prompt_tokens,
            .recorder = recorder,
        };
    }

    pub fn run(self: *Server) !void {
        switch (self.input_mode) {
            .tcp => try self.runTcp(),
            .local => try self.runLocal(),
        }
    }

    fn runTcp(self: *Server) !void {
        const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port);
        const listener = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 1);

        // Query actual port (needed when self.port == 0 for OS-assigned port)
        var bound: net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(@TypeOf(bound.any));
        try posix.getsockname(listener, &bound.any, &addr_len);
        const actual_port = bound.getPort();

        std.debug.print("Listening on port {d}\n", .{actual_port});

        while (true) {
            const conn = try posix.accept(listener, null, null, posix.SOCK.CLOEXEC);
            defer posix.close(conn);

            std.debug.print("Client connected\n", .{});
            self.handleConnection(conn, conn, self.type_callback) catch |err| {
                std.debug.print("Connection error: {}\n", .{err});
            };
            std.debug.print("Client disconnected\n", .{});
        }
    }

    fn runLocal(self: *Server) !void {
        std.debug.print("Starting local PipeWire capture...\n", .{});

        var capture = AudioCapture.init(self.pw_target, self.pw_channel) catch |err| {
            std.debug.print("Failed to start PipeWire capture: {}\n", .{err});
            return err;
        };
        defer capture.deinit();

        // Register capture so setLive can toggle stream active state.
        // If already live (no --trigger), activate the stream immediately.
        capture_ptr.store(&capture, .monotonic);
        defer capture_ptr.store(null, .monotonic);
        if (is_live.load(.monotonic)) {
            capture.setActive(true);
        }

        const stdout_fd: posix.fd_t = 1; // STDOUT_FILENO
        if (self.type_callback != null) {
            std.debug.print("Capturing audio, injecting text via uinput\n", .{});
        } else {
            std.debug.print("Capturing audio, transcribing to stdout\n", .{});
        }

        self.handleConnection(capture.getFd(), stdout_fd, self.type_callback) catch |err| {
            std.debug.print("Local capture error: {}\n", .{err});
            return err;
        };
    }

    fn handleConnection(self: *Server, audio_fd: posix.fd_t, output_fd: posix.fd_t, type_cb: ?TypeCallback) !void {
        var pipeline = try Pipeline.init(self.allocator, self.ctx, .{}, 4, self.verbose, self.prompt_tokens);
        defer pipeline.deinit();

        const start_ns = std.time.nanoTimestamp();

        // Audio buffer (raw PCM S16_LE bytes)
        var pcm_buf = std.ArrayListUnmanaged(u8){};
        defer pcm_buf.deinit(self.allocator);

        var pcm_trim_total: usize = 0; // cumulative bytes trimmed (for absolute frame calc)

        var recv_buf: [32768]u8 = undefined;
        var state: State = .idle;
        var bytes_since_last_cycle: usize = 0;
        var cycle_count: usize = 0;
        var was_live: bool = is_live.load(.monotonic); // track previous live state for transition detection

        while (true) {
            // Use poll for timeout support during active speech
            var fds = [_]posix.pollfd{.{
                .fd = audio_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const poll_timeout: i32 = switch (state) {
                .speaking, .trailing_silence => 2000, // 2s timeout for end-of-stream detection
                .idle => -1, // block forever in idle
            };
            const poll_ready = try posix.poll(&fds, poll_timeout);

            var n: usize = 0;
            var timed_out = false;
            if (poll_ready == 0) {
                // Poll timeout — no data arrived
                timed_out = true;
            } else {
                n = posix.read(audio_fd, &recv_buf) catch |err| switch (err) {
                    error.ConnectionResetByPeer => return,
                    else => return err,
                };
            }

            if (n > 0) {
                try pcm_buf.appendSlice(self.allocator, recv_buf[0..n]);
                bytes_since_last_cycle += n;
                if (self.recorder) |rec| rec.recordPcm(recv_buf[0..n]);
            }

            const client_closed = (!timed_out and n == 0);

            // Throttle: wait for enough new audio before processing
            const min_bytes: usize = switch (state) {
                .idle, .speaking => transcribe_interval_bytes,
                .trailing_silence => vad_window_bytes,
            };

            if (!client_closed and !timed_out and bytes_since_last_cycle < min_bytes) continue;
            if (pcm_buf.items.len == 0) {
                if (client_closed) return;
                continue;
            }

            bytes_since_last_cycle = 0;

            // Push-to-talk gating
            const live = is_live.load(.monotonic);

            // PTT release edge: let active speech drain via timeout, clear idle audio
            if (was_live and !live) {
                was_live = false;
                if (self.recorder) |rec| rec.logEvent(start_ns, "PTT released");
                if (state == .idle) {
                    pcm_trim_total += pcm_buf.items.len;
                    pcm_buf.clearRetainingCapacity();
                    continue;
                }
                // speaking/trailing_silence: fall through — poll will time out,
                // triggering the final flush path which handles transcribe + reset
            }

            // Not live and idle: discard accumulated audio, wait for key press
            if (!live and state == .idle) {
                pcm_trim_total += pcm_buf.items.len;
                pcm_buf.clearRetainingCapacity();
                continue;
            }

            // Going live: keep buffer (pre-trigger audio) for first transcription
            if (!was_live and live) {
                var ts_buf2: [32]u8 = undefined;
                const ts2 = formatElapsed(&ts_buf2, start_ns);
                std.debug.print("[{s}s] LIVE\n", .{ts2});
                state = .idle;
                cycle_count = 0;
                was_live = true;
                if (self.recorder) |rec| rec.logEvent(start_ns, "PTT pressed");
            }

            // Final flush on disconnect or read timeout — emit everything
            if (client_closed or timed_out) {
                if (state == .speaking or state == .trailing_silence) {
                    // VAD gate: only transcribe if speech is present in the tail
                    const flush_has_speech = blk: {
                        const vad_start = if (pcm_buf.items.len > vad_window_bytes)
                            (pcm_buf.items.len - vad_window_bytes) & ~@as(usize, 1)
                        else
                            0;
                        const vad_samples = try utils.pcmToFloat(self.allocator, pcm_buf.items[vad_start..]);
                        defer self.allocator.free(vad_samples);
                        break :blk self.vad.hasSpeech(vad_samples);
                    };
                    if (flush_has_speech) {
                        cycle_count += 1;
                        _ = try self.transcribeAndEmit(&pipeline, pcm_buf.items, true, output_fd, start_ns, type_cb, cycle_count, "FINAL");
                    }
                    const end_reason: EndReason = if (!live) .released else .timeout;
                    self.resetUtterance(&pipeline, &pcm_buf, &pcm_trim_total, end_reason);
                }
                if (client_closed) return;
                // After timeout flush, go idle with clean buffer
                pcm_trim_total += pcm_buf.items.len;
                pcm_buf.clearRetainingCapacity();
                state = .idle;
                cycle_count = 0;
                continue;
            }

            // VAD check on last 0.5s
            const t_vad = std.time.nanoTimestamp();
            const has_speech = blk: {
                const vad_start = if (pcm_buf.items.len > vad_window_bytes)
                    (pcm_buf.items.len - vad_window_bytes) & ~@as(usize, 1)
                else
                    0;
                const vad_samples = try utils.pcmToFloat(self.allocator, pcm_buf.items[vad_start..]);
                defer self.allocator.free(vad_samples);

                break :blk self.vad.hasSpeech(vad_samples);
            };
            const vad_ms = msFromNs(t_vad);

            // State machine
            var should_transcribe = false;
            var should_flush = false;

            var ts_buf: [32]u8 = undefined;

            switch (state) {
                .idle => {
                    if (has_speech) {
                        const ts = formatElapsed(&ts_buf, start_ns);
                        std.debug.print("[{s}s] idle → speaking (buf={d} vad={d:.1}ms)\n", .{ ts, pcm_buf.items.len, vad_ms });
                        state = .speaking;
                        should_transcribe = true;
                        if (self.recorder) |rec| {
                            rec.startUtterance(pcm_buf.items);
                            rec.logEvent(start_ns, "idle → speaking");
                        }
                    } else {
                        const old_len = pcm_buf.items.len;
                        utils.trimBuffer(&pcm_buf, idle_keep_bytes);
                        pcm_trim_total += old_len - pcm_buf.items.len;
                        continue;
                    }
                },
                .speaking => {
                    if (!has_speech) {
                        const ts = formatElapsed(&ts_buf, start_ns);
                        std.debug.print("[{s}s] speaking → trailing_silence (buf={d} vad={d:.1}ms)\n", .{ ts, pcm_buf.items.len, vad_ms });
                        state = .{ .trailing_silence = .{ .silence_start_pos = pcm_buf.items.len, .transcribe_done = false } };
                        if (self.recorder) |rec| rec.logEvent(start_ns, "speaking → trailing_silence");
                        // Transcribe before entering silence to capture trailing words
                        should_transcribe = true;
                    } else {
                        should_transcribe = true;
                    }
                },
                .trailing_silence => |*ts_state| {
                    if (has_speech) {
                        const ts = formatElapsed(&ts_buf, start_ns);
                        std.debug.print("[{s}s] trailing_silence → speaking (buf={d} vad={d:.1}ms)\n", .{ ts, pcm_buf.items.len, vad_ms });
                        state = .speaking;
                        if (self.recorder) |rec| rec.logEvent(start_ns, "trailing_silence → speaking");
                        should_transcribe = true;
                    } else if (pcm_buf.items.len - ts_state.silence_start_pos >= silence_timeout_bytes) {
                        should_flush = true;
                    } else if (!ts_state.transcribe_done) {
                        should_transcribe = true;
                        ts_state.transcribe_done = true;
                    }
                },
            }

            // Transcribe and emit delta
            if (should_transcribe or should_flush) {
                cycle_count += 1;
                const state_name: []const u8 = switch (state) {
                    .idle => "idle",
                    .speaking => "speaking",
                    .trailing_silence => "trailing",
                };
                _ = try self.transcribeAndEmit(&pipeline, pcm_buf.items, should_flush, output_fd, start_ns, type_cb, cycle_count, state_name);

                if (should_flush) {
                    self.resetUtterance(&pipeline, &pcm_buf, &pcm_trim_total, .flush);
                    const flush_ts = formatElapsed(&ts_buf, start_ns);
                    std.debug.print("[{s}s] flush → idle\n", .{flush_ts});
                    state = .idle;
                    cycle_count = 0;
                } else {
                    const old_len = pcm_buf.items.len;
                    utils.trimBuffer(&pcm_buf, max_buffer_bytes);
                    const trimmed = old_len - pcm_buf.items.len;
                    pcm_trim_total += trimmed;
                    // Keep silence_start_pos valid after trim
                    switch (state) {
                        .trailing_silence => |*ts_state| {
                            ts_state.silence_start_pos -|= trimmed;
                        },
                        else => {},
                    }
                    if (trimmed > 0) {
                        // Audio was trimmed from the front — mel cache is invalid.
                        pipeline.mel_buffer.reset();
                        // Demote front tokens from forced (after [notimestamps]) to
                        // conditioning (before [sot]). They no longer correspond to
                        // audio in the buffer but still provide context to the model.
                        try pipeline.demoteTokens(trimmed, old_len);
                    }
                }
            }
        }
    }
    const TranscribeResult = struct {
        emitted: bool,
    };

    fn transcribeAndEmit(
        self: *Server,
        pipeline: *Pipeline,
        pcm_buf: []const u8,
        is_last: bool,
        output_fd: posix.fd_t,
        start_ns: i128,
        type_cb: ?TypeCallback,
        cycle_count: usize,
        state_name: []const u8,
    ) !TranscribeResult {
        if (pcm_buf.len < min_transcribe_bytes) return .{ .emitted = false };

        const samples = try utils.pcmToFloat(self.allocator, pcm_buf);
        defer self.allocator.free(samples);

        const result = try pipeline.transcribe(samples, is_last) orelse {
            if (self.verbose) {
                var ts_buf: [32]u8 = undefined;
                const ts = formatElapsed(&ts_buf, start_ns);
                std.debug.print("    [{s}s] cycle={d} NULL buf={d}ms\n", .{
                    ts, cycle_count, pcm_buf.len * 1000 / 32000,
                });
            }
            return .{ .emitted = false };
        };
        defer self.allocator.free(result.text);
        defer self.allocator.free(result.words);
        defer self.allocator.free(result.tokens);

        if (result.text.len == 0 or result.was_rewind) {
            if (self.verbose) {
                var ts_buf: [32]u8 = undefined;
                const ts = formatElapsed(&ts_buf, start_ns);
                std.debug.print("    [{s}s] cycle={d} {s} buf={d}ms\n", .{
                    ts, cycle_count, if (result.was_rewind) "REWIND" else "empty", pcm_buf.len * 1000 / 32000,
                });
            }
            return .{ .emitted = false };
        }

        const buf_duration_ms = pcm_buf.len * 1000 / 32000;
        const t = result.timing;

        // Use result.text as-is: whisper BPE tokens include leading spaces for
        // word-initial tokens. Continuation tokens (no space) should concatenate
        // directly with the previous emission (e.g. "duplic" + "ation").
        const delta = try self.allocator.dupe(u8, result.text);
        defer self.allocator.free(delta);

        emitDelta(output_fd, start_ns, delta, type_cb, self.recorder) catch return error.BrokenPipe;
        try pipeline.commitTokens(result.tokens);

        if (self.verbose) {
            var ts_buf: [32]u8 = undefined;
            const ts = formatElapsed(&ts_buf, start_ns);
            const accum = pipeline.accumulated_tokens.items.len;
            const ctx = pipeline.context_tokens.items.len;
            std.debug.print("    [{s}s] cycle={d} {s} words={d} accum={d} ctx={d} buf={d}ms | {s} state={d:.0}ms mel={d:.0}ms enc={d:.0}ms dec={d:.0}ms({d}tok/{s}) total={d:.0}ms EMIT\n", .{
                ts, cycle_count, state_name, result.words.len, accum, ctx, buf_duration_ms,
                utils.textPreview(result.text), t.state_init_ms, t.mel_ms, t.encode_ms, t.decode_ms, t.tokens_generated, t.stop_reason, t.total_ms,
            });
        }

        if (self.recorder) |rec| {
            rec.logCycle(start_ns, cycle_count, state_name, buf_duration_ms, result.words.len, result.text);
        }

        return .{ .emitted = true };
    }

    fn resetUtterance(
        self: *Server,
        pipeline: *Pipeline,
        pcm_buf: *std.ArrayListUnmanaged(u8),
        pcm_trim_total: *usize,
        end_reason: EndReason,
    ) void {
        pipeline.resetSegment();
        if (self.recorder) |rec| rec.endUtterance(end_reason) catch |err| {
            std.debug.print("[rec] write error: {}\n", .{err});
        };
        pcm_trim_total.* += pcm_buf.items.len;
        pcm_buf.clearRetainingCapacity();
    }
};

fn msFromNs(start: i128) f64 {
    const elapsed: i128 = std.time.nanoTimestamp() - start;
    return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
}

/// Format elapsed time since start_ns as "{s}.{tenths}" into buf.
fn formatElapsed(buf: []u8, start_ns: i128) []u8 {
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    const elapsed_ms: u64 = @intCast(@max(0, @divTrunc(elapsed_ns, 1_000_000)));
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ elapsed_ms / 1000, (elapsed_ms % 1000) / 100 }) catch buf[0..3];
}

/// Write a timestamped delta to the output fd (or type callback) and log it.
fn emitDelta(output_fd: posix.fd_t, start_ns: i128, delta: []const u8, type_cb: ?TypeCallback, recorder: ?*Recorder) error{BrokenPipe}!void {
    var ts_buf: [32]u8 = undefined;
    const ts = formatElapsed(&ts_buf, start_ns);

    if (type_cb) |cb| {
        // Inject text as keystrokes (evdev mode)
        cb.call(delta);
    } else {
        // Write wire protocol to fd
        _ = posix.write(output_fd, ts) catch return error.BrokenPipe;
        _ = posix.write(output_fd, "\t") catch return error.BrokenPipe;
        _ = posix.write(output_fd, delta) catch return error.BrokenPipe;
        _ = posix.write(output_fd, "\n") catch return error.BrokenPipe;
    }
    std.debug.print("  [{s}s] >> {s}\n", .{ ts, delta });
    if (recorder) |rec| rec.logEmit(delta);
}

