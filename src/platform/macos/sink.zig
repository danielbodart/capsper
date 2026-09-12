// src/platform/macos/sink.zig — no virtual sink here yet.
//
// The Linux sink is a PipeWire loopback module. macOS has no equivalent a
// program can create for itself: capturing system audio needs either a
// user-installed loopback driver (BlackHole, which `test/ca-stream.test.ts`
// already relies on) or a Core Audio taps entitlement. Both are decisions in
// their own right, so meeting capture is Linux-only until one is made.

const std = @import("std");
const source = @import("../../shared/source.zig");

pub const VirtualSink = struct {
    name: [:0]const u8,

    pub fn init(
        name: [:0]const u8,
        description: [:0]const u8,
        output_target: ?[:0]const u8,
    ) !VirtualSink {
        _ = name;
        _ = description;
        _ = output_target;
        return error.VirtualSinkUnsupported;
    }

    pub fn deinit(self: *VirtualSink) void {
        _ = self;
    }
};

/// Unreachable alongside `VirtualSink`, and present so the shared code takes
/// the same arguments on both platforms. When meeting capture does reach
/// macOS, the counterpart is CoreAudio's voice processing I/O unit, which
/// cancels in the system rather than in the graph -- a different shape, not a
/// port of this one.
pub const EchoCanceller = struct {
    mic: [:0]const u8,

    pub fn init(
        sink_name: [:0]const u8,
        description: [:0]const u8,
        mic_target: ?[:0]const u8,
    ) !EchoCanceller {
        _ = sink_name;
        _ = description;
        _ = mic_target;
        return error.EchoCancelUnsupported;
    }

    pub fn deinit(self: *EchoCanceller) void {
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

    /// Nothing to describe while there is nothing to watch. Present so the
    /// shared code writes its metadata file the same way on both platforms.
    pub fn snapshot(self: *const SinkWatch, arena: std.mem.Allocator) ![]const source.Stream {
        _ = self;
        _ = arena;
        return &.{};
    }

    pub fn deinit(self: *SinkWatch) void {
        _ = self;
    }

    pub fn activeStreams(self: *const SinkWatch) u32 {
        _ = self;
        return 0;
    }
};
