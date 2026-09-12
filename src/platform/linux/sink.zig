// src/platform/linux/sink.zig — the output device capsper owns.
//
// Turning on meeting capture puts a sink in the desktop's output picker. The
// user selects it in the meeting app, and that selection is what says "record
// this"; nothing else is ever in it. The audio carries on to the real default
// output, so the call is still audible.
//
// Everything here is a thin wrapper over `pw_virtual_sink_create` in
// `pw_helpers.c`. The module arguments are a SPA-flavoured string and the
// module API is C, so per the PipeWire FFI rule the work lives on that side.

const std = @import("std");
const pw = @import("pipewire_c.zig");

pub const VirtualSink = struct {
    handle: *pw.pw_virtual_sink,
    /// The node name the sink appears under, which is also the node to capture
    /// the far end from: a sink's monitor is addressed by the sink's own name.
    ///
    /// Capturing it needs `stream.capture.sink = true` on the capture stream's
    /// properties, and that is not an optimisation. Targeting a sink by name
    /// *without* it does not fail -- the stream falls back to the default
    /// source and quietly records the microphone instead, which sounds like
    /// working code right up until the far-end track turns out to be a second
    /// copy of the near end. `test/pw-sink.test.ts` pins this down by
    /// asserting the monitor reads as digital silence when nothing is playing.
    name: [:0]const u8,

    pub fn init(name: [:0]const u8, description: [:0]const u8) !VirtualSink {
        const handle = pw.pw_virtual_sink_create(name.ptr, description.ptr) orelse
            return error.VirtualSinkFailed;
        return .{ .handle = handle, .name = name };
    }

    pub fn deinit(self: *VirtualSink) void {
        pw.pw_virtual_sink_destroy(self.handle);
    }
};

/// Watches how many applications are currently playing into the sink.
///
/// This is gate 1: the user selecting the sink in a meeting app is the signal
/// that a call is happening, and the graph reports it without capsper having
/// to guess from calendars or window titles. Only `running` streams count, so
/// a paused call reads as zero -- the debounce that stops a brief mute ending
/// a session lives in `shared/meeting.zig`.
pub const SinkWatch = struct {
    handle: *pw.pw_sink_watch,

    pub fn init(sink_name: [:0]const u8) !SinkWatch {
        const handle = pw.pw_sink_watch_create(sink_name.ptr) orelse
            return error.SinkWatchFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *SinkWatch) void {
        pw.pw_sink_watch_destroy(self.handle);
    }

    pub fn activeStreams(self: *const SinkWatch) u32 {
        return pw.pw_sink_watch_active_streams(self.handle);
    }
};
