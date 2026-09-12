// src/platform/macos/mic_level.zig — not implemented here.
//
// CoreAudio already levels the device rather than the stream: `setGain` in
// ./audio.zig prefers `kAudioDevicePropertyVolumeScalar` on the input scope and
// falls back to multiplying in the capture callback. So the thing this exists
// to provide on Linux, a level that lands on the microphone rather than on one
// capture of it, macOS has had all along through a different door.
//
// Following the default input as it changes is genuinely missing, and so is
// meeting capture, which is what wants it. Both are Linux only today.

const std = @import("std");

pub const MicLevel = struct {
    pub fn init(_: ?[:0]const u8) !MicLevel {
        return error.MicLevelUnavailable;
    }

    pub fn deinit(_: *MicLevel) void {}

    pub fn set(_: *MicLevel, _: f32) bool {
        return false;
    }

    pub fn tookChange(_: *MicLevel) bool {
        return false;
    }

    pub fn nodeName(_: *MicLevel) []const u8 {
        return "";
    }
};
