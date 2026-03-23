/// CoreML Nemotron RNNT streaming ASR pipeline (macOS).
///
/// Same architecture as nemotron_pipeline.zig but calls CoreML via
/// coreml_helpers.m instead of onnxruntime. Mel computation and RNNT
/// greedy decode logic are identical — only the model invocation differs.
const std = @import("std");
const nemo_mel = @import("../../shared/nemo_mel.zig");
const mel_state_mod = @import("../../shared/nemo_mel_state.zig");
const NemoMelState = mel_state_mod.NemoMelState;
const tokenizer = @import("../../shared/tokenizer.zig");
const asr_types = @import("../../shared/asr_types.zig");
const utils = @import("../../shared/utils.zig");
const context_graph_mod = @import("../../shared/context_graph.zig");
const ContextGraph = context_graph_mod.ContextGraph;
const ContextState = context_graph_mod.ContextState;

pub const TranscribeResult = asr_types.TranscribeResult;
pub const Timing = asr_types.Timing;

// Streaming parameters — must match the CoreML model conversion settings
const MEL_SHIFT: usize = 56;
const PRE_ENCODE_CACHE: usize = 9;
const CACHE_CH_DIM: usize = 70;
const CACHE_TIME_DIM: usize = 8;
const ENC_LAYERS: usize = 24;
const ENC_DIM: usize = 1024;
const PRED_HIDDEN: usize = 640;
const PRED_LAYERS: usize = 2;
const MAX_SYMBOLS_PER_FRAME: usize = 10;
const N_MELS = mel_state_mod.N_MELS;

// CoreML C API (from coreml_helpers.m)
pub const CapsperCoreMLModels = opaque {};
extern fn capsper_coreml_run_encoder(
    models: *CapsperCoreMLModels,
    mel_data: [*]const f32,
    out_encoded: [*]f32,
    out_encoded_len: *i32,
) c_int;
extern fn capsper_coreml_run_decoder(
    models: *CapsperCoreMLModels,
    enc_frame: [*]const f32,
    token: i32,
    state_h: [*]const f32,
    state_c: [*]const f32,
    out_logits: [*]f32,
    out_state_h: [*]f32,
    out_state_c: [*]f32,
) c_int;
extern fn capsper_coreml_reset_state(models: *CapsperCoreMLModels) void;

/// Process-lifetime config. CoreML models are shared across connections.
pub const CoreMLConfig = struct {
    models: *CapsperCoreMLModels,
    filterbank: []const f32,
    token_map: *const tokenizer.TokenMap,
    context_graph: ?*const ContextGraph = null,
};

pub const CoreMLPipeline = struct {
    allocator: std.mem.Allocator,
    config: CoreMLConfig,
    verbose: bool,

    // Incremental mel state
    mel: NemoMelState,
    mel_frame_cursor: usize = 0,

    // Pre-encode cache: last PRE_ENCODE_CACHE mel frames from previous chunk
    pre_cache: [N_MELS * PRE_ENCODE_CACHE]f32 = [_]f32{0} ** (N_MELS * PRE_ENCODE_CACHE),

    // RNNT decoder state
    dec_state1: []f32,
    dec_state2: []f32,
    last_token: i32 = tokenizer.BLANK_ID,

    // Accumulated text this segment
    emitted_text: std.ArrayListUnmanaged(u8) = .{},
    emit_cursor: usize = 0,

    // Context biasing trie state
    trie_state: *const ContextState = undefined,

    pub fn init(allocator: std.mem.Allocator, config: CoreMLConfig, verbose: bool) !CoreMLPipeline {
        const dec_state_size = PRED_LAYERS * 1 * PRED_HIDDEN;

        const dec_state1 = try allocator.alloc(f32, dec_state_size);
        errdefer allocator.free(dec_state1);
        @memset(dec_state1, 0);

        const dec_state2 = try allocator.alloc(f32, dec_state_size);
        errdefer allocator.free(dec_state2);
        @memset(dec_state2, 0);

        var pipeline = CoreMLPipeline{
            .allocator = allocator,
            .config = config,
            .verbose = verbose,
            .mel = NemoMelState.init(allocator, config.filterbank),
            .dec_state1 = dec_state1,
            .dec_state2 = dec_state2,
        };
        if (config.context_graph) |cg| {
            pipeline.trie_state = cg.root;
        }
        return pipeline;
    }

    pub fn deinit(self: *CoreMLPipeline) void {
        self.allocator.free(self.dec_state1);
        self.allocator.free(self.dec_state2);
        self.emitted_text.deinit(self.allocator);
        self.mel.deinit();
    }

    pub fn transcribe(self: *CoreMLPipeline, samples: []const f32, flush: bool, _: ?usize) !?TranscribeResult {
        const t_start = std.time.nanoTimestamp();

        try self.mel.feed(samples);
        try self.processEncoderChunks();

        if (flush and self.mel.n_frames > self.mel_frame_cursor) {
            try self.processPartialChunk();
        }

        const elapsed_ns = std.time.nanoTimestamp() - t_start;
        const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

        const full_new = self.emitted_text.items[self.emit_cursor..];
        if (full_new.len == 0) return null;

        const text = try self.allocator.dupe(u8, full_new);
        self.emit_cursor += full_new.len;

        if (self.verbose) {
            const label = if (flush) "flush" else "chunk";
            std.debug.print("  [coreml] {s}({d}): \"{s}\"\n", .{ label, text.len, text });
        }

        return .{
            .text = text,
            .words = try self.allocator.alloc(utils.TimedWord, 0),
            .tokens = try self.allocator.alloc(i32, 0),
            .token_frames = try self.allocator.alloc(usize, 0),
            .was_rewind = false,
            .timing = .{
                .total_ms = elapsed_ms,
                .stop_reason = if (flush) "coreml-flush" else "coreml",
            },
        };
    }

    pub fn resetSegment(self: *CoreMLPipeline) void {
        self.mel.reset();
        self.mel_frame_cursor = 0;
        @memset(&self.pre_cache, 0);
        capsper_coreml_reset_state(self.config.models);
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

    fn processEncoderChunks(self: *CoreMLPipeline) !void {
        while (self.mel.n_frames >= self.mel_frame_cursor + MEL_SHIFT) {
            try self.runEncoderChunk(MEL_SHIFT);
            self.mel_frame_cursor += MEL_SHIFT;
        }
    }

    fn processPartialChunk(self: *CoreMLPipeline) !void {
        const remaining = self.mel.n_frames - self.mel_frame_cursor;
        if (remaining == 0) return;
        try self.runEncoderChunk(remaining);
        self.mel_frame_cursor = self.mel.n_frames;
    }

    fn runEncoderChunk(self: *CoreMLPipeline, chunk_mel_frames: usize) !void {
        // Build chunk: pre_cache (9 frames) + new frames
        const full_chunk_frames = PRE_ENCODE_CACHE + chunk_mel_frames;
        const chunk_data = try self.allocator.alloc(f32, N_MELS * full_chunk_frames);
        defer self.allocator.free(chunk_data);

        // Copy pre_cache into chunk (band-major)
        for (0..N_MELS) |band| {
            for (0..PRE_ENCODE_CACHE) |f| {
                chunk_data[band * full_chunk_frames + f] = self.pre_cache[band * PRE_ENCODE_CACHE + f];
            }
        }

        // Export new mel frames
        const new_frames_buf = try self.allocator.alloc(f32, N_MELS * chunk_mel_frames);
        defer self.allocator.free(new_frames_buf);
        self.mel.exportBandMajor(new_frames_buf, self.mel_frame_cursor, chunk_mel_frames);

        for (0..N_MELS) |band| {
            for (0..chunk_mel_frames) |f| {
                chunk_data[band * full_chunk_frames + PRE_ENCODE_CACHE + f] = new_frames_buf[band * chunk_mel_frames + f];
            }
        }

        // Update pre_cache
        if (chunk_mel_frames >= PRE_ENCODE_CACHE) {
            const start = chunk_mel_frames - PRE_ENCODE_CACHE;
            for (0..N_MELS) |band| {
                for (0..PRE_ENCODE_CACHE) |f| {
                    self.pre_cache[band * PRE_ENCODE_CACHE + f] = new_frames_buf[band * chunk_mel_frames + start + f];
                }
            }
        } else {
            const keep = PRE_ENCODE_CACHE - chunk_mel_frames;
            for (0..N_MELS) |band| {
                for (0..keep) |f| {
                    self.pre_cache[band * PRE_ENCODE_CACHE + f] = self.pre_cache[band * PRE_ENCODE_CACHE + chunk_mel_frames + f];
                }
                for (0..chunk_mel_frames) |f| {
                    self.pre_cache[band * PRE_ENCODE_CACHE + keep + f] = new_frames_buf[band * chunk_mel_frames + f];
                }
            }
        }

        // Pad to 65 frames if partial chunk (CoreML expects fixed [1, 128, 65])
        var mel_input: [N_MELS * (PRE_ENCODE_CACHE + MEL_SHIFT)]f32 = [_]f32{0} ** (N_MELS * (PRE_ENCODE_CACHE + MEL_SHIFT));
        const copy_frames = @min(full_chunk_frames, PRE_ENCODE_CACHE + MEL_SHIFT);
        for (0..N_MELS) |band| {
            for (0..copy_frames) |f| {
                mel_input[band * (PRE_ENCODE_CACHE + MEL_SHIFT) + f] = chunk_data[band * full_chunk_frames + f];
            }
        }

        // Run CoreML encoder
        // Output buffer: [1, ENC_DIM, max_T_out] — 7 frames for 65 input
        var enc_output: [ENC_DIM * 7]f32 = undefined;
        var enc_len: i32 = 0;

        const status = capsper_coreml_run_encoder(
            self.config.models,
            &mel_input,
            &enc_output,
            &enc_len,
        );
        if (status != 0) {
            std.debug.print("capsper_coreml: encoder error\n", .{});
            return;
        }

        const T_out: usize = 7; // Fixed for 65-frame input with 8x subsampling
        const frames_to_decode: usize = @intCast(@min(enc_len, @as(i32, @intCast(T_out))));
        try self.rnntDecode(&enc_output, T_out, frames_to_decode);
    }

    fn rnntDecode(self: *CoreMLPipeline, enc_data: []const f32, T_out: usize, frames_to_decode: usize) !void {
        var enc_frame: [ENC_DIM]f32 = undefined;

        for (0..frames_to_decode) |t| {
            // Extract encoder frame [D] — band-major layout
            for (0..ENC_DIM) |d| {
                enc_frame[d] = enc_data[d * T_out + t];
            }

            var symbols: usize = 0;
            while (symbols < MAX_SYMBOLS_PER_FRAME) {
                var logits: [tokenizer.VOCAB_SIZE + 1]f32 = undefined;
                var new_h: [PRED_LAYERS * PRED_HIDDEN]f32 = undefined;
                var new_c: [PRED_LAYERS * PRED_HIDDEN]f32 = undefined;

                const status = capsper_coreml_run_decoder(
                    self.config.models,
                    &enc_frame,
                    self.last_token,
                    self.dec_state1.ptr,
                    self.dec_state2.ptr,
                    &logits,
                    &new_h,
                    &new_c,
                );
                if (status != 0) {
                    std.debug.print("capsper_coreml: decoder error\n", .{});
                    break;
                }

                // Apply context biasing
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

                // Argmax
                var best: i32 = 0;
                var best_val: f32 = logits[0];
                for (1..tokenizer.VOCAB_SIZE + 1) |i| {
                    if (logits[i] > best_val) {
                        best_val = logits[i];
                        best = @intCast(i);
                    }
                }

                if (best == tokenizer.BLANK_ID) break;

                // Advance trie state
                if (self.config.context_graph) |cg| {
                    if (!tokenizer.isPunctuation(self.config.token_map, best)) {
                        const step = cg.forwardOneStep(self.trie_state, best);
                        self.trie_state = step.next_state;
                    }
                }

                // Emit token
                self.last_token = best;
                symbols += 1;
                try tokenizer.detokenize(self.config.token_map, best, &self.emitted_text, self.allocator);

                // Update decoder states
                @memcpy(self.dec_state1, &new_h);
                @memcpy(self.dec_state2, &new_c);
            }
        }
    }
};
