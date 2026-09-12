// src/platform/macos/sink.zig — no virtual sink here yet.
//
// The Linux sink is a PipeWire loopback module. macOS has no equivalent a
// program can create for itself: capturing system audio needs either a
// user-installed loopback driver (BlackHole, which `test/ca-stream.test.ts`
// already relies on) or a Core Audio taps entitlement. Both are decisions in
// their own right, so meeting capture is Linux-only until one is made.

pub const VirtualSink = struct {
    name: [:0]const u8,

    pub fn init(name: [:0]const u8, description: [:0]const u8) !VirtualSink {
        _ = name;
        _ = description;
        return error.VirtualSinkUnsupported;
    }

    pub fn deinit(self: *VirtualSink) void {
        _ = self;
    }
};

/// Unimplemented alongside `VirtualSink`: with no sink to watch there is
/// nothing for gate 1 to read.
pub const SinkWatch = struct {
    pub fn init(sink_name: [:0]const u8) !SinkWatch {
        _ = sink_name;
        return error.VirtualSinkUnsupported;
    }

    pub fn deinit(self: *SinkWatch) void {
        _ = self;
    }

    pub fn activeStreams(self: *const SinkWatch) u32 {
        _ = self;
        return 0;
    }
};
