// src/platform/linux/mic_level.zig — the microphone's own level.
//
// The level belongs on the microphone rather than on one capture of it. That
// is the node the echo canceller reads, so the canceller sees a properly
// levelled signal rather than having its output adjusted afterwards, and it is
// one mechanism for every path: dictation has no canceller and wants exactly
// the same thing.
//
// The cost is deliberate. This is the level every application sees, and
// WirePlumber saves it, so whatever the controller settles on outlives capsper.
// That is the same control a desktop's input slider drives, which is as much
// the argument for it as against.
//
// Held open rather than set on demand, because the controller adjusts it while
// audio is flowing and a PipeWire connection per adjustment would be built
// inside the capture loop. See `pw_helpers.c`.

const std = @import("std");
const pw = @import("pipewire_c.zig");

const log = std.log.scoped(.mic_level);

pub const MicLevel = struct {
    handle: *pw.pw_mic_level,

    /// `target` names the microphone, or is null to follow the desktop's
    /// default input and keep following it as it changes.
    pub fn init(target: ?[:0]const u8) !MicLevel {
        const handle = pw.pw_mic_level_create(
            if (target) |t| t.ptr else null,
        ) orelse return error.MicLevelUnavailable;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *MicLevel) void {
        pw.pw_mic_level_destroy(self.handle);
    }

    /// Linear, matching the `gain` setting: 1.0 is unity. PipeWire clamps at
    /// 10x, so anything past +20 dB would have to be a multiply of our own.
    ///
    /// False when there is no microphone bound yet, which is ordinary rather
    /// than wrong: the node may not have reached the registry, or the desktop
    /// may have no default input at all.
    pub fn set(self: *MicLevel, volume: f32) bool {
        return pw.pw_mic_level_set(self.handle, volume) == 0;
    }

    /// Whether the microphone has changed since this was last asked, clearing
    /// the flag as it answers.
    ///
    /// A controller seeing true should start again from the configured level.
    /// Carrying the old one across is levelling for hardware that is no longer
    /// there, and the two can be a long way apart -- a quiet interface and a
    /// headset that sits against the mouth are not the same problem.
    pub fn tookChange(self: *MicLevel) bool {
        return pw.pw_mic_level_take_changed(self.handle) != 0;
    }

    /// The microphone being levelled, for saying which one in a log. Empty
    /// when nothing is bound.
    pub fn nodeName(self: *MicLevel) []const u8 {
        return std.mem.span(pw.pw_mic_level_node_name(self.handle));
    }
};
