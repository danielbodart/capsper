/// Incremental NeMo mel feature computation.
///
/// Feeds raw f32 audio samples in arbitrary-sized chunks and produces mel frames
/// compatible with nemo_mel.compute(). Handles cross-chunk preemphasis continuity
/// and center=True reflect padding identically to the batch version.
///
/// Output is frame-major: [frame * N_MELS + band]. Use exportBandMajor() to
/// convert to the [band * n_frames + frame] layout needed by the encoder.
const std = @import("std");
const math = std.math;
const nemo_mel = @import("nemo_mel.zig");

const N_FFT = nemo_mel.N_FFT;
const HOP_LENGTH = nemo_mel.HOP_LENGTH;
const WIN_LENGTH = nemo_mel.WIN_LENGTH;
const N_FFT_BINS = nemo_mel.N_FFT_BINS;
pub const N_MELS = nemo_mel.N_MELS;
const PREEMPH = nemo_mel.PREEMPH;
const LOG_GUARD = nemo_mel.LOG_GUARD;
const PAD = N_FFT / 2; // 256 — center=True padding

pub const NemoMelState = struct {
    allocator: std.mem.Allocator,
    filterbank: []const f32,

    /// All pre-emphasized samples accumulated so far.
    preemph: std.ArrayListUnmanaged(f32) = .{},

    /// Accumulated mel frames in frame-major layout: [frame * N_MELS + band]
    frames: std.ArrayListUnmanaged(f32) = .{},
    n_frames: usize = 0,

    /// Last raw sample for cross-chunk preemphasis continuity.
    last_raw_sample: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, filterbank: []const f32) NemoMelState {
        return .{
            .allocator = allocator,
            .filterbank = filterbank,
        };
    }

    pub fn deinit(self: *NemoMelState) void {
        self.preemph.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    pub fn reset(self: *NemoMelState) void {
        self.preemph.clearRetainingCapacity();
        self.frames.clearRetainingCapacity();
        self.n_frames = 0;
        self.last_raw_sample = 0;
    }

    /// Feed new raw f32 audio samples. Computes as many new mel frames as possible.
    pub fn feed(self: *NemoMelState, raw_samples: []const f32) !void {
        if (raw_samples.len == 0) return;

        // Pre-emphasis with cross-chunk continuity
        try self.preemph.ensureUnusedCapacity(self.allocator, raw_samples.len);
        var prev = self.last_raw_sample;
        for (raw_samples) |s| {
            self.preemph.appendAssumeCapacity(s - PREEMPH * prev);
            prev = s;
        }
        self.last_raw_sample = raw_samples[raw_samples.len - 1];

        // Compute new frames. Uses the same padding logic as nemo_mel.compute().
        try self.computeNewFrames();
    }

    fn computeNewFrames(self: *NemoMelState) !void {
        const pe = self.preemph.items;
        // Padded length = pe.len + 2*PAD (center=True)
        // Total possible frames = (padded_len - N_FFT) / HOP_LENGTH + 1
        // But we can't compute frames that depend on right-reflect padding of
        // future samples. A frame at padded position `frame_start` needs samples
        // up to `frame_start + N_FFT - 1` in padded space. The rightmost real
        // sample used is at padded index `pe.len + PAD - 1`. So we can compute
        // a frame if `frame_start + N_FFT - 1 <= pe.len + PAD - 1`, i.e.
        // `frame_start <= pe.len + PAD - N_FFT = pe.len - PAD`.
        if (pe.len < PAD) return; // Not enough samples for even the first frame

        const max_frame_start = pe.len - PAD; // pe.len + PAD - N_FFT = pe.len - 256
        var frame_start = self.n_frames * HOP_LENGTH;

        var fft_in: [N_FFT * 2]f32 = undefined;
        var fft_out: [N_FFT * 2 * 2 * 2]f32 = undefined;
        var power: [N_FFT_BINS]f32 = undefined;

        while (frame_start <= max_frame_start) {
            @memset(&fft_in, 0);
            const win_offset = (N_FFT - WIN_LENGTH) / 2; // 56

            for (0..N_FFT) |j| {
                const padded_idx = frame_start + j;
                const sample: f32 = if (padded_idx < PAD) blk: {
                    // Left reflect padding
                    const reflect_idx = PAD - padded_idx;
                    break :blk if (reflect_idx < pe.len) pe[reflect_idx] else 0;
                } else if (padded_idx - PAD < pe.len)
                    pe[padded_idx - PAD]
                else blk: {
                    // Right reflect padding (shouldn't happen with our frame limit)
                    const over = padded_idx - PAD - pe.len;
                    const reflect_idx = pe.len -| (2 + over);
                    break :blk if (reflect_idx < pe.len) pe[reflect_idx] else 0;
                };

                if (j >= win_offset and j < win_offset + WIN_LENGTH) {
                    fft_in[j] = HANN_WINDOW[j - win_offset] * sample;
                }
            }

            nemo_mel.fft(&fft_in, N_FFT, &fft_out);

            for (0..N_FFT_BINS) |k| {
                const re = fft_out[2 * k];
                const im = fft_out[2 * k + 1];
                power[k] = re * re + im * im;
            }

            try self.frames.ensureUnusedCapacity(self.allocator, N_MELS);
            for (0..N_MELS) |band| {
                const filter_row = self.filterbank[band * N_FFT_BINS ..][0..N_FFT_BINS];
                var sum: f64 = 0;

                var k: usize = 0;
                while (k + 3 < N_FFT_BINS) : (k += 4) {
                    sum += @as(f64, power[k + 0]) * @as(f64, filter_row[k + 0]) +
                        @as(f64, power[k + 1]) * @as(f64, filter_row[k + 1]) +
                        @as(f64, power[k + 2]) * @as(f64, filter_row[k + 2]) +
                        @as(f64, power[k + 3]) * @as(f64, filter_row[k + 3]);
                }
                while (k < N_FFT_BINS) : (k += 1) {
                    sum += @as(f64, power[k]) * @as(f64, filter_row[k]);
                }

                self.frames.appendAssumeCapacity(@floatCast(@log(sum + LOG_GUARD)));
            }
            self.n_frames += 1;

            frame_start += HOP_LENGTH;
        }
    }

    /// Export a range of frames in band-major layout: [band * count + frame_offset].
    /// This is the layout the streaming encoder expects.
    pub fn exportBandMajor(
        self: *const NemoMelState,
        dst: []f32,
        start_frame: usize,
        count: usize,
    ) void {
        std.debug.assert(start_frame + count <= self.n_frames);
        std.debug.assert(dst.len >= N_MELS * count);

        for (0..N_MELS) |band| {
            for (0..count) |f| {
                dst[band * count + f] = self.frames.items[(start_frame + f) * N_MELS + band];
            }
        }
    }

    // ─── Hann window (same as nemo_mel.zig) ─────────────────────────────────

    const HANN_WINDOW = computeHannWindow();

    fn computeHannWindow() [WIN_LENGTH]f32 {
        const n_f: f64 = @floatFromInt(WIN_LENGTH - 1);
        var w: [WIN_LENGTH]f32 = undefined;
        for (0..WIN_LENGTH) |i| {
            const x: f64 = 2.0 * math.pi * @as(f64, @floatFromInt(i)) / n_f;
            w[i] = @floatCast(0.5 * (1.0 - @cos(x)));
        }
        return w;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "incremental mel matches batch mel" {
    const allocator = std.testing.allocator;

    // Generate a test signal (sine wave at 440Hz, 1 second)
    const n_samples = 16000;
    const samples = try allocator.alloc(f32, n_samples);
    defer allocator.free(samples);
    for (0..n_samples) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 16000.0;
        samples[i] = @floatCast(@sin(2.0 * math.pi * 440.0 * t) * 0.5);
    }

    // Load filterbank (free the underlying u8 allocation via ptrCast)
    const fb = nemo_mel.loadFilterbank(allocator, if (@import("builtin").os.tag == .macos) "dist/macos/models/nemotron/filterbank.bin" else "dist/linux/models/nemotron/filterbank.bin") catch return;
    defer allocator.free(@as([*]u8, @ptrCast(fb.ptr))[0 .. fb.len * @sizeOf(f32)]);

    // Batch computation (reference)
    const batch = try nemo_mel.compute(allocator, samples, fb);
    defer batch.deinit(allocator);

    // Incremental computation — feed in chunks of various sizes
    var state = NemoMelState.init(allocator, fb);
    defer state.deinit();

    const chunk_sizes = [_]usize{ 1600, 3200, 800, 4000, 2000, 1600, 2800 };
    var offset: usize = 0;
    for (chunk_sizes) |cs| {
        const end = @min(offset + cs, n_samples);
        try state.feed(samples[offset..end]);
        offset = end;
        if (offset >= n_samples) break;
    }

    // Compare frames — should be bit-identical since we use the same logic
    const common_frames = @min(state.n_frames, batch.n_frames);
    try std.testing.expect(common_frames > 0);

    var max_diff: f32 = 0;
    for (0..common_frames) |f| {
        for (0..N_MELS) |band| {
            const inc_val = state.frames.items[f * N_MELS + band];
            const batch_val = batch.features[band * batch.n_frames + f];
            const diff = @abs(inc_val - batch_val);
            if (diff > max_diff) max_diff = diff;
        }
    }

    // Same algorithm, same data → should be exact match (or very close due to FP)
    try std.testing.expect(max_diff < 1e-6);
}

test "incremental mel — single sample at a time" {
    const allocator = std.testing.allocator;

    const n_samples = 3200; // 200ms
    const samples = try allocator.alloc(f32, n_samples);
    defer allocator.free(samples);
    for (0..n_samples) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / 16000.0;
        samples[i] = @floatCast(@sin(2.0 * math.pi * 1000.0 * t) * 0.3);
    }

    const fb = nemo_mel.loadFilterbank(allocator, if (@import("builtin").os.tag == .macos) "dist/macos/models/nemotron/filterbank.bin" else "dist/linux/models/nemotron/filterbank.bin") catch return;
    defer allocator.free(@as([*]u8, @ptrCast(fb.ptr))[0 .. fb.len * @sizeOf(f32)]);

    // Feed one sample at a time
    var state = NemoMelState.init(allocator, fb);
    defer state.deinit();

    for (samples) |s| {
        try state.feed(&.{s});
    }

    // Batch reference
    const batch = try nemo_mel.compute(allocator, samples, fb);
    defer batch.deinit(allocator);

    const common_frames = @min(state.n_frames, batch.n_frames);
    try std.testing.expect(common_frames > 0);

    var max_diff: f32 = 0;
    for (0..common_frames) |f| {
        for (0..N_MELS) |band| {
            const inc_val = state.frames.items[f * N_MELS + band];
            const batch_val = batch.features[band * batch.n_frames + f];
            const diff = @abs(inc_val - batch_val);
            if (diff > max_diff) max_diff = diff;
        }
    }

    // Same logic regardless of chunk size → should match
    try std.testing.expect(max_diff < 1e-6);
}

test "exportBandMajor layout" {
    const allocator = std.testing.allocator;

    var state = NemoMelState{
        .allocator = allocator,
        .filterbank = &.{},
    };
    defer state.deinit();

    // Manually insert 2 frames of fake data in frame-major layout
    for (0..2) |f| {
        for (0..N_MELS) |b| {
            try state.frames.append(allocator, @as(f32, @floatFromInt(f)) + @as(f32, @floatFromInt(b)) * 0.01);
        }
    }
    state.n_frames = 2;

    var dst: [N_MELS * 2]f32 = undefined;
    state.exportBandMajor(&dst, 0, 2);

    // Band-major: dst[band * 2 + frame]
    try std.testing.expectApproxEqAbs(dst[0 * 2 + 0], 0.0, 1e-6);
    try std.testing.expectApproxEqAbs(dst[0 * 2 + 1], 1.0, 1e-6);
    try std.testing.expectApproxEqAbs(dst[1 * 2 + 0], 0.01, 1e-6);
    try std.testing.expectApproxEqAbs(dst[1 * 2 + 1], 1.01, 1e-6);
}
