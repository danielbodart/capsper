const std = @import("std");
const c = @import("whisper_c.zig");

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
