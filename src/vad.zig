const std = @import("std");
const c = @cImport({
    @cInclude("whisper.h");
});

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

        return .{
            .vctx = vctx.?,
            .params = c.whisper_vad_default_params(),
        };
    }

    pub fn deinit(self: *Vad) void {
        c.whisper_vad_free(self.vctx);
    }

    /// Detect whether audio contains speech.
    pub fn hasSpeech(self: *Vad, samples: []const f32) bool {
        return c.whisper_vad_detect_speech(self.vctx, samples.ptr, @intCast(samples.len));
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
