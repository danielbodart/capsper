const std = @import("std");
const c = @import("whisper_c.zig");
const Vad = @import("vad.zig").Vad;
const Pipeline = @import("pipeline.zig").Pipeline;
const AudioCapture = @import("audio_capture.zig").AudioCapture;
const utils = @import("utils.zig");
const Recorder = @import("recorder.zig").Recorder;

const posix = std.posix;
const net = std.net;

// Global pause state (module-level so input handler can access it via setPaused).
// Default unpaused; main.zig sets to paused when --trigger is used.
pub var is_paused = std.atomic.Value(bool).init(false);

// Global capture pointer — set by runLocal so setPaused can toggle the PipeWire stream.
// When non-null, setPaused also activates/deactivates the stream so the desktop
// microphone indicator only appears during active recording.
var capture_ptr = std.atomic.Value(?*AudioCapture).init(null);

pub fn setPaused(paused: bool) void {
    is_paused.store(paused, .monotonic);
    if (capture_ptr.load(.monotonic)) |cap| {
        cap.setActive(!paused);
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
const max_buffer_bytes: usize = 480000; // 15s — sliding window cap
const min_transcribe_bytes: usize = 16000; // 0.5s — minimum audio worth transcribing

// Frame-based stability: word is stable if prev_words has a word within ±tolerance frames.
// 10 frames = 200ms at 50fps encoder output.
const frame_tolerance: usize = 10;
// Bytes per encoder frame: 320 samples × 2 bytes/sample = 640
const bytes_per_frame: usize = 640;
// Guard band for frame-based dedup: ignore words within this many frames of
// last_emitted_frame to absorb cross-attention jitter (1-5 frames typical).
// 4 frames = 80ms, safely below minimum inter-word gap (~5 frames for fast speech).
const dedup_guard_frames: usize = 4;

const State = enum { idle, speaking, trailing_silence };

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

        // Register capture so setPaused can toggle stream active state.
        // If not starting paused (no --trigger), activate the stream immediately.
        capture_ptr.store(&capture, .monotonic);
        defer capture_ptr.store(null, .monotonic);
        if (!is_paused.load(.monotonic)) {
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

        // Frame-based stability state
        var prev_words = std.ArrayListUnmanaged(utils.TimedWord){};
        defer prev_words.deinit(self.allocator);

        var pcm_trim_total: usize = 0; // cumulative bytes trimmed (for absolute frame calc)
        var last_emitted_frame: usize = 0; // absolute frame of last emitted word
        var emitted_in_utterance: bool = false; // whether we've emitted anything in current utterance
        var last_emitted_word_buf: [64]u8 = undefined; // text of last emitted word (for text-aware dedup)
        var last_emitted_word_len: usize = 0;

        var recv_buf: [32768]u8 = undefined;
        var state: State = .idle;
        var bytes_since_last_cycle: usize = 0;
        var silence_start_pos: usize = 0;
        var cycle_count: usize = 0;
        var cycles_without_emit: usize = 0; // force-emit after too many dry cycles
        var trailing_transcribe_done: bool = false; // limit trailing_silence to 1 extra transcription
        var was_paused: bool = is_paused.load(.monotonic); // track previous pause state for transition detection

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

            // Pause logic: when paused, drain audio and skip all processing
            const paused = is_paused.load(.monotonic);
            if (paused) {
                if (!was_paused and (state == .speaking or state == .trailing_silence)) {
                    if (self.recorder) |rec| rec.endUtterance(.pause) catch |err| {
                        std.debug.print("[rec] write error: {}\n", .{err});
                    };
                }
                const old_len = pcm_buf.items.len;
                utils.trimBuffer(&pcm_buf, idle_keep_bytes);
                pcm_trim_total += old_len - pcm_buf.items.len;
                was_paused = true;
                continue;
            }

            // Unpause transition: reset state for clean first transcription
            if (was_paused) {
                var ts_buf2: [32]u8 = undefined;
                const ts2 = formatElapsed(&ts_buf2, start_ns);
                std.debug.print("[{s}s] UNPAUSED\n", .{ts2});
                state = .idle;
                cycle_count = 0;
                cycles_without_emit = 0;
                emitted_in_utterance = false;
                was_paused = false;
            }

            // Final flush on disconnect or read timeout — emit everything
            if (client_closed or timed_out) {
                if (state == .speaking or state == .trailing_silence) {
                    if (pcm_buf.items.len >= min_transcribe_bytes) {
                        const samples = try utils.pcmToFloat(self.allocator, pcm_buf.items);
                        defer self.allocator.free(samples);

                        if (try pipeline.transcribe(samples, true)) |result| {
                            defer self.allocator.free(result.text);
                            defer self.allocator.free(result.words);
                            defer self.allocator.free(result.tokens);
                            if (result.words.len > 0) {
                                const frame_offset = pcm_trim_total / bytes_per_frame;
                                if (self.verbose) {
                                    var flush_ts_buf: [32]u8 = undefined;
                                    const ts = formatElapsed(&flush_ts_buf, start_ns);
                                    std.debug.print("    [{s}s] FINAL FLUSH words={d} timed_out={} closed={}\n", .{ ts, result.words.len, timed_out, client_closed });
                                }
                                _ = emitNewWords(output_fd, start_ns, result.text, result.words, frame_offset, result.words.len, &last_emitted_frame, &emitted_in_utterance, last_emitted_word_buf[0..last_emitted_word_len], &last_emitted_word_buf, &last_emitted_word_len, type_cb, self.recorder) catch {};
                                if (self.recorder) |rec| {
                                    rec.logCycle(start_ns, cycle_count, "FINAL", pcm_buf.items.len * 1000 / 32000, result.words.len, result.words.len, result.text);
                                }
                            }
                        }
                    }
                }
                if (self.recorder) |rec| rec.endUtterance(.timeout) catch |err| {
                    std.debug.print("[rec] write error: {}\n", .{err});
                };
                if (client_closed) return;
                // After timeout flush, go idle. Keep prev_words for stability bridging.
                const old_len = pcm_buf.items.len;
                utils.trimBuffer(&pcm_buf, idle_keep_bytes);
                pcm_trim_total += old_len - pcm_buf.items.len;
                emitted_in_utterance = false;
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
                        if (self.recorder) |rec| rec.startUtterance();
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
                        state = .trailing_silence;
                        silence_start_pos = pcm_buf.items.len;
                        trailing_transcribe_done = false;
                        // Transcribe before entering silence to capture trailing words
                        should_transcribe = true;
                    } else {
                        should_transcribe = true;
                    }
                },
                .trailing_silence => {
                    if (has_speech) {
                        const ts = formatElapsed(&ts_buf, start_ns);
                        std.debug.print("[{s}s] trailing_silence → speaking (buf={d} vad={d:.1}ms)\n", .{ ts, pcm_buf.items.len, vad_ms });
                        state = .speaking;
                        should_transcribe = true;
                    } else if (pcm_buf.items.len - silence_start_pos >= silence_timeout_bytes) {
                        should_flush = true;
                    } else if (!trailing_transcribe_done) {
                        should_transcribe = true;
                        trailing_transcribe_done = true;
                    }
                },
            }

            // Transcribe and emit delta
            if (should_transcribe or should_flush) {
                if (pcm_buf.items.len >= min_transcribe_bytes) {
                    cycle_count += 1;
                    const t_cycle = std.time.nanoTimestamp();
                    const buf_duration_ms = pcm_buf.items.len * 1000 / 32000;

                    const all_samples = try utils.pcmToFloat(self.allocator, pcm_buf.items);
                    defer self.allocator.free(all_samples);
                    // Always pass is_last=true to pipeline: AlignAtt's frame_threshold=25
                    // is too conservative for short buffers (null for <8s audio).
                    // Stability check handles hallucination filtering instead.
                    if (try pipeline.transcribe(all_samples, true)) |result| {
                        defer self.allocator.free(result.text);
                        defer self.allocator.free(result.words);
                        defer self.allocator.free(result.tokens);

                        if (result.words.len > 0) {
                            const frame_offset = pcm_trim_total / bytes_per_frame;
                            const text_words = result.words.len;
                            const t = result.timing;

                            // Convert to absolute frames for stability comparison
                            const abs_words = try self.allocator.alloc(utils.TimedWord, result.words.len);
                            defer self.allocator.free(abs_words);
                            for (result.words, 0..) |w, i| {
                                abs_words[i] = .{
                                    .text_start = w.text_start,
                                    .text_end = w.text_end,
                                    .frame = w.frame + frame_offset,
                                };
                            }

                            const stable_count = if (prev_words.items.len > 0)
                                utils.findTimedStableCount(prev_words.items, abs_words, frame_tolerance)
                            else
                                0; // First cycle: store for next stability check

                            const emit_count = if (should_flush)
                                abs_words.len
                            else if (cycles_without_emit >= 4)
                                abs_words.len // Force-emit after 4+ dry cycles (~4s) to prevent stalls
                            else
                                stable_count;

                            const did_emit = emitNewWords(output_fd, start_ns, result.text, result.words, frame_offset, emit_count, &last_emitted_frame, &emitted_in_utterance, last_emitted_word_buf[0..last_emitted_word_len], &last_emitted_word_buf, &last_emitted_word_len, type_cb, self.recorder) catch return;
                            if (did_emit) {
                                cycles_without_emit = 0;
                            } else {
                                cycles_without_emit += 1;
                            }

                            // Debug logging (verbose only — per-cycle timing)
                            if (self.verbose) {
                                const ts = formatElapsed(&ts_buf, start_ns);
                                const cycle_ms = msFromNs(t_cycle);
                                if (should_flush) {
                                    std.debug.print("    [{s}s] cycle={d} FLUSH words={d} buf={d}ms | {s} state={d:.0}ms enc={d:.0}ms dec={d:.0}ms({d}tok/{s}) total={d:.0}ms\n", .{
                                        ts, cycle_count, text_words, buf_duration_ms,
                                        utils.textPreview(result.text), t.state_init_ms, t.encode_ms, t.decode_ms, t.tokens_generated, t.stop_reason, t.total_ms,
                                    });
                                } else if (prev_words.items.len > 0) {
                                    std.debug.print("    [{s}s] cycle={d} stable={d} last_frame={d} words={d} buf={d}ms | {s} state={d:.0}ms enc={d:.0}ms dec={d:.0}ms({d}tok/{s}) cycle={d:.0}ms{s}\n", .{
                                        ts,           cycle_count,  emit_count, last_emitted_frame, text_words, buf_duration_ms,
                                        utils.textPreview(result.text), t.state_init_ms, t.encode_ms, t.decode_ms, t.tokens_generated, t.stop_reason, cycle_ms,
                                        if (did_emit) " EMIT" else "",
                                    });
                                } else {
                                    std.debug.print("    [{s}s] cycle={d} FIRST words={d} buf={d}ms | {s} state={d:.0}ms enc={d:.0}ms dec={d:.0}ms({d}tok/{s}) total={d:.0}ms\n", .{
                                        ts, cycle_count, text_words, buf_duration_ms,
                                        utils.textPreview(result.text), t.state_init_ms, t.encode_ms, t.decode_ms, t.tokens_generated, t.stop_reason, t.total_ms,
                                    });
                                }
                            }

                            // Recorder: log cycle after transcription
                            if (self.recorder) |rec| {
                                const state_name: []const u8 = switch (state) {
                                    .speaking => "speaking",
                                    .trailing_silence => "trailing",
                                    .idle => "idle",
                                };
                                rec.logCycle(start_ns, cycle_count, state_name, buf_duration_ms, text_words, emit_count, result.text);
                            }

                            // Update prev_words with absolute frames
                            prev_words.clearRetainingCapacity();
                            try prev_words.appendSlice(self.allocator, abs_words);

                        }
                    } else if (self.verbose) {
                        // Pipeline returned null — log it
                        const ts = formatElapsed(&ts_buf, start_ns);
                        const cycle_ms = msFromNs(t_cycle);
                        std.debug.print("    [{s}s] cycle={d} NULL buf={d}ms cycle={d:.0}ms\n", .{
                            ts, cycle_count, buf_duration_ms, cycle_ms,
                        });
                    }
                }

                if (should_flush) {
                    if (self.recorder) |rec| rec.endUtterance(.flush) catch |err| {
                        std.debug.print("[rec] write error: {}\n", .{err});
                    };
                    const flush_ts = formatElapsed(&ts_buf, start_ns);
                    std.debug.print("[{s}s] flush → idle\n", .{flush_ts});
                    // Boost last_emitted_frame past the last word to prevent
                    // cross-utterance re-emission due to frame drift after trim
                    if (prev_words.items.len > 0) {
                        const last_word_frame = prev_words.items[prev_words.items.len - 1].frame;
                        last_emitted_frame = @max(last_emitted_frame, last_word_frame + frame_tolerance);
                    }
                    // Keep prev_words from flush transcription — allows the first post-flush
                    // cycle to use stability checking against the flush result, capturing words
                    // like "How it works" that appear in both the flush and first new cycle.
                    // last_emitted_frame prevents re-emitting already-flushed words.
                    const old_len = pcm_buf.items.len;
                    utils.trimBuffer(&pcm_buf, idle_keep_bytes);
                    pcm_trim_total += old_len - pcm_buf.items.len;
                    emitted_in_utterance = false;
                    state = .idle;
                    cycle_count = 0;
                } else {
                    const old_len = pcm_buf.items.len;
                    utils.trimBuffer(&pcm_buf, max_buffer_bytes);
                    const trimmed = old_len - pcm_buf.items.len;
                    pcm_trim_total += trimmed;
                    // Keep silence_start_pos valid after trim
                    silence_start_pos -|= trimmed;
                }
            }
        }
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

/// Emit words from text that are past last_emitted_frame (plus guard band).
/// `count` limits how many words from the start of `words` to consider.
/// Returns true if any words were emitted.
fn emitNewWords(
    output_fd: posix.fd_t,
    start_ns: i128,
    text: []const u8,
    words: []const utils.TimedWord,
    frame_offset: usize,
    count: usize,
    last_emitted_frame: *usize,
    emitted_in_utterance: *bool,
    last_emitted_word: []const u8,
    last_emitted_word_buf: *[64]u8,
    last_emitted_word_len: *usize,
    type_cb: ?TypeCallback,
    recorder: ?*Recorder,
) error{BrokenPipe}!bool {
    if (count == 0 or words.len == 0) return false;

    const limit = @min(count, words.len);

    // Find contiguous range of new words (frame past guard band around last_emitted_frame)
    var first_new: ?usize = null;
    var last_new: ?usize = null;
    for (0..limit) |i| {
        const abs_frame = words[i].frame + frame_offset;
        if (abs_frame > last_emitted_frame.* + dedup_guard_frames) {
            if (first_new == null) first_new = i;
            last_new = i;
        }
    }

    if (first_new) |fi_raw| {
        var fi = fi_raw;
        const li = last_new.?;

        // Text-aware dedup: if the first "new" word matches the last emitted word's
        // text and is within frame_tolerance, it's the same word drifted by whisper's
        // cross-attention jitter. Skip it. This catches drift >dedup_guard_frames
        // without raising the guard so high that legitimate new words get blocked.
        if (last_emitted_word.len > 0 and fi <= li) {
            const w = words[fi];
            const abs_frame = w.frame + frame_offset;
            if (abs_frame <= last_emitted_frame.* + frame_tolerance) {
                const word_text = text[w.text_start..w.text_end];
                if (std.ascii.eqlIgnoreCase(word_text, last_emitted_word)) {
                    fi += 1; // skip duplicate
                }
            }
        }

        if (fi > li) return false; // all words were duplicates

        // Build emission range: include space before first word for non-first emissions
        const raw_start = words[fi].text_start;
        const emit_start = if (emitted_in_utterance.* and raw_start > 0) raw_start - 1 else raw_start;
        const emit_end = words[li].text_end;
        if (emit_end > emit_start and emit_end <= text.len) {
            try emitDelta(output_fd, start_ns, text[emit_start..emit_end], type_cb, recorder);
            last_emitted_frame.* = words[li].frame + frame_offset;
            emitted_in_utterance.* = true;
            // Track last emitted word text for next cycle's text-aware dedup
            const last_w = words[li];
            const last_text = text[last_w.text_start..last_w.text_end];
            const copy_len = @min(last_text.len, last_emitted_word_buf.len);
            @memcpy(last_emitted_word_buf[0..copy_len], last_text[0..copy_len]);
            last_emitted_word_len.* = copy_len;
            return true;
        }
    }
    return false;
}
