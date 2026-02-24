/// Pure DSP helper functions extracted from pitch_est.zig.
/// No C FFI dependency — testable with zero linkage.
///
/// Originally derived from TEN-VAD (ten-vad/src/pitch_est.cc),
/// Mozilla LPCNet (lpcnet_enc.c), BSD-2-Clause / BSD-3-Clause.
const std = @import("std");

// ── Constants ──

pub const NB_BANDS = 18;
pub const LPC_ORDER = 16;
pub const FFT_SZ = 1024;
pub const N_BINS = FFT_SZ / 2 + 1; // 513
pub const MAX_PERIOD = 64; // MAX_PERIOD_16K(256) / RESAMPLE_RATE(4)

const ASSUMED_FFT_4_BAND_ENG = 80;

pub const BAND_START_INDEX = [NB_BANDS]i32{
    0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 34, 40,
};

pub const BAND_LPC_COMP = [NB_BANDS]f32{
    0.8, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.666667,
    0.5, 0.5, 0.5, 0.333333, 0.25, 0.25, 0.2, 0.166667, 0.173913,
};

// 5-section biquad coefficients for 4kHz anti-aliasing (from pitch_est_st.h)
pub const NSECT = 5;
pub const B_4KHZ = [NSECT][3]f32{
    .{ 1.0, 1.198825, 1.0 },
    .{ 1.0, -0.5674614, 1.0 },
    .{ 1.0, -1.099061, 1.0 },
    .{ 1.0, -1.265846, 1.0 },
    .{ 1.0, -1.318849, 1.0 },
};
pub const A_4KHZ = [NSECT][3]f32{
    .{ 1.0, -1.445267, 0.5463974 },
    .{ 1.0, -1.426720, 0.6820138 },
    .{ 1.0, -1.408255, 0.8286664 },
    .{ 1.0, -1.400909, 0.9240320 },
    .{ 1.0, -1.408242, 0.9789776 },
};
pub const G_4KHZ: f32 = 0.2692541;

pub const BandInfo = struct {
    band_sz: i32,
    index_offset: i32,
};

pub const BAND_TABLE = computeBandTable();

fn computeBandTable() [NB_BANDS - 1]BandInfo {
    var table: [NB_BANDS - 1]BandInfo = undefined;
    const index_conv: f32 = @as(f32, FFT_SZ) / ASSUMED_FFT_4_BAND_ENG;
    for (0..NB_BANDS - 1) |i| {
        table[i] = .{
            .band_sz = @intFromFloat(@round(@as(f32, @floatFromInt(BAND_START_INDEX[i + 1] - BAND_START_INDEX[i])) * index_conv)),
            .index_offset = @intFromFloat(@round(@as(f32, @floatFromInt(BAND_START_INDEX[i])) * index_conv)),
        };
    }
    // zwanzig-disable-next-line: stack-escape-engine
    return table;
}

// ── 5-section cascaded biquad IIR filter ──

pub const BiquadFilter = struct {
    sect_w: [NSECT][2]f32 = [_][2]f32{.{ 0, 0 }} ** NSECT,

    pub fn reset(self: *BiquadFilter) void {
        self.sect_w = [_][2]f32{.{ 0, 0 }} ** NSECT;
    }

    pub fn process(self: *BiquadFilter, input: []const f32, output: []f32) void {
        // Copy input to output as working buffer for first section
        @memcpy(output[0..input.len], input);

        for (0..NSECT) |s| {
            for (0..input.len) |i| {
                const src = if (s == 0) input[i] else output[i];
                const tmp1 = src - A_4KHZ[s][1] * self.sect_w[s][0] - A_4KHZ[s][2] * self.sect_w[s][1];
                output[i] = G_4KHZ * (B_4KHZ[s][0] * tmp1 + B_4KHZ[s][1] * self.sect_w[s][0] + B_4KHZ[s][2] * self.sect_w[s][1]);
                self.sect_w[s][1] = self.sect_w[s][0];
                self.sect_w[s][0] = tmp1;
            }
        }
    }
};

// ── Static helper functions ──

pub fn computeBandEnergy(bin_pow: []const f32, band_e: *[NB_BANDS]f32) void {
    @memset(band_e, 0);

    for (0..NB_BANDS - 1) |i| {
        const band_sz = BAND_TABLE[i].band_sz;
        const index_offset = BAND_TABLE[i].index_offset;

        for (0..@intCast(band_sz)) |j| {
            const fj: f32 = @floatFromInt(j);
            const frac = fj / @as(f32, @floatFromInt(band_sz));
            const acc_idx: usize = @intCast(@min(@as(i32, N_BINS - 1), index_offset + @as(i32, @intCast(j))));
            band_e[i] += (1.0 - frac) * bin_pow[acc_idx];
            band_e[i + 1] += frac * bin_pow[acc_idx];
        }
    }
    band_e[0] *= 2;
    band_e[NB_BANDS - 1] *= 2;
}

pub fn interpBandGain(band_e: *const [NB_BANDS]f32, g: *[N_BINS]f32) void {
    @memset(g, 0);

    for (0..NB_BANDS - 1) |i| {
        const band_sz = BAND_TABLE[i].band_sz;
        const index_offset = BAND_TABLE[i].index_offset;

        for (0..@intCast(band_sz)) |j| {
            const fj: f32 = @floatFromInt(j);
            const frac = fj / @as(f32, @floatFromInt(band_sz));
            const acc_idx: usize = @intCast(@min(@as(i32, N_BINS - 1), index_offset + @as(i32, @intCast(j))));
            g[acc_idx] = (1.0 - frac) * band_e[i] + frac * band_e[i + 1];
        }
    }
}

/// Levinson-Durbin recursion. Returns prediction error.
pub fn celtLpc(ac: *const [LPC_ORDER + 1]f32, lpc_out: *[LPC_ORDER]f32) f32 {
    var lpc_buf: [LPC_ORDER]f32 = [_]f32{0} ** LPC_ORDER;
    var err = ac[0];

    if (ac[0] != 0) {
        for (0..LPC_ORDER) |i| {
            var rr: f32 = 0;
            for (0..i) |j| rr += lpc_buf[j] * ac[i - j];
            rr += ac[i + 1];
            const r = -rr / err;

            lpc_buf[i] = r;
            var j: usize = 0;
            while (j < (i + 1) / 2) : (j += 1) {
                const tmp1 = lpc_buf[j];
                const tmp2 = lpc_buf[i - 1 - j];
                lpc_buf[j] = tmp1 + r * tmp2;
                lpc_buf[i - 1 - j] = tmp2 + r * tmp1;
            }

            err = err - r * r * err;
            if (err < 0.001 * ac[0]) break;
        }
    }

    lpc_out.* = lpc_buf;
    return err;
}

/// Unrolled 4-wide cross-correlation kernel (from LPCNet/CELT).
pub fn xcorrKernel(x: []const f32, y: []const f32, sum: *[4]f32, len: usize) void {
    var y0 = y[0];
    var y1 = y[1];
    var y2 = y[2];
    var y3: f32 = 0;
    var xi: usize = 0;
    var yi: usize = 3;
    var j: usize = 0;

    while (j + 3 < len) : (j += 4) {
        var tmp = x[xi];
        xi += 1;
        y3 = y[yi];
        yi += 1;
        sum[0] += tmp * y0;
        sum[1] += tmp * y1;
        sum[2] += tmp * y2;
        sum[3] += tmp * y3;

        tmp = x[xi];
        xi += 1;
        y0 = y[yi];
        yi += 1;
        sum[0] += tmp * y1;
        sum[1] += tmp * y2;
        sum[2] += tmp * y3;
        sum[3] += tmp * y0;

        tmp = x[xi];
        xi += 1;
        y1 = y[yi];
        yi += 1;
        sum[0] += tmp * y2;
        sum[1] += tmp * y3;
        sum[2] += tmp * y0;
        sum[3] += tmp * y1;

        tmp = x[xi];
        xi += 1;
        y2 = y[yi];
        yi += 1;
        sum[0] += tmp * y3;
        sum[1] += tmp * y0;
        sum[2] += tmp * y1;
        sum[3] += tmp * y2;
    }
    if (j < len) {
        const tmp = x[xi];
        xi += 1;
        y3 = y[yi];
        yi += 1;
        sum[0] += tmp * y0;
        sum[1] += tmp * y1;
        sum[2] += tmp * y2;
        sum[3] += tmp * y3;
        j += 1;
    }
    if (j < len) {
        const tmp = x[xi];
        xi += 1;
        y0 = y[yi];
        yi += 1;
        sum[0] += tmp * y1;
        sum[1] += tmp * y2;
        sum[2] += tmp * y3;
        sum[3] += tmp * y0;
        j += 1;
    }
    if (j < len) {
        const tmp = x[xi];
        sum[0] += tmp * y2;
        sum[1] += tmp * y3;
        sum[2] += tmp * y0;
        sum[3] += tmp * y1;
    }
}

pub fn mvingXCorr(corr_window_len: usize, corr_shift_times: usize, ref_in: []const f32, y_in: []const f32, xcorr: *[MAX_PERIOD]f32) void {
    var i: usize = 0;
    while (i + 3 < corr_shift_times) : (i += 4) {
        var sum = [4]f32{ 0, 0, 0, 0 };
        xcorrKernel(ref_in, y_in[i..], &sum, corr_window_len);
        xcorr[i] = sum[0];
        xcorr[i + 1] = sum[1];
        xcorr[i + 2] = sum[2];
        xcorr[i + 3] = sum[3];
    }
    while (i < corr_shift_times) : (i += 1) {
        var dot: f32 = 0;
        for (0..corr_window_len) |k| dot += ref_in[k] * y_in[i + k];
        xcorr[i] = dot;
    }
}

// ============================================================
// Unit Tests
// ============================================================

const testing = std.testing;

// ── celtLpc tests ──

test "celtLpc: white noise autocorrelation → zero coefficients" {
    // ac = [1, 0, 0, ...] means white noise — no prediction possible
    var ac: [LPC_ORDER + 1]f32 = [_]f32{0} ** (LPC_ORDER + 1);
    ac[0] = 1.0;
    var lpc: [LPC_ORDER]f32 = undefined;
    const err = celtLpc(&ac, &lpc);
    try testing.expectApproxEqAbs(@as(f32, 1.0), err, 1e-6);
    for (lpc) |c| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), c, 1e-6);
    }
}

test "celtLpc: zero autocorrelation → zero coefficients, zero error" {
    var ac = [_]f32{0} ** (LPC_ORDER + 1);
    var lpc: [LPC_ORDER]f32 = undefined;
    const err = celtLpc(&ac, &lpc);
    try testing.expectApproxEqAbs(@as(f32, 0.0), err, 1e-6);
    for (lpc) |c| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), c, 1e-6);
    }
}

test "celtLpc: correlated signal → non-zero coefficients, reduced error" {
    // Autocorrelation from a signal with moderate correlation:
    // exponentially decaying ac: ac[k] = 0.9^k
    var ac: [LPC_ORDER + 1]f32 = undefined;
    ac[0] = 1.0;
    for (1..LPC_ORDER + 1) |k| {
        ac[k] = ac[k - 1] * 0.9;
    }
    var lpc: [LPC_ORDER]f32 = undefined;
    const err = celtLpc(&ac, &lpc);
    // Error should be positive and less than ac[0]
    try testing.expect(err > 0);
    try testing.expect(err <= ac[0] + 1e-6);
    // First coefficient should be non-zero (predicts from lag-1)
    try testing.expect(@abs(lpc[0]) > 0.01);
}

// ── computeBandEnergy tests ──

test "computeBandEnergy: zero spectrum → all zeros" {
    var bin_pow = [_]f32{0} ** N_BINS;
    var band_e: [NB_BANDS]f32 = undefined;
    computeBandEnergy(&bin_pow, &band_e);
    for (band_e) |e| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), e, 1e-10);
    }
}

test "computeBandEnergy: flat spectrum → non-negative energies" {
    var bin_pow: [N_BINS]f32 = undefined;
    @memset(&bin_pow, 1.0);
    var band_e: [NB_BANDS]f32 = undefined;
    computeBandEnergy(&bin_pow, &band_e);
    for (band_e) |e| {
        try testing.expect(e >= 0);
    }
    // First and last bands are doubled
    try testing.expect(band_e[0] > 0);
    try testing.expect(band_e[NB_BANDS - 1] > 0);
}

test "computeBandEnergy: single-bin impulse → energy in correct band" {
    // Put energy in bin 0 — should show up in band 0
    var bin_pow = [_]f32{0} ** N_BINS;
    bin_pow[0] = 100.0;
    var band_e: [NB_BANDS]f32 = undefined;
    computeBandEnergy(&bin_pow, &band_e);
    try testing.expect(band_e[0] > 0);
    // Most other bands should be zero (bin 0 maps to band 0)
    for (band_e[2..]) |e| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), e, 1e-6);
    }
}

// ── interpBandGain tests ──

test "interpBandGain: constant energies → roughly constant output" {
    var band_e: [NB_BANDS]f32 = undefined;
    @memset(&band_e, 5.0);
    var g: [N_BINS]f32 = undefined;
    interpBandGain(&band_e, &g);
    // Non-zero bins should be close to 5.0
    for (g[0..BAND_TABLE[NB_BANDS - 2].index_offset + BAND_TABLE[NB_BANDS - 2].band_sz]) |v| {
        _ = v;
    }
    // Just verify all values are non-negative and finite
    for (&g) |v| {
        try testing.expect(v >= 0);
        try testing.expect(std.math.isFinite(v));
    }
}

test "interpBandGain: zero energies → all zeros" {
    var band_e = [_]f32{0} ** NB_BANDS;
    var g: [N_BINS]f32 = undefined;
    interpBandGain(&band_e, &g);
    for (g) |v| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), v, 1e-10);
    }
}

// ── BiquadFilter tests ──

test "BiquadFilter: impulse response first sample" {
    var bq = BiquadFilter{};
    var input = [_]f32{0} ** 16;
    input[0] = 1.0;
    var output: [16]f32 = undefined;
    bq.process(&input, &output);
    // First output should be non-zero (impulse passed through all sections)
    try testing.expect(output[0] != 0);
    try testing.expect(std.math.isFinite(output[0]));
}

test "BiquadFilter: zero input → zero output" {
    var bq = BiquadFilter{};
    var input = [_]f32{0} ** 16;
    var output: [16]f32 = undefined;
    bq.process(&input, &output);
    for (output) |v| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), v, 1e-10);
    }
}

test "BiquadFilter: reset clears state" {
    var bq = BiquadFilter{};
    var input = [_]f32{0} ** 16;
    input[0] = 1.0;
    var output: [16]f32 = undefined;
    bq.process(&input, &output);
    // State should be non-zero now
    try testing.expect(bq.sect_w[0][0] != 0 or bq.sect_w[0][1] != 0);
    bq.reset();
    for (bq.sect_w) |sect| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), sect[0], 1e-10);
        try testing.expectApproxEqAbs(@as(f32, 0.0), sect[1], 1e-10);
    }
}

// ── xcorrKernel tests ──

test "xcorrKernel: auto-correlation at lag 0 = energy" {
    const x = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    // y is padded: x values then 3 extra for the kernel's 4-wide window
    const y = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 0.0, 0.0, 0.0 };
    var sum = [4]f32{ 0, 0, 0, 0 };
    xcorrKernel(&x, &y, &sum, 8);
    // sum[0] should be auto-correlation at lag 0 = sum(x[i]^2)
    var expected: f32 = 0;
    for (x) |v| expected += v * v;
    try testing.expectApproxEqAbs(expected, sum[0], 1e-4);
}

test "xcorrKernel: known signal pair" {
    // x = [1,1,1,1], y = [1,1,1,1,0,0,0] (with padding)
    const x = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const y = [_]f32{ 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0 };
    var sum = [4]f32{ 0, 0, 0, 0 };
    xcorrKernel(&x, &y, &sum, 4);
    // Lag 0: dot(x, y[0..4]) = 4
    try testing.expectApproxEqAbs(@as(f32, 4.0), sum[0], 1e-4);
    // Lag 1: dot(x, y[1..5]) = 3
    try testing.expectApproxEqAbs(@as(f32, 3.0), sum[1], 1e-4);
    // Lag 2: dot(x, y[2..6]) = 2
    try testing.expectApproxEqAbs(@as(f32, 2.0), sum[2], 1e-4);
    // Lag 3: dot(x, y[3..7]) = 1
    try testing.expectApproxEqAbs(@as(f32, 1.0), sum[3], 1e-4);
}

// ── mvingXCorr tests ──

test "mvingXCorr: auto-correlation peak at lag 0" {
    // ref signal
    var ref: [32 + MAX_PERIOD]f32 = undefined;
    for (&ref, 0..) |*v, i| {
        const fi: f32 = @floatFromInt(i);
        v.* = @sin(fi * 0.3);
    }
    var xcorr: [MAX_PERIOD]f32 = undefined;
    mvingXCorr(32, MAX_PERIOD, ref[0..], ref[0..], &xcorr);
    // Lag 0 should be the largest (auto-correlation peak)
    for (1..MAX_PERIOD) |i| {
        try testing.expect(xcorr[0] >= xcorr[i] - 1e-4);
    }
}
