const std = @import("std");
const c = @import("whisper_c.zig");

pub const Segment = struct {
    start_s: f32,
    end_s: f32,
};

pub const Vad = struct {
    vctx: *c.whisper_vad_context,
    params: c.whisper_vad_params,

    pub fn init(model_path: [:0]const u8) !Vad {
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
