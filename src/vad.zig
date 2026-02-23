const std = @import("std");
const c = @import("whisper_c.zig");

const ten_vad_ggml_c = @cImport({
    @cInclude("ten_vad_ggml.h");
});

// ============================================================
// VAD Backends
// ============================================================

pub const VadBackend = union(enum) {
    silero: *SileroVad,
    ten_vad_ggml: *TenVadGgml,

    /// Get speech probability for a chunk of S16_LE PCM bytes.
    /// Each backend handles its own format conversion internally.
    pub fn chunkProb(self: VadBackend, chunk: *const [VadFilter.chunk_pcm_bytes]u8) f32 {
        return switch (self) {
            .silero => |vad| vad.chunkProbS16(chunk),
            .ten_vad_ggml => |tv| tv.chunkProbS16(chunk),
        };
    }

    pub fn reset(self: VadBackend) void {
        switch (self) {
            .silero => {},
            .ten_vad_ggml => |tv| tv.reset(),
        }
    }

    pub fn name(self: VadBackend) []const u8 {
        return switch (self) {
            .silero => "silero",
            .ten_vad_ggml => "ten-vad",
        };
    }

    pub const Thresholds = struct {
        onset: f32,
        offset: f32,
        min_silence_ms: u32,
    };

    /// Per-backend default thresholds tuned for each model's probability distribution.
    pub fn defaultThresholds(self: VadBackend) Thresholds {
        return switch (self) {
            .silero => .{ .onset = 0.3, .offset = 0.1, .min_silence_ms = 1000 },
            .ten_vad_ggml => .{ .onset = 0.6, .offset = 0.5, .min_silence_ms = 1000 },
        };
    }
};

pub const SileroVad = struct {
    vctx: *c.whisper_vad_context,

    pub fn init(model_path: [:0]const u8) !SileroVad {
        c.whisper_log_set(&sileroLogFilter, null);

        var ctx_params = c.whisper_vad_default_context_params();
        ctx_params.use_gpu = false;
        ctx_params.n_threads = 2;

        const vctx = c.whisper_vad_init_from_file_with_params(model_path.ptr, ctx_params);
        if (vctx == null) return error.VadInitFailed;

        return .{ .vctx = vctx.? };
    }

    fn sileroLogFilter(_: c.ggml_log_level, text: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
        if (text == null) return;
        const msg = std.mem.span(text);
        if (std.mem.startsWith(u8, msg, "whisper_vad_detect_speech:")) return;
        std.debug.print("{s}", .{msg});
    }

    pub fn deinit(self: *SileroVad) void {
        c.whisper_vad_free(self.vctx);
    }

    /// Get speech probability from S16_LE PCM. Converts to f32 for Silero.
    pub fn chunkProbS16(self: *SileroVad, chunk: *const [VadFilter.chunk_pcm_bytes]u8) f32 {
        const n_samples = VadFilter.chunk_pcm_bytes / 2;
        var float_buf: [n_samples]f32 = undefined;
        for (&float_buf, 0..) |*sample, i| {
            const offset = i * 2;
            const raw = std.mem.readInt(i16, chunk[offset..][0..2], .little);
            sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
        }

        const ok = c.whisper_vad_detect_speech(self.vctx, &float_buf, n_samples);
        if (!ok) return 0;

        const n_probs = c.whisper_vad_n_probs(self.vctx);
        if (n_probs <= 0) return 0;

        const probs: [*]const f32 = c.whisper_vad_probs(self.vctx) orelse return 0;
        const n: usize = @intCast(n_probs);
        var max_prob: f32 = 0.0;
        for (probs[0..n]) |p| {
            if (p > max_prob) max_prob = p;
        }
        return max_prob;
    }
};

pub const TenVadGgml = struct {
    ctx: *ten_vad_ggml_c.ten_vad_ctx,

    pub fn init(model_path: [:0]const u8) !TenVadGgml {
        const ctx = ten_vad_ggml_c.ten_vad_ggml_init(model_path.ptr) orelse return error.TenVadInitFailed;
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *TenVadGgml) void {
        ten_vad_ggml_c.ten_vad_ggml_free(self.ctx);
    }

    /// Get speech probability from S16_LE PCM.
    /// Processes 256-sample hops (ten-VAD's native size), returns max prob.
    pub fn chunkProbS16(self: *TenVadGgml, chunk: *const [VadFilter.chunk_pcm_bytes]u8) f32 {
        const hop_samples = 256;
        const hop_bytes = hop_samples * 2;
        var max_prob: f32 = 0;
        var offset: usize = 0;
        while (offset + hop_bytes <= VadFilter.chunk_pcm_bytes) {
            var i16_buf: [hop_samples]i16 = undefined;
            for (&i16_buf, 0..) |*out, i| {
                out.* = std.mem.readInt(i16, chunk[offset + i * 2 ..][0..2], .little);
            }
            const prob = ten_vad_ggml_c.ten_vad_ggml_process(self.ctx, &i16_buf, hop_samples);
            if (prob > max_prob) max_prob = prob;
            offset += hop_bytes;
        }
        return max_prob;
    }

    pub fn reset(self: *TenVadGgml) void {
        ten_vad_ggml_c.ten_vad_ggml_reset(self.ctx);
    }
};

// ============================================================
// VadFilter — backend-agnostic state machine
// ============================================================

pub const VadFilter = struct {
    pub const default_threshold: f32 = 0.3;
    pub const default_threshold_off: f32 = 0.1;
    pub const default_min_silence_bytes: usize = 32000; // 1000ms at 32000 bytes/sec
    pub const chunk_pcm_bytes: usize = 1024; // 512 samples * 2 bytes

    threshold: f32 = default_threshold,
    threshold_off: f32 = default_threshold_off,
    min_silence_bytes: usize = default_min_silence_bytes,

    backend: VadBackend,
    allocator: std.mem.Allocator,
    triggered: bool = false,
    silence_bytes: usize = 0,
    last_prob: f32 = 0,
    pcm_partial: [chunk_pcm_bytes]u8 = undefined,
    pcm_partial_len: usize = 0,
    output_buf: std.ArrayListUnmanaged(u8) = .{},

    pub const Options = struct {
        threshold: f32 = default_threshold,
        threshold_off: f32 = default_threshold_off,
        min_silence_bytes: usize = default_min_silence_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, backend: VadBackend, opts: Options) VadFilter {
        return .{
            .backend = backend,
            .allocator = allocator,
            .threshold = opts.threshold,
            .threshold_off = opts.threshold_off,
            .min_silence_bytes = opts.min_silence_bytes,
        };
    }

    pub fn deinit(self: *VadFilter) void {
        self.output_buf.deinit(self.allocator);
    }

    /// Pure state machine update — unit-testable without C FFI.
    /// Returns true if the chunk should be forwarded (speech or bridging silence).
    pub fn processChunkProb(self: *VadFilter, prob: f32) bool {
        if (!self.triggered) {
            if (prob >= self.threshold) {
                self.triggered = true;
                self.silence_bytes = 0;
                return true;
            }
            return false;
        }

        // Currently triggered
        if (prob >= self.threshold_off) {
            self.silence_bytes = 0;
            return true;
        }

        // Below threshold_off — accumulate silence
        self.silence_bytes += chunk_pcm_bytes;
        if (self.silence_bytes >= self.min_silence_bytes) {
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

    pub fn processOneChunk(self: *VadFilter, chunk: *const [chunk_pcm_bytes]u8) bool {
        const prob = self.backend.chunkProb(chunk);
        self.last_prob = prob;
        return self.processChunkProb(prob);
    }

    pub fn reset(self: *VadFilter) void {
        self.triggered = false;
        self.silence_bytes = 0;
        self.pcm_partial_len = 0;
        self.last_prob = 0;
        self.backend.reset();
    }
};

// ============================================================
// VadFilter unit tests (processChunkProb only — no C FFI needed)
// ============================================================

test "processChunkProb: not triggered, below threshold -> stays not-triggered" {
    var filter = VadFilter{
        .backend = undefined,
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(!filter.processChunkProb(0.2));
    try std.testing.expect(!filter.triggered);
}

test "processChunkProb: not triggered, above threshold -> triggers" {
    var filter = VadFilter{
        .backend = undefined,
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(filter.processChunkProb(0.5));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(@as(usize, 0), filter.silence_bytes);
}

test "processChunkProb: not triggered, exact threshold boundary -> triggers" {
    var filter = VadFilter{
        .backend = undefined,
        .allocator = std.testing.allocator,
    };
    try std.testing.expect(filter.processChunkProb(VadFilter.default_threshold));
    try std.testing.expect(filter.triggered);
}

test "processChunkProb: triggered, above threshold_off -> resets silence counter" {
    var filter = VadFilter{
        .backend = undefined,
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
        .backend = undefined,
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
        .backend = undefined,
        .allocator = std.testing.allocator,
        .triggered = true,
        .silence_bytes = VadFilter.default_min_silence_bytes - VadFilter.chunk_pcm_bytes,
    };
    // This chunk pushes silence_bytes past min_silence_bytes
    try std.testing.expect(!filter.processChunkProb(0.05));
    try std.testing.expect(!filter.triggered);
}

test "processChunkProb: speech during bridging -> resets silence counter" {
    var filter = VadFilter{
        .backend = undefined,
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
        .backend = undefined,
        .allocator = std.testing.allocator,
        .triggered = true,
        .silence_bytes = 4096,
    };
    try std.testing.expect(filter.processChunkProb(VadFilter.default_threshold_off));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(@as(usize, 0), filter.silence_bytes);
}
