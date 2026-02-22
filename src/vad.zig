const std = @import("std");
const c = @import("whisper_c.zig");

pub const Segment = struct {
    start_s: f32,
    end_s: f32,
};

pub const VadFilter = struct {
    pub const threshold: f32 = 0.3; // onset: confident speech detection (audio is normalized via auto-gain)
    pub const threshold_off: f32 = 0.1; // offset hysteresis: stay triggered through brief dips
    pub const min_silence_bytes: usize = 32000; // 1000ms at 32000 bytes/sec
    pub const chunk_pcm_bytes: usize = 1024; // 512 samples * 2 bytes (one Silero chunk)

    vad: *Vad,
    allocator: std.mem.Allocator,
    triggered: bool = false,
    silence_bytes: usize = 0,
    last_prob: f32 = 0, // probability from most recent processOneChunk call
    pcm_partial: [chunk_pcm_bytes]u8 = undefined,
    pcm_partial_len: usize = 0,
    output_buf: std.ArrayListUnmanaged(u8) = .{},

    pub fn init(allocator: std.mem.Allocator, vad: *Vad) VadFilter {
        return .{
            .vad = vad,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VadFilter) void {
        self.output_buf.deinit(self.allocator);
    }

    /// Pure state machine update — unit-testable without C FFI.
    /// Returns true if the chunk should be forwarded (speech or bridging silence).
    pub fn processChunkProb(self: *VadFilter, prob: f32) bool {
        if (!self.triggered) {
            if (prob >= threshold) {
                self.triggered = true;
                self.silence_bytes = 0;
                return true;
            }
            return false;
        }

        // Currently triggered
        if (prob >= threshold_off) {
            self.silence_bytes = 0;
            return true;
        }

        // Below threshold_off — accumulate silence
        self.silence_bytes += chunk_pcm_bytes;
        if (self.silence_bytes >= min_silence_bytes) {
            self.triggered = false;
            return false;
        }
        // Bridging: still triggered but below threshold_off
        return true;
    }

    /// Filter audio, returning a slice containing only speech PCM.
    /// The returned slice is valid until the next call to filterAudio.
    pub fn filterAudio(self: *VadFilter, pcm_bytes: []const u8) []const u8 {
        self.output_buf.items.len = 0;

        var pos: usize = 0;
        var input = pcm_bytes;

        // Handle partial chunk carryover from previous call
        if (self.pcm_partial_len > 0) {
            const need = chunk_pcm_bytes - self.pcm_partial_len;
            if (input.len >= need) {
                @memcpy(self.pcm_partial[self.pcm_partial_len..chunk_pcm_bytes], input[0..need]);
                const forward = self.processOneChunk(&self.pcm_partial);
                if (forward) {
                    self.output_buf.appendSlice(self.allocator, &self.pcm_partial) catch return self.output_buf.items;
                }
                input = input[need..];
                self.pcm_partial_len = 0;
            } else {
                // Still not enough for a full chunk — buffer and use current triggered state
                @memcpy(self.pcm_partial[self.pcm_partial_len .. self.pcm_partial_len + input.len], input);
                self.pcm_partial_len += input.len;
                if (self.triggered) {
                    self.output_buf.appendSlice(self.allocator, input) catch {};
                }
                return self.output_buf.items;
            }
        }

        // Process complete chunks
        while (pos + chunk_pcm_bytes <= input.len) {
            const chunk = input[pos..][0..chunk_pcm_bytes];
            const forward = self.processOneChunk(chunk);
            if (forward) {
                self.output_buf.appendSlice(self.allocator, chunk) catch return self.output_buf.items;
            }
            pos += chunk_pcm_bytes;
        }

        // Buffer remaining partial chunk
        const remaining = input.len - pos;
        if (remaining > 0) {
            @memcpy(self.pcm_partial[0..remaining], input[pos..]);
            self.pcm_partial_len = remaining;
            // Forward partial based on current triggered state
            if (self.triggered) {
                self.output_buf.appendSlice(self.allocator, input[pos..]) catch {};
            }
        }

        return self.output_buf.items;
    }

    /// Get raw VAD probability for a chunk without updating state.
    pub fn chunkProb(self: *VadFilter, chunk: *const [chunk_pcm_bytes]u8) f32 {
        const n_samples = chunk_pcm_bytes / 2;
        var float_buf: [n_samples]f32 = undefined;
        for (&float_buf, 0..) |*sample, i| {
            const offset = i * 2;
            const raw = std.mem.readInt(i16, chunk[offset..][0..2], .little);
            sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
        }

        const ok = c.whisper_vad_detect_speech(self.vad.vctx, &float_buf, n_samples);
        if (!ok) return 0;

        const n_probs = c.whisper_vad_n_probs(self.vad.vctx);
        if (n_probs <= 0) return 0;

        const probs: [*]const f32 = c.whisper_vad_probs(self.vad.vctx) orelse return 0;
        const n: usize = @intCast(n_probs);
        var max_prob: f32 = 0.0;
        for (probs[0..n]) |p| {
            if (p > max_prob) max_prob = p;
        }
        return max_prob;
    }

    pub fn processOneChunk(self: *VadFilter, chunk: *const [chunk_pcm_bytes]u8) bool {
        const prob = self.chunkProb(chunk);
        self.last_prob = prob;
        return self.processChunkProb(prob);
    }

    pub fn reset(self: *VadFilter) void {
        self.triggered = false;
        self.silence_bytes = 0;
        self.pcm_partial_len = 0;
        self.last_prob = 0;
    }
};

pub const Vad = struct {
    vctx: *c.whisper_vad_context,
    params: c.whisper_vad_params,

    pub fn init(model_path: [:0]const u8) !Vad {
        // Suppress verbose whisper_vad_detect_speech debug logging.
        c.whisper_log_set(&vadLogFilter, null);

        var ctx_params = c.whisper_vad_default_context_params();
        ctx_params.use_gpu = false; // VAD is tiny, CPU is fine
        ctx_params.n_threads = 2;

        const vctx = c.whisper_vad_init_from_file_with_params(model_path.ptr, ctx_params);
        if (vctx == null) return error.VadInitFailed;

        var params = c.whisper_vad_default_params();
        params.threshold = 0.2; // Default 0.5 is too aggressive for quiet mics
        return .{
            .vctx = vctx.?,
            .params = params,
        };
    }

    /// Log callback that suppresses verbose per-chunk VAD messages.
    fn vadLogFilter(_: c.ggml_log_level, text: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        if (text == null) return;
        const msg = std.mem.span(text);
        // Suppress repetitive VAD debug messages (fired per 32ms chunk)
        if (std.mem.startsWith(u8, msg, "whisper_vad_detect_speech:")) return;
        std.debug.print("{s}", .{msg});
    }

    pub fn deinit(self: *Vad) void {
        c.whisper_vad_free(self.vctx);
    }

    /// Detect whether audio contains speech.
    /// whisper_vad_detect_speech returns a success bool, not a speech indicator.
    /// We must read the per-chunk probabilities it computes and check the threshold.
    pub fn hasSpeech(self: *Vad, samples: []const f32) bool {
        const ok = c.whisper_vad_detect_speech(self.vctx, samples.ptr, @intCast(samples.len));
        if (!ok) return false;

        const n_probs = c.whisper_vad_n_probs(self.vctx);
        if (n_probs <= 0) return false;

        const probs: [*]const f32 = c.whisper_vad_probs(self.vctx) orelse return false;
        const n: usize = @intCast(n_probs);
        var max_prob: f32 = 0.0;
        for (probs[0..n]) |p| {
            if (p > max_prob) max_prob = p;
        }
        return max_prob >= self.params.threshold;
    }

    /// Get speech segments from audio samples.
    /// Caller must call freeSegments on the result.
    pub fn getSegments(self: *Vad, samples: []const f32) ![]Segment {
        const segs = c.whisper_vad_segments_from_samples(
            self.vctx,
            self.params,
            samples.ptr,
            @intCast(samples.len),
        );
        if (segs == null) return error.VadSegmentsFailed;
        defer c.whisper_vad_free_segments(segs);

        const n: usize = @intCast(c.whisper_vad_segments_n_segments(segs));
        if (n == 0) return &.{};

        // Copy segments — the C data is freed when we return
        // API returns centiseconds (int64 cast to float), convert to seconds
        const allocator = std.heap.page_allocator;
        const result = try allocator.alloc(Segment, n);
        for (0..n) |i| {
            result[i] = .{
                .start_s = c.whisper_vad_segments_get_segment_t0(segs, @intCast(i)) / 100.0,
                .end_s = c.whisper_vad_segments_get_segment_t1(segs, @intCast(i)) / 100.0,
            };
        }
        return result;
    }
};

// ============================================================
// VadFilter unit tests (processChunkProb only — no C FFI needed)
// ============================================================

test "processChunkProb: not triggered, below threshold -> stays not-triggered" {
    var filter = VadFilter{
        .vad = undefined,
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(!filter.processChunkProb(0.2));
    try std.testing.expect(!filter.triggered);
}

test "processChunkProb: not triggered, above threshold -> triggers" {
    var filter = VadFilter{
        .vad = undefined,
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(filter.processChunkProb(0.5));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(@as(usize, 0), filter.silence_bytes);
}

test "processChunkProb: not triggered, exact threshold boundary -> triggers" {
    var filter = VadFilter{
        .vad = undefined,
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(filter.processChunkProb(VadFilter.threshold));
    try std.testing.expect(filter.triggered);
}

test "processChunkProb: triggered, above threshold_off -> resets silence counter" {
    var filter = VadFilter{
        .vad = undefined,
        .allocator = std.testing.allocator,
        .triggered = true,
        .silence_bytes = 4096,
    };
    try std.testing.expect(filter.processChunkProb(0.15));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(@as(usize, 0), filter.silence_bytes);
}

test "processChunkProb: triggered, below threshold_off, short silence -> bridges" {
    var filter = VadFilter{
        .vad = undefined,
        .allocator = std.testing.allocator,
        .triggered = true,
        .silence_bytes = 0,
    };
    // One chunk of silence (1024 bytes) — well below min_silence_bytes (32000)
    try std.testing.expect(filter.processChunkProb(0.05));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(VadFilter.chunk_pcm_bytes, filter.silence_bytes);
}

test "processChunkProb: triggered, sustained silence -> un-triggers" {
    var filter = VadFilter{
        .vad = undefined,
        .allocator = std.testing.allocator,
        .triggered = true,
        .silence_bytes = VadFilter.min_silence_bytes - VadFilter.chunk_pcm_bytes,
    };
    // This chunk pushes silence_bytes past min_silence_bytes
    try std.testing.expect(!filter.processChunkProb(0.05));
    try std.testing.expect(!filter.triggered);
}

test "processChunkProb: speech during bridging -> resets silence counter" {
    var filter = VadFilter{
        .vad = undefined,
        .allocator = std.testing.allocator,
        .triggered = true,
        .silence_bytes = 16000, // mid-bridge
    };
    try std.testing.expect(filter.processChunkProb(0.8));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(@as(usize, 0), filter.silence_bytes);
}

test "processChunkProb: exact threshold_off boundary keeps triggered" {
    var filter = VadFilter{
        .vad = undefined,
        .allocator = std.testing.allocator,
        .triggered = true,
        .silence_bytes = 4096,
    };
    try std.testing.expect(filter.processChunkProb(VadFilter.threshold_off));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(@as(usize, 0), filter.silence_bytes);
}
