// src/audio_detect_macos.zig — Core Audio device detection wizard (macOS)
//
// Stub implementation for Phase 1 (Metal validation via --stream-wav).
// Full implementation will follow in Phase 2.

const std = @import("std");

pub fn detectChannel(_allocator: std.mem.Allocator, _target: ?[:0]const u8, _duration: u32) void {
    _ = _allocator;
    _ = _target;
    _ = _duration;
    std.debug.print("Audio device detection not yet implemented for macOS.\n", .{});
    std.debug.print("Use --input tcp mode for testing.\n", .{});
}
