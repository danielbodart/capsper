// src/backend/ort/vad.zig — Silero VAD through ONNX Runtime.
//
// Nearly free here, because ONNX Runtime is already loaded for the ASR model
// and the VAD is two megabytes beside a six-hundred-megabyte one. It runs on
// the CPU regardless of what the ASR is using: the graph is tiny, and moving
// 512 samples to a GPU costs more than the arithmetic saves.
//
// The model is stateful. It takes the previous state in and hands the next one
// back, which is what lets a 32 ms window be judged in the context of the
// speech around it rather than on its own.

const std = @import("std");
const ort_c = @import("ort_c.zig");
const vad = @import("../../shared/vad.zig");

const log = std.log.scoped(.vad);

/// Silero.s native window at 16 kHz. Not negotiable: the graph has it baked in.
pub const window_samples: usize = 512;
pub const window_bytes: usize = window_samples * 2;
pub const window_ms: u32 = @intCast(window_samples * 1000 / 16000);

/// Samples of the previous window handed back to the model with the next one.
///
/// Easy to miss and silent when wrong: the input axis is dynamic, so a model
/// fed 512 samples instead of 576 runs perfectly happily and returns a
/// probability near zero for the loudest speech you have.
const context_samples: usize = 64;
const input_samples: usize = context_samples + window_samples;

/// Two layers of 128, the recurrent state the model carries between windows.
const state_len: usize = 2 * 1 * 128;

pub const Vad = struct {
    api: *const ort_c.OrtApi,
    env: *ort_c.OrtEnv,
    session: *ort_c.OrtSession,
    mem_info: *ort_c.OrtMemoryInfo,
    session_opts: *ort_c.OrtSessionOptions,
    allocator: std.mem.Allocator,

    state: []f32,
    samples: []f32,
    /// Audio that arrived but did not fill a window, carried to the next call.
    pending: std.ArrayListUnmanaged(u8) = .{},

    gate: vad.Gate,

    pub fn init(
        allocator: std.mem.Allocator,
        model_path: [:0]const u8,
        thresholds: vad.Thresholds,
    ) !*Vad {
        const api = ort_c.getApi();

        var env: ?*ort_c.OrtEnv = null;
        try ort_c.check(api, api.CreateEnv.?(ort_c.ORT_LOGGING_LEVEL_WARNING, "capsper-vad", @ptrCast(&env)));
        errdefer api.ReleaseEnv.?(env.?);

        var opts: ?*ort_c.OrtSessionOptions = null;
        try ort_c.check(api, api.CreateSessionOptions.?(&opts));
        errdefer api.ReleaseSessionOptions.?(opts.?);

        // One thread: the graph is far too small for a pool to pay for itself,
        // and the ASR wants the cores.
        try ort_c.check(api, api.SetIntraOpNumThreads.?(opts.?, 1));
        try ort_c.check(api, api.SetInterOpNumThreads.?(opts.?, 1));

        var session: ?*ort_c.OrtSession = null;
        try ort_c.check(api, api.CreateSession.?(env.?, model_path.ptr, opts.?, @ptrCast(&session)));
        errdefer api.ReleaseSession.?(session.?);

        var mem: ?*ort_c.OrtMemoryInfo = null;
        try ort_c.check(api, api.CreateCpuMemoryInfo.?(0, 0, @ptrCast(&mem)));
        errdefer api.ReleaseMemoryInfo.?(mem.?);

        const self = try allocator.create(Vad);
        errdefer allocator.destroy(self);

        self.* = .{
            .api = api,
            .env = env.?,
            .session = session.?,
            .mem_info = mem.?,
            .session_opts = opts.?,
            .allocator = allocator,
            .state = try allocator.alloc(f32, state_len),
            .samples = try allocator.alloc(f32, input_samples),
            .gate = .{ .thresholds = thresholds },
        };
        @memset(self.state, 0);
        @memset(self.samples, 0);


        return self;
    }

    pub fn deinit(self: *Vad) void {
        const api = self.api;
        self.pending.deinit(self.allocator);
        self.allocator.free(self.samples);
        self.allocator.free(self.state);
        api.ReleaseSessionOptions.?(self.session_opts);
        api.ReleaseSession.?(self.session);
        api.ReleaseMemoryInfo.?(self.mem_info);
        api.ReleaseEnv.?(self.env);
        self.allocator.destroy(self);
    }

    /// Forget the recurrent state and close the gate, for a new session.
    pub fn reset(self: *Vad) void {
        @memset(self.state, 0);
        @memset(self.samples, 0);
        self.pending.clearRetainingCapacity();
        self.gate.reset();
    }

    /// Should this PCM reach the encoder?
    ///
    /// The answer is for the whole slice, not per window: the caller feeds the
    /// encoder in 560 ms chunks, so a chunk with any speech in it has to go
    /// through whole. Anything left over after the last complete window is
    /// carried into the next call, so the model always sees the continuous
    /// stream it was trained on.
    ///
    /// Errs towards encoding. A window the model could not be run on is
    /// treated as speech, because the cost of being wrong that way is one
    /// encoder pass and the cost of the other way is lost transcript.
    pub fn shouldEncode(self: *Vad, pcm: []const u8) bool {
        self.pending.appendSlice(self.allocator, pcm) catch return true;

        var any = false;
        while (self.pending.items.len >= window_bytes) {
            const window = self.pending.items[0..window_bytes];
            const p = self.speechProbability(window) catch {
                self.consume(window_bytes);
                return true;
            };
            if (self.gate.update(p, window_ms)) any = true;
            self.consume(window_bytes);
        }

        // Less than one window of audio so far. The gate's current state is
        // the best answer available.
        if (!any and self.gate.open) return true;
        return any;
    }

    fn consume(self: *Vad, n: usize) void {
        const rest = self.pending.items.len - n;
        std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[n..]);
        self.pending.shrinkRetainingCapacity(rest);
    }

    /// Run one window, and carry the model's state forward.
    fn speechProbability(self: *Vad, window: []const u8) !f32 {
        const api = self.api;

        // The model sees the previous window.s tail followed by this one, so
        // it has the run-up to whatever starts at the boundary.
        for (self.samples[context_samples..], 0..) |*sample, i| {
            const raw = std.mem.readInt(i16, window[i * 2 ..][0..2], .little);
            sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
        }
        defer @memcpy(self.samples[0..context_samples], self.samples[input_samples - context_samples ..]);

        var input_shape = [_]i64{ 1, @intCast(input_samples) };
        var input_tensor: ?*ort_c.OrtValue = null;
        try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info,
            @ptrCast(self.samples.ptr),
            self.samples.len * @sizeOf(f32),
            &input_shape,
            2,
            ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
            &input_tensor,
        ));
        defer api.ReleaseValue.?(input_tensor.?);

        var state_shape = [_]i64{ 2, 1, 128 };
        var state_tensor: ?*ort_c.OrtValue = null;
        try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info,
            @ptrCast(self.state.ptr),
            self.state.len * @sizeOf(f32),
            &state_shape,
            3,
            ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
            &state_tensor,
        ));
        defer api.ReleaseValue.?(state_tensor.?);

        // A rank-0 scalar, not a one-element tensor. The graph compares this
        // against 16000 to pick a sample-rate branch, and an `If` needs a
        // scalar condition -- give it rank 1 and the model runs happily and
        // returns a probability near zero for even the loudest speech.
        var rate = [_]i64{16000};
        var rate_tensor: ?*ort_c.OrtValue = null;
        try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
            self.mem_info,
            @ptrCast(&rate),
            @sizeOf(i64),
            null,
            0,
            ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
            &rate_tensor,
        ));
        defer api.ReleaseValue.?(rate_tensor.?);

        const input_names = [_][*:0]const u8{ "input", "state", "sr" };
        const output_names = [_][*:0]const u8{ "output", "stateN" };
        const inputs = [_]?*const ort_c.OrtValue{ input_tensor, state_tensor, rate_tensor };
        var outputs: [2]?*ort_c.OrtValue = .{ null, null };

        try ort_c.check(api, api.Run.?(
            self.session,
            null,
            &input_names,
            @ptrCast(&inputs),
            3,
            &output_names,
            2,
            @ptrCast(&outputs),
        ));
        defer for (&outputs) |*o| {
            if (o.*) |v| api.ReleaseValue.?(v);
        };

        var next_state: ?*f32 = null;
        try ort_c.check(api, api.GetTensorMutableData.?(outputs[1].?, @ptrCast(&next_state)));
        @memcpy(self.state, @as([*]f32, @ptrCast(next_state.?))[0..state_len]);

        var probability_out: ?*f32 = null;
        try ort_c.check(api, api.GetTensorMutableData.?(outputs[0].?, @ptrCast(&probability_out)));
        return probability_out.?.*;
    }
};

/// Load the VAD, or return null with a warning. A missing model means no gate,
/// not a failure to start: everything still works, it just costs more.
pub fn load(
    allocator: std.mem.Allocator,
    model_path: [:0]const u8,
    thresholds: vad.Thresholds,
) ?*Vad {
    return Vad.init(allocator, model_path, thresholds) catch |err| {
        log.warn("no voice activity gate ({s}: {}); silence will be transcribed", .{ model_path, err });
        return null;
    };
}
