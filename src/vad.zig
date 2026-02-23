const std = @import("std");
const c = @import("whisper_c.zig");

const ten_vad_ggml_c = @cImport({
    @cInclude("ten_vad_ggml.h");
});

const ten_vad_native_c = @cImport({
    @cInclude("ten_vad.h");
});

// ============================================================
// VAD Backends
// ============================================================

pub const VadBackend = union(enum) {
    silero: *SileroVad,
    ten_vad_ggml: *TenVadGgml,
    ten_native: *TenVadNative,

    /// Native chunk size in bytes for this backend.
    pub fn chunkBytes(self: VadBackend) usize {
        return switch (self) {
            .silero => SileroVad.chunk_bytes,
            .ten_vad_ggml => TenVadGgml.chunk_bytes,
            .ten_native => TenVadNative.chunk_bytes,
        };
    }

    /// Get speech probability for a chunk of S16_LE PCM bytes.
    /// Each backend handles its own format conversion internally.
    pub fn chunkProb(self: VadBackend, chunk: []const u8) f32 {
        return switch (self) {
            .silero => |vad| vad.chunkProbS16(chunk),
            .ten_vad_ggml => |tv| tv.chunkProbS16(chunk),
            .ten_native => |tv| tv.chunkProbS16(chunk),
        };
    }

    pub fn reset(self: VadBackend) void {
        switch (self) {
            .silero => |vad| vad.reset(),
            .ten_vad_ggml => |tv| tv.reset(),
            .ten_native => |tv| tv.reset(),
        }
    }

    pub fn name(self: VadBackend) []const u8 {
        return switch (self) {
            .silero => "silero",
            .ten_vad_ggml => "ten-vad",
            .ten_native => "ten-native",
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
            .ten_native => .{ .onset = 0.6, .offset = 0.5, .min_silence_ms = 1000 },
        };
    }
};

pub const SileroVad = struct {
    pub const chunk_bytes: usize = 1024; // 512 samples * 2 bytes — Silero's native n_window

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

    pub fn reset(self: *SileroVad) void {
        c.whisper_vad_reset_state(self.vctx);
    }

    /// Get speech probability from S16_LE PCM. Converts to f32 for Silero.
    pub fn chunkProbS16(self: *SileroVad, chunk: []const u8) f32 {
        const n_samples = chunk.len / 2;
        var float_buf: [chunk_bytes / 2]f32 = undefined;
        for (float_buf[0..n_samples], 0..) |*sample, i| {
            const off = i * 2;
            const raw = std.mem.readInt(i16, chunk[off..][0..2], .little);
            sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
        }

        const ok = c.whisper_vad_detect_speech_no_reset(self.vctx, &float_buf, @intCast(n_samples));
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
    pub const chunk_bytes: usize = 512; // 256 samples * 2 bytes — TEN-VAD's native hop

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
    pub fn chunkProbS16(self: *TenVadGgml, chunk: []const u8) f32 {
        const hop_samples = 256;
        const hop_bytes = hop_samples * 2;
        var max_prob: f32 = 0;
        var offset: usize = 0;
        while (offset + hop_bytes <= chunk.len) {
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

pub const TenVadNative = struct {
    pub const chunk_bytes: usize = 512; // 256 samples * 2 bytes — same hop as GGML

    handle: ten_vad_native_c.ten_vad_handle_t,

    pub fn init() !TenVadNative {
        var handle: ten_vad_native_c.ten_vad_handle_t = null;
        const rc = ten_vad_native_c.ten_vad_create(&handle, 256, 0.5);
        if (rc != 0 or handle == null) return error.TenVadNativeInitFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *TenVadNative) void {
        _ = ten_vad_native_c.ten_vad_destroy(&self.handle);
    }

    /// Get speech probability from S16_LE PCM.
    /// Processes 256-sample hops (ten-VAD's native size), returns max prob.
    pub fn chunkProbS16(self: *TenVadNative, chunk: []const u8) f32 {
        const hop_samples = 256;
        const hop_bytes = hop_samples * 2;
        var max_prob: f32 = 0;
        var offset: usize = 0;
        while (offset + hop_bytes <= chunk.len) {
            var i16_buf: [hop_samples]i16 = undefined;
            for (&i16_buf, 0..) |*out, i| {
                out.* = std.mem.readInt(i16, chunk[offset + i * 2 ..][0..2], .little);
            }
            var prob: f32 = 0;
            var flag: c_int = 0;
            _ = ten_vad_native_c.ten_vad_process(self.handle, &i16_buf, hop_samples, &prob, &flag);
            if (prob > max_prob) max_prob = prob;
            offset += hop_bytes;
        }
        return max_prob;
    }

    pub fn reset(self: *TenVadNative) void {
        // Native library has no reset — destroy and recreate
        _ = ten_vad_native_c.ten_vad_destroy(&self.handle);
        self.handle = null;
        _ = ten_vad_native_c.ten_vad_create(&self.handle, 256, 0.5);
    }
};

// ============================================================
// VadFilter — backend-agnostic state machine
// ============================================================

pub const VadFilter = struct {
    pub const default_threshold: f32 = 0.3;
    pub const default_threshold_off: f32 = 0.1;
    pub const default_min_silence_bytes: usize = 32000; // 1000ms at 32000 bytes/sec
    pub const max_chunk_bytes: usize = 1024; // buffer size — fits largest backend (Silero)

    threshold: f32 = default_threshold,
    threshold_off: f32 = default_threshold_off,
    min_silence_bytes: usize = default_min_silence_bytes,
    chunk_size: usize, // runtime — set from backend.chunkBytes()

    backend: VadBackend,
    allocator: std.mem.Allocator,
    triggered: bool = false,
    silence_bytes: usize = 0,
    last_prob: f32 = 0,
    pcm_partial: [max_chunk_bytes]u8 = undefined,
    pcm_partial_len: usize = 0,
    output_buf: std.ArrayListUnmanaged(u8) = .{},

    pub const AudioEvent = struct {
        audio: []const u8, // filtered speech (valid until next filterAudio call)
        onset_byte_offset: ?usize, // byte offset into input where onset was detected
        trailing_silence_bytes: usize, // silence_bytes at the moment offset fired
    };

    pub const Options = struct {
        threshold: f32 = default_threshold,
        threshold_off: f32 = default_threshold_off,
        min_silence_bytes: usize = default_min_silence_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, backend: VadBackend, opts: Options) VadFilter {
        return .{
            .backend = backend,
            .allocator = allocator,
            .chunk_size = backend.chunkBytes(),
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
        self.silence_bytes += self.chunk_size;
        if (self.silence_bytes >= self.min_silence_bytes) {
            self.triggered = false;
            return false;
        }
        // Bridging: still triggered but below threshold_off
        return true;
    }

    /// Filter audio, returning an AudioEvent with filtered speech PCM and
    /// precise onset/offset byte positions for trimming.
    pub fn filterAudio(self: *VadFilter, pcm_bytes: []const u8) AudioEvent {
        self.output_buf.items.len = 0;
        var onset_byte_offset: ?usize = null;
        var trailing_silence_bytes: usize = 0;

        var carry_consumed: usize = 0;
        var pos: usize = 0;
        var input = pcm_bytes;

        const fail_event = AudioEvent{
            .audio = self.output_buf.items,
            .onset_byte_offset = onset_byte_offset,
            .trailing_silence_bytes = trailing_silence_bytes,
        };

        // Handle partial chunk carryover from previous call
        const cs = self.chunk_size;
        if (self.pcm_partial_len > 0) {
            const need = cs - self.pcm_partial_len;
            if (input.len >= need) {
                @memcpy(self.pcm_partial[self.pcm_partial_len..self.pcm_partial_len + need], input[0..need]);
                const partial_chunk = self.pcm_partial[0..cs];
                const was_triggered = self.triggered;
                const forward = self.processOneChunk(partial_chunk);
                if (!was_triggered and self.triggered) {
                    onset_byte_offset = 0;
                }
                if (was_triggered and !self.triggered) {
                    trailing_silence_bytes = self.silence_bytes;
                }
                if (forward) {
                    self.output_buf.appendSlice(self.allocator, partial_chunk) catch return fail_event;
                }
                carry_consumed = need;
                input = input[need..];
                self.pcm_partial_len = 0;
            } else {
                // Still not enough for a full chunk — buffer and use current triggered state
                @memcpy(self.pcm_partial[self.pcm_partial_len .. self.pcm_partial_len + input.len], input);
                self.pcm_partial_len += input.len;
                if (self.triggered) {
                    self.output_buf.appendSlice(self.allocator, input) catch {};
                }
                return .{
                    .audio = self.output_buf.items,
                    .onset_byte_offset = onset_byte_offset,
                    .trailing_silence_bytes = trailing_silence_bytes,
                };
            }
        }

        // Process complete chunks
        while (pos + cs <= input.len) {
            const chunk = input[pos..][0..cs];
            const was_triggered = self.triggered;
            const forward = self.processOneChunk(chunk);
            if (!was_triggered and self.triggered) {
                onset_byte_offset = carry_consumed + pos;
            }
            if (was_triggered and !self.triggered) {
                trailing_silence_bytes = self.silence_bytes;
            }
            if (forward) {
                self.output_buf.appendSlice(self.allocator, chunk) catch return fail_event;
            }
            pos += cs;
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

        return .{
            .audio = self.output_buf.items,
            .onset_byte_offset = onset_byte_offset,
            .trailing_silence_bytes = trailing_silence_bytes,
        };
    }

    pub fn processOneChunk(self: *VadFilter, chunk: []const u8) bool {
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
        .chunk_size = 512,
    };
    try std.testing.expect(!filter.processChunkProb(0.2));
    try std.testing.expect(!filter.triggered);
}

test "processChunkProb: not triggered, above threshold -> triggers" {
    var filter = VadFilter{
        .backend = undefined,
        .allocator = std.testing.allocator,
        .chunk_size = 512,
    };
    try std.testing.expect(filter.processChunkProb(0.5));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(@as(usize, 0), filter.silence_bytes);
}

test "processChunkProb: not triggered, exact threshold boundary -> triggers" {
    var filter = VadFilter{
        .backend = undefined,
        .allocator = std.testing.allocator,
        .chunk_size = 512,
    };
    try std.testing.expect(filter.processChunkProb(VadFilter.default_threshold));
    try std.testing.expect(filter.triggered);
}

test "processChunkProb: triggered, above threshold_off -> resets silence counter" {
    var filter = VadFilter{
        .backend = undefined,
        .allocator = std.testing.allocator,
        .chunk_size = 512,
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
        .chunk_size = 512,
        .triggered = true,
        .silence_bytes = 0,
    };
    // One chunk of silence (512 bytes) — well below min_silence_bytes (32000)
    try std.testing.expect(filter.processChunkProb(0.05));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(@as(usize, 512), filter.silence_bytes);
}

test "processChunkProb: triggered, sustained silence -> un-triggers" {
    var filter = VadFilter{
        .backend = undefined,
        .allocator = std.testing.allocator,
        .chunk_size = 512,
        .triggered = true,
        .silence_bytes = VadFilter.default_min_silence_bytes - 512,
    };
    // This chunk pushes silence_bytes past min_silence_bytes
    try std.testing.expect(!filter.processChunkProb(0.05));
    try std.testing.expect(!filter.triggered);
}

test "processChunkProb: speech during bridging -> resets silence counter" {
    var filter = VadFilter{
        .backend = undefined,
        .allocator = std.testing.allocator,
        .chunk_size = 512,
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
        .chunk_size = 512,
        .triggered = true,
        .silence_bytes = 4096,
    };
    try std.testing.expect(filter.processChunkProb(VadFilter.default_threshold_off));
    try std.testing.expect(filter.triggered);
    try std.testing.expectEqual(@as(usize, 0), filter.silence_bytes);
}
