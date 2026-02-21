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

// Streaming constants (byte counts for S16_LE at 16kHz = 32000 bytes/sec)
const transcribe_interval_bytes: usize = 32000; // 1s — re-transcribe cadence during speech
const vad_window_bytes: usize = 16000; // 0.5s — VAD lookback window for silence detection
const silence_timeout_bytes: usize = 64000; // 2s — silence before utterance flush
const max_buffer_bytes: usize = 960000; // 30s — sliding window cap (matches whisper's full 30s window)
const min_transcribe_bytes: usize = 16000; // 0.5s — minimum audio worth transcribing

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

        var vad_filter = VadFilter.init(self.allocator, &self.vad);
        defer vad_filter.deinit();

        var auto_gain = AutoGain{};

        const start_ns = std.time.nanoTimestamp();

        var pcm_buf = std.ArrayListUnmanaged(u8){};
        defer pcm_buf.deinit(self.allocator);

        var pcm_trim_total: usize = 0;
        var recv_buf: [32768]u8 = undefined;
        var bytes_since_last_cycle: usize = 0;
        var cycle_count: usize = 0;
        var speaking = false;
        var was_live: bool = is_live.load(.monotonic);
        var ptt_tracking_press_ns: i128 = 0;
        // Segmentation: use hasSpeech on last 500ms of pcm_buf.
        // When silence is first detected, record position. After 2s of sustained
        // silence, flush and reset.
        var silence_start_pos: ?usize = null;
        var bytes_since_last_vad: usize = 0;

        while (true) {
            // ── Poll ──────────────────────────────────────────────
            var fds = [_]posix.pollfd{.{
                .fd = audio_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const poll_timeout: i32 = if (speaking) 100 else -1;
            const poll_ready = try posix.poll(&fds, poll_timeout);

            var n: usize = 0;
            var timed_out = false;
            if (poll_ready == 0) {
                timed_out = true;
            } else {
                n = posix.read(audio_fd, &recv_buf) catch |err| switch (err) {
                    error.ConnectionResetByPeer => return,
                    else => return err,
                };
            }

            const client_closed = (!timed_out and n == 0);

            // ── Layer 1: PTT Gate ─────────────────────────────────
            const live = is_live.load(.monotonic);

            // PTT release edge
            if (was_live and !live) {
                was_live = false;
                ptt_tracking_press_ns = 0;
                if (self.recorder) |rec| rec.logEvent(start_ns, "PTT released");
                if (speaking) {
                    if (pcm_buf.items.len >= min_transcribe_bytes) {
                        cycle_count += 1;
                        _ = try self.transcribeAndEmit(&pipeline, pcm_buf.items, true, output_fd, start_ns, type_cb, cycle_count, "ptt-flush");
                    }
                    self.resetUtterance(&pipeline, &pcm_buf, &pcm_trim_total, &vad_filter, .released);
                    speaking = false;
                    cycle_count = 0;
                    silence_start_pos = null;
                    bytes_since_last_vad = 0;
                }
                pcm_trim_total += pcm_buf.items.len;
                pcm_buf.clearRetainingCapacity();
                continue;
            }

            // PTT press edge
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
                vad_filter.reset();
                speaking = false;
                cycle_count = 0;
                silence_start_pos = null;
                bytes_since_last_vad = 0;
                was_live = true;
                pcm_trim_total += pcm_buf.items.len;
                pcm_buf.clearRetainingCapacity();
                if (self.recorder) |rec| rec.logEvent(start_ns, "PTT pressed");
            }

            // Not live — discard everything
            if (!live) {
                pcm_trim_total += pcm_buf.items.len;
                pcm_buf.clearRetainingCapacity();
                if (client_closed) return;
                continue;
            }

            // ── Layer 2: VAD Segmentation ─────────────────────────
            // All audio goes to pcm_buf unfiltered. hasSpeech (500ms window,
            // threshold=0.2) drives all state transitions — same as old code.
            if (n > 0) {
                if (self.recorder) |rec| rec.recordPcm(recv_buf[0..n]);

                try pcm_buf.appendSlice(self.allocator, recv_buf[0..n]);
                bytes_since_last_cycle += n;
                bytes_since_last_vad += n;

                // Throttle: match the old 3-state code's check cadence.
                // During speech (no silence detected): check every 1s — brief inter-word
                // pauses (<1s) are never seen, preventing false segmentation.
                // During silence tracking or idle: check every 0.5s — fast detection of
                // speech resumption or onset.
                const vad_interval: usize = if (speaking and silence_start_pos == null) transcribe_interval_bytes else vad_window_bytes;
                if (bytes_since_last_vad >= vad_interval and pcm_buf.items.len >= vad_window_bytes) {
                    bytes_since_last_vad = 0;
                    const vad_start = (pcm_buf.items.len - vad_window_bytes) & ~@as(usize, 1);
                    const n_samples = vad_window_bytes / 2;
                    var vad_float_buf: [n_samples]f32 = undefined;
                    for (&vad_float_buf, 0..) |*sample, i| {
                        const offset = vad_start + i * 2;
                        const raw = std.mem.readInt(i16, pcm_buf.items[offset..][0..2], .little);
                        sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
                    }
                    const has_speech = self.vad.hasSpeech(&vad_float_buf);

                    // Auto-gain: measure speech level during confirmed speech
                    if (speaking and has_speech) {
                        const rms = utils.channelRms(recv_buf[0..n], 1, 0);
                        if (auto_gain.update(rms)) |new_gain| {
                            if (capture_ptr.load(.monotonic)) |cap| {
                                cap.setGain(new_gain);
                            }
                            if (self.verbose) {
                                std.debug.print("  auto-gain: {d:.2}x\n", .{new_gain});
                            }
                        }
                    }

                    if (!speaking and has_speech) {
                        // Speech onset
                        var ts_buf: [32]u8 = undefined;
                        const ts = formatElapsed(&ts_buf, start_ns);
                        std.debug.print("[{s}s] speech onset (buf={d})\n", .{ ts, pcm_buf.items.len });
                        pipeline.resetSegment();
                        speaking = true;
                        cycle_count = 0;
                        bytes_since_last_cycle = pcm_buf.items.len;
                        silence_start_pos = null;
                        if (self.recorder) |rec| {
                            rec.startUtterance(pcm_buf.items);
                            rec.logEvent(start_ns, "speech onset");
                        }
                    } else if (speaking and has_speech) {
                        silence_start_pos = null;
                    } else if (speaking and !has_speech) {
                        if (silence_start_pos == null) {
                            silence_start_pos = pcm_buf.items.len;
                        }
                        const silence_bytes = pcm_buf.items.len - silence_start_pos.?;
                        if (silence_bytes >= silence_timeout_bytes) {
                            if (pcm_buf.items.len >= min_transcribe_bytes) {
                                cycle_count += 1;
                                const emit_result = try self.transcribeAndEmit(&pipeline, pcm_buf.items, true, output_fd, start_ns, type_cb, cycle_count, "silence-flush");
                                if (emit_result.emitted and ptt_tracking_press_ns != 0) {
                                    std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                                    ptt_tracking_press_ns = 0;
                                }
                            }
                            var ts_buf: [32]u8 = undefined;
                            const flush_ts = formatElapsed(&ts_buf, start_ns);
                            std.debug.print("[{s}s] silence timeout → idle (silence={d}ms)\n", .{ flush_ts, silence_bytes * 1000 / 32000 });
                            self.resetUtterance(&pipeline, &pcm_buf, &pcm_trim_total, &vad_filter, .flush);
                            speaking = false;
                            cycle_count = 0;
                            bytes_since_last_cycle = 0;
                            silence_start_pos = null;
                            bytes_since_last_vad = 0;
                        }
                    }
                }
            }

            // ── Disconnect / timeout ──────────────────────────────
            if (client_closed or timed_out) {
                if (speaking and pcm_buf.items.len >= min_transcribe_bytes) {
                    cycle_count += 1;
                    const emit_result = try self.transcribeAndEmit(&pipeline, pcm_buf.items, true, output_fd, start_ns, type_cb, cycle_count, "FINAL");
                    if (emit_result.emitted and ptt_tracking_press_ns != 0) {
                        std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                        ptt_tracking_press_ns = 0;
                    }
                    const end_reason: EndReason = if (!live) .released else .timeout;
                    self.resetUtterance(&pipeline, &pcm_buf, &pcm_trim_total, &vad_filter, end_reason);
                    speaking = false;
                    cycle_count = 0;
                }
                if (client_closed) return;
                if (!speaking) {
                    pcm_trim_total += pcm_buf.items.len;
                    pcm_buf.clearRetainingCapacity();
                }
                continue;
            }

            // ── Layer 3: Pipeline Processing ──────────────────────
            if (!speaking) {
                pcm_trim_total += pcm_buf.items.len;
                pcm_buf.clearRetainingCapacity();
                bytes_since_last_cycle = 0;
                continue;
            }

            // Throttle: wait for 1s of speech before transcribing
            if (bytes_since_last_cycle < transcribe_interval_bytes) continue;
            if (pcm_buf.items.len < min_transcribe_bytes) continue;
            bytes_since_last_cycle = 0;

            // Transcribe
            cycle_count += 1;
            const emit_result = try self.transcribeAndEmit(&pipeline, pcm_buf.items, false, output_fd, start_ns, type_cb, cycle_count, "speaking");
            if (emit_result.emitted and ptt_tracking_press_ns != 0) {
                std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                ptt_tracking_press_ns = 0;
            }

            // Sliding window trim
            const old_len = pcm_buf.items.len;
            utils.trimBuffer(&pcm_buf, max_buffer_bytes);
            const trimmed = old_len - pcm_buf.items.len;
            pcm_trim_total += trimmed;
            if (trimmed > 0) {
                // Adjust silence_start_pos so it stays valid after front-trim
                if (silence_start_pos) |ssp| {
                    silence_start_pos = if (ssp > trimmed) ssp - trimmed else 0;
                }
                try pipeline.handleTrim(trimmed);
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
        flush: bool,
        output_fd: posix.fd_t,
        start_ns: i128,
        type_cb: ?TypeCallback,
        cycle_count: usize,
        state_name: []const u8,
    ) !TranscribeResult {
        if (pcm_buf.len < min_transcribe_bytes) return .{ .emitted = false };

        const samples = try utils.pcmToFloat(self.allocator, pcm_buf);
        defer self.allocator.free(samples);

        const result = try pipeline.transcribe(samples, flush, null) orelse {
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
        defer self.allocator.free(result.token_frames);

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
        try pipeline.commitTokens(result.tokens, result.token_frames);

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
        vad_filter: *VadFilter,
        end_reason: EndReason,
    ) void {
        pipeline.resetSegment();
        vad_filter.reset();
        if (self.recorder) |rec| rec.endUtterance(end_reason) catch |err| {
            std.debug.print("[rec] write error: {}\n", .{err});
        };
        pcm_trim_total.* += pcm_buf.items.len;
        pcm_buf.clearRetainingCapacity();
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

