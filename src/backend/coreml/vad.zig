// src/backend/coreml/vad.zig — no voice activity gate on macOS.
//
// The gate is a small ONNX model, and the CoreML build deliberately does not
// link ONNX Runtime: the plan is to convert the model to CoreML rather than
// carry a second runtime for two megabytes of graph. Until that conversion
// lands there is no gate here.
//
// Nothing is broken by its absence -- Nemotron does not hallucinate into
// silence -- it simply costs an encoder pass per chunk of silence. Meeting
// capture is Linux-only anyway, since macOS gives a program no way to create a
// virtual output device for itself.

const std = @import("std");
const vad = @import("../../shared/vad.zig");

pub const window_samples: usize = 512;
pub const window_bytes: usize = window_samples * 2;
pub const window_ms: u32 = @intCast(window_samples * 1000 / 16000);

pub const Vad = struct {
    pub fn deinit(self: *Vad) void {
        _ = self;
    }

    pub fn reset(self: *Vad) void {
        _ = self;
    }

    /// Always yes, which is exactly what the behaviour was before a gate
    /// existed at all.
    pub fn shouldEncode(self: *Vad, pcm: []const u8) bool {
        _ = self;
        _ = pcm;
        return true;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    model_path: [:0]const u8,
    thresholds: vad.Thresholds,
) ?*Vad {
    _ = allocator;
    _ = model_path;
    _ = thresholds;
    return null;
}
