/// TEN-VAD via GGML — feature extraction + model loading + inference.
///
/// Feature extraction ported from ten-vad/src/aed.cc with exact numerical parity:
///   Pre-emphasis → STFT (Hann768, FFT1024) → Power spectrum → Mel filterbank
///   → Log → Z-normalize → Context stack [3][41] → GGML inference
///
/// Model architecture (from ONNX graph):
///   SepConv2D(1→16, VALID) → MaxPool → SepConv1D(16→16) → SepConv1D(16→16) → Flatten(80)
///   → LSTM(80→64) → LSTM(64→64) → Concat(h1,h0→128) → Dense(128→32) → Dense(32→1) → Sigmoid
const std = @import("std");
const PitchEstimator = @import("pitch_est.zig").PitchEstimator;
const ggml = @cImport({
    @cInclude("ggml.h");
    @cInclude("ggml-alloc.h");
    @cInclude("ggml-backend.h");
    @cInclude("ggml-cpu.h");
});
const fft = @cImport({
    @cInclude("fftw.h");
});

// ── Constants ──

const FS = 16000;
const HOP_SIZE = 256;
const WINDOW_SIZE = 768;
const FFT_SIZE = 1024;
const N_BINS = FFT_SIZE / 2 + 1; // 513
const MEL_BANDS = 40;
const FEA_LEN = MEL_BANDS + 1; // 41 = 40 mel + 1 pitch
const CONTEXT_LEN = 3;
const HIDDEN_DIM = 64;
const EPS = 1e-20;
const PREEMPH = 0.97;
const N_WEIGHT_TENSORS = 21;

const FEATURE_MEANS = [FEA_LEN]f32{
    -8.198236465454e+00, -6.265716552734e+00, -5.483818531036e+00,
    -4.758691310883e+00, -4.417088985443e+00, -4.142892837524e+00,
    -3.912850379944e+00, -3.845927953720e+00, -3.657090425491e+00,
    -3.723418712616e+00, -3.876134157181e+00, -3.843890905380e+00,
    -3.690405130386e+00, -3.756065845490e+00, -3.698696136475e+00,
    -3.650463104248e+00, -3.700468778610e+00, -3.567321300507e+00,
    -3.498900175095e+00, -3.477807044983e+00, -3.458816051483e+00,
    -3.444923877716e+00, -3.401328563690e+00, -3.306261301041e+00,
    -3.278556823730e+00, -3.233250856400e+00, -3.198616027832e+00,
    -3.204526424408e+00, -3.208798646927e+00, -3.257838010788e+00,
    -3.381376743317e+00, -3.534021377563e+00, -3.640867948532e+00,
    -3.726858854294e+00, -3.773730993271e+00, -3.804667234421e+00,
    -3.832901000977e+00, -3.871120452881e+00, -3.990592956543e+00,
    -4.480289459229e+00, 9.235690307617e+01,
};

const FEATURE_STDS = [FEA_LEN]f32{
    5.166063785553e+00, 4.977209568024e+00, 4.698895931244e+00,
    4.630621433258e+00, 4.634347915649e+00, 4.641156196594e+00,
    4.640676498413e+00, 4.666367053986e+00, 4.650534629822e+00,
    4.640020847321e+00, 4.637400150299e+00, 4.620099067688e+00,
    4.596316337585e+00, 4.562654972076e+00, 4.554360389709e+00,
    4.566910743713e+00, 4.562489986420e+00, 4.562412738800e+00,
    4.585299491882e+00, 4.600179672241e+00, 4.592845916748e+00,
    4.585922718048e+00, 4.583496570587e+00, 4.626092910767e+00,
    4.626957893372e+00, 4.626289367676e+00, 4.637005805969e+00,
    4.683015823364e+00, 4.726813793182e+00, 4.734289646149e+00,
    4.753227233887e+00, 4.849722862244e+00, 4.869434833527e+00,
    4.884482860565e+00, 4.921327114105e+00, 4.959212303162e+00,
    4.996619224548e+00, 5.044823646545e+00, 5.072216987610e+00,
    5.096439361572e+00, 1.152136917114e+02,
};

const HANN_WINDOW = computeHannWindow();

fn computeHannWindow() [WINDOW_SIZE]f32 {
    var w: [WINDOW_SIZE]f32 = undefined;
    for (0..WINDOW_SIZE) |i| {
        const fi: f32 = @floatFromInt(i);
        const n: f32 = @floatFromInt(WINDOW_SIZE);
        w[i] = 0.5 * (1.0 - @cos(2.0 * std.math.pi * fi / n));
    }
    // zwanzig-disable-next-line: stack-escape-engine
    return w;
}

// ── Feature extraction state ──

const Features = struct {
    preemph_prev: f32 = 0,
    input_q: [WINDOW_SIZE]f32 = [_]f32{0} ** WINDOW_SIZE,
    fft_in: [FFT_SIZE]f32 = undefined,
    fft_out: [FFT_SIZE]f32 = undefined,
    mel_fb: [MEL_BANDS * N_BINS]f32 = undefined,
    mel_bins: [MEL_BANDS + 2]i32 = undefined,
    feat_stack: [CONTEXT_LEN * FEA_LEN]f32 = [_]f32{0} ** (CONTEXT_LEN * FEA_LEN),
    pitch_est: PitchEstimator = PitchEstimator.init(),

    fn initMelFilterbank(self: *Features) void {
        const low_mel = 2595.0 * std.math.log10(1.0 + 0.0 / 700.0);
        const high_mel = 2595.0 * std.math.log10(1.0 + 8000.0 / 700.0);

        for (0..MEL_BANDS + 2) |i| {
            const fi: f32 = @floatFromInt(i);
            const mel = fi * (high_mel - low_mel) / (@as(f32, MEL_BANDS) + 1.0) + low_mel;
            const hz = 700.0 * (std.math.pow(f32, 10.0, mel / 2595.0) - 1.0);
            self.mel_bins[i] = @intFromFloat((FFT_SIZE + 1.0) * hz / @as(f32, FS));
        }

        @memset(&self.mel_fb, 0);
        for (0..MEL_BANDS) |j| {
            const lo = self.mel_bins[j];
            const mid = self.mel_bins[j + 1];
            const hi = self.mel_bins[j + 2];
            var i = lo;
            while (i < mid) : (i += 1) {
                const ui: usize = @intCast(i);
                self.mel_fb[j * N_BINS + ui] = @as(f32, @floatFromInt(i - lo)) /
                    @as(f32, @floatFromInt(mid - lo));
            }
            i = mid;
            while (i < hi) : (i += 1) {
                const ui: usize = @intCast(i);
                self.mel_fb[j * N_BINS + ui] = @as(f32, @floatFromInt(hi - i)) /
                    @as(f32, @floatFromInt(hi - mid));
            }
        }
    }

    fn reset(self: *Features) void {
        self.preemph_prev = 0;
        @memset(&self.input_q, 0);
        @memset(&self.feat_stack, 0);
        self.pitch_est.reset();
    }

    /// Extract one frame of features from a hop of raw int16 samples.
    fn extract(self: *Features, samples: []const i16) *const [CONTEXT_LEN * FEA_LEN]f32 {
        // 1. Convert int16 → float (raw scale, no normalization)
        var raw: [HOP_SIZE]f32 = undefined;
        for (0..@min(samples.len, HOP_SIZE)) |i| {
            raw[i] = @floatFromInt(samples[i]);
        }

        // 2. Pre-emphasis: y[n] = x[n] - 0.97 * x[n-1]
        var emph: [HOP_SIZE]f32 = undefined;
        for (0..@min(samples.len, HOP_SIZE)) |i| {
            emph[i] = raw[i] - PREEMPH * self.preemph_prev;
            self.preemph_prev = raw[i];
        }

        // 3. STFT: slide overlap buffer, apply window, zero-pad, FFT
        std.mem.copyForwards(f32, self.input_q[0 .. WINDOW_SIZE - HOP_SIZE], self.input_q[HOP_SIZE..WINDOW_SIZE]);
        @memcpy(self.input_q[WINDOW_SIZE - HOP_SIZE ..], emph[0..HOP_SIZE]);

        for (0..WINDOW_SIZE) |i| {
            self.fft_in[i] = self.input_q[i] * HANN_WINDOW[i];
        }
        @memset(self.fft_in[WINDOW_SIZE..FFT_SIZE], 0);

        // FFT (real-to-complex, 1024-point)
        fft.AUP_FFTW_r2c_1024(&self.fft_in, &self.fft_out);
        fft.AUP_FFTW_InplaceTransf(1, FFT_SIZE, &self.fft_out);
        fft.AUP_FFTW_RescaleFFTOut(FFT_SIZE, &self.fft_out);

        // 4. Power spectrum
        var bin_pow: [N_BINS]f32 = undefined;
        bin_pow[0] = self.fft_out[0] * self.fft_out[0];
        bin_pow[N_BINS - 1] = self.fft_out[1] * self.fft_out[1];
        for (1..N_BINS - 1) |i| {
            const ri = i * 2;
            bin_pow[i] = self.fft_out[ri] * self.fft_out[ri] +
                self.fft_out[ri + 1] * self.fft_out[ri + 1];
        }

        // 5. Context stack: shift left, new frame at end
        std.mem.copyForwards(f32, self.feat_stack[0 .. (CONTEXT_LEN - 1) * FEA_LEN], self.feat_stack[FEA_LEN..]);
        const cur = self.feat_stack[(CONTEXT_LEN - 1) * FEA_LEN ..][0..FEA_LEN];

        // 6. Mel filterbank → log → z-normalize
        const power_norm: f32 = 32768.0 * 32768.0;
        for (0..MEL_BANDS) |i| {
            var sum: f32 = 0;
            const coef = self.mel_fb[i * N_BINS ..][0..N_BINS];
            for (0..N_BINS) |j| {
                sum += bin_pow[j] * coef[j];
            }
            sum = sum / power_norm;
            sum = @log(sum + EPS);
            cur[i] = (sum - FEATURE_MEANS[i]) / (FEATURE_STDS[i] + EPS);
        }

        // 7. Pitch estimation (LPC-residual autocorrelation with Viterbi tracking)
        const pitch_freq = self.pitch_est.process(&raw, &bin_pow);
        cur[MEL_BANDS] = (pitch_freq - FEATURE_MEANS[MEL_BANDS]) / (FEATURE_STDS[MEL_BANDS] + EPS);

        return &self.feat_stack;
    }
};

// ── Model weights ──

const Model = struct {
    sep_conv_dw: [3]*ggml.ggml_tensor = undefined,
    sep_conv_pw: [3]*ggml.ggml_tensor = undefined,
    sep_conv_bias: [3]*ggml.ggml_tensor = undefined,
    lstm_ih_weight: [2]*ggml.ggml_tensor = undefined,
    lstm_hh_weight: [2]*ggml.ggml_tensor = undefined,
    lstm_ih_bias: [2]*ggml.ggml_tensor = undefined,
    lstm_hh_bias: [2]*ggml.ggml_tensor = undefined,
    dense_weight: [2]*ggml.ggml_tensor = undefined,
    dense_bias: [2]*ggml.ggml_tensor = undefined,
};

// ── Separable conv layers ──

fn runConvs(model: *const Model, backend: ggml.ggml_backend_t, features: *const [CONTEXT_LEN * FEA_LEN]f32) [80]f32 {
    // Read all weights into local buffers
    var dw0: [9]f32 = undefined;
    var pw0: [16]f32 = undefined;
    var b0: [16]f32 = undefined;
    var dw1: [48]f32 = undefined;
    var pw1: [256]f32 = undefined;
    var b1: [16]f32 = undefined;
    var dw2: [48]f32 = undefined;
    var pw2: [256]f32 = undefined;
    var b2: [16]f32 = undefined;

    ggml.ggml_backend_tensor_get(model.sep_conv_dw[0], &dw0, 0, @sizeOf(@TypeOf(dw0)));
    ggml.ggml_backend_tensor_get(model.sep_conv_pw[0], &pw0, 0, @sizeOf(@TypeOf(pw0)));
    ggml.ggml_backend_tensor_get(model.sep_conv_bias[0], &b0, 0, @sizeOf(@TypeOf(b0)));
    ggml.ggml_backend_tensor_get(model.sep_conv_dw[1], &dw1, 0, @sizeOf(@TypeOf(dw1)));
    ggml.ggml_backend_tensor_get(model.sep_conv_pw[1], &pw1, 0, @sizeOf(@TypeOf(pw1)));
    ggml.ggml_backend_tensor_get(model.sep_conv_bias[1], &b1, 0, @sizeOf(@TypeOf(b1)));
    ggml.ggml_backend_tensor_get(model.sep_conv_dw[2], &dw2, 0, @sizeOf(@TypeOf(dw2)));
    ggml.ggml_backend_tensor_get(model.sep_conv_pw[2], &pw2, 0, @sizeOf(@TypeOf(pw2)));
    ggml.ggml_backend_tensor_get(model.sep_conv_bias[2], &b2, 0, @sizeOf(@TypeOf(b2)));

    _ = backend;

    // Layer 0: SeparableConv2D on [1,1,3,41], VALID → [1,1,1,39]
    var dw0_out: [39]f32 = undefined;
    for (0..39) |w| {
        var sum: f32 = 0;
        for (0..3) |kh| {
            for (0..3) |kw| {
                sum += features[kh * FEA_LEN + (w + kw)] * dw0[kh * 3 + kw];
            }
        }
        dw0_out[w] = sum;
    }

    // Pointwise conv: (16,1,1,1) + bias + ReLU → [16, 1, 39]
    var pw0_out: [16 * 39]f32 = undefined;
    for (0..16) |oc| {
        for (0..39) |i| {
            const val = dw0_out[i] * pw0[oc] + b0[oc];
            pw0_out[oc * 39 + i] = @max(val, 0);
        }
    }

    // MaxPool: kernel(1,3), stride(1,2) → [16, 1, 19]
    var pool_out: [16 * 19]f32 = undefined;
    for (0..16) |oc| {
        for (0..19) |ow| {
            const w_start = ow * 2;
            var mx: f32 = -1e30;
            for (0..3) |k| {
                const iw = w_start + k;
                if (iw < 39) {
                    mx = @max(mx, pw0_out[oc * 39 + iw]);
                }
            }
            pool_out[oc * 19 + ow] = mx;
        }
    }

    // Layer 1: DW conv kernel(1,3), stride(2,2), pads=[0,1,0,1]
    var dw1_out: [16 * 10]f32 = undefined;
    for (0..16) |ch| {
        for (0..10) |ow| {
            var sum: f32 = 0;
            for (0..3) |k| {
                const iw_signed: i32 = @as(i32, @intCast(ow)) * 2 + @as(i32, @intCast(k)) - 1;
                if (iw_signed >= 0 and iw_signed < 19) {
                    const iw: usize = @intCast(iw_signed);
                    sum += pool_out[ch * 19 + iw] * dw1[ch * 3 + k];
                }
            }
            dw1_out[ch * 10 + ow] = sum;
        }
    }

    // Pointwise + bias + ReLU
    var pw1_out: [16 * 10]f32 = undefined;
    for (0..16) |oc| {
        for (0..10) |i| {
            var sum: f32 = b1[oc];
            for (0..16) |ic| {
                sum += dw1_out[ic * 10 + i] * pw1[oc * 16 + ic];
            }
            pw1_out[oc * 10 + i] = @max(sum, 0);
        }
    }

    // Layer 2: DW conv kernel(1,3), stride(2,2), pads=[0,0,0,1]
    var dw2_out: [16 * 5]f32 = undefined;
    for (0..16) |ch| {
        for (0..5) |ow| {
            var sum: f32 = 0;
            for (0..3) |k| {
                const iw = ow * 2 + k;
                if (iw < 10) {
                    sum += pw1_out[ch * 10 + iw] * dw2[ch * 3 + k];
                }
            }
            dw2_out[ch * 5 + ow] = sum;
        }
    }

    // Pointwise + bias + ReLU
    var pw2_out: [16 * 5]f32 = undefined;
    for (0..16) |oc| {
        for (0..5) |i| {
            var sum: f32 = b2[oc];
            for (0..16) |ic| {
                sum += dw2_out[ic * 5 + i] * pw2[oc * 16 + ic];
            }
            pw2_out[oc * 5 + i] = @max(sum, 0);
        }
    }

    // Flatten: [16, 1, 5] → [80] via transpose [16,5] → [5,16]
    var out: [80]f32 = undefined;
    for (0..5) |w| {
        for (0..16) |ch| {
            out[w * 16 + ch] = pw2_out[ch * 5 + w];
        }
    }
    // zwanzig-disable-next-line: stack-escape-engine
    return out;
}

// ── Public API ──

pub const TenVadGgmlCtx = struct {
    feat: Features,
    model: Model,
    ctx_weight: *ggml.ggml_context,
    buf_weight: ggml.ggml_backend_buffer_t,
    ctx_state: *ggml.ggml_context,
    buf_state: ggml.ggml_backend_buffer_t,
    h_state: [2]*ggml.ggml_tensor,
    c_state: [2]*ggml.ggml_tensor,
    backend: ggml.ggml_backend_t,
    meta_buf: []u8,
    gf: *ggml.ggml_cgraph,
    sched: ggml.ggml_backend_sched_t,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, model_path: [:0]const u8) !*TenVadGgmlCtx {
        const fp = std.c.fopen(model_path.ptr, "rb") orelse return error.TenVadOpenFailed;
        errdefer _ = std.c.fclose(fp);

        // Verify magic
        var magic: u32 = 0;
        if (std.c.fread(@ptrCast(&magic), 4, 1, fp) != 1 or magic != 0x67676d6c)
            return error.TenVadBadMagic;

        // Skip model type string
        const str_len = readI32(fp);
        if (str_len > 0 and str_len < 64) {
            var skip_buf: [64]u8 = undefined;
            _ = std.c.fread(@ptrCast(&skip_buf), 1, @intCast(str_len), fp);
        }

        // Read version
        const major = readI32(fp);
        const minor = readI32(fp);
        const patch = readI32(fp);
        std.debug.print("ten_vad_ggml: v{d}.{d}.{d}\n", .{ major, minor, patch });

        // Read hyperparams (verify hidden_dim)
        _ = readI32(fp); // n_sep_conv
        _ = readI32(fp); // n_lstm
        const hidden_dim = readI32(fp);
        _ = readI32(fp); // lstm1_in
        _ = readI32(fp); // lstm2_in
        _ = readI32(fp); // dense1_in
        _ = readI32(fp); // dense1_out
        _ = readI32(fp); // dense2_out

        if (hidden_dim != HIDDEN_DIM) return error.TenVadBadHiddenDim;

        // Allocate context
        var ctx = try allocator.create(TenVadGgmlCtx);
        ctx.allocator = allocator;
        // zwanzig-disable: store-violations-engine
        errdefer allocator.destroy(ctx);
        // zwanzig-enable: store-violations-engine

        // Initialize feature extraction
        ctx.feat = .{};
        ctx.feat.initMelFilterbank();
        ctx.feat.reset();

        // CPU backend
        ctx.backend = ggml.ggml_backend_cpu_init() orelse return error.TenVadBackendFailed;

        // Create weight tensors
        const ctx_size = N_WEIGHT_TENSORS * ggml.ggml_tensor_overhead() + ggml.ggml_graph_overhead();
        ctx.ctx_weight = ggml.ggml_init(.{
            .mem_size = ctx_size,
            .mem_buffer = null,
            .no_alloc = true,
        }) orelse return error.TenVadWeightCtxFailed;

        const TensorEntry = struct { name: [*c]const u8, ptr: **ggml.ggml_tensor };
        var tensor_map: [N_WEIGHT_TENSORS]TensorEntry = undefined;
        var ti: usize = 0;

        // Sep conv layers
        const sep_shapes = [_]struct { dw: [4]i64, pw: [4]i64 }{
            .{ .dw = .{ 3, 3, 1, 1 }, .pw = .{ 1, 1, 1, 16 } },
            .{ .dw = .{ 3, 1, 1, 16 }, .pw = .{ 1, 1, 16, 16 } },
            .{ .dw = .{ 3, 1, 1, 16 }, .pw = .{ 1, 1, 16, 16 } },
        };
        const layer_names = [_][*c]const u8{
            "sep_conv_0_dw",  "sep_conv_0_pw",  "sep_conv_0_bias",
            "sep_conv_1_dw",  "sep_conv_1_pw",  "sep_conv_1_bias",
            "sep_conv_2_dw",  "sep_conv_2_pw",  "sep_conv_2_bias",
        };
        for (0..3) |l| {
            ctx.model.sep_conv_dw[l] = ggml.ggml_new_tensor_4d(ctx.ctx_weight, ggml.GGML_TYPE_F32, sep_shapes[l].dw[0], sep_shapes[l].dw[1], sep_shapes[l].dw[2], sep_shapes[l].dw[3]);
            ctx.model.sep_conv_pw[l] = ggml.ggml_new_tensor_4d(ctx.ctx_weight, ggml.GGML_TYPE_F32, sep_shapes[l].pw[0], sep_shapes[l].pw[1], sep_shapes[l].pw[2], sep_shapes[l].pw[3]);
            ctx.model.sep_conv_bias[l] = ggml.ggml_new_tensor_1d(ctx.ctx_weight, ggml.GGML_TYPE_F32, 16);
            _ = ggml.ggml_set_name(ctx.model.sep_conv_dw[l], layer_names[l * 3 + 0]);
            _ = ggml.ggml_set_name(ctx.model.sep_conv_pw[l], layer_names[l * 3 + 1]);
            _ = ggml.ggml_set_name(ctx.model.sep_conv_bias[l], layer_names[l * 3 + 2]);
            tensor_map[ti] = .{ .name = layer_names[l * 3 + 0], .ptr = &ctx.model.sep_conv_dw[l] };
            ti += 1;
            tensor_map[ti] = .{ .name = layer_names[l * 3 + 1], .ptr = &ctx.model.sep_conv_pw[l] };
            ti += 1;
            tensor_map[ti] = .{ .name = layer_names[l * 3 + 2], .ptr = &ctx.model.sep_conv_bias[l] };
            ti += 1;
        }

        // LSTM layers
        const lstm_names = [_][*c]const u8{
            "lstm_0_ih_weight", "lstm_0_hh_weight", "lstm_0_ih_bias", "lstm_0_hh_bias",
            "lstm_1_ih_weight", "lstm_1_hh_weight", "lstm_1_ih_bias", "lstm_1_hh_bias",
        };
        const lstm_ih_sizes = [2]i64{ 80, 64 };
        for (0..2) |l| {
            ctx.model.lstm_ih_weight[l] = ggml.ggml_new_tensor_2d(ctx.ctx_weight, ggml.GGML_TYPE_F32, lstm_ih_sizes[l], 256);
            ctx.model.lstm_hh_weight[l] = ggml.ggml_new_tensor_2d(ctx.ctx_weight, ggml.GGML_TYPE_F32, 64, 256);
            ctx.model.lstm_ih_bias[l] = ggml.ggml_new_tensor_1d(ctx.ctx_weight, ggml.GGML_TYPE_F32, 256);
            ctx.model.lstm_hh_bias[l] = ggml.ggml_new_tensor_1d(ctx.ctx_weight, ggml.GGML_TYPE_F32, 256);
            _ = ggml.ggml_set_name(ctx.model.lstm_ih_weight[l], lstm_names[l * 4 + 0]);
            _ = ggml.ggml_set_name(ctx.model.lstm_hh_weight[l], lstm_names[l * 4 + 1]);
            _ = ggml.ggml_set_name(ctx.model.lstm_ih_bias[l], lstm_names[l * 4 + 2]);
            _ = ggml.ggml_set_name(ctx.model.lstm_hh_bias[l], lstm_names[l * 4 + 3]);
            tensor_map[ti] = .{ .name = lstm_names[l * 4 + 0], .ptr = &ctx.model.lstm_ih_weight[l] };
            ti += 1;
            tensor_map[ti] = .{ .name = lstm_names[l * 4 + 1], .ptr = &ctx.model.lstm_hh_weight[l] };
            ti += 1;
            tensor_map[ti] = .{ .name = lstm_names[l * 4 + 2], .ptr = &ctx.model.lstm_ih_bias[l] };
            ti += 1;
            tensor_map[ti] = .{ .name = lstm_names[l * 4 + 3], .ptr = &ctx.model.lstm_hh_bias[l] };
            ti += 1;
        }

        // Dense layers
        const dense_shapes = [_]struct { w0: i64, w1: i64, b: i64 }{
            .{ .w0 = 128, .w1 = 32, .b = 32 },
            .{ .w0 = 32, .w1 = 1, .b = 1 },
        };
        const dense_names = [_][*c]const u8{
            "dense_0_weight", "dense_0_bias",
            "dense_1_weight", "dense_1_bias",
        };
        for (0..2) |l| {
            ctx.model.dense_weight[l] = ggml.ggml_new_tensor_2d(ctx.ctx_weight, ggml.GGML_TYPE_F32, dense_shapes[l].w0, dense_shapes[l].w1);
            ctx.model.dense_bias[l] = ggml.ggml_new_tensor_1d(ctx.ctx_weight, ggml.GGML_TYPE_F32, dense_shapes[l].b);
            _ = ggml.ggml_set_name(ctx.model.dense_weight[l], dense_names[l * 2 + 0]);
            _ = ggml.ggml_set_name(ctx.model.dense_bias[l], dense_names[l * 2 + 1]);
            tensor_map[ti] = .{ .name = dense_names[l * 2 + 0], .ptr = &ctx.model.dense_weight[l] };
            ti += 1;
            tensor_map[ti] = .{ .name = dense_names[l * 2 + 1], .ptr = &ctx.model.dense_bias[l] };
            ti += 1;
        }

        // Allocate weight buffer
        ctx.buf_weight = ggml.ggml_backend_alloc_ctx_tensors(ctx.ctx_weight, ctx.backend) orelse
            return error.TenVadWeightAllocFailed;

        // Load tensor data from file
        var loaded: usize = 0;
        while (true) {
            var n_dims: i32 = 0;
            var name_len: i32 = 0;
            var skip_ttype: i32 = 0;
            if (std.c.fread(@ptrCast(&n_dims), 4, 1, fp) != 1) break;
            if (std.c.fread(@ptrCast(&name_len), 4, 1, fp) != 1) break;
            if (std.c.fread(@ptrCast(&skip_ttype), 4, 1, fp) != 1) break;

            // Skip dimension values (we get shape from pre-created tensors)
            var skip_ne: [4]i32 = .{ 1, 1, 1, 1 };
            for (0..@intCast(n_dims)) |d| {
                if (std.c.fread(@ptrCast(&skip_ne[d]), 4, 1, fp) != 1) return error.TenVadLoadFailed;
            }

            var name: [128]u8 = [_]u8{0} ** 128;
            if (name_len > 0 and name_len < 128) {
                if (std.c.fread(&name, 1, @intCast(name_len), fp) != @as(usize, @intCast(name_len)))
                    return error.TenVadLoadFailed;
            }

            // Find matching tensor
            const name_slice = name[0..@intCast(name_len)];
            var tensor: ?*ggml.ggml_tensor = null;
            for (&tensor_map) |entry| {
                if (std.mem.eql(u8, std.mem.span(entry.name), name_slice)) {
                    tensor = entry.ptr.*;
                    break;
                }
            }
            const t = tensor orelse return error.TenVadUnknownTensor;

            // Read data
            const nbytes = ggml.ggml_nbytes(t);
            const buf = try allocator.alloc(u8, nbytes);
            defer allocator.free(buf);
            if (std.c.fread(buf.ptr, 1, nbytes, fp) != nbytes) return error.TenVadLoadFailed;
            ggml.ggml_backend_tensor_set(t, buf.ptr, 0, nbytes);
            loaded += 1;
        }
        _ = std.c.fclose(fp);

        if (loaded != N_WEIGHT_TENSORS) return error.TenVadIncompleteLoad;

        // LSTM state context
        const state_ctx_size = 4 * ggml.ggml_tensor_overhead();
        ctx.ctx_state = ggml.ggml_init(.{
            .mem_size = state_ctx_size,
            .mem_buffer = null,
            .no_alloc = true,
        }) orelse return error.TenVadStateCtxFailed;

        const h_names = [2][*c]const u8{ "h0", "h1" };
        const c_names = [2][*c]const u8{ "c0", "c1" };
        for (0..2) |i| {
            ctx.h_state[i] = ggml.ggml_new_tensor_1d(ctx.ctx_state, ggml.GGML_TYPE_F32, HIDDEN_DIM);
            ctx.c_state[i] = ggml.ggml_new_tensor_1d(ctx.ctx_state, ggml.GGML_TYPE_F32, HIDDEN_DIM);
            _ = ggml.ggml_set_name(ctx.h_state[i], h_names[i]);
            _ = ggml.ggml_set_name(ctx.c_state[i], c_names[i]);
        }
        ctx.buf_state = ggml.ggml_backend_alloc_ctx_tensors(ctx.ctx_state, ctx.backend) orelse
            return error.TenVadStateAllocFailed;
        ggml.ggml_backend_buffer_clear(ctx.buf_state, 0);

        // Build and schedule compute graph
        const meta_size = ggml.ggml_tensor_overhead() * 128 + ggml.ggml_graph_overhead();
        ctx.meta_buf = try allocator.alloc(u8, meta_size);

        ctx.gf = buildGraph(ctx) orelse return error.TenVadGraphBuildFailed;
        ctx.sched = ggml.ggml_backend_sched_new(&ctx.backend, null, 1, meta_size, false, false) orelse
            return error.TenVadSchedFailed;
        if (!ggml.ggml_backend_sched_alloc_graph(ctx.sched, ctx.gf))
            return error.TenVadGraphAllocFailed;

        return ctx;
    }

    pub fn process(self: *TenVadGgmlCtx, samples: []const i16) f32 {
        const features = self.feat.extract(samples);
        const conv_out = runConvs(&self.model, self.backend, features);

        const input_tensor = ggml.ggml_graph_get_tensor(self.gf, "input") orelse return 0;
        const prob_tensor = ggml.ggml_graph_get_tensor(self.gf, "prob") orelse return 0;

        ggml.ggml_backend_tensor_set(input_tensor, &conv_out, 0, @sizeOf(@TypeOf(conv_out)));

        if (ggml.ggml_backend_sched_graph_compute(self.sched, self.gf) != ggml.GGML_STATUS_SUCCESS)
            return 0;

        var result: f32 = 0;
        ggml.ggml_backend_tensor_get(prob_tensor, &result, 0, @sizeOf(f32));
        return result;
    }

    pub fn reset(self: *TenVadGgmlCtx) void {
        ggml.ggml_backend_buffer_clear(self.buf_state, 0);
        self.feat.reset();
    }

    pub fn deinit(self: *TenVadGgmlCtx) void {
        ggml.ggml_backend_sched_free(self.sched);
        self.allocator.free(self.meta_buf);
        ggml.ggml_backend_buffer_free(self.buf_state);
        ggml.ggml_free(self.ctx_state);
        ggml.ggml_backend_buffer_free(self.buf_weight);
        ggml.ggml_free(self.ctx_weight);
        ggml.ggml_backend_free(self.backend);
        self.allocator.destroy(self);
    }
};

// ── Graph construction ──

fn buildLstmLayer(ctx0: *ggml.ggml_context, vctx: *TenVadGgmlCtx, layer: usize, cur: *ggml.ggml_tensor, gf: *ggml.ggml_cgraph) *ggml.ggml_tensor {
    const m = &vctx.model;
    const hdim_bytes = ggml.ggml_row_size(ggml.GGML_TYPE_F32, HIDDEN_DIM);

    const x_t = ggml.ggml_transpose(ctx0, cur);
    var inp_gate = ggml.ggml_mul_mat(ctx0, m.lstm_ih_weight[layer], x_t);
    inp_gate = ggml.ggml_add(ctx0, inp_gate, m.lstm_ih_bias[layer]);
    var hid_gate = ggml.ggml_mul_mat(ctx0, m.lstm_hh_weight[layer], vctx.h_state[layer]);
    hid_gate = ggml.ggml_add(ctx0, hid_gate, m.lstm_hh_bias[layer]);
    const gates = ggml.ggml_add(ctx0, inp_gate, hid_gate);

    const i_t = ggml.ggml_sigmoid(ctx0, ggml.ggml_view_1d(ctx0, gates, HIDDEN_DIM, 0 * hdim_bytes));
    const f_t = ggml.ggml_sigmoid(ctx0, ggml.ggml_view_1d(ctx0, gates, HIDDEN_DIM, 1 * hdim_bytes));
    const g_t = ggml.ggml_tanh(ctx0, ggml.ggml_view_1d(ctx0, gates, HIDDEN_DIM, 2 * hdim_bytes));
    const o_t = ggml.ggml_sigmoid(ctx0, ggml.ggml_view_1d(ctx0, gates, HIDDEN_DIM, 3 * hdim_bytes));

    const c_out = ggml.ggml_add(ctx0, ggml.ggml_mul(ctx0, f_t, vctx.c_state[layer]), ggml.ggml_mul(ctx0, i_t, g_t));
    ggml.ggml_build_forward_expand(gf, ggml.ggml_cpy(ctx0, c_out, vctx.c_state[layer]));

    const h_out = ggml.ggml_mul(ctx0, o_t, ggml.ggml_tanh(ctx0, c_out));
    ggml.ggml_build_forward_expand(gf, ggml.ggml_cpy(ctx0, h_out, vctx.h_state[layer]));

    return h_out;
}

fn buildGraph(ctx: *TenVadGgmlCtx) ?*ggml.ggml_cgraph {
    const ctx0 = ggml.ggml_init(.{
        .mem_size = ctx.meta_buf.len,
        .mem_buffer = ctx.meta_buf.ptr,
        .no_alloc = true,
    }) orelse return null;

    const gf = ggml.ggml_new_graph(ctx0) orelse return null;

    const input = ggml.ggml_new_tensor_2d(ctx0, ggml.GGML_TYPE_F32, 1, 80);
    _ = ggml.ggml_set_name(input, "input");
    ggml.ggml_set_input(input);

    const h0 = buildLstmLayer(ctx0, ctx, 0, input, gf);
    const h1_in = ggml.ggml_reshape_2d(ctx0, h0, 1, HIDDEN_DIM);
    const h1 = buildLstmLayer(ctx0, ctx, 1, h1_in, gf);

    const concat = ggml.ggml_concat(ctx0, h1, h0, 0);

    var d0 = ggml.ggml_mul_mat(ctx0, ctx.model.dense_weight[0], concat);
    d0 = ggml.ggml_add(ctx0, d0, ctx.model.dense_bias[0]);
    d0 = ggml.ggml_relu(ctx0, d0);

    var d1 = ggml.ggml_mul_mat(ctx0, ctx.model.dense_weight[1], d0);
    d1 = ggml.ggml_add(ctx0, d1, ctx.model.dense_bias[1]);
    d1 = ggml.ggml_sigmoid(ctx0, d1);

    _ = ggml.ggml_set_name(d1, "prob");
    ggml.ggml_set_output(d1);
    ggml.ggml_build_forward_expand(gf, d1);
    ggml.ggml_free(ctx0);

    return gf;
}

fn readI32(fp: *std.c.FILE) i32 {
    var val: i32 = 0;
    _ = std.c.fread(@ptrCast(&val), @sizeOf(i32), 1, fp);
    return val;
}
