const std = @import("std");
const c = @import("whisper_c.zig");
const vad_mod = @import("vad.zig");
const VadBackend = vad_mod.VadBackend;
const VadFilter = vad_mod.VadFilter;
const Pipeline = @import("pipeline.zig").Pipeline;
const AudioCapture = @import("audio_capture.zig").AudioCapture;
const AutoGain = @import("auto_gain.zig").AutoGain;
const utils = @import("utils.zig");
const recorder_mod = @import("recorder.zig");
const Recorder = recorder_mod.Recorder;

const posix = std.posix;
const net = std.net;

// Global live state (module-level so input handler can access it via setLive).
// Default not-live. Callers set it explicitly: runTcp on accept/disconnect,
// main.zig for no-trigger local mode, trigger key press/release.
pub var is_live = std.atomic.Value(bool).init(false);

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

/// Chunked audio reader. Buffers raw reads and yields exactly `chunk_size`
/// bytes at a time, ensuring every transport (TCP, PipeWire pipe, etc.)
/// delivers identical chunk boundaries to the VAD and server loop.
/// This makes VAD edge detection deterministic regardless of read() granularity.
const ChunkedReader = struct {
    fd: posix.fd_t,
    chunk_size: usize,
    buf: [32768]u8 = undefined,
    buffered: usize = 0, // bytes available in buf[0..buffered]
    offset: usize = 0, // read cursor within buf[0..buffered]
    saw_eof: bool = false,

    fn init(fd: posix.fd_t, chunk_size: usize) ChunkedReader {
        return .{ .fd = fd, .chunk_size = chunk_size };
    }

    /// Read exactly one chunk of audio, or empty slice on EOF.
    /// Caller does not own the returned memory.
    fn read(self: *ChunkedReader) ![]u8 {
        // Compact: move unconsumed data to front
        if (self.offset > 0 and self.buffered > self.offset) {
            const remaining = self.buffered - self.offset;
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.offset..self.buffered]);
            self.buffered = remaining;
            self.offset = 0;
        } else if (self.offset > 0) {
            self.buffered = 0;
            self.offset = 0;
        }

        // Fill buffer until we have a full chunk (or EOF)
        while (self.buffered < self.chunk_size) {
            if (self.saw_eof) return &.{};
            const n = posix.read(self.fd, self.buf[self.buffered..]) catch |err| switch (err) {
                error.ConnectionResetByPeer => return &.{},
                else => return err,
            };
            if (n == 0) {
                self.saw_eof = true;
                // Return whatever we have (partial final chunk) — S16-aligned
                if (self.buffered > self.offset) {
                    var len = self.buffered - self.offset;
                    len -= len % 2; // ensure even number of bytes
                    if (len > 0) {
                        const start = self.offset;
                        self.offset += len;
                        return self.buf[start..start + len];
                    }
                }
                return &.{};
            }
            self.buffered += n;
        }

        // Yield exactly one chunk
        const start = self.offset;
        self.offset += self.chunk_size;
        return self.buf[start..start + self.chunk_size];
    }
};

// Streaming constants (S16_LE at 16kHz = 32000 bytes/sec)
const bytes_per_second: usize = 16000 * 2; // sample_rate * bytes_per_sample
const transcribe_interval_bytes: usize = bytes_per_second; // 1s — re-transcribe cadence during speech
const max_buffer_bytes: usize = bytes_per_second * 30; // 30s — sliding window cap (matches whisper's full 30s window)
const min_transcribe_bytes: usize = bytes_per_second / 2; // 0.5s — minimum audio worth transcribing

// VadFilter drives all segmentation. No hasSpeech polling — only two states.
const VadState = enum { idle, speaking };

pub const InputMode = enum { tcp, local };

pub const Server = struct {
    allocator: std.mem.Allocator,
    ctx: *c.whisper_context,
    vad_backend: VadBackend,
    port: u16,
    input_mode: InputMode,
    pw_target: ?[:0]const u8,
    pw_channel: u32,
    verbose: bool,
    low_latency: bool,
    type_callback: ?TypeCallback,
    prompt_tokens: []const c.whisper_token,
    drop_terms: []const []const u8,
    recorder: ?*Recorder,
    initial_gain: f32,
    no_auto_gain: bool,
    vad_threshold: f32,
    vad_threshold_off: f32,
    min_silence_bytes: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *c.whisper_context,
        vad_backend: VadBackend,
        port: u16,
        input_mode: InputMode,
        pw_target: ?[:0]const u8,
        pw_channel: u32,
        verbose: bool,
        low_latency: bool,
        type_callback: ?TypeCallback,
        prompt_tokens: []const c.whisper_token,
        drop_terms: []const []const u8,
        recorder: ?*Recorder,
        initial_gain: f32,
        no_auto_gain: bool,
        vad_threshold: f32,
        vad_threshold_off: f32,
        min_silence_bytes: usize,
    ) Server {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .vad_backend = vad_backend,
            .port = port,
            .input_mode = input_mode,
            .pw_target = pw_target,
            .pw_channel = pw_channel,
            .verbose = verbose,
            .low_latency = low_latency,
            .type_callback = type_callback,
            .prompt_tokens = prompt_tokens,
            .drop_terms = drop_terms,
            .recorder = recorder,
            .initial_gain = initial_gain,
            .no_auto_gain = no_auto_gain,
            .vad_threshold = vad_threshold,
            .vad_threshold_off = vad_threshold_off,
            .min_silence_bytes = min_silence_bytes,
        };
    }

    pub fn run(self: *Server) !void {
        switch (self.input_mode) {
            .tcp => try self.runTcp(),
            .local => try self.runPipeWire(),
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
            setLive(true);
            if (self.recorder) |rec| rec.startRecording();
            self.handleConnection(conn, conn, self.type_callback) catch |err| {
                std.debug.print("Connection error: {}\n", .{err});
            };
            if (self.recorder) |rec| rec.endRecording() catch |err| {
                std.debug.print("[rec] write error: {}\n", .{err});
            };
            setLive(false);
            std.debug.print("Client disconnected\n", .{});
        }
    }

    fn runPipeWire(self: *Server) !void {
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

        var vad_filter = VadFilter.init(self.allocator, self.vad_backend, .{
            .threshold = self.vad_threshold,
            .threshold_off = self.vad_threshold_off,
            .min_silence_bytes = self.min_silence_bytes,
        });
        defer vad_filter.deinit();

        // Speech buffer — only contains audio during confirmed speech (after VadFilter onset).
        // Never contains silence. Fed to pipeline.transcribe().
        var speech_buf = std.ArrayListUnmanaged(u8){};
        defer speech_buf.deinit(self.allocator);

        var speech_trim_total: usize = 0; // cumulative bytes trimmed (for absolute frame calc)

        var reader = ChunkedReader.init(audio_fd, vad_filter.chunk_size);
        var vad_state: VadState = .idle;
        var bytes_since_last_cycle: usize = 0;
        var cycle_count: usize = 0;
        var was_live: bool = is_live.load(.monotonic);
        var ptt_tracking_press_ns: i128 = 0;
        var total_audio_bytes: usize = 0; // audio-position clock (32000 bytes/sec)

        while (true) {
            const audio = try reader.read();
            const n = audio.len;
            total_audio_bytes += n;

            // --- Audio input processing ---
            if (n > 0) {
                if (self.recorder) |rec| rec.recordPcm(audio);

                // VadFilter: run on raw audio for edge detection (handles any size via pcm_partial)
                const was_triggered = vad_filter.triggered;
                const vad_event = vad_filter.filterAudio(audio);

                // VadFilter onset edge: idle → speaking
                if (!was_triggered and vad_filter.triggered and vad_state == .idle) {
                    vad_state = .speaking;
                    pipeline.resetSegment();
                    try speech_buf.appendSlice(self.allocator, audio);
                    bytes_since_last_cycle += audio.len;
                    var ts_buf: [32]u8 = undefined;
                    std.debug.print("[{s}s] idle → speaking (buf={d})\n", .{ formatAudioTime(&ts_buf, total_audio_bytes), speech_buf.items.len });
                    if (self.recorder) |rec| rec.logEvent(total_audio_bytes, "idle → speaking");
                } else if (vad_state == .speaking) {
                    try speech_buf.appendSlice(self.allocator, audio);
                    bytes_since_last_cycle += audio.len;
                }

                // Auto-gain: only in PipeWire mode (measures capture audio, adjusts gain)
                if (vad_state == .speaking and !self.no_auto_gain) {
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
                    // Trim trailing silence, but keep 375ms safety buffer for whisper context
                    const safety_buffer: usize = 12000; // 375ms at 32000 bytes/sec
                    const silence_trim = vad_event.trailing_silence_bytes;
                    const trim_amount = if (silence_trim > safety_buffer) silence_trim - safety_buffer else 0;
                    if (trim_amount > 0 and trim_amount < speech_buf.items.len) {
                        speech_buf.items.len -= trim_amount;
                    }
                    if (speech_buf.items.len >= min_transcribe_bytes) {
                        cycle_count += 1;
                        const flush_emit = try self.transcribeAndEmit(&pipeline, speech_buf.items, true, output_fd, total_audio_bytes, type_cb, cycle_count, "vad-flush");
                        if (flush_emit.emitted and ptt_tracking_press_ns != 0) {
                            std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                            ptt_tracking_press_ns = 0;
                        }
                    }
                    var ts_buf: [32]u8 = undefined;
                    std.debug.print("[{s}s] flush → idle\n", .{formatAudioTime(&ts_buf, total_audio_bytes)});
                    self.resetUtterance(&pipeline, &speech_buf, &speech_trim_total, &vad_filter);
                    vad_state = .idle;
                    cycle_count = 0;
                    bytes_since_last_cycle = 0;
                    continue;
                }
            }

            const client_closed = (n == 0);

            // --- PTT gating ---
            const live = is_live.load(.monotonic);

            // PTT release edge
            if (was_live and !live) {
                was_live = false;
                ptt_tracking_press_ns = 0;
                if (self.recorder) |rec| rec.logEvent(total_audio_bytes, "PTT released");
                if (vad_state == .speaking) {
                    // Flush active speech immediately on PTT release
                    if (speech_buf.items.len >= min_transcribe_bytes) {
                        cycle_count += 1;
                        const flush_emit = try self.transcribeAndEmit(&pipeline, speech_buf.items, true, output_fd, total_audio_bytes, type_cb, cycle_count, "ptt-release");
                        if (flush_emit.emitted and ptt_tracking_press_ns != 0) {
                            std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                        }
                    }
                    var ts_buf: [32]u8 = undefined;
                    std.debug.print("[{s}s] flush → idle\n", .{formatAudioTime(&ts_buf, total_audio_bytes)});
                    self.resetUtterance(&pipeline, &speech_buf, &speech_trim_total, &vad_filter);
                } else {
                    speech_trim_total += speech_buf.items.len;
                    speech_buf.clearRetainingCapacity();
                    vad_filter.reset();
                }
                if (self.recorder) |rec| rec.endRecording() catch |err| {
                    std.debug.print("[rec] write error: {}\n", .{err});
                };
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
                const ts2 = formatAudioTime(&ts_buf2, total_audio_bytes);
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
                if (self.recorder) |rec| {
                    rec.startRecording();
                    rec.logEvent(total_audio_bytes, "PTT pressed");
                }
            }

            // --- Final flush on client disconnect (TCP EOF or PipeWire pipe close) ---
            if (client_closed) {
                if (vad_state == .speaking and speech_buf.items.len >= min_transcribe_bytes) {
                    cycle_count += 1;
                    const flush_emit = try self.transcribeAndEmit(&pipeline, speech_buf.items, true, output_fd, total_audio_bytes, type_cb, cycle_count, "client-eof");
                    if (flush_emit.emitted and ptt_tracking_press_ns != 0) {
                        std.debug.print("  PTT first-emit: {d:.0}ms total\n", .{nsToF64Ms(std.time.nanoTimestamp() - ptt_tracking_press_ns)});
                        ptt_tracking_press_ns = 0;
                    }
                    self.resetUtterance(&pipeline, &speech_buf, &speech_trim_total, &vad_filter);
                }
                if (self.recorder) |rec| rec.endRecording() catch |err| {
                    std.debug.print("[rec] write error: {}\n", .{err});
                };
                return;
            }

            // --- Periodic transcription during speech ---
            if (vad_state == .speaking and bytes_since_last_cycle >= transcribe_interval_bytes) {
                bytes_since_last_cycle = 0;
                cycle_count += 1;
                const emit_result = try self.transcribeAndEmit(&pipeline, speech_buf.items, false, output_fd, total_audio_bytes, type_cb, cycle_count, "speaking");
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
                    var ts_buf2: [32]u8 = undefined;
                    std.debug.print("[{s}s] TRIM: buf={d}ms→{d}ms trimmed={d}ms cycle={d}\n", .{
                        formatAudioTime(&ts_buf2, total_audio_bytes),
                        old_len * 1000 / 32000,
                        speech_buf.items.len * 1000 / 32000,
                        trimmed * 1000 / 32000,
                        cycle_count,
                    });
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
        total_audio_bytes: usize,
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
                const ts = formatAudioTime(&ts_buf, total_audio_bytes);
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
                const ts = formatAudioTime(&ts_buf, total_audio_bytes);
                std.debug.print("    [{s}s] cycle={d} {s} buf={d}ms\n", .{
                    ts, cycle_count, if (result.was_rewind) "REWIND" else "empty", speech_buf.len * 1000 / 32000,
                });
            }
            return .{ .emitted = false };
        }

        // Drop terms: check if full result text matches any drop term
        // Whisper prepends a leading space, so compare " " ++ term against result.text
        if (self.drop_terms.len > 0) {
            const text = result.text;
            for (self.drop_terms) |term| {
                // Match " <term>" (whisper's leading space + the drop term)
                if (text.len == term.len + 1 and text[0] == ' ' and std.mem.eql(u8, text[1..], term)) {
                    std.debug.print("  [drop] suppressed: \"{s}\"\n", .{text});
                    return .{ .emitted = false };
                }
            }
        }

        const buf_duration_ms = speech_buf.len * 1000 / 32000;
        const t = result.timing;

        // Use result.text as-is: whisper BPE tokens include leading spaces for
        // word-initial tokens. Continuation tokens (no space) should concatenate
        // directly with the previous emission (e.g. "duplic" + "ation").
        const delta = try self.allocator.dupe(u8, result.text);
        defer self.allocator.free(delta);

        emitDelta(output_fd, total_audio_bytes, delta, type_cb, self.recorder) catch return error.BrokenPipe;
        try pipeline.commitTokens(result.tokens, result.token_frames);

        if (self.verbose) {
            var ts_buf: [32]u8 = undefined;
            const ts = formatAudioTime(&ts_buf, total_audio_bytes);
            std.debug.print("    [{s}s] cycle={d} {s} words={d} buf={d}ms | {s} state={d:.0}ms mel={d:.0}ms enc={d:.0}ms dec={d:.0}ms({d}tok/{s}) total={d:.0}ms EMIT\n", .{
                ts, cycle_count, state_name, result.words.len, buf_duration_ms,
                utils.textPreview(result.text), t.state_init_ms, t.mel_ms, t.encode_ms, t.decode_ms, t.tokens_generated, t.stop_reason, t.total_ms,
            });
        }

        if (self.recorder) |rec| {
            rec.logCycle(total_audio_bytes, cycle_count, state_name, buf_duration_ms, result.words.len, result.text);
        }

        return .{ .emitted = true };
    }

    fn resetUtterance(
        self: *Server,
        pipeline: *Pipeline,
        speech_buf: *std.ArrayListUnmanaged(u8),
        speech_trim_total: *usize,
        vad_filter: *VadFilter,
    ) void {
        _ = self;
        pipeline.resetSegment();
        vad_filter.reset();
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

/// Format audio-position timestamp as "{s}.{tenths}" into buf.
/// Uses total audio bytes received (at 32000 bytes/sec) instead of wall-clock,
/// so timestamps are consistent across TCP fast, TCP realtime, and PipeWire modes.
fn formatAudioTime(buf: []u8, total_audio_bytes: usize) []u8 {
    const elapsed_ms: u64 = total_audio_bytes * 1000 / 32000;
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ elapsed_ms / 1000, (elapsed_ms % 1000) / 100 }) catch buf[0..3];
}

/// Write a timestamped delta to the output fd (or type callback) and log it.
fn emitDelta(output_fd: posix.fd_t, total_audio_bytes: usize, delta: []const u8, type_cb: ?TypeCallback, recorder: ?*Recorder) error{BrokenPipe}!void {
    var ts_buf: [32]u8 = undefined;
    const ts = formatAudioTime(&ts_buf, total_audio_bytes);

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
