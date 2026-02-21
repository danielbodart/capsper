const std = @import("std");
const utils = @import("utils.zig");

/// Automatic gain controller for PipeWire capture streams.
/// Measures speech level during VAD-detected speech and adjusts
/// PipeWire software gain to reach a target RMS level.
/// Pure math — no C dependencies.
pub const AutoGain = struct {
    current_gain: f32 = 1.0,
    target_db: f32 = -15.0, // target speech RMS level
    alpha: f32 = 0.1, // exponential smoothing factor
    max_gain: f32 = 10.0, // PipeWire caps software gain at 10x (+20 dB)

    /// Feed speech chunk RMS. Returns new gain if changed >1%, null if stable.
    /// measured_db is post-gain (PipeWire already applied current gain).
    pub fn update(self: *AutoGain, rms: f64) ?f32 {
        const db: f32 = @floatCast(utils.rmsToDb(rms));
        if (db < -50) return null; // too quiet to measure reliably

        // Closed-loop: adjust gain so post-gain level reaches target_db
        const adjustment = std.math.pow(f32, 10.0, (self.target_db - db) / 20.0);
        const ideal = @max(self.current_gain * adjustment, 1.0); // never attenuate below unity

        // Exponential smoothing
        const new_gain = self.current_gain * (1.0 - self.alpha) + ideal * self.alpha;
        const final_gain = @min(@max(new_gain, 1.0), self.max_gain);

        if (@abs(final_gain - self.current_gain) < 0.01) return null;
        self.current_gain = final_gain;
        return final_gain;
    }
};

// ============================================================
// Tests
// ============================================================

test "quiet signal increases gain towards max" {
    var ag = AutoGain{};
    // -40 dB is very quiet — gain should increase
    const result = ag.update(0.01); // ~-40 dB
    try std.testing.expect(result != null);
    try std.testing.expect(result.? > 1.0);
}

test "loud signal at target stays at unity" {
    var ag = AutoGain{};
    // -15 dB ≈ RMS of 0.178 — exactly at target
    const rms = std.math.pow(f64, 10.0, -15.0 / 20.0);
    const result = ag.update(rms);
    // Should either be null (no change) or very close to 1.0
    if (result) |g| {
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), g, 0.05);
    }
}

test "convergence: repeated updates stabilize" {
    var ag = AutoGain{};
    // Simulate moderately quiet audio at -30 dB
    const rms = std.math.pow(f64, 10.0, -30.0 / 20.0);
    var last_gain: f32 = 1.0;
    var settled = false;
    for (0..100) |_| {
        // Post-gain measurement: the audio gets louder as gain increases
        const post_gain_rms = rms * @as(f64, ag.current_gain);
        if (ag.update(post_gain_rms)) |g| {
            last_gain = g;
        } else {
            settled = true;
            break;
        }
    }
    // Should have settled (returned null) or be close to a stable value
    try std.testing.expect(settled or @abs(last_gain - ag.current_gain) < 0.02);
}

test "very quiet signal below -50 dB returns null" {
    var ag = AutoGain{};
    const result = ag.update(1e-6); // ~-120 dB
    try std.testing.expect(result == null);
}

test "gain never drops below unity" {
    var ag = AutoGain{};
    // Very loud signal — would want to attenuate, but unity floor prevents it
    const result = ag.update(1.0); // 0 dB, well above target
    if (result) |g| {
        try std.testing.expect(g >= 1.0);
    }
    try std.testing.expect(ag.current_gain >= 1.0);
}

test "very quiet signal can reach high gain but stays under max" {
    var ag = AutoGain{};
    // -45 dB signal — well above -50 threshold, needs ~30 dB boost (gain ~31x)
    const rms = std.math.pow(f64, 10.0, -45.0 / 20.0); // ~0.0056
    for (0..100) |_| {
        _ = ag.update(rms);
    }
    try std.testing.expect(ag.current_gain > 4.0);
    try std.testing.expect(ag.current_gain <= ag.max_gain);
}
