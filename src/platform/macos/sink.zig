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
