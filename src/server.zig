const std = @import("std");
const c = @import("whisper_c.zig");
const vad_mod = @import("vad.zig");
const Vad = vad_mod.Vad;
const VadFilter = vad_mod.VadFilter;
const Pipeline = @import("pipeline.zig").Pipeline;
const AudioCapture = @import("audio_capture.zig").AudioCapture;
const AutoGain = @import("auto_gain.zig").AutoGain;
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

// Low-latency mode: cork/uncork stream instead of connect/disconnect.
// Set once during init, read from input thread via setLive().
var use_cork_mode = std.atomic.Value(bool).init(false);

// PTT latency tracking — set by input thread via setLive(), read by server loop.
var ptt_press_ns = std.atomic.Value(i128).init(0);
var pw_connect_done_ns = std.atomic.Value(i128).init(0);

pub fn setLive(live: bool) void {
    if (live) ptt_press_ns.store(std.time.nanoTimestamp(), .monotonic);
    is_live.store(live, .monotonic);
    if (capture_ptr.load(.monotonic)) |cap| {
        if (use_cork_mode.load(.monotonic)) {
            cap.setCork(!live);
        } else {
            cap.setActive(live);
        }
        if (live) pw_connect_done_ns.store(std.time.nanoTimestamp(), .monotonic);
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

/// S16_LE-aligned reader. Wraps a raw fd and ensures every read returns
/// an even number of bytes (complete S16 samples). Stashes a trailing
/// odd byte between reads so the stream stays aligned.
const AlignedReader = struct {
    fd: posix.fd_t,
    buf: [32769]u8 = undefined, // +1 for carry prepend
    carry: ?u8 = null,

    fn init(fd: posix.fd_t) AlignedReader {
        return .{ .fd = fd };
    }

    /// Read S16-aligned audio. Returns a slice of complete samples,
    /// or empty slice on EOF. Caller does not own the returned memory.
    fn read(self: *AlignedReader) ![]u8 {
        const start: usize = if (self.carry != null) 1 else 0;
        var n = posix.read(self.fd, self.buf[start..]) catch |err| switch (err) {
            error.ConnectionResetByPeer => return &.{},
            else => return err,
        };
        if (n == 0) return &.{};
        if (self.carry) |cb| {
            self.buf[0] = cb;
            n += 1;
            self.carry = null;
        }
        if (n % 2 != 0) {
            n -= 1;
            self.carry = self.buf[n];
        }
        return self.buf[0..n];
    }
};

// Streaming constants (byte counts for S16_LE at 16kHz = 32000 bytes/sec)
const transcribe_interval_bytes: usize = 32000; // 1s — re-transcribe cadence during speech
const max_buffer_bytes: usize = 960000; // 30s — sliding window cap (matches whisper's full 30s window)
const min_transcribe_bytes: usize = 16000; // 0.5s — minimum audio worth transcribing

// VadFilter drives all segmentation. No hasSpeech polling — only two states.
const VadState = enum { idle, speaking };

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
    low_latency: bool,
    type_callback: ?TypeCallback,
    prompt_tokens: []const c.whisper_token,
    recorder: ?*Recorder,
    initial_gain: f32,
    vad_threshold: f32,
    vad_threshold_off: f32,
    min_silence_bytes: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *c.whisper_context,
        vad: Vad,
        port: u16,
        input_mode: InputMode,
        pw_target: ?[:0]const u8,
        pw_channel: u32,
        verbose: bool,
        low_latency: bool,
        type_callback: ?TypeCallback,
        prompt_tokens: []const c.whisper_token,
        recorder: ?*Recorder,
        initial_gain: f32,
        vad_threshold: f32,
        vad_threshold_off: f32,
        min_silence_bytes: usize,
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
            .low_latency = low_latency,
            .type_callback = type_callback,
            .prompt_tokens = prompt_tokens,
            .recorder = recorder,
            .initial_gain = initial_gain,
            .vad_threshold = vad_threshold,
            .vad_threshold_off = vad_threshold_off,
            .min_silence_bytes = min_silence_bytes,
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
        capture_ptr.store(&capture, .monotonic);
        defer capture_ptr.store(null, .monotonic);

        // Apply calibrated initial gain (from --pw-gain) before first audio arrives
        if (self.initial_gain > 1.01) {
            capture.setGain(self.initial_gain);
            std.debug.print("Auto-gain starting at {d:.1}x\n", .{self.initial_gain});
        }

        if (self.low_latency) {
            // Low-latency mode: connect stream once at startup, use cork/uncork for PTT.
            // Mic indicator stays visible, but avoids ~1.3s PipeWire reconnect on each press.
            use_cork_mode.store(true, .monotonic);
            capture.setActive(true);
            if (!is_live.load(.monotonic)) {
                capture.setCork(true);
            }
            std.debug.print("Low-latency mode: stream stays connected, using cork/uncork\n", .{});
        } else if (is_live.load(.monotonic)) {
            // Normal mode: connect now (no --trigger, always live).
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

        var auto_gain = AutoGain{ .current_gain = self.initial_gain };

        var vad_filter = VadFilter.init(self.allocator, &self.vad, .{
            .threshold = self.vad_threshold,
            .threshold_off = self.vad_threshold_off,
            .min_silence_bytes = self.min_silence_bytes,
        });
        defer vad_filter.deinit();

        const start_ns = std.time.nanoTimestamp();

        // Speech buffer — only contains audio during confirmed speech (after VadFilter onset).
        // Never contains silence. Fed to pipeline.transcribe().
        var speech_buf = std.ArrayListUnmanaged(u8){};
        defer speech_buf.deinit(self.allocator);

        var speech_trim_total: usize = 0; // cumulative bytes trimmed (for absolute frame calc)

        var reader = AlignedReader.init(audio_fd);
        var vad_state: VadState = .idle;
        var bytes_since_last_cycle: usize = 0;
        var cycle_count: usize = 0;
        var was_live: bool = is_live.load(.monotonic);
        var ptt_tracking_press_ns: i128 = 0;

        while (true) {
            // Poll: short wakeup during speech (for timeout flush), block forever when idle
            var fds = [_]posix.pollfd{.{
                .fd = audio_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const poll_timeout: i32 = if (vad_state == .speaking) 100 else -1;
            const poll_ready = try posix.poll(&fds, poll_timeout);

            var timed_out = false;
            var audio: []u8 = &.{};
            if (poll_ready == 0) {
                timed_out = true;
            } else {
                audio = try reader.read();
            }
            const n = audio.len;

            // --- Audio input processing ---
            if (n > 0) {
                if (self.recorder) |rec| rec.recordPcm(audio);

                // VadFilter: run on raw audio for edge detection (handles any size via pcm_partial)
                const was_triggered = vad_filter.triggered;
                _ = vad_filter.filterAudio(audio);

                // VadFilter onset edge: idle → speaking
                if (!was_triggered and vad_filter.triggered and vad_state == .idle) {
                    vad_state = .speaking;
                    pipeline.resetSegment();
                    try speech_buf.appendSlice(self.allocator, audio);
                    bytes_since_last_cycle += audio.len;
                    var ts_buf: [32]u8 = undefined;
                    std.debug.print("[{s}s] idle → speaking (buf={d})\n", .{ formatElapsed(&ts_buf, start_ns), speech_buf.items.len });
                    if (self.recorder) |rec| {
                        rec.startUtterance(speech_buf.items);
                        rec.logEvent(start_ns, "idle → speaking");
                    }
                } else if (vad_state == .speaking) {
                    try speech_buf.appendSlice(self.allocator, audio);
                    bytes_since_last_cycle += audio.len;
                }

                // Auto-gain: only in PipeWire mode (measures capture audio, adjusts gain)
                if (vad_state == .speaking) {
                    if (capture_ptr.load(.monotonic)) |cap| {
                        const rms = utils.channelRms(audio, 1, 0);
                        if (auto_gain.update(rms)) |new_gain| {
                            cap.setGain(new_gain);
                            if (self.verbose) {
                                std.debug.print("  auto-gain: {d:.2}x\n", .{new_gain});
                            }
                        }
                    }
                }

                // VadFilter offset edge: speaking → flush → idle
                if (was_triggered and !vad_filter.triggered and vad_state == .speaking) {
                    if (speech_buf.items.len >= min_transcribe_bytes) {
                        cycle_count += 1;
                        const flush_emit = try self.transcribeAndEmit(&pipeline, speech_buf.items, true, output_fd, start_ns, type_cb, cycle_count, "vad-flush");
                        if (flush_emit.emitted and ptt_tracking_press_ns != 0) {
                            std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                            ptt_tracking_press_ns = 0;
                        }
                    }
                    var ts_buf: [32]u8 = undefined;
                    std.debug.print("[{s}s] flush → idle\n", .{formatElapsed(&ts_buf, start_ns)});
                    self.resetUtterance(&pipeline, &speech_buf, &speech_trim_total, &vad_filter, .flush);
                    vad_state = .idle;
                    cycle_count = 0;
                    bytes_since_last_cycle = 0;
                    continue;
                }
            }

            const client_closed = (!timed_out and n == 0);

            // --- PTT gating ---
            const live = is_live.load(.monotonic);

            // PTT release edge
            if (was_live and !live) {
                was_live = false;
                ptt_tracking_press_ns = 0;
                if (self.recorder) |rec| rec.logEvent(start_ns, "PTT released");
                if (vad_state == .speaking) {
                    // Flush active speech immediately on PTT release
                    if (speech_buf.items.len >= min_transcribe_bytes) {
                        cycle_count += 1;
                        const flush_emit = try self.transcribeAndEmit(&pipeline, speech_buf.items, true, output_fd, start_ns, type_cb, cycle_count, "ptt-release");
                        if (flush_emit.emitted and ptt_tracking_press_ns != 0) {
                            std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                        }
                    }
                    var ts_buf: [32]u8 = undefined;
                    std.debug.print("[{s}s] flush → idle\n", .{formatElapsed(&ts_buf, start_ns)});
                    self.resetUtterance(&pipeline, &speech_buf, &speech_trim_total, &vad_filter, .released);
                } else {
                    speech_trim_total += speech_buf.items.len;
                    speech_buf.clearRetainingCapacity();
                    vad_filter.reset();
                }
                vad_state = .idle;
                cycle_count = 0;
                bytes_since_last_cycle = 0;
                continue;
            }

            // Not live and idle: discard, wait for key press
            if (!live and vad_state == .idle) {
                if (speech_buf.items.len > 0) {
                    speech_trim_total += speech_buf.items.len;
                    speech_buf.clearRetainingCapacity();
                    vad_filter.reset();
                }
                if (client_closed) return;
                continue;
            }

            // PTT press edge: go live
            if (!was_live and live) {
                const live_detected_ns = std.time.nanoTimestamp();
                var ts_buf2: [32]u8 = undefined;
                const ts2 = formatElapsed(&ts_buf2, start_ns);
                const press = ptt_press_ns.load(.monotonic);
                const connect = pw_connect_done_ns.load(.monotonic);
                if (press > 0 and connect > 0) {
                    ptt_tracking_press_ns = press;
                    std.debug.print("[{s}s] LIVE (press→connect={d:.0}ms connect→audio={d:.0}ms)\n", .{
                        ts2, nsToF64Ms(connect - press), nsToF64Ms(live_detected_ns - connect),
                    });
                } else {
                    std.debug.print("[{s}s] LIVE\n", .{ts2});
                }
                vad_state = .idle;
                cycle_count = 0;
                bytes_since_last_cycle = 0;
                was_live = true;
                vad_filter.reset();
                speech_trim_total += speech_buf.items.len;
                speech_buf.clearRetainingCapacity();
                if (self.recorder) |rec| rec.logEvent(start_ns, "PTT pressed");
            }

            // --- Final flush on disconnect or timeout ---
            if (client_closed or timed_out) {
                if (vad_state == .speaking and speech_buf.items.len >= min_transcribe_bytes) {
                    cycle_count += 1;
                    const flush_emit = try self.transcribeAndEmit(&pipeline, speech_buf.items, true, output_fd, start_ns, type_cb, cycle_count, "FINAL");
                    if (flush_emit.emitted and ptt_tracking_press_ns != 0) {
                        std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                        ptt_tracking_press_ns = 0;
                    }
                    const end_reason: EndReason = if (!live) .released else .timeout;
                    self.resetUtterance(&pipeline, &speech_buf, &speech_trim_total, &vad_filter, end_reason);
                }
                if (client_closed) return;
                speech_trim_total += speech_buf.items.len;
                speech_buf.clearRetainingCapacity();
                vad_filter.reset();
                vad_state = .idle;
                cycle_count = 0;
                bytes_since_last_cycle = 0;
                continue;
            }

            // --- Periodic transcription during speech ---
            if (vad_state == .speaking and bytes_since_last_cycle >= transcribe_interval_bytes) {
                bytes_since_last_cycle = 0;
                cycle_count += 1;
                const emit_result = try self.transcribeAndEmit(&pipeline, speech_buf.items, false, output_fd, start_ns, type_cb, cycle_count, "speaking");
                if (emit_result.emitted and ptt_tracking_press_ns != 0) {
                    std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                    ptt_tracking_press_ns = 0;
                }

                // Sliding window trim
                const old_len = speech_buf.items.len;
                utils.trimBuffer(&speech_buf, max_buffer_bytes);
                const trimmed = old_len - speech_buf.items.len;
                speech_trim_total += trimmed;
                if (trimmed > 0) {
                    try pipeline.handleTrim(trimmed);
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
        speech_buf: []const u8,
        flush: bool,
        output_fd: posix.fd_t,
        start_ns: i128,
        type_cb: ?TypeCallback,
        cycle_count: usize,
        state_name: []const u8,
    ) !TranscribeResult {
        if (speech_buf.len < min_transcribe_bytes) return .{ .emitted = false };

        const samples = try utils.pcmToFloat(self.allocator, speech_buf);
        defer self.allocator.free(samples);




        const result = try pipeline.transcribe(samples, flush, null) orelse {
            if (self.verbose) {
                var ts_buf: [32]u8 = undefined;
                const ts = formatElapsed(&ts_buf, start_ns);
                std.debug.print("    [{s}s] cycle={d} NULL buf={d}ms\n", .{
                    ts, cycle_count, speech_buf.len * 1000 / 32000,
                });
            }
            return .{ .emitted = false };
        };
        defer self.allocator.free(result.text);
        defer self.allocator.free(result.words);
        defer self.allocator.free(result.tokens);
        defer self.allocator.free(result.token_frames);

        if (result.text.len == 0 or result.was_rewind) {
            if (self.verbose) {
                var ts_buf: [32]u8 = undefined;
                const ts = formatElapsed(&ts_buf, start_ns);
                std.debug.print("    [{s}s] cycle={d} {s} buf={d}ms\n", .{
                    ts, cycle_count, if (result.was_rewind) "REWIND" else "empty", speech_buf.len * 1000 / 32000,
                });
            }
            return .{ .emitted = false };
        }

        const buf_duration_ms = speech_buf.len * 1000 / 32000;
        const t = result.timing;

        // Use result.text as-is: whisper BPE tokens include leading spaces for
        // word-initial tokens. Continuation tokens (no space) should concatenate
        // directly with the previous emission (e.g. "duplic" + "ation").
        const delta = try self.allocator.dupe(u8, result.text);
        defer self.allocator.free(delta);

        emitDelta(output_fd, start_ns, delta, type_cb, self.recorder) catch return error.BrokenPipe;
        try pipeline.commitTokens(result.tokens, result.token_frames);

        if (self.verbose) {
            var ts_buf: [32]u8 = undefined;
            const ts = formatElapsed(&ts_buf, start_ns);
            std.debug.print("    [{s}s] cycle={d} {s} words={d} buf={d}ms | {s} state={d:.0}ms mel={d:.0}ms enc={d:.0}ms dec={d:.0}ms({d}tok/{s}) total={d:.0}ms EMIT\n", .{
                ts, cycle_count, state_name, result.words.len, buf_duration_ms,
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
        speech_buf: *std.ArrayListUnmanaged(u8),
        speech_trim_total: *usize,
        vad_filter: *VadFilter,
        end_reason: EndReason,
    ) void {
        pipeline.resetSegment();
        vad_filter.reset();
        if (self.recorder) |rec| rec.endUtterance(end_reason) catch |err| {
            std.debug.print("[rec] write error: {}\n", .{err});
        };
        speech_trim_total.* += speech_buf.items.len;
        speech_buf.clearRetainingCapacity();
    }
};

fn nsToF64Ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

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
