const std = @import("std");
const c = @import("whisper_c.zig");
const Vad = @import("vad.zig").Vad;
const Pipeline = @import("pipeline.zig").Pipeline;

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

        // Audio buffer (raw PCM S16_LE bytes)
        var pcm_buf = std.ArrayListUnmanaged(u8){};
        defer pcm_buf.deinit(self.allocator);

        // Previously emitted text for delta computation
        var emitted_text = std.ArrayListUnmanaged(u8){};
        defer emitted_text.deinit(self.allocator);

        var recv_buf: [32768]u8 = undefined;
        var state: State = .idle;
        var bytes_since_last_cycle: usize = 0;
        var silence_start_pos: usize = 0;

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

            // Final flush on disconnect
            if (client_closed) {
                if (state == .speaking or state == .trailing_silence) {
                    if (pcm_buf.items.len >= min_transcribe_bytes) {
                        const samples = try pcmToFloat(self.allocator, pcm_buf.items);
                        defer self.allocator.free(samples);

                        if (try pipeline.transcribe(samples, true)) |result| {
                            if (result.text.len > 0) {
                                defer self.allocator.free(result.text);
                                const text = std.mem.trim(u8, result.text, " ");
                                const delta = computeDelta(emitted_text.items, text);
                                if (delta.len > 0) {
                                    _ = posix.write(conn, delta) catch {};
                                    _ = posix.write(conn, "\n") catch {};
                                    std.debug.print("  >> {s}\n", .{delta});
                                }
                            }
                        }
                    }
                }
                return;
            }

            // VAD check on last 0.5s
            const has_speech = blk: {
                const vad_start = if (pcm_buf.items.len > vad_window_bytes)
                    (pcm_buf.items.len - vad_window_bytes) & ~@as(usize, 1)
                else
                    0;
                const vad_samples = try pcmToFloat(self.allocator, pcm_buf.items[vad_start..]);
                defer self.allocator.free(vad_samples);
                break :blk self.vad.hasSpeech(vad_samples);
            };

            // State machine
            var should_transcribe = false;
            var should_flush = false;

            switch (state) {
                .idle => {
                    if (has_speech) {
                        std.debug.print("[state] idle → speaking\n", .{});
                        state = .speaking;
                        should_transcribe = true;
                    } else {
                        trimBuffer(&pcm_buf, vad_window_bytes);
                        continue;
                    }
                },
                .speaking => {
                    if (!has_speech) {
                        std.debug.print("[state] speaking → trailing_silence\n", .{});
                        state = .trailing_silence;
                        silence_start_pos = pcm_buf.items.len;
                        continue;
                    }
                    should_transcribe = true;
                },
                .trailing_silence => {
                    if (has_speech) {
                        std.debug.print("[state] trailing_silence → speaking\n", .{});
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
                const is_last = should_flush;

                if (pcm_buf.items.len >= min_transcribe_bytes) {
                    const all_samples = try pcmToFloat(self.allocator, pcm_buf.items);
                    defer self.allocator.free(all_samples);

                    if (try pipeline.transcribe(all_samples, is_last)) |result| {
                        // result.text is "" (string literal) on rewind — only free if allocated
                        if (result.text.len > 0) {
                            defer self.allocator.free(result.text);
                            const text = std.mem.trim(u8, result.text, " ");
                            const delta = computeDelta(emitted_text.items, text);
                            if (delta.len > 0) {
                                _ = posix.write(conn, delta) catch return;
                                _ = posix.write(conn, "\n") catch return;
                                std.debug.print("  >> {s}\n", .{delta});
                                if (!is_last) {
                                    try emitted_text.appendSlice(self.allocator, delta);
                                }
                            } else if (emitted_text.items.len > 0 and text.len > 0) {
                                // Whisper rephrased earlier text — resync so we don't get stuck
                                std.debug.print("  [resync] emitted={d} new={d}\n", .{ emitted_text.items.len, text.len });
                                emitted_text.clearRetainingCapacity();
                                try emitted_text.appendSlice(self.allocator, text);
                            }
                        }
                    }
                }

                if (should_flush) {
                    std.debug.print("[state] flush → idle\n", .{});
                    trimBuffer(&pcm_buf, vad_window_bytes);
                    emitted_text.clearRetainingCapacity();
                    state = .idle;
                } else {
                    trimBuffer(&pcm_buf, max_buffer_bytes);
                }
            }
        }
    }
};

fn pcmToFloat(allocator: std.mem.Allocator, pcm_bytes: []const u8) ![]f32 {
    const n_samples = pcm_bytes.len / 2;
    const result = try allocator.alloc(f32, n_samples);
    errdefer allocator.free(result);

    for (result, 0..) |*sample, i| {
        const offset = i * 2;
        if (offset + 2 > pcm_bytes.len) break;
        const raw = std.mem.readInt(i16, pcm_bytes[offset..][0..2], .little);
        sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    return result;
}

/// Find the new text that extends beyond what was already emitted.
/// Returns "" if new_text diverges from emitted (Whisper rephrased).
fn computeDelta(emitted: []const u8, new_text: []const u8) []const u8 {
    const min_len = @min(emitted.len, new_text.len);
    var common_len: usize = 0;
    while (common_len < min_len) : (common_len += 1) {
        if (emitted[common_len] != new_text[common_len]) break;
    }
    if (common_len < emitted.len) return "";
    return new_text[common_len..];
}

/// Trim buffer to keep only the last `keep_bytes`, aligned to sample boundary.
fn trimBuffer(buf: *std.ArrayListUnmanaged(u8), keep_bytes: usize) void {
    if (buf.items.len <= keep_bytes) return;
    const trim = (buf.items.len - keep_bytes) & ~@as(usize, 1);
    if (trim == 0) return;
    const remaining = buf.items.len - trim;
    std.mem.copyForwards(u8, buf.items[0..remaining], buf.items[trim..]);
    buf.items.len = remaining;
}
