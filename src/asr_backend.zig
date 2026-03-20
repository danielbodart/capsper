const std = @import("std");
const build_options = @import("build_options");
const asr_types = @import("asr_types.zig");
const utils = @import("utils.zig");
const Pipeline = @import("pipeline.zig").Pipeline;
const whisper_c = @import("whisper_c.zig");
const alignatt = @import("alignatt.zig");
const SherpaPipeline = if (build_options.asr_sherpa) @import("sherpa_pipeline.zig").SherpaPipeline else void;
const sherpa_c = if (build_options.asr_sherpa) @import("sherpa_c.zig") else struct {};

pub const TranscribeResult = asr_types.TranscribeResult;

/// Process-lifetime ASR configuration. Holds the model context (whisper ctx or
/// sherpa recognizer) that outlives individual connections.
pub const AsrBackend = union(enum) {
    whisper: WhisperConfig,
    sherpa: SherpaConfig,

    pub const WhisperConfig = struct {
        ctx: *whisper_c.whisper_context,
        prompt_tokens: []const whisper_c.whisper_token,
    };

    pub const SherpaConfig = if (build_options.asr_sherpa) struct {
        recognizer: *const sherpa_c.SherpaOnnxOnlineRecognizer,
    } else struct {};

    pub fn name(self: AsrBackend) []const u8 {
        return switch (self) {
            .whisper => "whisper",
            .sherpa => "sherpa",
        };
    }
};

/// Per-connection ASR instance. Created at the start of each connection,
/// destroyed at the end. Wraps either a Pipeline or SherpaPipeline.
pub const AsrInstance = union(enum) {
    whisper: *Pipeline,
    sherpa: if (build_options.asr_sherpa) *SherpaPipeline else void,

    pub fn create(backend: AsrBackend, allocator: std.mem.Allocator, verbose: bool, max_tokens_per_second: usize) !AsrInstance {
        switch (backend) {
            .whisper => |cfg| {
                const pipeline = try allocator.create(Pipeline);
                pipeline.* = try Pipeline.init(allocator, cfg.ctx, .{}, 4, verbose, cfg.prompt_tokens);
                pipeline.max_tokens_per_second = max_tokens_per_second;
                return .{ .whisper = pipeline };
            },
            .sherpa => |cfg| {
                if (!build_options.asr_sherpa) unreachable;
                const pipeline = try allocator.create(SherpaPipeline);
                pipeline.* = SherpaPipeline.init(allocator, cfg.recognizer, verbose);
                return .{ .sherpa = pipeline };
            },
        }
    }

    pub fn deinit(self: AsrInstance, allocator: std.mem.Allocator) void {
        switch (self) {
            .whisper => |p| {
                p.deinit();
                allocator.destroy(p);
            },
            .sherpa => |p| {
                if (!build_options.asr_sherpa) unreachable;
                p.deinit();
                allocator.destroy(p);
            },
        }
    }

    pub fn transcribe(self: AsrInstance, samples: []const f32, flush: bool) !?TranscribeResult {
        return switch (self) {
            .whisper => |p| p.transcribe(samples, flush, null),
            .sherpa => |p| {
                if (!build_options.asr_sherpa) unreachable;
                return p.transcribe(samples, flush, null);
            },
        };
    }

    pub fn commitTokens(self: AsrInstance, tokens: []const i32, frames: []const usize) !void {
        return switch (self) {
            .whisper => |p| p.commitTokens(tokens, frames),
            .sherpa => |p| {
                if (!build_options.asr_sherpa) unreachable;
                return p.commitTokens(tokens, frames);
            },
        };
    }

    pub fn handleTrim(self: AsrInstance, trimmed_bytes: usize) !void {
        return switch (self) {
            .whisper => |p| p.handleTrim(trimmed_bytes),
            .sherpa => |p| {
                if (!build_options.asr_sherpa) unreachable;
                return p.handleTrim(trimmed_bytes);
            },
        };
    }

    pub fn resetSegment(self: AsrInstance) void {
        switch (self) {
            .whisper => |p| p.resetSegment(),
            .sherpa => |p| {
                if (!build_options.asr_sherpa) unreachable;
                p.resetSegment();
            },
        }
    }

    pub fn lastAttendFrame(self: AsrInstance) ?usize {
        return switch (self) {
            .whisper => |p| p.last_attend_frame,
            .sherpa => null,
        };
    }

    pub fn isRateLimited(self: AsrInstance) bool {
        return switch (self) {
            .whisper => |p| p.rate_limited,
            .sherpa => false,
        };
    }

    pub fn clearRateLimited(self: AsrInstance) void {
        switch (self) {
            .whisper => |p| {
                p.rate_limited = false;
            },
            .sherpa => {},
        }
    }
};
