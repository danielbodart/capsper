const std = @import("std");
const c = @import("sherpa_c.zig");
const utils = @import("utils.zig");
const asr_types = @import("asr_types.zig");

pub const TranscribeResult = asr_types.TranscribeResult;
pub const Timing = asr_types.Timing;

pub const SherpaPipeline = struct {
    allocator: std.mem.Allocator,
    recognizer: *const c.SherpaOnnxOnlineRecognizer,
    stream: ?*const c.SherpaOnnxOnlineStream,
    verbose: bool,

    // Track how many samples have been fed to the stream so far,
    // so we only feed new audio on each transcribe() call.
    samples_fed: usize = 0,

    // Dummy field to match Pipeline interface expectations
    rate_limited: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        recognizer: *const c.SherpaOnnxOnlineRecognizer,
        verbose: bool,
    ) SherpaPipeline {
        return .{
            .allocator = allocator,
            .recognizer = recognizer,
            .stream = null,
            .verbose = verbose,
        };
    }

    pub fn deinit(self: *SherpaPipeline) void {
        if (self.stream) |s| {
            c.SherpaOnnxDestroyOnlineStream(s);
        }
    }

    /// Feed audio, decode, and return a delta (new text since last emission).
    /// Returns null if no new text was produced.
    pub fn transcribe(self: *SherpaPipeline, samples: []const f32, flush: bool, _: ?usize) !?TranscribeResult {
        const t_start = std.time.nanoTimestamp();

        // Ensure stream exists (created on first transcribe or after resetSegment)
        if (self.stream == null) {
            self.stream = c.SherpaOnnxCreateOnlineStream(self.recognizer) orelse
                return error.StreamCreateFailed;
        }
        const stream = self.stream.?;

        // Feed only new audio samples (sherpa maintains its own cache, so we
        // must not re-feed audio it's already seen).
        // On flush, speech_buf may have been trimmed (trailing silence removed),
        // making it shorter than what was already fed — skip feeding in that case.
        if (self.samples_fed < samples.len) {
            const new_samples = samples[self.samples_fed..];
            c.SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, new_samples.ptr, @intCast(new_samples.len));
            self.samples_fed = samples.len;
        }

        // Decode all available frames
        while (c.SherpaOnnxIsOnlineStreamReady(self.recognizer, stream) != 0) {
            c.SherpaOnnxDecodeOnlineStream(self.recognizer, stream);
        }

        // Get the full recognized text so far
        const result_ptr = c.SherpaOnnxGetOnlineStreamResult(self.recognizer, stream) orelse
            return null;

        // Immediately copy the text — result_ptr may reference stream-internal memory
        const raw_text = if (result_ptr.*.text) |t| std.mem.span(t) else "";
        const owned_text = try self.allocator.dupe(u8, raw_text);

        // Now safe to destroy the result
        c.SherpaOnnxDestroyOnlineRecognizerResult(result_ptr);

        if (self.verbose and owned_text.len > 0) {
            std.debug.print("  [sherpa] {s}({d}): \"{s}\"\n", .{ if (flush) "flush" else "partial", owned_text.len, owned_text });
        }

        // Only emit on flush (VAD offset / EOF) when the hypothesis is stable.
        if (!flush) {
            self.allocator.free(owned_text);
            return null;
        }

        if (owned_text.len == 0) {
            self.allocator.free(owned_text);
            return null;
        }

        const elapsed_ns = std.time.nanoTimestamp() - t_start;
        const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

        // Prefix with space to match whisper's convention (server expects leading space).
        const text = try std.fmt.allocPrint(self.allocator, " {s}", .{owned_text});
        self.allocator.free(owned_text);

        // Don't call resetSegment() here — the server calls it via resetUtterance
        // after this function returns. Calling it here would destroy the stream
        // while result_ptr may still reference stream-internal memory.

        return .{
            .text = text,
            .words = try self.allocator.alloc(utils.TimedWord, 0),
            .tokens = try self.allocator.alloc(i32, 0),
            .token_frames = try self.allocator.alloc(usize, 0),
            .was_rewind = false,
            .timing = .{
                .total_ms = elapsed_ms,
                .stop_reason = "sherpa",
            },
        };
    }

    /// No-op for sherpa — token accumulation is handled internally by the RNNT decoder.
    pub fn commitTokens(self: *SherpaPipeline, _: []const i32, _: []const usize) !void {
        _ = self;
    }

    /// Adjust samples_fed when audio is trimmed from front of speech_buf.
    pub fn handleTrim(self: *SherpaPipeline, trimmed_bytes: usize) !void {
        const trimmed_samples = trimmed_bytes / 2; // S16_LE = 2 bytes per sample
        self.samples_fed -|= trimmed_samples; // saturating subtract
    }

    /// Reset for a new VAD segment: destroy the current stream and clear accumulated text.
    /// A new stream is created lazily on the next transcribe() call.
    pub fn resetSegment(self: *SherpaPipeline) void {
        if (self.stream) |s| {
            c.SherpaOnnxDestroyOnlineStream(s);
            self.stream = null;
        }
        self.samples_fed = 0;
    }
};
