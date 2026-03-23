const std = @import("std");
const math = std.math;

/// NeMo AudioToMelSpectrogramPreprocessor parameters for Nemotron.
/// Extracted from the model's .nemo config. Must match exactly.
pub const N_FFT: usize = 512;
pub const HOP_LENGTH: usize = 160; // window_stride=0.01 * 16000
pub const WIN_LENGTH: usize = 400; // window_size=0.025 * 16000
pub const N_FFT_BINS: usize = 1 + N_FFT / 2; // 257
pub const N_MELS: usize = 128;
pub const SAMPLE_RATE: usize = 16000;
pub const PREEMPH: f32 = 0.97;
pub const LOG_GUARD: f64 = 5.960464477539063e-08; // 2^-24

/// Compute NeMo-compatible mel features from f32 audio samples.
///
/// Pipeline: pre-emphasis(0.97) → STFT(n_fft=512, hop=160, win=400, center=True, Hann)
///           → power spectrum → mel filterbank → ln(x + 2^-24)
///
/// Output layout: [n_mels, n_frames] row-major (band-major, NeMo convention).
/// Caller owns the returned slice.
pub fn compute(
    allocator: std.mem.Allocator,
    samples: []const f32,
    filterbank: []const f32, // [N_MELS * N_FFT_BINS] loaded from filterbank.bin
) !MelResult {
    std.debug.assert(filterbank.len == N_MELS * N_FFT_BINS);

    // Step 1: Pre-emphasis
    const preemph = try allocator.alloc(f32, samples.len);
    defer allocator.free(preemph);
    preemph[0] = samples[0]; // first sample unchanged (or multiplied by 1-0.97, NeMo does x[0] - 0.97*0)
    for (1..samples.len) |i| {
        preemph[i] = samples[i] - PREEMPH * samples[i - 1];
    }

    // Step 2: Frame count (center=True: pad n_fft/2 on each side)
    const pad = N_FFT / 2; // 256
    const padded_len = samples.len + 2 * pad;
    const n_frames = (padded_len - N_FFT) / HOP_LENGTH + 1;

    // Step 3: STFT for each frame → power spectrum → mel → log
    const result = try allocator.alloc(f32, N_MELS * n_frames);
    errdefer allocator.free(result);

    // Scratch buffers
    var fft_in: [N_FFT * 2]f32 = undefined;
    var fft_out: [N_FFT * 2 * 2 * 2]f32 = undefined;
    var power: [N_FFT_BINS]f32 = undefined;

    for (0..n_frames) |frame| {
        // The center of this frame in the padded signal
        const frame_start = frame * HOP_LENGTH; // position in padded signal

        // Fill FFT input: extract n_fft samples, then apply centered Hann window.
        // torch.stft extracts [frame_start..frame_start+n_fft] from the padded signal,
        // then multiplies by a centered window: [0]*pad_left + hann(win_length) + [0]*pad_right
        // where pad_left = (n_fft - win_length) / 2 = 56.
        @memset(&fft_in, 0);
        const win_offset = (N_FFT - WIN_LENGTH) / 2; // 56

        for (0..N_FFT) |j| {
            const padded_idx = frame_start + j;
            const sample: f32 = if (padded_idx < pad) blk: {
                // Left reflect padding
                const reflect_idx = pad - padded_idx;
                break :blk if (reflect_idx < preemph.len) preemph[reflect_idx] else 0;
            } else if (padded_idx - pad < preemph.len)
                preemph[padded_idx - pad]
            else blk: {
                // Right reflect padding
                const over = padded_idx - pad - preemph.len;
                const reflect_idx = preemph.len - 2 - over;
                break :blk if (reflect_idx < preemph.len) preemph[reflect_idx] else 0;
            };

            // Apply centered window: only non-zero for indices [win_offset..win_offset+WIN_LENGTH)
            if (j >= win_offset and j < win_offset + WIN_LENGTH) {
                fft_in[j] = HANN_WINDOW[j - win_offset] * sample;
            }
            // else: fft_in[j] stays 0 (from memset)
        }

        // FFT (reuse the existing Cooley-Tukey from mel.zig)
        fft(&fft_in, N_FFT, &fft_out);

        // Power spectrum: |FFT[k]|² for k = 0..N_FFT_BINS-1
        for (0..N_FFT_BINS) |k| {
            const re = fft_out[2 * k];
            const im = fft_out[2 * k + 1];
            power[k] = re * re + im * im;
        }

        // Mel filterbank dot product + natural log
        for (0..N_MELS) |band| {
            const filter_row = filterbank[band * N_FFT_BINS ..][0..N_FFT_BINS];
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

            // NeMo uses: log(mel_energy + 2^-24)
            // Output layout: band-major [band * n_frames + frame]
            result[band * n_frames + frame] = @floatCast(@log(sum + LOG_GUARD));
        }
    }

    return .{
        .features = result,
        .n_frames = n_frames,
        .n_mels = N_MELS,
    };
}

pub const MelResult = struct {
    features: []f32, // [n_mels * n_frames] band-major
    n_frames: usize,
    n_mels: usize,

    pub fn deinit(self: MelResult, allocator: std.mem.Allocator) void {
        allocator.free(self.features);
    }
};

/// Load filterbank weights from a binary file.
/// Expected format: [1, N_MELS, N_FFT_BINS] f32 (NeMo's fb tensor).
pub fn loadFilterbank(allocator: std.mem.Allocator, path: []const u8) ![]f32 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const expected_bytes = 1 * N_MELS * N_FFT_BINS * @sizeOf(f32);
    const data = try allocator.alloc(u8, expected_bytes);
    errdefer allocator.free(data);

    const n = try file.readAll(data);
    if (n != expected_bytes) return error.InvalidFilterbankSize;

    // Reinterpret as f32 slice, skip the leading dimension of 1
    const floats: []f32 = @as([*]f32, @ptrCast(@alignCast(data.ptr)))[0 .. N_MELS * N_FFT_BINS];
    // The data is [1, 128, 257]. We need [128, 257] = skip first 0 floats since dim 0 has size 1.
    // Actually the leading dim=1 means the data starts at the right place already.
    return floats;
}

// ─── Hann window (non-periodic, symmetric) ──────────────────────────────────

const HANN_WINDOW = computeHannWindow();

/// Symmetric Hann window: w[n] = 0.5 * (1 - cos(2π·n / (N-1)))
/// NeMo uses torch.hann_window(periodic=False) which is the symmetric version.
fn computeHannWindow() [WIN_LENGTH]f32 {
    const n_f: f64 = @floatFromInt(WIN_LENGTH - 1); // N-1 for symmetric
    var w: [WIN_LENGTH]f32 = undefined;
    for (0..WIN_LENGTH) |i| {
        const x: f64 = 2.0 * math.pi * @as(f64, @floatFromInt(i)) / n_f;
        w[i] = @floatCast(0.5 * (1.0 - @cos(x)));
    }
    return w;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "Hann window symmetric" {
    const hann = HANN_WINDOW;
    // Symmetric: first and last should be 0 (or very close)
    try std.testing.expectApproxEqAbs(hann[0], 0.0, 1e-7);
    try std.testing.expectApproxEqAbs(hann[WIN_LENGTH - 1], 0.0, 1e-7);
    // Mid-point should be 1.0
    // Symmetric window peaks near the center but not exactly at 1.0 for even N
    try std.testing.expectApproxEqAbs(hann[WIN_LENGTH / 2], 1.0, 1e-3);
}

test "pre-emphasis" {
    const allocator = std.testing.allocator;
    // Simple pre-emphasis check: [1.0, 0.5, 0.3] with coeff 0.97
    // Expected: [1.0, 0.5 - 0.97*1.0, 0.3 - 0.97*0.5]
    //         = [1.0, -0.47, -0.185]
    const samples = [_]f32{ 1.0, 0.5, 0.3 };
    const preemph = try allocator.alloc(f32, 3);
    defer allocator.free(preemph);
    preemph[0] = samples[0];
    for (1..3) |i| {
        preemph[i] = samples[i] - PREEMPH * samples[i - 1];
    }
    try std.testing.expectApproxEqAbs(preemph[0], 1.0, 1e-6);
    try std.testing.expectApproxEqAbs(preemph[1], -0.47, 1e-6);
    try std.testing.expectApproxEqAbs(preemph[2], -0.185, 1e-6);
}

// ─── FFT (Cooley-Tukey radix-2 + DFT fallback) ─────────────────────────────

/// In-place Cooley-Tukey FFT. `in` must have space for 2*N scratch.
/// `out` must have space for 4*N (2*N result + 2*N scratch).
pub fn fft(in: []f32, N: usize, out: []f32) void {
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
    const even_fft = out[2 * N ..];
    fft(even, half_N, even_fft);

    // Extract odd-indexed elements (reuse even's memory since we're done with it)
    const odd = even;
    for (0..half_N) |i| {
        odd[i] = in[2 * i + 1];
    }
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
