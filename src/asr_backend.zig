/// ASR backend — runtime interface for speech recognition pipelines.
///
/// Uses a vtable pattern (like std.mem.Allocator) so the backend selection
/// is a one-time runtime decision at startup. No comptime platform branching
/// leaks beyond the init call.
const std = @import("std");
const asr_types = @import("asr_types.zig");

pub const TranscribeResult = asr_types.TranscribeResult;
pub const Timing = asr_types.Timing;

pub const AsrPipeline = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        transcribe: *const fn (ptr: *anyopaque, samples: []const f32, flush: bool, max_tokens: ?usize) anyerror!?TranscribeResult,
        resetSegment: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn transcribe(self: AsrPipeline, samples: []const f32, flush: bool, max_tokens: ?usize) !?TranscribeResult {
        return self.vtable.transcribe(self.ptr, samples, flush, max_tokens);
    }

    pub fn resetSegment(self: AsrPipeline) void {
        self.vtable.resetSegment(self.ptr);
    }

    pub fn deinit(self: AsrPipeline) void {
        self.vtable.deinit(self.ptr);
    }
};
