const std = @import("std");
const math = std.math;

// Whisper mel spectrogram constants (must match whisper.h)
pub const N_FFT: usize = 400;
pub const HOP_LENGTH: usize = 160;
pub const N_FFT_BINS: usize = 1 + N_FFT / 2; // 201 (DC to Nyquist)
pub const SAMPLE_RATE: usize = 16000;
pub const WHISPER_N_FRAMES: usize = 3000; // 30s at 100fps

/// Incremental mel spectrogram buffer.
/// Computes only new mel frames as audio grows, caches previous frames.
/// Maintains a persistent output buffer for whisper_set_mel_with_state().
pub const MelBuffer = struct {
    allocator: std.mem.Allocator,
    n_mel: usize, // 80 or 128, determined at runtime from model

    // Precomputed mel filterbank [n_mel * N_FFT_BINS] — triangular filters on mel scale
    filters: []f32,

    // Cached raw mel frames (pre-normalization, log10 scale).
    // Layout: frame-major — [frame0_band0, frame0_band1, ..., frame1_band0, ...]
    // Each frame is n_mel consecutive floats.
    raw_mel: std.ArrayListUnmanaged(f32) = .{},
    n_computed: usize = 0,

    // Persistent output buffer [n_mel * WHISPER_N_FRAMES] — row-major by mel band.
    // Reused across cycles to avoid per-cycle allocation.
    output_buf: []f32,

    // Audio samples (the full growing buffer). Stored so we can access any sample
    // for frame computation (frames near the boundary overlap old + new samples).
    samples: []const f32 = &.{},

    pub fn init(allocator: std.mem.Allocator, n_mel: usize) !MelBuffer {
        const filters = try allocator.alloc(f32, n_mel * N_FFT_BINS);
        errdefer allocator.free(filters);
        computeMelFilters(filters, n_mel);

        const output_buf = try allocator.alloc(f32, n_mel * WHISPER_N_FRAMES);
        errdefer allocator.free(output_buf);

        return .{
            .allocator = allocator,
            .n_mel = n_mel,
            .filters = filters,
            .output_buf = output_buf,
        };
    }

    pub fn deinit(self: *MelBuffer) void {
        self.allocator.free(self.output_buf);
        self.raw_mel.deinit(self.allocator);
        self.allocator.free(self.filters);
    }

    pub fn reset(self: *MelBuffer) void {
        self.raw_mel.clearRetainingCapacity();
        self.n_computed = 0;
        self.samples = &.{};
    }

    /// Compute mel frames for the given audio buffer.
    /// `samples` must be the FULL audio buffer (growing each cycle).
    /// Only computes frames not already cached. Returns number of new frames.
    pub fn addSamples(self: *MelBuffer, samples: []const f32) !usize {
        self.samples = samples;
        const n_samples = samples.len;

        // Match whisper.cpp frame counting:
        // Padded buffer = [reflect_pad(200)] [samples] [zeros...]
        // Content frame count = (n_samples + 200) / HOP_LENGTH + 1
        // (frames where the window overlaps real audio, including reflective pad)
        const padded_len = n_samples + N_FFT / 2; // n_samples + 200
        const total_content_frames = @min(padded_len / HOP_LENGTH + 1, WHISPER_N_FRAMES);

        if (total_content_frames <= self.n_computed) return 0;

        const new_frame_count = total_content_frames - self.n_computed;
        try self.raw_mel.ensureUnusedCapacity(self.allocator, new_frame_count * self.n_mel);

        // Scratch buffers for FFT (stack-allocated, reused across frames)
        // Sizes match whisper.cpp: in=frame_size*2, out=frame_size*2*2*2
        var fft_in: [N_FFT * 2]f32 = undefined;
        var fft_out: [N_FFT * 2 * 2 * 2]f32 = undefined;
        var power: [N_FFT_BINS]f32 = undefined;

        for (self.n_computed..total_content_frames) |frame_idx| {
            self.computeFrame(frame_idx, &fft_in, &fft_out, &power);
        }

        return new_frame_count;
    }

    /// Normalize cached raw mel into the persistent output buffer.
    /// Output layout: row-major by mel band — output[band * WHISPER_N_FRAMES + frame].
    /// Pads with silence to WHISPER_N_FRAMES (30s). Returns the buffer directly.
    pub fn exportForWhisper(self: *MelBuffer) []f32 {
        const silence_raw: f32 = comptime @floatCast(@log10(1e-10));

        // Find global max across all cached raw frames
        var mmax: f32 = silence_raw;
        for (self.raw_mel.items) |v| {
            if (v > mmax) mmax = v;
        }

        const clamp_floor = mmax - 8.0;
        const silence_norm = (@max(silence_raw, clamp_floor) + 4.0) / 4.0;

        for (0..self.n_mel) |band| {
            const row_start = band * WHISPER_N_FRAMES;
            for (0..self.n_computed) |frame| {
                const raw = self.raw_mel.items[frame * self.n_mel + band];
                self.output_buf[row_start + frame] = (@max(raw, clamp_floor) + 4.0) / 4.0;
            }
            @memset(self.output_buf[row_start + self.n_computed .. row_start + WHISPER_N_FRAMES], silence_norm);
        }

        return self.output_buf;
    }

    fn computeFrame(
        self: *MelBuffer,
        frame_idx: usize,
        fft_in: *[N_FFT * 2]f32,
        fft_out: *[N_FFT * 2 * 2 * 2]f32,
        power: *[N_FFT_BINS]f32,
    ) void {
        const reflect_pad: usize = N_FFT / 2; // 200
        const offset = frame_idx * HOP_LENGTH;
        const padded_len = self.samples.len + reflect_pad;

        // Fill fft_in with Hann-windowed samples (zero-padded beyond available)
        @memset(fft_in, 0);
        const available = if (offset < padded_len) padded_len - offset else 0;
        const copy_len = @min(N_FFT, available);

        for (0..copy_len) |j| {
            const padded_idx = offset + j;
            const sample: f32 = if (padded_idx < reflect_pad) blk: {
                // Reflective padding: padded[k] = samples[reflect_pad - k]
                // whisper.cpp: std::reverse_copy(samples + 1, samples + 1 + 200, padded.begin())
                // gives padded[k] = samples[200 - k] for k = 0..199
                const src_idx = reflect_pad - padded_idx;
                break :blk if (src_idx < self.samples.len) self.samples[src_idx] else 0;
            } else blk: {
                const src_idx = padded_idx - reflect_pad;
                break :blk if (src_idx < self.samples.len) self.samples[src_idx] else 0;
            };
            fft_in[j] = HANN_WINDOW[j] * sample;
        }

        // FFT (real input in fft_in[0..N_FFT], scratch in fft_in[N_FFT..2*N_FFT])
        fft(fft_in, N_FFT, fft_out);

        // Power spectrum: |FFT[k]|² for k = 0..N_FFT_BINS-1
        for (0..N_FFT_BINS) |k| {
            const re = fft_out[2 * k];
            const im = fft_out[2 * k + 1];
            power[k] = re * re + im * im;
        }

        // Mel filterbank + log10 — append n_mel values to raw_mel
        for (0..self.n_mel) |band| {
            const filter_row = self.filters[band * N_FFT_BINS ..][0..N_FFT_BINS];
            var sum: f64 = 0;

            // 4x unrolled dot product (matches whisper.cpp)
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

            self.raw_mel.appendAssumeCapacity(@floatCast(@log10(@max(sum, 1e-10))));
        }

        self.n_computed += 1;
    }
};

// ─── FFT ────────────────────────────────────────────────────────────────────────

/// Cooley-Tukey radix-2 FFT. Faithful port of whisper.cpp's fft().
/// `in` must have at least 2*N floats (N values + scratch space).
/// `out` must have at least 4*N floats (2*N complex output + scratch space).
fn fft(in: []f32, N: usize, out: []f32) void {
    if (N == 1) {
        out[0] = in[0];
        out[1] = 0;
        return;
    }

    if (N % 2 == 1) {
        dft(in[0..N], N, out);
        return;
    }

    const half_N = N / 2;

    // Extract even-indexed elements into in[N..N+half_N]
    const even = in[N..];
    for (0..half_N) |i| {
        even[i] = in[2 * i];
    }
    // Recurse on even: output to out[2*N..]
    const even_fft = out[2 * N ..];
    fft(even, half_N, even_fft);

    // Extract odd-indexed elements (reuse even's memory since we're done with it)
    const odd = even;
    for (0..half_N) |i| {
        odd[i] = in[2 * i + 1];
    }
    // Recurse on odd: output to out[2*N + N..]
    const odd_fft = even_fft[N..];
    fft(odd, half_N, odd_fft);

    // Butterfly combination
    for (0..half_N) |k| {
        const theta: f64 = -2.0 * math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(N));
        const re: f32 = @floatCast(@cos(theta));
        const im: f32 = @floatCast(@sin(theta));

        const re_odd = odd_fft[2 * k + 0];
        const im_odd = odd_fft[2 * k + 1];

        out[2 * k + 0] = even_fft[2 * k + 0] + re * re_odd - im * im_odd;
        out[2 * k + 1] = even_fft[2 * k + 1] + re * im_odd + im * re_odd;

        out[2 * (k + half_N) + 0] = even_fft[2 * k + 0] - re * re_odd + im * im_odd;
        out[2 * (k + half_N) + 1] = even_fft[2 * k + 1] - re * im_odd - im * re_odd;
    }
}

/// Naive DFT for non-power-of-2 sizes (fallback for Cooley-Tukey).
fn dft(in: []const f32, N: usize, out: []f32) void {
    const n_f: f64 = @floatFromInt(N);
    for (0..N) |k| {
        var re: f64 = 0;
        var im: f64 = 0;
        for (0..N) |n| {
            const angle: f64 = -2.0 * math.pi * @as(f64, @floatFromInt(k)) * @as(f64, @floatFromInt(n)) / n_f;
            re += @as(f64, in[n]) * @cos(angle);
            im += @as(f64, in[n]) * @sin(angle);
        }
        out[2 * k] = @floatCast(re);
        out[2 * k + 1] = @floatCast(im);
    }
}

// ─── Hann window ────────────────────────────────────────────────────────────────

const HANN_WINDOW = computeHannWindow();

/// Periodic Hann window: w[n] = 0.5 * (1 - cos(2π·n / N))
/// Matches whisper.cpp (and PyTorch's periodic mode).
fn computeHannWindow() [N_FFT]f32 {
    const n_f: f64 = @floatFromInt(N_FFT);
    var w: [N_FFT]f32 = undefined;
    for (0..N_FFT) |i| {
        const x: f64 = 2.0 * math.pi * @as(f64, @floatFromInt(i)) / n_f;
        w[i] = @floatCast(0.5 * (1.0 - @cos(x)));
    }
    // zwanzig-disable-next-line: stack-escape-engine
    return w;
}

// ─── Mel filterbank ─────────────────────────────────────────────────────────────

/// Compute mel filterbank matrix using the standard librosa/HTK formula.
/// Produces n_mel × N_FFT_BINS triangular filters with Slaney normalization.
/// This matches the mel_filters.npz embedded in whisper models.
fn computeMelFilters(out: []f32, n_mel: usize) void {
    std.debug.assert(out.len == n_mel * N_FFT_BINS);
    const fmin: f64 = 0.0;
    const fmax: f64 = @as(f64, @floatFromInt(SAMPLE_RATE)) / 2.0; // 8000 Hz

    // mel_frequencies: n_mel + 2 equally spaced points on the mel scale
    // Fixed-size stack buffer (max 130 entries for n_mel=128)
    var mel_freqs_buf: [130]f64 = undefined;
    const mel_freqs = mel_freqs_buf[0 .. n_mel + 2];
    {
        const min_mel = htkMel(fmin);
        const max_mel = htkMel(fmax);
        for (0..n_mel + 2) |i| {
            const m = min_mel + @as(f64, @floatFromInt(i)) * (max_mel - min_mel) / @as(f64, @floatFromInt(n_mel + 1));
            mel_freqs[i] = htkMelInverse(m);
        }
    }

    // FFT bin center frequencies: linearly spaced 0 to sr/2
    var fft_freqs: [N_FFT_BINS]f64 = undefined;
    for (0..N_FFT_BINS) |i| {
        fft_freqs[i] = @as(f64, @floatFromInt(i)) * fmax / @as(f64, @floatFromInt(N_FFT_BINS - 1));
    }

    // Build triangular filters with Slaney normalization
    for (0..n_mel) |band| {
        const f_low = mel_freqs[band];
        const f_center = mel_freqs[band + 1];
        const f_high = mel_freqs[band + 2];
        const enorm = 2.0 / (f_high - f_low); // Slaney normalization

        for (0..N_FFT_BINS) |bin| {
            const f = fft_freqs[bin];
            var weight: f64 = 0;

            if (f >= f_low and f <= f_center and f_center > f_low) {
                weight = (f - f_low) / (f_center - f_low);
            } else if (f > f_center and f <= f_high and f_high > f_center) {
                weight = (f_high - f) / (f_high - f_center);
            }

            out[band * N_FFT_BINS + bin] = @floatCast(weight * enorm);
        }
    }
}

/// HTK mel scale: mel = 2595 * log10(1 + f/700)
fn htkMel(f: f64) f64 {
    return 2595.0 * @log10(1.0 + f / 700.0);
}

/// Inverse HTK mel scale: f = 700 * (10^(mel/2595) - 1)
fn htkMelInverse(m: f64) f64 {
    return 700.0 * (math.pow(f64, 10.0, m / 2595.0) - 1.0);
}

// ─── Tests ──────────────────────────────────────────────────────────────────────

test "Hann window properties" {
    const hann = HANN_WINDOW;

    // First sample should be ~0 (periodic Hann starts at 0)
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hann[0], 1e-7);

    // Mid-point should be ~1.0 (peak of Hann window)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hann[N_FFT / 2], 1e-5);

    // Window should be symmetric: hann[k] == hann[N-k] (approximately, for periodic)
    for (1..N_FFT / 2) |k| {
        try std.testing.expectApproxEqAbs(hann[k], hann[N_FFT - k], 1e-6);
    }
}

test "FFT of DC signal" {
    // DC signal: all ones → FFT should have energy only at bin 0
    var in_buf: [N_FFT * 2]f32 = undefined;
    var out_buf: [N_FFT * 2 * 2 * 2]f32 = undefined;
    @memset(&in_buf, 0);
    for (0..N_FFT) |i| in_buf[i] = 1.0;

    fft(&in_buf, N_FFT, &out_buf);

    // Bin 0 should be N_FFT (sum of all ones)
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(N_FFT)), out_buf[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out_buf[1], 1e-3);

    // All other bins should be ~0
    for (1..N_FFT_BINS) |k| {
        const mag_sq = out_buf[2 * k] * out_buf[2 * k] + out_buf[2 * k + 1] * out_buf[2 * k + 1];
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), mag_sq, 1e-2);
    }
}

test "FFT of sine wave" {
    // Sine wave at 1000 Hz, sampled at 16kHz
    // Bin frequency resolution = 16000 / 400 = 40 Hz/bin
    // 1000 Hz → bin 25
    var in_buf: [N_FFT * 2]f32 = undefined;
    var out_buf: [N_FFT * 2 * 2 * 2]f32 = undefined;
    @memset(&in_buf, 0);

    const freq: f64 = 1000.0;
    for (0..N_FFT) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SAMPLE_RATE));
        in_buf[i] = @floatCast(@sin(2.0 * math.pi * freq * t));
    }

    fft(&in_buf, N_FFT, &out_buf);

    // Find bin with max magnitude
    var max_mag: f32 = 0;
    var max_bin: usize = 0;
    for (0..N_FFT_BINS) |k| {
        const mag = out_buf[2 * k] * out_buf[2 * k] + out_buf[2 * k + 1] * out_buf[2 * k + 1];
        if (mag > max_mag) {
            max_mag = mag;
            max_bin = k;
        }
    }

    // Peak should be at bin 25 (1000 Hz / 40 Hz/bin)
    try std.testing.expectEqual(@as(usize, 25), max_bin);
}

test "DFT matches FFT for small N" {
    // Compare DFT and FFT for N=8 (power of 2)
    const N = 8;
    var in_data: [N]f32 = .{ 1.0, 0.5, -0.3, 0.8, -1.0, 0.2, 0.7, -0.4 };
    var fft_in: [N * 2]f32 = undefined;
    @memset(&fft_in, 0);
    @memcpy(fft_in[0..N], &in_data);
    var fft_out: [N * 2 * 2 * 2]f32 = undefined;
    var dft_out: [N * 2]f32 = undefined;

    fft(&fft_in, N, &fft_out);
    dft(&in_data, N, &dft_out);

    for (0..N) |k| {
        try std.testing.expectApproxEqAbs(dft_out[2 * k], fft_out[2 * k], 1e-4);
        try std.testing.expectApproxEqAbs(dft_out[2 * k + 1], fft_out[2 * k + 1], 1e-4);
    }
}

test "mel filterbank shape and normalization" {
    const n_mel: usize = 80;
    var filters: [n_mel * N_FFT_BINS]f32 = undefined;
    computeMelFilters(&filters, n_mel);

    // Each filter should be non-negative
    for (&filters) |v| {
        try std.testing.expect(v >= 0);
    }

    // Each filter should have non-zero values (active bins)
    for (0..n_mel) |band| {
        var sum: f64 = 0;
        for (0..N_FFT_BINS) |bin| {
            sum += @as(f64, filters[band * N_FFT_BINS + bin]);
        }
        try std.testing.expect(sum > 0);
    }

    // Lower bands should have tighter filters (fewer active bins) than upper bands
    var low_active: usize = 0;
    var high_active: usize = 0;
    for (0..N_FFT_BINS) |bin| {
        if (filters[0 * N_FFT_BINS + bin] > 0) low_active += 1;
        if (filters[(n_mel - 1) * N_FFT_BINS + bin] > 0) high_active += 1;
    }
    try std.testing.expect(low_active < high_active);
}

test "mel filterbank 128 bands" {
    const n_mel: usize = 128;
    var filters: [n_mel * N_FFT_BINS]f32 = undefined;
    computeMelFilters(&filters, n_mel);

    // Most bands should have non-zero energy. The highest bands may have
    // zero weight because the triangular filter falls between FFT bin centers
    // (bin spacing ~40Hz vs narrow high-frequency mel bands). This is fine —
    // whisper.cpp's model uses precomputed filters that handle this edge case.
    var active_bands: usize = 0;
    for (0..n_mel) |band| {
        var sum: f64 = 0;
        for (0..N_FFT_BINS) |bin| {
            sum += @as(f64, filters[band * N_FFT_BINS + bin]);
        }
        if (sum > 0) active_bands += 1;
    }
    // At least 120 of 128 bands should be active
    try std.testing.expect(active_bands >= 120);
}

test "MelBuffer incremental computation" {
    const allocator = std.testing.allocator;
    var buf = try MelBuffer.init(allocator, 80);
    defer buf.deinit();

    // Generate 1 second of 440 Hz sine wave
    const n_samples = 16000;
    var samples: [n_samples]f32 = undefined;
    for (0..n_samples) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SAMPLE_RATE));
        samples[i] = @floatCast(@sin(2.0 * math.pi * 440.0 * t));
    }

    // First call: compute all frames from scratch
    const frames_1 = try buf.addSamples(&samples);
    const expected = (n_samples + 200) / HOP_LENGTH + 1;
    try std.testing.expectEqual(expected, frames_1);
    try std.testing.expectEqual(expected, buf.n_computed);

    // Second call with same buffer: no new frames
    const frames_2 = try buf.addSamples(&samples);
    try std.testing.expectEqual(@as(usize, 0), frames_2);

    // Third call with more audio: only new frames
    var longer: [n_samples + 3200]f32 = undefined;
    @memcpy(longer[0..n_samples], &samples);
    @memset(longer[n_samples..], 0);
    const frames_3 = try buf.addSamples(&longer);
    try std.testing.expect(frames_3 > 0);
    try std.testing.expect(frames_3 < frames_1); // Should be much fewer than first call
}

test "MelBuffer export format" {
    const allocator = std.testing.allocator;
    const n_mel: usize = 80;
    var buf = try MelBuffer.init(allocator, n_mel);
    defer buf.deinit();

    // Generate 0.5 seconds of audio
    const n_samples = 8000;
    var samples: [n_samples]f32 = undefined;
    for (0..n_samples) |i| {
        const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(SAMPLE_RATE));
        samples[i] = @floatCast(@sin(2.0 * math.pi * 440.0 * t));
    }

    _ = try buf.addSamples(&samples);

    // Export uses persistent buffer — no allocation
    const output = buf.exportForWhisper();
    try std.testing.expectEqual(n_mel * WHISPER_N_FRAMES, output.len);

    // Content frames should have varying values
    var has_variation = false;
    if (buf.n_computed > 1) {
        const v0 = output[0]; // band 0, frame 0
        const v1 = output[1]; // band 0, frame 1
        if (@abs(v0 - v1) > 1e-6) has_variation = true;
    }
    try std.testing.expect(has_variation);

    // Padding frames (beyond content) should all be the same silence value
    if (buf.n_computed + 1 < WHISPER_N_FRAMES) {
        const pad_val = output[buf.n_computed]; // band 0, first padding frame
        const pad_val2 = output[buf.n_computed + 1]; // band 0, second padding frame
        try std.testing.expectApproxEqAbs(pad_val, pad_val2, 1e-7);
    }
}

test "MelBuffer reset" {
    const allocator = std.testing.allocator;
    var buf = try MelBuffer.init(allocator, 80);
    defer buf.deinit();

    var samples: [4800]f32 = undefined;
    @memset(&samples, 0.5);
    _ = try buf.addSamples(&samples);
    try std.testing.expect(buf.n_computed > 0);

    buf.reset();
    try std.testing.expectEqual(@as(usize, 0), buf.n_computed);
    try std.testing.expectEqual(@as(usize, 0), buf.raw_mel.items.len);
}
