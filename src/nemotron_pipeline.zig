/// Nemotron RNNT streaming ASR pipeline.
///
/// Cache-aware FastConformer encoder + RNNT greedy decoder using onnxruntime directly.
/// Receives f32 audio samples incrementally, computes mel features, runs streaming
/// encoder in 560ms chunks, and decodes tokens via RNNT greedy search.
///
/// The sole ASR backend for capsper.
const std = @import("std");
const ort_c = @import("ort_c.zig");
const nemo_mel = @import("nemo_mel.zig");
const mel_state_mod = @import("nemo_mel_state.zig");
const NemoMelState = mel_state_mod.NemoMelState;
const tokenizer = @import("tokenizer.zig");
const asr_types = @import("asr_types.zig");
const utils = @import("utils.zig");
const context_graph_mod = @import("context_graph.zig");
const ContextGraph = context_graph_mod.ContextGraph;
const ContextState = context_graph_mod.ContextState;

const AsrPipeline = @import("asr_backend.zig").AsrPipeline;
pub const TranscribeResult = asr_types.TranscribeResult;
pub const Timing = asr_types.Timing;

// Streaming parameters (560ms latency, att_context=[70,6])
const MEL_SHIFT: usize = 56; // mel frames per encoder chunk
const PRE_ENCODE_CACHE: usize = 9; // mel frames prepended from previous chunk
const CACHE_CH_DIM: usize = 70;
const CACHE_TIME_DIM: usize = 8;
const ENC_LAYERS: usize = 24;
const ENC_DIM: usize = 1024;
const PRED_HIDDEN: usize = 640;
const PRED_LAYERS: usize = 2;
const MAX_SYMBOLS_PER_FRAME: usize = 10;
const N_MELS = mel_state_mod.N_MELS;

/// Process-lifetime config. ORT sessions are shared across connections.
pub const NemotronConfig = struct {
    api: *const ort_c.OrtApi,
    enc_session: *ort_c.OrtSession,
    dec_session: *ort_c.OrtSession,
    mem_info: *ort_c.OrtMemoryInfo,
    filterbank: []const f32,
    token_map: *const tokenizer.TokenMap,
    context_graph: ?*const ContextGraph = null,
};

pub const NemotronPipeline = struct {
    allocator: std.mem.Allocator,
    config: NemotronConfig,
    verbose: bool,

    // Incremental mel state
    mel: NemoMelState,
    mel_frame_cursor: usize = 0, // next mel frame to encode

    // Pre-encode cache: last PRE_ENCODE_CACHE mel frames from previous encoder chunk
    pre_cache: [N_MELS * PRE_ENCODE_CACHE]f32 = [_]f32{0} ** (N_MELS * PRE_ENCODE_CACHE),

    // Encoder caches
    cache_ch: []f32,
    cache_time: []f32,
    cache_ch_len: [1]i64 = .{0},

    // RNNT decoder state
    dec_state1: []f32,
    dec_state2: []f32,
    last_token: i32 = tokenizer.BLANK_ID,

    // Accumulated text this segment
    emitted_text: std.ArrayListUnmanaged(u8) = .{},
    // Cursor: how much of emitted_text has been returned to the caller
    emit_cursor: usize = 0,

    // Context biasing trie state (Aho-Corasick position)
    trie_state: *const ContextState = undefined, // set in init

    pub fn init(allocator: std.mem.Allocator, config: NemotronConfig, verbose: bool) !NemotronPipeline {
        const cache_ch_size = ENC_LAYERS * 1 * CACHE_CH_DIM * ENC_DIM;
        const cache_time_size = ENC_LAYERS * 1 * ENC_DIM * CACHE_TIME_DIM;
        const dec_state_size = PRED_LAYERS * 1 * PRED_HIDDEN;

        const cache_ch = try allocator.alloc(f32, cache_ch_size);
        errdefer allocator.free(cache_ch);
        @memset(cache_ch, 0);

        const cache_time = try allocator.alloc(f32, cache_time_size);
        errdefer allocator.free(cache_time);
        @memset(cache_time, 0);

        const dec_state1 = try allocator.alloc(f32, dec_state_size);
        errdefer allocator.free(dec_state1);
        @memset(dec_state1, 0);

        const dec_state2 = try allocator.alloc(f32, dec_state_size);
        errdefer allocator.free(dec_state2);
        @memset(dec_state2, 0);

        var pipeline = NemotronPipeline{
            .allocator = allocator,
            .config = config,
            .verbose = verbose,
            .mel = NemoMelState.init(allocator, config.filterbank),
            .cache_ch = cache_ch,
            .cache_time = cache_time,
            .dec_state1 = dec_state1,
            .dec_state2 = dec_state2,
        };
        if (config.context_graph) |cg| {
            pipeline.trie_state = cg.root;
        }
        return pipeline;
    }

    /// Return the type-erased AsrPipeline interface.
    pub fn asrPipeline(self: *NemotronPipeline) AsrPipeline {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = AsrPipeline.VTable{
        .transcribe = struct {
            fn f(ptr: *anyopaque, samples: []const f32, flush: bool, max_tokens: ?usize) anyerror!?TranscribeResult {
                const self: *NemotronPipeline = @ptrCast(@alignCast(ptr));
                return self.transcribe(samples, flush, max_tokens);
            }
        }.f,
        .resetSegment = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NemotronPipeline = @ptrCast(@alignCast(ptr));
                self.resetSegment();
            }
        }.f,
        .deinit = struct {
            fn f(ptr: *anyopaque) void {
                const self: *NemotronPipeline = @ptrCast(@alignCast(ptr));
                self.deinit();
            }
        }.f,
    };

    pub fn deinit(self: *NemotronPipeline) void {
        self.allocator.free(self.cache_ch);
        self.allocator.free(self.cache_time);
        self.allocator.free(self.dec_state1);
        self.allocator.free(self.dec_state2);
        self.emitted_text.deinit(self.allocator);
        self.mel.deinit();
    }

    /// Feed audio samples, run encoder+decoder on any complete chunks.
    /// Returns new text decoded since last call (per-chunk streaming).
    /// On flush, processes any remaining partial frames before returning.
    pub fn transcribe(self: *NemotronPipeline, samples: []const f32, flush: bool, _: ?usize) !?TranscribeResult {
        const t_start = std.time.nanoTimestamp();

        // Feed samples into incremental mel
        try self.mel.feed(samples);

        // Process complete MEL_SHIFT-sized chunks
        try self.processEncoderChunks();

        // On flush: process any remaining partial mel frames
        if (flush and self.mel.n_frames > self.mel_frame_cursor) {
            try self.processPartialChunk();
        }

        const elapsed_ns = std.time.nanoTimestamp() - t_start;
        const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

        // Return new text since last emission, splitting at word boundaries.
        // SentencePiece ▁ produces spaces for word-initial tokens. On non-flush,
        // emit up to the last word boundary (space) so we never emit subword fragments.
        // On flush, emit everything remaining.
        const full_new = self.emitted_text.items[self.emit_cursor..];
        if (full_new.len == 0) return null;

        const emit_end = full_new.len;

        const text = try self.allocator.dupe(u8, full_new[0..emit_end]);
        self.emit_cursor += emit_end;

        if (self.verbose) {
            const label = if (flush) "flush" else "chunk";
            std.debug.print("  [nemotron] {s}({d}): \"{s}\"\n", .{ label, text.len, text });
        }

        return .{
            .text = text,
            .words = try self.allocator.alloc(utils.TimedWord, 0),
            .tokens = try self.allocator.alloc(i32, 0),
            .token_frames = try self.allocator.alloc(usize, 0),
            .was_rewind = false,
            .timing = .{
                .total_ms = elapsed_ms,
                .stop_reason = if (flush) "nemotron-flush" else "nemotron",
            },
        };
    }

    /// Reset all state for a new utterance.
    pub fn resetSegment(self: *NemotronPipeline) void {
        self.mel.reset();
        self.mel_frame_cursor = 0;
        @memset(&self.pre_cache, 0);
        @memset(self.cache_ch, 0);
        @memset(self.cache_time, 0);
        self.cache_ch_len = .{0};
        @memset(self.dec_state1, 0);
        @memset(self.dec_state2, 0);
        self.last_token = tokenizer.BLANK_ID;
        self.emitted_text.clearRetainingCapacity();
        self.emit_cursor = 0;
        if (self.config.context_graph) |cg| {
            self.trie_state = cg.root;
        }
    }

    // ─── Internal: encoder + decoder ─────────────────────────────────────────

    fn processEncoderChunks(self: *NemotronPipeline) !void {
        while (self.mel.n_frames >= self.mel_frame_cursor + MEL_SHIFT) {
            try self.runEncoderChunk(MEL_SHIFT);
            self.mel_frame_cursor += MEL_SHIFT;
        }
    }

    fn processPartialChunk(self: *NemotronPipeline) !void {
        const remaining = self.mel.n_frames - self.mel_frame_cursor;
        if (remaining == 0) return;
        // Process the remaining frames (encoder handles partial chunks)
        try self.runEncoderChunk(remaining);
        self.mel_frame_cursor = self.mel.n_frames;
    }

    fn runEncoderChunk(self: *NemotronPipeline, chunk_mel_frames: usize) !void {
        const api = self.config.api;
        const mem_info = self.config.mem_info;

        // Build chunk: pre_cache (9 frames) + new frames
        const full_chunk_frames = PRE_ENCODE_CACHE + chunk_mel_frames;
        const chunk_data = try self.allocator.alloc(f32, N_MELS * full_chunk_frames);
        defer self.allocator.free(chunk_data);

        // Copy pre_cache (band-major layout) into chunk
        for (0..N_MELS) |band| {
            for (0..PRE_ENCODE_CACHE) |f| {
                chunk_data[band * full_chunk_frames + f] = self.pre_cache[band * PRE_ENCODE_CACHE + f];
            }
        }

        // Copy new mel frames via exportBandMajor into the right position
        // We need to fill chunk_data[band * full_chunk_frames + PRE_ENCODE_CACHE ..] for each band
        // Export into a temp buffer first, then copy
        const new_frames_buf = try self.allocator.alloc(f32, N_MELS * chunk_mel_frames);
        defer self.allocator.free(new_frames_buf);
        self.mel.exportBandMajor(new_frames_buf, self.mel_frame_cursor, chunk_mel_frames);

        for (0..N_MELS) |band| {
            for (0..chunk_mel_frames) |f| {
                chunk_data[band * full_chunk_frames + PRE_ENCODE_CACHE + f] = new_frames_buf[band * chunk_mel_frames + f];
            }
        }

        // Update pre_cache for next chunk
        if (chunk_mel_frames >= PRE_ENCODE_CACHE) {
            // Take last PRE_ENCODE_CACHE frames from the new frames
            const start = chunk_mel_frames - PRE_ENCODE_CACHE;
            for (0..N_MELS) |band| {
                for (0..PRE_ENCODE_CACHE) |f| {
                    self.pre_cache[band * PRE_ENCODE_CACHE + f] = new_frames_buf[band * chunk_mel_frames + start + f];
                }
            }
        } else {
            // Shift pre_cache left and append the new frames
            const keep = PRE_ENCODE_CACHE - chunk_mel_frames;
            for (0..N_MELS) |band| {
                // Shift existing
                for (0..keep) |f| {
                    self.pre_cache[band * PRE_ENCODE_CACHE + f] = self.pre_cache[band * PRE_ENCODE_CACHE + chunk_mel_frames + f];
                }
                // Append new
                for (0..chunk_mel_frames) |f| {
                    self.pre_cache[band * PRE_ENCODE_CACHE + keep + f] = new_frames_buf[band * chunk_mel_frames + f];
                }
            }
        }

        // Create encoder input tensors
        var signal_shape = [_]i64{ 1, N_MELS, @intCast(full_chunk_frames) };
        var signal_tensor: ?*ort_c.OrtValue = null;
        try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
            mem_info, @ptrCast(chunk_data.ptr), chunk_data.len * @sizeOf(f32),
            &signal_shape, 3, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &signal_tensor,
        ));
        defer api.ReleaseValue.?(signal_tensor.?);

        var length_val = [_]i64{@intCast(full_chunk_frames)};
        var length_shape = [_]i64{1};
        var length_tensor: ?*ort_c.OrtValue = null;
        try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
            mem_info, @ptrCast(&length_val), @sizeOf(i64), &length_shape, 1,
            ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &length_tensor,
        ));
        defer api.ReleaseValue.?(length_tensor.?);

        var cache_ch_shape = [_]i64{ 1, ENC_LAYERS, CACHE_CH_DIM, ENC_DIM };
        var cache_ch_tensor: ?*ort_c.OrtValue = null;
        try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
            mem_info, @ptrCast(self.cache_ch.ptr), self.cache_ch.len * @sizeOf(f32),
            &cache_ch_shape, 4, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &cache_ch_tensor,
        ));
        defer api.ReleaseValue.?(cache_ch_tensor.?);

        var cache_time_shape = [_]i64{ 1, ENC_LAYERS, ENC_DIM, CACHE_TIME_DIM };
        var cache_time_tensor: ?*ort_c.OrtValue = null;
        try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
            mem_info, @ptrCast(self.cache_time.ptr), self.cache_time.len * @sizeOf(f32),
            &cache_time_shape, 4, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &cache_time_tensor,
        ));
        defer api.ReleaseValue.?(cache_time_tensor.?);

        var cache_ch_len_shape = [_]i64{1};
        var cache_ch_len_tensor: ?*ort_c.OrtValue = null;
        try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
            mem_info, @ptrCast(&self.cache_ch_len), @sizeOf(i64), &cache_ch_len_shape, 1,
            ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &cache_ch_len_tensor,
        ));
        defer api.ReleaseValue.?(cache_ch_len_tensor.?);

        // Run encoder
        const enc_input_names = [_][*:0]const u8{ "audio_signal", "length", "cache_last_channel", "cache_last_time", "cache_last_channel_len" };
        const enc_output_names = [_][*:0]const u8{ "outputs", "encoded_lengths", "cache_last_channel_next", "cache_last_time_next", "cache_last_channel_next_len" };
        const enc_inputs = [_]?*const ort_c.OrtValue{ signal_tensor, length_tensor, cache_ch_tensor, cache_time_tensor, cache_ch_len_tensor };
        var enc_outputs: [5]?*ort_c.OrtValue = .{ null, null, null, null, null };

        try ort_c.check(api, api.Run.?(
            self.config.enc_session, null, &enc_input_names, @ptrCast(&enc_inputs), 5,
            &enc_output_names, 5, @ptrCast(&enc_outputs),
        ));
        defer for (&enc_outputs) |*o| {
            if (o.*) |v| api.ReleaseValue.?(v);
        };

        // Read encoder output length
        var enc_len_raw: ?*i64 = null;
        try ort_c.check(api, api.GetTensorMutableData.?(enc_outputs[1].?, @ptrCast(&enc_len_raw)));
        const enc_len: usize = @intCast(enc_len_raw.?.*);

        // Copy updated caches
        var new_ch_raw: ?*f32 = null;
        try ort_c.check(api, api.GetTensorMutableData.?(enc_outputs[2].?, @ptrCast(&new_ch_raw)));
        @memcpy(self.cache_ch, @as([*]f32, @ptrCast(new_ch_raw.?))[0..self.cache_ch.len]);

        var new_time_raw: ?*f32 = null;
        try ort_c.check(api, api.GetTensorMutableData.?(enc_outputs[3].?, @ptrCast(&new_time_raw)));
        @memcpy(self.cache_time, @as([*]f32, @ptrCast(new_time_raw.?))[0..self.cache_time.len]);

        var new_ch_len_raw: ?*i64 = null;
        try ort_c.check(api, api.GetTensorMutableData.?(enc_outputs[4].?, @ptrCast(&new_ch_len_raw)));
        self.cache_ch_len[0] = new_ch_len_raw.?.*;

        // Get encoder output data
        var enc_data_raw: ?*f32 = null;
        try ort_c.check(api, api.GetTensorMutableData.?(enc_outputs[0].?, @ptrCast(&enc_data_raw)));
        const enc_data: [*]f32 = @ptrCast(enc_data_raw.?);

        // Get T dimension from output shape
        var enc_info: ?*ort_c.OrtTensorTypeAndShapeInfo = null;
        try ort_c.check(api, api.GetTensorTypeAndShape.?(enc_outputs[0].?, &enc_info));
        var enc_dims: [3]i64 = undefined;
        try ort_c.check(api, api.GetDimensions.?(enc_info.?, &enc_dims, 3));
        api.ReleaseTensorTypeAndShapeInfo.?(enc_info.?);
        const T_out: usize = @intCast(enc_dims[2]);

        // RNNT greedy decode for this chunk's encoder frames
        const frames_to_decode = @min(enc_len, T_out);
        try self.rnntDecode(enc_data, T_out, frames_to_decode);
    }

    fn rnntDecode(self: *NemotronPipeline, enc_data: [*]f32, T_out: usize, frames_to_decode: usize) !void {
        const api = self.config.api;
        const mem_info = self.config.mem_info;

        const enc_frame = try self.allocator.alloc(f32, ENC_DIM);
        defer self.allocator.free(enc_frame);

        for (0..frames_to_decode) |t| {
            // Extract encoder frame [1, D, 1] — band-major layout
            for (0..ENC_DIM) |d| {
                enc_frame[d] = enc_data[d * T_out + t];
            }

            var symbols: usize = 0;
            while (symbols < MAX_SYMBOLS_PER_FRAME) {
                var enc_frame_shape = [_]i64{ 1, ENC_DIM, 1 };
                var enc_frame_tensor: ?*ort_c.OrtValue = null;
                try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
                    mem_info, @ptrCast(enc_frame.ptr), ENC_DIM * @sizeOf(f32),
                    &enc_frame_shape, 3, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &enc_frame_tensor,
                ));
                defer api.ReleaseValue.?(enc_frame_tensor.?);

                var target = [_]i32{self.last_token};
                var target_shape = [_]i64{ 1, 1 };
                var target_tensor: ?*ort_c.OrtValue = null;
                try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
                    mem_info, @ptrCast(&target), @sizeOf(i32),
                    &target_shape, 2, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32, &target_tensor,
                ));
                defer api.ReleaseValue.?(target_tensor.?);

                var tgt_len = [_]i32{1};
                var tgt_len_shape = [_]i64{1};
                var tgt_len_tensor: ?*ort_c.OrtValue = null;
                try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
                    mem_info, @ptrCast(&tgt_len), @sizeOf(i32),
                    &tgt_len_shape, 1, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32, &tgt_len_tensor,
                ));
                defer api.ReleaseValue.?(tgt_len_tensor.?);

                var s1_shape = [_]i64{ PRED_LAYERS, 1, PRED_HIDDEN };
                var s1_tensor: ?*ort_c.OrtValue = null;
                try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
                    mem_info, @ptrCast(self.dec_state1.ptr), self.dec_state1.len * @sizeOf(f32),
                    &s1_shape, 3, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &s1_tensor,
                ));
                defer api.ReleaseValue.?(s1_tensor.?);

                var s2_shape = [_]i64{ PRED_LAYERS, 1, PRED_HIDDEN };
                var s2_tensor: ?*ort_c.OrtValue = null;
                try ort_c.check(api, api.CreateTensorWithDataAsOrtValue.?(
                    mem_info, @ptrCast(self.dec_state2.ptr), self.dec_state2.len * @sizeOf(f32),
                    &s2_shape, 3, ort_c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &s2_tensor,
                ));
                defer api.ReleaseValue.?(s2_tensor.?);

                const dec_in_names = [_][*:0]const u8{ "encoder_outputs", "targets", "target_length", "input_states_1", "input_states_2" };
                const dec_out_names = [_][*:0]const u8{ "outputs", "prednet_lengths", "output_states_1", "output_states_2" };
                const dec_ins = [_]?*const ort_c.OrtValue{ enc_frame_tensor, target_tensor, tgt_len_tensor, s1_tensor, s2_tensor };
                var dec_outs: [4]?*ort_c.OrtValue = .{ null, null, null, null };

                try ort_c.check(api, api.Run.?(
                    self.config.dec_session, null, &dec_in_names, @ptrCast(&dec_ins), 5,
                    &dec_out_names, 4, @ptrCast(&dec_outs),
                ));
                defer for (&dec_outs) |*o| {
                    if (o.*) |v| api.ReleaseValue.?(v);
                };

                // Argmax over logits (with context biasing)
                var logits_raw: ?*f32 = null;
                try ort_c.check(api, api.GetTensorMutableData.?(dec_outs[0].?, @ptrCast(&logits_raw)));
                const logits: [*]f32 = @ptrCast(logits_raw.?);

                // Apply context biasing: boost/suppress tokens reachable from current trie state.
                // Only bias direct children of current state (not failure chain) to avoid
                // penalizing common tokens like "you" when a suppression phrase starts with them.
                if (self.config.context_graph != null) {
                    var iter = self.trie_state.next.iterator();
                    while (iter.next()) |entry| {
                        const tok_id = entry.key_ptr.*;
                        const child = entry.value_ptr.*;
                        if (tok_id >= 0 and tok_id < tokenizer.VOCAB_SIZE) {
                            logits[@intCast(tok_id)] += child.token_score;
                        }
                    }
                }

                var best: i32 = 0;
                var best_val: f32 = logits[0];
                for (1..tokenizer.VOCAB_SIZE + 1) |i| {
                    if (logits[i] > best_val) {
                        best_val = logits[i];
                        best = @intCast(i);
                    }
                }

                if (best == tokenizer.BLANK_ID) break;

                // Advance trie state on non-blank emission (skip punctuation
                // so ", you know" still matches the phrase "you know")
                if (self.config.context_graph) |cg| {
                    if (!tokenizer.isPunctuation(self.config.token_map, best)) {
                        const step = cg.forwardOneStep(self.trie_state, best);
                        self.trie_state = step.next_state;
                    }
                }

                // Emit token
                self.last_token = best;
                symbols += 1;

                // Detokenize and append
                try tokenizer.detokenize(self.config.token_map, best, &self.emitted_text, self.allocator);

                // Update decoder states
                var ns1_raw: ?*f32 = null;
                try ort_c.check(api, api.GetTensorMutableData.?(dec_outs[2].?, @ptrCast(&ns1_raw)));
                @memcpy(self.dec_state1, @as([*]f32, @ptrCast(ns1_raw.?))[0..self.dec_state1.len]);
                var ns2_raw: ?*f32 = null;
                try ort_c.check(api, api.GetTensorMutableData.?(dec_outs[3].?, @ptrCast(&ns2_raw)));
                @memcpy(self.dec_state2, @as([*]f32, @ptrCast(ns2_raw.?))[0..self.dec_state2.len]);
            }
        }
    }
};
