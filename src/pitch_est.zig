/// Pitch estimator ported from TEN-VAD (ten-vad/src/pitch_est.cc).
/// Derived from Mozilla LPCNet (lpcnet_enc.c), BSD-2-Clause / BSD-3-Clause.
///
/// LPC-residual autocorrelation with Viterbi path tracking.
/// Hardcoded for: fftSz=1024, hopSz=256, procFs=4000, useLPCPreFiltering=1.
const std = @import("std");
const dsp = @import("dsp.zig");
const fft_c = @cImport({
    @cInclude("fftw.h");
});

// ── Re-import DSP constants used locally ──

const NB_BANDS = dsp.NB_BANDS;
const LPC_ORDER = dsp.LPC_ORDER;
const FFT_SZ = dsp.FFT_SZ;
const N_BINS = dsp.N_BINS;
const MAX_PERIOD = dsp.MAX_PERIOD;

// ── Local constants ──

const HOP_SZ = 256;
const PROC_FS: f32 = 4000;
const RESAMPLE_RATE = 4; // 16000 / 4000
const MIN_PERIOD_16K = 32;
const MIN_PERIOD = MIN_PERIOD_16K / RESAMPLE_RATE; // 8
const DIF_PERIOD = MAX_PERIOD - MIN_PERIOD; // 56
const XCORR_TRAINING_OFFSET = 80;
const INPUT_Q_LEN = @max(XCORR_TRAINING_OFFSET, HOP_SZ) + HOP_SZ; // 336
const EXC_BUF_LEN = MAX_PERIOD + HOP_SZ / RESAMPLE_RATE + 1; // 64 + 64 + 1 = 129
const FEAT_TIME_WINDOW_MS = 40;
const N_FEAT = @min(
    @as(comptime_int, @intFromFloat(@ceil(@as(f64, FEAT_TIME_WINDOW_MS) * 16000.0 / (@as(f64, HOP_SZ) * 1000.0)))),
    12,
); // ceil(40*16000/(256*1000)) = ceil(2.5) = 3
const CORR_HALF_HOPSZ = HOP_SZ / (RESAMPLE_RATE * 2); // 32
const PITCHMAXPATH_W: f32 = 0.02;
const VOICED_THR: f32 = 0.4;

const DCT_RATIO: f32 = @sqrt(2.0 / @as(f32, NB_BANDS));

const DCT_TABLE = computeDctTable();

fn computeDctTable() [NB_BANDS * NB_BANDS]f32 {
    @setEvalBranchQuota(2000);
    var table: [NB_BANDS * NB_BANDS]f32 = undefined;
    for (0..NB_BANDS) |i| {
        const fi: f32 = @floatFromInt(i);
        for (0..NB_BANDS) |j| {
            const fj: f32 = @floatFromInt(j);
            table[i * NB_BANDS + j] = @cos((fi + 0.5) * fj * std.math.pi / NB_BANDS);
            if (j == 0) table[i * NB_BANDS + j] *= @sqrt(0.5);
        }
    }
    return table;
}

// ── Pitch Estimator ──

pub const PitchEstimator = struct {
    // LPC state
    lpc: [LPC_ORDER]f32 = [_]f32{0} ** LPC_ORDER,
    pitch_mem: [LPC_ORDER]f32 = [_]f32{0} ** LPC_ORDER,
    pitch_filt: f32 = 0,

    // Input queue
    input_q: [INPUT_Q_LEN]f32 = [_]f32{0} ** INPUT_Q_LEN,

    // Excitation buffers (decimated LPC residual)
    exc_buf: [EXC_BUF_LEN]f32 = [_]f32{0} ** EXC_BUF_LEN,
    exc_buf_sq: [EXC_BUF_LEN]f32 = [_]f32{0} ** EXC_BUF_LEN,

    // Cross-correlation circular buffer [nFeat*2][maxPeriod+1]
    x_corr: [N_FEAT * 2][MAX_PERIOD + 1]f32 = [_][MAX_PERIOD + 1]f32{[_]f32{0} ** (MAX_PERIOD + 1)} ** (N_FEAT * 2),
    x_corr_offset_idx: usize = 0,

    // Frame weights
    frm_weight: [N_FEAT * 2]f32 = [_]f32{0} ** (N_FEAT * 2),

    // Viterbi state
    pitch_max_path_reg: [2][MAX_PERIOD]f32 = [_][MAX_PERIOD]f32{[_]f32{0} ** MAX_PERIOD} ** 2,
    pitch_prev: [N_FEAT * 2][MAX_PERIOD]i32 = [_][MAX_PERIOD]i32{[_]i32{0} ** MAX_PERIOD} ** (N_FEAT * 2),
    pitch_max_path_all: f32 = 0,
    best_period_est: i32 = 0,

    // Biquad filter for decimation
    biquad: dsp.BiquadFilter = .{},

    // Work buffers
    input_resample_buf: [HOP_SZ * 2]f32 = [_]f32{0} ** (HOP_SZ * 2),
    input_resample_buf_idx: usize = 0,

    pub fn init() PitchEstimator {
        return PitchEstimator{};
    }

    pub fn reset(self: *PitchEstimator) void {
        self.lpc = [_]f32{0} ** LPC_ORDER;
        self.pitch_mem = [_]f32{0} ** LPC_ORDER;
        self.pitch_filt = 0;
        @memset(&self.input_q, 0);
        @memset(&self.exc_buf, 0);
        @memset(&self.exc_buf_sq, 0);
        for (&self.x_corr) |*row| @memset(row, 0);
        self.x_corr_offset_idx = 0;
        @memset(&self.frm_weight, 0);
        for (&self.pitch_max_path_reg) |*row| @memset(row, 0);
        for (&self.pitch_prev) |*row| @memset(row, 0);
        self.pitch_max_path_all = 0;
        self.best_period_est = 0;
        @memset(&self.input_resample_buf, 0);
        self.input_resample_buf_idx = 0;
        self.biquad.reset();
    }

    /// Process one hop. time_signal: raw float samples [256] in [-32768,32767] scale.
    /// bin_pow: power spectrum [513] from the STFT.
    /// Returns pitch frequency in Hz (0 if unvoiced).
    pub fn process(self: *PitchEstimator, time_signal: []const f32, bin_pow: []const f32) f32 {
        // ── Phase 1: LPC Pre-filtering ──

        // Band energy from power spectrum
        var band_pow: [NB_BANDS]f32 = [_]f32{0} ** NB_BANDS;
        dsp.computeBandEnergy(bin_pow, &band_pow);

        // Log + floor
        var ly: [NB_BANDS]f32 = undefined;
        var log_max: f32 = -2.0;
        var follow: f32 = -2.0;
        for (0..NB_BANDS) |i| {
            ly[i] = std.math.log10(1e-2 + band_pow[i]);
            ly[i] = @max(log_max - 8.0, @max(follow - 2.5, ly[i]));
            log_max = @max(log_max, ly[i]);
            follow = @max(follow - 2.5, ly[i]);
        }

        // DCT → cepstrum
        var cepstrum: [NB_BANDS]f32 = undefined;
        self.dct(&ly, &cepstrum);

        // Cepstrum → LPC
        _ = self.lpcCompute(&cepstrum);

        // Slide input queue, append new samples
        std.mem.copyForwards(f32, self.input_q[0 .. INPUT_Q_LEN - HOP_SZ], self.input_q[HOP_SZ..INPUT_Q_LEN]);
        @memcpy(self.input_q[INPUT_Q_LEN - HOP_SZ ..], time_signal[0..HOP_SZ]);

        // Aligned input (offset by XCORR_TRAINING_OFFSET from end)
        const offset = @max(0, @as(i32, INPUT_Q_LEN - HOP_SZ) - XCORR_TRAINING_OFFSET);
        var aligned_in: [HOP_SZ]f32 = undefined;
        @memcpy(&aligned_in, self.input_q[@intCast(offset)..][0..HOP_SZ]);

        // FIR LPC filtering + 1-pole post-filter
        var lpc_out: [HOP_SZ]f32 = undefined;
        for (0..HOP_SZ) |i| {
            var sum: f32 = aligned_in[i];
            for (0..LPC_ORDER) |j| {
                sum += self.lpc[j] * self.pitch_mem[j];
            }
            // Shift pitch_mem right by 1
            var j: usize = LPC_ORDER - 1;
            while (j > 0) : (j -= 1) {
                self.pitch_mem[j] = self.pitch_mem[j - 1];
            }
            self.pitch_mem[0] = aligned_in[i];

            lpc_out[i] = sum + 0.7 * self.pitch_filt;
            self.pitch_filt = sum;
        }

        // Biquad anti-alias + 4:1 decimation
        var bq_out: [HOP_SZ]f32 = undefined;
        self.biquad.process(&lpc_out, &bq_out);

        const tmp_idx = self.input_resample_buf_idx;
        @memcpy(self.input_resample_buf[tmp_idx..][0..HOP_SZ], &bq_out);

        // Decimate: keep every 4th sample
        var write_idx = tmp_idx;
        var read_idx = tmp_idx;
        while (read_idx < tmp_idx + HOP_SZ) : (read_idx += RESAMPLE_RATE) {
            self.input_resample_buf[write_idx] = self.input_resample_buf[read_idx];
            write_idx += 1;
        }
        self.input_resample_buf_idx = write_idx;

        // Update excitation buffer
        const n_decimated = self.input_resample_buf_idx;
        std.mem.copyForwards(f32, self.exc_buf[0 .. EXC_BUF_LEN - n_decimated], self.exc_buf[n_decimated..EXC_BUF_LEN]);
        @memcpy(self.exc_buf[EXC_BUF_LEN - n_decimated ..], self.input_resample_buf[0..n_decimated]);
        self.input_resample_buf_idx = 0;

        // Compute squared excitation
        for (0..EXC_BUF_LEN) |i| {
            self.exc_buf_sq[i] = self.exc_buf[i] * self.exc_buf[i];
        }

        // Shift frame weights left
        for (0..N_FEAT - 1) |i| {
            self.frm_weight[2 * i] = self.frm_weight[2 * (i + 1)];
            self.frm_weight[2 * i + 1] = self.frm_weight[2 * (i + 1) + 1];
        }

        // ── Phase 2: Cross-Correlation ──

        var x_corr_inst: [MAX_PERIOD]f32 = undefined;
        for (0..2) |sub| {
            const xcorr_acc_idx = 2 * self.x_corr_offset_idx + sub;
            const sub_offset = sub * CORR_HALF_HOPSZ;

            // Moving cross-correlation
            dsp.mvingXCorr(
                CORR_HALF_HOPSZ,
                MAX_PERIOD,
                self.exc_buf[MAX_PERIOD + sub_offset ..],
                self.exc_buf[sub_offset..],
                &x_corr_inst,
            );

            // Reference energy
            var energy0: f32 = 0;
            for (0..CORR_HALF_HOPSZ) |i| {
                energy0 += self.exc_buf_sq[MAX_PERIOD + sub_offset + i];
            }
            self.frm_weight[2 * (N_FEAT - 1) + sub] = energy0;

            // Sliding window energy
            var slid_sum: f32 = 0;
            for (0..CORR_HALF_HOPSZ) |i| {
                slid_sum += self.exc_buf_sq[sub_offset + i];
            }

            // Normalize: bin 0
            self.x_corr[xcorr_acc_idx][0] = 2.0 * x_corr_inst[0] / @max(1e-12, slid_sum + 1.0 + energy0);

            // Normalize: bins 1..maxPeriod-1
            for (1..MAX_PERIOD) |i| {
                slid_sum = @max(0, slid_sum - self.exc_buf_sq[sub_offset + i - 1]);
                slid_sum += self.exc_buf_sq[sub_offset + i + CORR_HALF_HOPSZ - 1];
                self.x_corr[xcorr_acc_idx][i] = 2.0 * x_corr_inst[i] / @max(1e-12, slid_sum + 1.0 + energy0);
            }

            // Harmonic suppression
            for (0..MAX_PERIOD - 2 * MIN_PERIOD) |i| {
                var max_octave: f32 = self.x_corr[xcorr_acc_idx][(MAX_PERIOD + i) / 2];
                max_octave = @max(max_octave, self.x_corr[xcorr_acc_idx][(MAX_PERIOD + i + 2) / 2]);
                max_octave = @max(max_octave, self.x_corr[xcorr_acc_idx][if (MAX_PERIOD + i >= 1) (MAX_PERIOD + i - 1) / 2 else 0]);
                if (self.x_corr[xcorr_acc_idx][i] < max_octave * 1.1) {
                    self.x_corr[xcorr_acc_idx][i] *= 0.8;
                }
            }
        }
        self.x_corr_offset_idx += 1;
        if (self.x_corr_offset_idx >= N_FEAT) self.x_corr_offset_idx = 0;

        // ── Phase 3: Viterbi Pitch Tracking ──

        // Normalize frame weights
        var weight_sum: f32 = 1e-15;
        for (0..N_FEAT * 2) |sub| weight_sum += self.frm_weight[sub];
        var frm_weight_norm: [N_FEAT * 2]f32 = undefined;
        for (0..N_FEAT * 2) |sub| {
            frm_weight_norm[sub] = self.frm_weight[sub] * (@as(f32, N_FEAT * 2) / weight_sum);
        }

        // Copy x_corr for modification
        var x_corr_tmp: [N_FEAT * 2][MAX_PERIOD + 1]f32 = undefined;
        for (0..N_FEAT * 2) |i| {
            @memcpy(&x_corr_tmp[i], &self.x_corr[i]);
        }

        // Shift pitchPrev left by 2
        for (0..N_FEAT * 2 - 2) |sub| {
            @memcpy(&self.pitch_prev[sub], &self.pitch_prev[sub + 2]);
        }

        // Forward pass (only last 2 sub-frames are new)
        for (N_FEAT * 2 - 2..N_FEAT * 2) |sub| {
            var xc_idx = sub + self.x_corr_offset_idx * 2;
            if (xc_idx >= N_FEAT * 2) xc_idx -= N_FEAT * 2;

            for (0..DIF_PERIOD) |idx| {
                var max_track: f32 = self.pitch_max_path_all - 1e10;
                self.pitch_prev[sub][idx] = self.best_period_est;

                const sidxt_i: i32 = @min(0, @as(i32, 4) - @as(i32, @intCast(idx)));
                var jdx: i32 = sidxt_i;
                while (jdx <= 4 and @as(i32, @intCast(idx)) + jdx < DIF_PERIOD) : (jdx += 1) {
                    const neighbor: usize = @intCast(@as(i32, @intCast(idx)) + jdx);
                    const penalty = PITCHMAXPATH_W * @as(f32, @floatFromInt(@as(i32, @intCast(@abs(jdx))))) * @as(f32, @floatFromInt(@as(i32, @intCast(@abs(jdx)))));
                    const score = self.pitch_max_path_reg[0][neighbor] - penalty;
                    if (score > max_track) {
                        max_track = score;
                        self.pitch_prev[sub][idx] = @intCast(neighbor);
                    }
                }

                self.pitch_max_path_reg[1][idx] = max_track + frm_weight_norm[sub] * x_corr_tmp[xc_idx][idx];
            }

            // Find best and normalize
            var max_path: f32 = -1e15;
            var best_idx: i32 = 0;
            for (0..DIF_PERIOD) |idx| {
                if (self.pitch_max_path_reg[1][idx] > max_path) {
                    max_path = self.pitch_max_path_reg[1][idx];
                    best_idx = @intCast(idx);
                }
            }
            self.pitch_max_path_all = max_path;
            self.best_period_est = best_idx;

            @memcpy(&self.pitch_max_path_reg[0], &self.pitch_max_path_reg[1]);
            for (0..DIF_PERIOD) |idx| {
                self.pitch_max_path_reg[0][idx] -= max_path;
            }
        }

        // Backward pass
        var tmp_period = self.best_period_est;
        var frm_corr: f32 = 0;
        var best_local: [N_FEAT * 2]i32 = undefined;
        var sub_i: i32 = @intCast(N_FEAT * 2 - 1);
        while (sub_i >= 0) : (sub_i -= 1) {
            const sub: usize = @intCast(sub_i);
            best_local[sub] = MAX_PERIOD - tmp_period;

            var xc_idx = sub + self.x_corr_offset_idx * 2;
            if (xc_idx >= N_FEAT * 2) xc_idx -= N_FEAT * 2;
            frm_corr += frm_weight_norm[sub] * x_corr_tmp[xc_idx][@intCast(tmp_period)];
            tmp_period = self.pitch_prev[sub][@intCast(tmp_period)];
        }
        frm_corr = @max(0, frm_corr / @as(f32, N_FEAT * 2));
        const voiced: bool = frm_corr >= VOICED_THR;

        // Weighted linear regression for pitch contour
        var sx: f32 = 0;
        var sxx: f32 = 0;
        var sxy: f32 = 0;
        var sy: f32 = 0;
        var sw: f32 = 0;
        for (0..N_FEAT * 2) |sub| {
            const w = frm_weight_norm[sub];
            const fsub: f32 = @floatFromInt(sub);
            const fperiod: f32 = @floatFromInt(best_local[sub]);
            sw += w;
            sx += w * fsub;
            sxx += w * fsub * fsub;
            sxy += w * fsub * fperiod;
            sy += w * fperiod;
        }

        var best_a: f32 = 0;
        const denom = sw * sxx - sx * sx;
        if (voiced) {
            best_a = if (denom == 0) (sw * sxy - sx * sy) / 1e-15 else (sw * sxy - sx * sy) / denom;
            const cap = (sy / sw) / (4.0 * 2.0 * N_FEAT);
            best_a = @min(cap, @max(-cap, best_a));
        }
        const best_b = (sy - best_a * sx) / sw;
        const estimated_period = best_b + 5.5 * best_a;

        return if (voiced) PROC_FS / @max(1.0, estimated_period) else 0;
    }

    // ── Internal functions ──

    fn dct(_: *const PitchEstimator, in: *const [NB_BANDS]f32, out: *[NB_BANDS]f32) void {
        for (0..NB_BANDS) |i| {
            var sum: f32 = 0;
            for (0..NB_BANDS) |j| {
                sum += in[j] * DCT_TABLE[j * NB_BANDS + i];
            }
            out[i] = sum * DCT_RATIO;
        }
    }

    fn idct(_: *const PitchEstimator, in: *const [NB_BANDS]f32, out: *[NB_BANDS]f32) void {
        for (0..NB_BANDS) |i| {
            var sum: f32 = 0;
            for (0..NB_BANDS) |j| {
                sum += in[j] * DCT_TABLE[i * NB_BANDS + j];
            }
            out[i] = sum * DCT_RATIO;
        }
    }

    fn lpcCompute(self: *PitchEstimator, cepstrum: *const [NB_BANDS]f32) f32 {
        // IDCT → band energies with compensation
        var ex: [NB_BANDS]f32 = undefined;
        self.idct(cepstrum, &ex);
        for (0..NB_BANDS) |i| {
            ex[i] = std.math.pow(f32, 10.0, ex[i]) * dsp.BAND_LPC_COMP[i];
        }

        // Interpolate band gains to frequency bins
        var xr: [N_BINS]f32 = [_]f32{0} ** N_BINS;
        dsp.interpBandGain(&ex, &xr);
        xr[N_BINS - 1] = 0;

        // IFFT to autocorrelation
        var x_freq: [FFT_SZ + 4]f32 = [_]f32{0} ** (FFT_SZ + 4);
        var x_time: [FFT_SZ + 4]f32 = [_]f32{0} ** (FFT_SZ + 4);
        x_freq[0] = xr[0];
        x_freq[1] = xr[N_BINS - 1];
        for (1..N_BINS - 1) |i| {
            x_freq[i * 2] = xr[i];
        }
        fft_c.AUP_FFTW_InplaceTransf(0, FFT_SZ, &x_freq);
        fft_c.AUP_FFTW_c2r_1024(&x_freq, &x_time);
        fft_c.AUP_FFTW_RescaleIFFTOut(FFT_SZ, &x_time);

        // Extract autocorrelation + noise floor + lag windowing
        var ac: [LPC_ORDER + 1]f32 = undefined;
        for (0..LPC_ORDER + 1) |i| ac[i] = x_time[i];

        const dc0_bias: f32 = 768.0 / 12.0 / 38.0; // windowSz=768
        ac[0] += ac[0] * 1e-4 + dc0_bias;
        for (1..LPC_ORDER + 1) |i| {
            const fi: f32 = @floatFromInt(i);
            ac[i] *= (1.0 - 6e-5 * fi * fi);
        }

        // Levinson-Durbin
        return dsp.celtLpc(&ac, &self.lpc);
    }
};

// ============================================================
// Unit Tests (DCT/IDCT)
// ============================================================

const testing = std.testing;

test "DCT/IDCT: roundtrip recovers original" {
    var pe = PitchEstimator.init();
    const input = [NB_BANDS]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0 };
    var dct_out: [NB_BANDS]f32 = undefined;
    var recovered: [NB_BANDS]f32 = undefined;
    pe.dct(&input, &dct_out);
    pe.idct(&dct_out, &recovered);
    for (0..NB_BANDS) |i| {
        try testing.expectApproxEqAbs(input[i], recovered[i], 1e-4);
    }
}

test "DCT/IDCT: all zeros → all zeros" {
    var pe = PitchEstimator.init();
    const input = [_]f32{0} ** NB_BANDS;
    var dct_out: [NB_BANDS]f32 = undefined;
    pe.dct(&input, &dct_out);
    for (dct_out) |v| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), v, 1e-10);
    }
    var idct_out: [NB_BANDS]f32 = undefined;
    pe.idct(&input, &idct_out);
    for (idct_out) |v| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), v, 1e-10);
    }
}

test "DCT: constant signal → energy only in DC" {
    var pe = PitchEstimator.init();
    var input: [NB_BANDS]f32 = undefined;
    @memset(&input, 3.0);
    var dct_out: [NB_BANDS]f32 = undefined;
    pe.dct(&input, &dct_out);
    // DC component (index 0) should have the energy
    try testing.expect(@abs(dct_out[0]) > 0.1);
    // Higher coefficients should be approximately zero
    for (dct_out[1..]) |v| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), v, 1e-4);
    }
}

test "DCT/IDCT: roundtrip property with seeded PRNG (100 vectors)" {
    var pe = PitchEstimator.init();
    var prng = std.Random.DefaultPrng.init(42);
    for (0..100) |_| {
        var input: [NB_BANDS]f32 = undefined;
        for (&input) |*v| {
            v.* = (@as(f32, @floatFromInt(prng.random().int(i16))) / 32768.0) * 10.0;
        }
        var dct_out: [NB_BANDS]f32 = undefined;
        var recovered: [NB_BANDS]f32 = undefined;
        pe.dct(&input, &dct_out);
        pe.idct(&dct_out, &recovered);
        for (0..NB_BANDS) |i| {
            try testing.expectApproxEqAbs(input[i], recovered[i], 1e-3);
        }
    }
}
