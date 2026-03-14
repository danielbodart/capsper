// src/audio_capture_macos.zig — Core Audio AUHAL capture (macOS)
//
// Stub implementation for Phase 1 (Metal validation via --stream-wav).
// Full implementation will follow in Phase 2.

const std = @import("std");
const posix = std.posix;

pub const AudioCapture = struct {
    pipe_read_fd: posix.fd_t,

    /// Default channel: 0 = first/mono channel on macOS (zero-indexed).
    pub const default_channel: u32 = 0;

    pub fn init(_target: ?[:0]const u8, _channel_position: u32) !AudioCapture {
        _ = _target;
        _ = _channel_position;
        return error.NotImplemented;
    }

    pub fn deinit(_: *AudioCapture) void {}

    pub fn setActive(_: *AudioCapture, _: bool) void {}

    pub fn setCork(_: *AudioCapture, _: bool) void {}

    pub fn setGain(_: *AudioCapture, _: f32) void {}

    pub fn getFd(self: *const AudioCapture) posix.fd_t {
        return self.pipe_read_fd;
    }

    /// Parse channel name to zero-based channel index.
    /// macOS uses simple integer indices, not SPA position constants.
    pub fn parseChannelName(name: []const u8) ?u32 {
        if (std.ascii.eqlIgnoreCase(name, "MONO")) return 0;
        if (std.ascii.eqlIgnoreCase(name, "FL")) return 0;
        if (std.ascii.eqlIgnoreCase(name, "FR")) return 1;
        // Parse AUXn → channel index n
        if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[0..3], "AUX")) {
            return std.fmt.parseInt(u32, name[3..], 10) catch return null;
        }
        return null;
    }
};
