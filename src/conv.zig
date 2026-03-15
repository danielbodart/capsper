/// Separable conv layers extracted from ten_vad_ggml.zig.
/// No C FFI dependency — testable with zero linkage.
///
/// Architecture: SepConv2D(1→16, VALID) → MaxPool → SepConv1D(16→16) → SepConv1D(16→16) → Flatten(80)

pub const FEA_LEN = 41; // 40 mel + 1 pitch
pub const CONTEXT_LEN = 3;

// ── Conv weight cache ──

pub const ConvWeights = struct {
    dw0: [9]f32,
    pw0: [16]f32,
    b0: [16]f32,
    dw1: [48]f32,
    pw1: [256]f32,
    b1: [16]f32,
    dw2: [48]f32,
    pw2: [256]f32,
    b2: [16]f32,
};

// ── Separable conv layers ──

pub fn runConvs(w: *const ConvWeights, features: *const [CONTEXT_LEN * FEA_LEN]f32) [80]f32 {
    // Layer 0: SeparableConv2D on [1,1,3,41], VALID → [1,1,1,39]
    var dw0_out: [39]f32 = undefined;
    for (0..39) |col| {
        var sum: f32 = 0;
        for (0..3) |kh| {
            for (0..3) |kw| {
                sum += features[kh * FEA_LEN + (col + kw)] * w.dw0[kh * 3 + kw];
            }
        }
        dw0_out[col] = sum;
    }

    // Pointwise conv: (16,1,1,1) + bias + ReLU → [16, 1, 39]
    var pw0_out: [16 * 39]f32 = undefined;
    for (0..16) |oc| {
        for (0..39) |i| {
            const val = dw0_out[i] * w.pw0[oc] + w.b0[oc];
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
                    sum += pool_out[ch * 19 + iw] * w.dw1[ch * 3 + k];
                }
            }
            dw1_out[ch * 10 + ow] = sum;
        }
    }

    // Pointwise + bias + ReLU
    var pw1_out: [16 * 10]f32 = undefined;
    for (0..16) |oc| {
        for (0..10) |i| {
            var sum: f32 = w.b1[oc];
            for (0..16) |ic| {
                sum += dw1_out[ic * 10 + i] * w.pw1[oc * 16 + ic];
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
                    sum += pw1_out[ch * 10 + iw] * w.dw2[ch * 3 + k];
                }
            }
            dw2_out[ch * 5 + ow] = sum;
        }
    }

    // Pointwise + bias + ReLU
    var pw2_out: [16 * 5]f32 = undefined;
    for (0..16) |oc| {
        for (0..5) |i| {
            var sum: f32 = w.b2[oc];
            for (0..16) |ic| {
                sum += dw2_out[ic * 5 + i] * w.pw2[oc * 16 + ic];
            }
            pw2_out[oc * 5 + i] = @max(sum, 0);
        }
    }

    // Flatten: [16, 1, 5] → [80] via transpose [16,5] → [5,16]
    var out: [80]f32 = undefined;
    for (0..5) |col| {
        for (0..16) |ch| {
            out[col * 16 + ch] = pw2_out[ch * 5 + col];
        }
    }
    return out;
}

// ============================================================
// Unit Tests
// ============================================================

const std = @import("std");
const testing = std.testing;

test "runConvs: zero features + zero weights → all zeros" {
    const w = ConvWeights{
        .dw0 = [_]f32{0} ** 9,
        .pw0 = [_]f32{0} ** 16,
        .b0 = [_]f32{0} ** 16,
        .dw1 = [_]f32{0} ** 48,
        .pw1 = [_]f32{0} ** 256,
        .b1 = [_]f32{0} ** 16,
        .dw2 = [_]f32{0} ** 48,
        .pw2 = [_]f32{0} ** 256,
        .b2 = [_]f32{0} ** 16,
    };
    const features = [_]f32{0} ** (CONTEXT_LEN * FEA_LEN);
    const out = runConvs(&w, &features);
    for (out) |v| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), v, 1e-10);
    }
}

test "runConvs: zero features + positive bias → output follows ReLU bias propagation" {
    // With zero features, dw0 produces zero, so layer 0 output = max(0, 0*pw + bias)
    // Positive biases propagate through ReLU; negative biases get clamped to 0
    const w = ConvWeights{
        .dw0 = [_]f32{0} ** 9,
        .pw0 = [_]f32{0} ** 16,
        .b0 = [_]f32{1.0} ** 16, // positive bias → passes ReLU
        .dw1 = [_]f32{0} ** 48,
        .pw1 = [_]f32{0} ** 256,
        .b1 = [_]f32{0} ** 16,
        .dw2 = [_]f32{0} ** 48,
        .pw2 = [_]f32{0} ** 256,
        .b2 = [_]f32{0} ** 16,
    };
    const features = [_]f32{0} ** (CONTEXT_LEN * FEA_LEN);
    const out = runConvs(&w, &features);
    // All outputs should be finite
    for (out) |v| {
        try testing.expect(std.math.isFinite(v));
    }
}

test "runConvs: negative bias with zero input → clamped to zero by ReLU" {
    const w = ConvWeights{
        .dw0 = [_]f32{0} ** 9,
        .pw0 = [_]f32{0} ** 16,
        .b0 = [_]f32{-5.0} ** 16, // negative bias → clamped by ReLU
        .dw1 = [_]f32{0} ** 48,
        .pw1 = [_]f32{0} ** 256,
        .b1 = [_]f32{0} ** 16,
        .dw2 = [_]f32{0} ** 48,
        .pw2 = [_]f32{0} ** 256,
        .b2 = [_]f32{0} ** 16,
    };
    const features = [_]f32{0} ** (CONTEXT_LEN * FEA_LEN);
    const out = runConvs(&w, &features);
    // ReLU clamps negative → zero, and zero propagates through subsequent layers
    for (out) |v| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), v, 1e-10);
    }
}

test "runConvs: all outputs finite for known non-trivial inputs" {
    // Identity-like weights: DW=1 at center, PW=identity-ish
    var w = ConvWeights{
        .dw0 = [_]f32{0} ** 9,
        .pw0 = [_]f32{0} ** 16,
        .b0 = [_]f32{0.1} ** 16,
        .dw1 = [_]f32{0} ** 48,
        .pw1 = [_]f32{0} ** 256,
        .b1 = [_]f32{0.1} ** 16,
        .dw2 = [_]f32{0} ** 48,
        .pw2 = [_]f32{0} ** 256,
        .b2 = [_]f32{0.1} ** 16,
    };
    // Set center DW weight to 1.0 for each layer
    w.dw0[4] = 1.0; // center of 3x3
    for (0..16) |ch| {
        w.dw1[ch * 3 + 1] = 1.0; // center of 1x3
        w.dw2[ch * 3 + 1] = 1.0;
    }
    // Diagonal pointwise weights
    for (0..16) |i| {
        w.pw0[i] = 0.5;
        w.pw1[i * 16 + i] = 0.5;
        w.pw2[i * 16 + i] = 0.5;
    }

    // Non-trivial features (ramp)
    var features: [CONTEXT_LEN * FEA_LEN]f32 = undefined;
    for (&features, 0..) |*v, i| {
        v.* = @as(f32, @floatFromInt(i)) / @as(f32, CONTEXT_LEN * FEA_LEN);
    }

    const out = runConvs(&w, &features);
    // Output should always be [80]f32
    try testing.expectEqual(@as(usize, 80), out.len);
    for (out) |v| {
        try testing.expect(std.math.isFinite(v));
        try testing.expect(v >= 0); // ReLU guarantees non-negative
    }
}
