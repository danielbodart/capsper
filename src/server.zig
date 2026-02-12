const std = @import("std");
const c = @import("whisper_c.zig");
const Vad = @import("vad.zig").Vad;
const Pipeline = @import("pipeline.zig").Pipeline;
const utils = @import("utils.zig");

const posix = std.posix;
const net = std.net;

// Streaming constants (byte counts for S16_LE at 16kHz = 32000 bytes/sec)
const transcribe_interval_bytes: usize = 32000; // 1s — re-transcribe cadence during speech
const vad_window_bytes: usize = 16000; // 0.5s — VAD lookback window
const silence_timeout_bytes: usize = 16000; // 0.5s — silence before utterance flush
const max_buffer_bytes: usize = 480000; // 15s — sliding window cap
const min_transcribe_bytes: usize = 16000; // 0.5s — minimum audio worth transcribing

const State = enum { idle, speaking, trailing_silence };

pub const Server = struct {
    allocator: std.mem.Allocator,
    ctx: *c.whisper_context,
    vad: Vad,
    port: u16,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *c.whisper_context,
        vad: Vad,
        port: u16,
    ) Server {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .vad = vad,
            .port = port,
        };
    }

    pub fn run(self: *Server) !void {
        const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port);
        const listener = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 1);

        std.debug.print("Listening on port {d}\n", .{self.port});

        while (true) {
            const conn = try posix.accept(listener, null, null, posix.SOCK.CLOEXEC);
            defer posix.close(conn);

            std.debug.print("Client connected\n", .{});
            self.handleConnection(conn) catch |err| {
                std.debug.print("Connection error: {}\n", .{err});
            };
            std.debug.print("Client disconnected\n", .{});
        }
    }

    fn handleConnection(self: *Server, conn: posix.socket_t) !void {
        var pipeline = try Pipeline.init(self.allocator, self.ctx, .{}, 4);
        defer pipeline.deinit();

        const start_ns = std.time.nanoTimestamp();

        // Audio buffer (raw PCM S16_LE bytes)
        var pcm_buf = std.ArrayListUnmanaged(u8){};
        defer pcm_buf.deinit(self.allocator);

        // Previous transcription result — used to confirm stability
        var prev_text = std.ArrayListUnmanaged(u8){};
        defer prev_text.deinit(self.allocator);

        // Word-level tracking: how many words have been sent to the client.
        // Word-level (not byte-level) makes delta computation robust to
        // Whisper changing punctuation between cycles ("so" vs "so,").
        var emitted_words: usize = 0;

        var recv_buf: [32768]u8 = undefined;
        var state: State = .idle;
        var bytes_since_last_cycle: usize = 0;
        var silence_start_pos: usize = 0;
        var cycle_count: usize = 0;

        while (true) {
            const n = posix.read(conn, &recv_buf) catch |err| switch (err) {
                error.ConnectionResetByPeer => return,
                else => return err,
            };

            if (n > 0) {
                try pcm_buf.appendSlice(self.allocator, recv_buf[0..n]);
                bytes_since_last_cycle += n;
            }

            const client_closed = (n == 0);

            // Throttle: wait for enough new audio before processing
            const min_bytes: usize = switch (state) {
                .idle, .speaking => transcribe_interval_bytes,
                .trailing_silence => vad_window_bytes,
            };

            if (!client_closed and bytes_since_last_cycle < min_bytes) continue;
            if (pcm_buf.items.len == 0) {
                if (client_closed) return;
                continue;
            }

            bytes_since_last_cycle = 0;

            // Final flush on disconnect — emit everything, no stability wait
            if (client_closed) {
                if (state == .speaking or state == .trailing_silence) {
                    if (pcm_buf.items.len >= min_transcribe_bytes) {
                        const samples = try utils.pcmToFloat(self.allocator, pcm_buf.items);
                        defer self.allocator.free(samples);

                        if (try pipeline.transcribe(samples, true)) |result| {
                            if (result.text.len > 0) {
                                defer self.allocator.free(result.text);
                                const text = std.mem.trim(u8, result.text, " ");
                                const delta = utils.wordDelta(text, emitted_words);
                                if (delta.len > 0) {
                                    emitDelta(conn, start_ns, delta) catch {}; // client may have disconnected; main loop handles it
                                }
                            }
                        }
                    }
                }
                return;
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
                    } else {
                        utils.trimBuffer(&pcm_buf, vad_window_bytes);
                        continue;
                    }
                },
                .speaking => {
                    if (!has_speech) {
                        const ts = formatElapsed(&ts_buf, start_ns);
                        std.debug.print("[{s}s] speaking → trailing_silence (buf={d} vad={d:.1}ms)\n", .{ ts, pcm_buf.items.len, vad_ms });
                        state = .trailing_silence;
                        silence_start_pos = pcm_buf.items.len;
                        continue;
                    }
                    should_transcribe = true;
                },
                .trailing_silence => {
                    if (has_speech) {
                        const ts = formatElapsed(&ts_buf, start_ns);
                        std.debug.print("[{s}s] trailing_silence → speaking (buf={d} vad={d:.1}ms)\n", .{ ts, pcm_buf.items.len, vad_ms });
                        state = .speaking;
                        should_transcribe = true;
                    } else if (pcm_buf.items.len - silence_start_pos >= silence_timeout_bytes) {
                        should_flush = true;
                    } else {
                        continue;
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
                        // result.text is "" (string literal) on rewind — only free if allocated
                        if (result.text.len > 0) {
                            defer self.allocator.free(result.text);
                            const text = std.mem.trim(u8, result.text, " ");
                            const text_words = utils.countWords(text);
                            const t = result.timing;

                            if (should_flush) {
                                // Utterance ended — emit everything remaining
                                const delta = utils.wordDelta(text, emitted_words);
                                if (delta.len > 0) {
                                    emitDelta(conn, start_ns, delta) catch return;
                                }
                                const ts = formatElapsed(&ts_buf, start_ns);
                                std.debug.print("    [{s}s] cycle={d} FLUSH words={d} emitted={d} buf={d}ms | {s} state={d:.0}ms enc={d:.0}ms dec={d:.0}ms({d}tok/{s}) total={d:.0}ms\n", .{
                                    ts, cycle_count, text_words, emitted_words, buf_duration_ms,
                                    utils.textPreview(text), t.state_init_ms, t.encode_ms, t.decode_ms, t.tokens_generated, t.stop_reason, t.total_ms,
                                });
                            } else if (prev_text.items.len > 0) {
                                // Stability check with flexible offset matching for sliding window shifts
                                const stability = utils.findStableWords(prev_text.items, text, emitted_words);
                                const stable_words = stability.stable_words;
                                const prev_skip = stability.prev_skip;

                                if (prev_skip > 0) {
                                    emitted_words = if (emitted_words > prev_skip)
                                        emitted_words - prev_skip
                                    else
                                        0;
                                }

                                const did_emit = stable_words > emitted_words;
                                if (did_emit) {
                                    const start_byte = utils.byteOffsetAfterWords(text, emitted_words);
                                    const end_byte = utils.byteOffsetAfterWords(text, stable_words);
                                    if (end_byte > start_byte) {
                                        emitDelta(conn, start_ns, text[start_byte..end_byte]) catch return;
                                        emitted_words = stable_words;
                                    }
                                }

                                // Debug: log every cycle's stability result
                                const ts = formatElapsed(&ts_buf, start_ns);
                                const cycle_ms = msFromNs(t_cycle);
                                std.debug.print("    [{s}s] cycle={d} stable={d} emitted={d} skip={d} words={d} buf={d}ms | {s} state={d:.0}ms enc={d:.0}ms dec={d:.0}ms({d}tok/{s}) cycle={d:.0}ms{s}\n", .{
                                    ts,           cycle_count,  stable_words, emitted_words, prev_skip, text_words, buf_duration_ms,
                                    utils.textPreview(text), t.state_init_ms, t.encode_ms, t.decode_ms, t.tokens_generated, t.stop_reason, cycle_ms,
                                    if (did_emit) " EMIT" else "",
                                });
                            } else {
                                // First cycle, no prev — just record, don't emit yet
                                const ts = formatElapsed(&ts_buf, start_ns);
                                std.debug.print("    [{s}s] cycle={d} FIRST words={d} buf={d}ms | {s} state={d:.0}ms enc={d:.0}ms dec={d:.0}ms({d}tok/{s}) total={d:.0}ms\n", .{
                                    ts, cycle_count, text_words, buf_duration_ms,
                                    utils.textPreview(text), t.state_init_ms, t.encode_ms, t.decode_ms, t.tokens_generated, t.stop_reason, t.total_ms,
                                });
                            }

                            // Update prev for next stability check
                            prev_text.clearRetainingCapacity();
                            try prev_text.appendSlice(self.allocator, text);
                        }
                    } else {
                        // Pipeline returned null — log it
                        const ts = formatElapsed(&ts_buf, start_ns);
                        const cycle_ms = msFromNs(t_cycle);
                        std.debug.print("    [{s}s] cycle={d} NULL buf={d}ms cycle={d:.0}ms\n", .{
                            ts, cycle_count, buf_duration_ms, cycle_ms,
                        });
                    }
                }

                if (should_flush) {
                    const flush_ts = formatElapsed(&ts_buf, start_ns);
                    std.debug.print("[{s}s] flush → idle\n", .{flush_ts});
                    utils.trimBuffer(&pcm_buf, vad_window_bytes);
                    emitted_words = 0;
                    prev_text.clearRetainingCapacity();
                    state = .idle;
                    cycle_count = 0;
                } else {
                    utils.trimBuffer(&pcm_buf, max_buffer_bytes);
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

/// Write a timestamped delta to the connection and log it.
fn emitDelta(conn: posix.socket_t, start_ns: i128, delta: []const u8) error{BrokenPipe}!void {
    var ts_buf: [32]u8 = undefined;
    const ts = formatElapsed(&ts_buf, start_ns);
    _ = posix.write(conn, ts) catch return error.BrokenPipe;
    _ = posix.write(conn, "\t") catch return error.BrokenPipe;
    _ = posix.write(conn, delta) catch return error.BrokenPipe;
    _ = posix.write(conn, "\n") catch return error.BrokenPipe;
    std.debug.print("  [{s}s] >> {s}\n", .{ ts, delta });
}
