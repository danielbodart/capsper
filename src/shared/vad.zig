// src/shared/vad.zig — turning speech probabilities into a gate.
//
// The model says how likely a 32 ms window is to be speech. This turns that
// stream of numbers into "feed this to the encoder" or "don't", and it is the
// part worth testing: the model is a fixed thing that either loads or does
// not, while the hysteresis is where a gate clips the start of every sentence
// or flutters open and shut on a pause.
//
// Two thresholds rather than one, because a single one chatters around it.
// Speech starts when the probability crosses `onset` and stops only after it
// has stayed under `offset` for `min_silence_ms` -- so an ordinary pause
// between words keeps the gate open, and only a real silence closes it.
//
// The gate is for cost, not for correctness. Nemotron does not hallucinate
// into silence, so nothing is broken by feeding it some; what is saved is the
// encoder pass, which costs the same for silence as for speech.

const std = @import("std");

pub const Thresholds = struct {
    /// Probability at which speech starts. Low, because the cost of opening
    /// late is a clipped word and the cost of opening early is one wasted
    /// encoder pass.
    onset: f32 = 0.3,
    /// Probability under which speech may end. Lower than `onset`, which is
    /// what stops the gate chattering at the boundary.
    offset: f32 = 0.1,
    /// How long the probability must stay under `offset` before the gate
    /// closes. A second, so a breath between sentences does not close it.
    min_silence_ms: u32 = 1000,
};

/// Decides whether audio should reach the encoder, from a stream of speech
/// probabilities. Pure: no model, no clock, no audio.
pub const Gate = struct {
    thresholds: Thresholds = .{},

    open: bool = false,
    /// Milliseconds of consecutive below-`offset` audio while open.
    quiet_ms: u32 = 0,

    /// Feed one window's probability and how much audio it covered. Returns
    /// whether that audio should be encoded.
    ///
    /// The window that opens the gate is itself encoded, so the first syllable
    /// of a sentence is not the price of noticing it.
    pub fn update(self: *Gate, probability: f32, window_ms: u32) bool {
        if (!self.open) {
            if (probability < self.thresholds.onset) return false;
            self.open = true;
            self.quiet_ms = 0;
            return true;
        }

        if (probability >= self.thresholds.offset) {
            self.quiet_ms = 0;
            return true;
        }

        // Quiet, but not yet for long enough to call it the end. The audio is
        // still encoded: this is the gap between words, and dropping it would
        // run two sentences together.
        self.quiet_ms +|= window_ms;
        if (self.quiet_ms < self.thresholds.min_silence_ms) return true;

        self.open = false;
        self.quiet_ms = 0;
        return false;
    }

    /// Forget everything, for the start of a new session.
    pub fn reset(self: *Gate) void {
        self.open = false;
        self.quiet_ms = 0;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const win: u32 = 32;

test "silence is not encoded" {
    var gate = Gate{};
    for (0..100) |_| {
        try testing.expect(!gate.update(0.01, win));
    }
}

test "the window that first sounds like speech is encoded, not skipped" {
    // Opening late clips the first syllable of every sentence, which is a
    // much worse trade than one wasted encoder pass.
    var gate = Gate{};
    try testing.expect(!gate.update(0.05, win));
    try testing.expect(gate.update(0.9, win));
}

test "speech keeps the gate open" {
    var gate = Gate{};
    _ = gate.update(0.9, win);
    for (0..50) |_| {
        try testing.expect(gate.update(0.8, win));
    }
}

test "a gap between words does not close the gate" {
    var gate = Gate{};
    _ = gate.update(0.9, win);

    // Half a second of quiet, well inside the minimum.
    for (0..16) |_| {
        try testing.expect(gate.update(0.01, win));
    }
    try testing.expect(gate.open);
    try testing.expect(gate.update(0.9, win));
}

test "a real silence closes the gate, and only after the minimum" {
    var gate = Gate{};
    _ = gate.update(0.9, win);

    // 31 windows is 992 ms, just under a second.
    for (0..31) |_| {
        try testing.expect(gate.update(0.01, win));
    }
    try testing.expect(gate.open);

    // The one that crosses a second closes it.
    try testing.expect(!gate.update(0.01, win));
    try testing.expect(!gate.open);
}

test "the quiet run restarts when speech comes back" {
    var gate = Gate{};
    _ = gate.update(0.9, win);

    for (0..20) |_| _ = gate.update(0.01, win);
    _ = gate.update(0.9, win);
    try testing.expectEqual(@as(u32, 0), gate.quiet_ms);

    // So it takes another full second from here, not the remainder.
    for (0..31) |_| {
        try testing.expect(gate.update(0.01, win));
    }
    try testing.expect(!gate.update(0.01, win));
}

test "the two thresholds stop the gate chattering at the boundary" {
    // A probability sitting between offset and onset holds the gate in
    // whatever state it was already in, rather than flipping every window.
    var gate = Gate{};
    const between: f32 = 0.2; // above offset 0.1, below onset 0.3

    // Closed, it stays closed.
    for (0..10) |_| try testing.expect(!gate.update(between, win));

    // Open, it stays open indefinitely.
    _ = gate.update(0.9, win);
    for (0..200) |_| try testing.expect(gate.update(between, win));
    try testing.expect(gate.open);
}

test "thresholds are configurable" {
    var gate = Gate{ .thresholds = .{ .onset = 0.8, .offset = 0.7, .min_silence_ms = 64 } };

    try testing.expect(!gate.update(0.75, win)); // under a high onset
    try testing.expect(gate.update(0.85, win));

    try testing.expect(gate.update(0.1, win)); // 32ms quiet
    try testing.expect(!gate.update(0.1, win)); // 64ms, closes
}

test "reset closes the gate and forgets the quiet run" {
    var gate = Gate{};
    _ = gate.update(0.9, win);
    _ = gate.update(0.01, win);

    gate.reset();
    try testing.expect(!gate.open);
    try testing.expectEqual(@as(u32, 0), gate.quiet_ms);
}

test "an absurdly long window closes the gate rather than overflowing" {
    // The counter saturates instead of wrapping, so a window longer than the
    // counter can hold reads as "long enough" -- which is the right answer,
    // and in particular is not a panic.
    var gate = Gate{};
    _ = gate.update(0.9, win);
    try testing.expect(!gate.update(0.0, std.math.maxInt(u32)));
    try testing.expect(!gate.open);
}

test "a silence far longer than the minimum stays closed" {
    var gate = Gate{};
    _ = gate.update(0.9, win);
    for (0..32) |_| _ = gate.update(0.0, win);
    try testing.expect(!gate.open);

    for (0..10_000) |_| {
        try testing.expect(!gate.update(0.0, win));
    }
}
