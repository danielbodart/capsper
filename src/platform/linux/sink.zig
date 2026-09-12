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
