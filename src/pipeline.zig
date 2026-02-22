const std = @import("std");
const c = @import("whisper_c.zig");
const alignatt = @import("alignatt.zig");
const utils = @import("utils.zig");
const mel = @import("mel.zig");

pub const Timing = struct {
    state_init_ms: f64 = 0,
    mel_ms: f64 = 0,
    encode_ms: f64 = 0,
    prompt_decode_ms: f64 = 0,
    decode_ms: f64 = 0,
    total_ms: f64 = 0,
    tokens_generated: usize = 0,
    stop_reason: []const u8 = "none",
};

pub const TranscribeResult = struct {
    text: []const u8,
    words: []const utils.TimedWord,
    tokens: []const c.whisper_token,
    token_frames: []const usize, // per-token audio frame from cross-attention
    was_rewind: bool,
    timing: Timing,
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    ctx: *c.whisper_context,
    state: *c.whisper_state,
    config: alignatt.Config,
    n_threads: c_int,
    verbose: bool,

    // Special tokens
    sot: c.whisper_token,
    sot_prev: c.whisper_token,
    lang_en: c.whisper_token,
    tok_transcribe: c.whisper_token,
    notimestamps: c.whisper_token,
    eot: c.whisper_token,
    token_beg: usize, // first timestamp token ID — all tokens >= this are timestamps
    n_vocab: usize,

    // Domain terms pre-tokenized (owned by caller, must outlive Pipeline)
    prompt_tokens: []const c.whisper_token,

    // Accumulated tokens from previous decode cycles within the current VAD segment.
    // Fed as forced decoder output AFTER [notimestamps] for consistency.
    accumulated_tokens: std.ArrayListUnmanaged(c.whisper_token) = .{},
    // Per-token audio frame (encoder frame at 50fps) from cross-attention.
    // Parallel to accumulated_tokens — used for exact trim decisions.
    accumulated_frames: std.ArrayListUnmanaged(usize) = .{},

    // Context tokens from audio that has been trimmed from the buffer.
    // Fed as conditioning BEFORE [sot] (in the <|startofprev|> section).
    // The model uses these as a hint but isn't forced to reproduce them.
    context_tokens: std.ArrayListUnmanaged(c.whisper_token) = .{},

    // Cross-cycle rewind detection: last most-attended frame from previous decode.
    // If attention jumps backwards by > rewind_threshold, tokens are discarded.
    // Reset on segment boundary; adjusted on buffer trim.
    last_attend_frame: ?usize = null,

    // Incremental mel spectrogram cache. Persists across transcribe cycles within
    // a VAD segment; reset on segment boundary.
    mel_buffer: mel.MelBuffer,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *c.whisper_context,
        config: alignatt.Config,
        n_threads: c_int,
        verbose: bool,
        prompt_tokens: []const c.whisper_token,
    ) !Pipeline {
        const state = c.whisper_init_state(ctx) orelse return error.StateInitFailed;

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .state = state,
            .config = config,
            .n_threads = n_threads,
            .verbose = verbose,
            .sot = c.whisper_token_sot(ctx),
            .sot_prev = c.whisper_token_prev(ctx),
            .lang_en = c.whisper_token_lang(ctx, c.whisper_lang_id("en")),
            .tok_transcribe = c.whisper_token_transcribe(ctx),
            .notimestamps = c.whisper_token_not(ctx),
            .eot = c.whisper_token_eot(ctx),
            .token_beg = @intCast(c.whisper_token_beg(ctx)),
            .n_vocab = @intCast(c.whisper_n_vocab(ctx)),
            .prompt_tokens = prompt_tokens,
            .mel_buffer = try mel.MelBuffer.init(allocator, @intCast(c.whisper_model_n_mels(ctx))),
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.mel_buffer.deinit();
        self.accumulated_tokens.deinit(self.allocator);
        self.accumulated_frames.deinit(self.allocator);
        self.context_tokens.deinit(self.allocator);
        c.whisper_free_state(self.state);
    }

    /// Append confirmed tokens to the accumulated context.
    /// Called by the server after emitting words — the confirmed tokens become
    /// forced prefix for subsequent decode cycles, ensuring consistency.
    pub fn commitTokens(self: *Pipeline, tokens: []const c.whisper_token, frames: []const usize) !void {
        try self.accumulated_tokens.appendSlice(self.allocator, tokens);
        try self.accumulated_frames.appendSlice(self.allocator, frames);
    }

    /// Clear all segment state: accumulated tokens, context tokens, mel cache, rewind cursor.
    pub fn resetSegment(self: *Pipeline) void {
        self.accumulated_tokens.clearRetainingCapacity();
        self.accumulated_frames.clearRetainingCapacity();
        self.context_tokens.clearRetainingCapacity();
        self.last_attend_frame = null;
        self.mel_buffer.reset();
    }

    /// Handle audio trimmed from the front of the buffer: invalidate mel cache,
    /// adjust last_attend_frame, and demote tokens whose audio was trimmed from
    /// forced (after [notimestamps]) to conditioning (before [sot]).
    pub fn handleTrim(self: *Pipeline, trimmed_bytes: usize) !void {
        if (trimmed_bytes == 0) return;

        // Mel cache is relative to buffer start — invalidate after front trim.
        self.mel_buffer.reset();

        // Convert trimmed bytes to encoder frame count (50fps = 320 samples/frame * 2 bytes/sample = 640 bytes/frame)
        const trim_frame = trimmed_bytes / 640;

        // Shift last_attend_frame so it stays relative to the new buffer start
        if (self.last_attend_frame) |laf| {
            self.last_attend_frame = laf -| trim_frame;
        }

        const n = self.accumulated_tokens.items.len;
        if (n == 0) return;

        // Find split point: first token whose frame >= trim_frame
        var drop: usize = 0;
        for (self.accumulated_frames.items[0..n]) |frame| {
            if (frame >= trim_frame) break;
            drop += 1;
        }
        // Always demote at least 1 token when audio was trimmed, to avoid
        // tokens referencing trimmed-away audio when frame data is imprecise.
        if (drop == 0) drop = 1;

        // Demote front tokens to context (conditioning before [sot])
        try self.context_tokens.appendSlice(self.allocator, self.accumulated_tokens.items[0..drop]);

        // Shift remaining tokens and frames to front
        const remaining = n - drop;
        std.mem.copyForwards(
            c.whisper_token,
            self.accumulated_tokens.items[0..remaining],
            self.accumulated_tokens.items[drop..n],
        );
        self.accumulated_tokens.items.len = remaining;

        // Adjust frame offsets: subtract trim_frame so they're relative to new buffer start
        for (self.accumulated_frames.items[drop..n], 0..) |frame, i| {
            self.accumulated_frames.items[i] = frame -| trim_frame;
        }
        self.accumulated_frames.items.len = remaining;
    }

    fn msFromNs(start: i128) f64 {
        const elapsed: i128 = std.time.nanoTimestamp() - start;
        return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
    }

    /// Transcribe audio samples using AlignAtt streaming policy.
    /// Uses accumulated_tokens as forced prefix for decoder consistency.
    /// When flush=true, uses a tighter stopping threshold, skips word
    /// truncation, and resets all segment state before returning.
    pub fn transcribe(
        self: *Pipeline,
        samples: []const f32,
        flush: bool,
        flush_budget: ?usize,
    ) !?TranscribeResult {
        const result = try self.transcribeInternal(samples, flush, self.accumulated_tokens.items, flush_budget);
        if (flush) self.resetSegment();
        return result;
    }

    fn transcribeInternal(
        self: *Pipeline,
        samples: []const f32,
        flush: bool,
        forced_tokens: []const c.whisper_token,
        flush_budget: ?usize,
    ) !?TranscribeResult {
        const t_total = std.time.nanoTimestamp();
        var timing = Timing{};

        // Fresh state for each transcription
        const t_state = std.time.nanoTimestamp();
        c.whisper_free_state(self.state);
        self.state = c.whisper_init_state(self.ctx) orelse return error.StateInitFailed;
        timing.state_init_ms = msFromNs(t_state);

        // Step 1: Incremental mel spectrogram
        const t_mel = std.time.nanoTimestamp();
        _ = try self.mel_buffer.addSamples(samples);
        const mel_data = self.mel_buffer.exportForWhisper();

        if (c.whisper_set_mel_with_state(self.ctx, self.state, mel_data.ptr, @intCast(mel.WHISPER_N_FRAMES), @intCast(self.mel_buffer.n_mel)) != 0) {
            return error.MelFailed;
        }
        timing.mel_ms = msFromNs(t_mel);

        // Content frames from actual audio (not padding) in encoder output space (50 frames/second)
        const content_frames: usize = samples.len / 320;

        // Step 2: Encode
        const t_encode = std.time.nanoTimestamp();
        if (c.whisper_encode_with_state(self.ctx, self.state, 0, self.n_threads) != 0) {
            return error.EncodeFailed;
        }
        timing.encode_ms = msFromNs(t_encode);

        // Step 3: Build prompt — two-tier token system:
        //   [sot_prev] [domain_terms...] [context_tokens...] [sot] [lang] [transcribe] [notimestamps] [forced_tokens...]
        //
        // Before [sot] (<|startofprev|> section) = conditioning:
        //   - domain_terms: fixed vocabulary hints (protected from trimming)
        //   - context_tokens: tokens from audio that was trimmed from the buffer;
        //     the model uses these as a hint but isn't forced to reproduce them
        //
        // After [notimestamps] = forced decoder output:
        //   - forced_tokens: tokens corresponding to audio still in the buffer
        const sot_seq = [_]c.whisper_token{ self.sot, self.lang_en, self.tok_transcribe, self.notimestamps };
        const max_decode: usize = 224;
        const total_budget: usize = 448 - sot_seq.len - max_decode;

        // Allocate budget: domain terms first (protected), then context, then forced
        const domain_len = @min(self.prompt_tokens.len, total_budget);
        const context_budget = total_budget - domain_len;
        const ctx_len = @min(self.context_tokens.items.len, context_budget);
        const forced_budget = context_budget - ctx_len;
        const forced_len = @min(forced_tokens.len, forced_budget);

        // Need [sot_prev] prefix if we have any conditioning tokens (domain or context)
        const has_conditioning = domain_len > 0 or ctx_len > 0;
        const prefix_len: usize = if (has_conditioning) 1 + domain_len + ctx_len else 0;

        const full_prompt = try self.allocator.alloc(c.whisper_token, prefix_len + sot_seq.len + forced_len);
        defer self.allocator.free(full_prompt);
        var pos: usize = 0;
        if (has_conditioning) {
            full_prompt[pos] = self.sot_prev;
            pos += 1;
            if (domain_len > 0) {
                @memcpy(full_prompt[pos..][0..domain_len], self.prompt_tokens[0..domain_len]);
                pos += domain_len;
            }
            if (ctx_len > 0) {
                // Use most recent context tokens (trim from front when budget exceeded)
                @memcpy(full_prompt[pos..][0..ctx_len], self.context_tokens.items[self.context_tokens.items.len - ctx_len ..]);
                pos += ctx_len;
            }
        }
        @memcpy(full_prompt[pos..][0..sot_seq.len], &sot_seq);
        pos += sot_seq.len;
        if (forced_len > 0) {
            @memcpy(full_prompt[pos..][0..forced_len], forced_tokens[forced_tokens.len - forced_len ..]);
        }

        // Decode prompt in two parts: batch the first N-1 tokens, then decode the
        // last token separately. whisper.cpp only populates logits for the last token
        // in a batch, but whisper_get_logits_from_state always reads from offset 0.
        const t_prompt = std.time.nanoTimestamp();
        if (full_prompt.len > 1) {
            if (c.whisper_decode_with_state_and_aheads(
                self.ctx, self.state, full_prompt.ptr, @intCast(full_prompt.len - 1), 0, self.n_threads,
            ) != 0) {
                return error.PromptDecodeFailed;
            }
        }
        var last_prompt = [_]c.whisper_token{full_prompt[full_prompt.len - 1]};
        if (c.whisper_decode_with_state_and_aheads(
            self.ctx, self.state, &last_prompt, 1, @intCast(full_prompt.len - 1), self.n_threads,
        ) != 0) {
            return error.PromptDecodeFailed;
        }
        timing.prompt_decode_ms = msFromNs(t_prompt);

        // Step 4: Autoregressive decode loop with AlignAtt
        const t_decode = std.time.nanoTimestamp();
        var generated = std.ArrayListUnmanaged(c.whisper_token){};
        defer generated.deinit(self.allocator);

        var token_frames = std.ArrayListUnmanaged(usize){};
        defer token_frames.deinit(self.allocator);

        var n_past: c_int = @intCast(full_prompt.len);
        const max_tokens: usize = if (flush) (flush_budget orelse 224) else 224;

        for (0..max_tokens) |_| {
            const logits = c.whisper_get_logits_from_state(self.state);
            if (logits == null) break;

            // Suppress timestamp token logits
            for (self.token_beg..self.n_vocab) |vi| {
                logits[vi] = -std.math.inf(f32);
            }

            // Greedy sample
            var best_token: c.whisper_token = 0;
            var best_logit: f32 = -std.math.inf(f32);
            for (0..self.token_beg) |vi| {
                if (logits[vi] > best_logit) {
                    best_logit = logits[vi];
                    best_token = @intCast(vi);
                }
            }

            if (best_token == self.eot) {
                timing.stop_reason = "eot";
                break;
            }

            // Skip initial blank/punctuation-only tokens
            if (generated.items.len == 0) {
                const str = c.whisper_token_to_str(self.ctx, best_token);
                if (str != null) {
                    const slice = std.mem.span(str);
                    if (utils.isBlankOrPunct(slice)) {
                        var skip = [_]c.whisper_token{best_token};
                        if (c.whisper_decode_with_state_and_aheads(
                            self.ctx, self.state, &skip, 1, n_past, self.n_threads,
                        ) != 0) break;
                        n_past += 1;
                        continue;
                    }
                }
            }

            try generated.append(self.allocator, best_token);
            try token_frames.append(self.allocator, 0); // placeholder — updated after attention

            // Decode this token
            var next = [_]c.whisper_token{best_token};
            if (c.whisper_decode_with_state_and_aheads(
                self.ctx, self.state, &next, 1, n_past, self.n_threads,
            ) != 0) break;
            n_past += 1;

            // Analyze attention
            var n_tok: c_int = 0;
            var n_actx: c_int = 0;
            var n_hd: c_int = 0;
            const attn_data = c.whisper_state_get_aheads_cross_qks(
                self.state, &n_tok, &n_actx, &n_hd,
            );
            if (attn_data == null) {
                _ = generated.pop();
                _ = token_frames.pop();
                timing.stop_reason = "no_attn";
                break;
            }

            const attention = try alignatt.analyzeAttention(
                self.allocator, attn_data,
                @intCast(n_tok), @intCast(n_actx), @intCast(n_hd),
                self.config,
            );
            defer self.allocator.free(attention);

            const frame_limit = @min(content_frames, attention.len);
            const most_attended = alignatt.argmax(attention[0..frame_limit]);

            // Update the frame for this token
            token_frames.items[token_frames.items.len - 1] = most_attended;

            // AlignAtt stopping check with cross-cycle rewind detection
            const decision = alignatt.checkStopping(
                most_attended, content_frames,
                self.last_attend_frame,
                flush, self.config,
            );

            switch (decision) {
                .stop_attention_at_end => {
                    if (generated.items.len > 0) {
                        _ = generated.pop();
                        _ = token_frames.pop();
                    }
                    self.last_attend_frame = most_attended;
                    timing.stop_reason = "attn_end";
                    break;
                },
                .rewind_detected => {
                    generated.clearRetainingCapacity();
                    token_frames.clearRetainingCapacity();
                    self.last_attend_frame = null;
                    timing.stop_reason = "rewind";
                    break;
                },
                .continue_decoding => {
                    self.last_attend_frame = most_attended;
                },
            }
        }

        timing.decode_ms = msFromNs(t_decode);
        timing.tokens_generated = generated.items.len;
        timing.total_ms = msFromNs(t_total);

        if (generated.items.len == 0) {
            timing.stop_reason = if (std.mem.eql(u8, timing.stop_reason, "none")) "empty" else timing.stop_reason;
            if (self.verbose) {
                std.debug.print("    [pipeline] null result ({s}) | state={d:.0}ms mel={d:.0}ms enc={d:.0}ms dec={d:.0}ms total={d:.0}ms\n", .{
                    timing.stop_reason, timing.state_init_ms, timing.mel_ms, timing.encode_ms, timing.decode_ms, timing.total_ms,
                });
            }
            return null;
        }

        // Step 5: Word boundary truncation (unless flush)
        // Skip truncation when there's a forced prefix — the prefix already anchors
        // prior words, and truncation of short continuations causes emission deadlocks.
        var n_tokens_to_use = generated.items.len;
        if (!flush and n_tokens_to_use > 0 and forced_tokens.len == 0) {
            n_tokens_to_use = truncateLastWord(self.ctx, generated.items);
        }
        if (n_tokens_to_use == 0) return null;

        const tokens_to_decode = generated.items[0..n_tokens_to_use];
        const frames_to_use = token_frames.items[0..n_tokens_to_use];

        // Step 6: Decode tokens to text and build TimedWord array
        var text_buf = std.ArrayListUnmanaged(u8){};
        defer text_buf.deinit(self.allocator);

        var words = std.ArrayListUnmanaged(utils.TimedWord){};
        defer words.deinit(self.allocator);

        var word_start: ?usize = null;
        var word_frame: usize = 0;

        for (tokens_to_decode, 0..) |token, idx| {
            if (@as(usize, @intCast(token)) >= self.token_beg) continue;

            const str = c.whisper_token_to_str(self.ctx, token);
            if (str == null) continue;
            const slice = std.mem.span(str);

            if (slice.len > 0 and slice[0] == ' ') {
                if (word_start) |ws| {
                    if (text_buf.items.len > ws) {
                        try words.append(self.allocator, .{
                            .text_start = ws,
                            .text_end = text_buf.items.len,
                            .frame = word_frame,
                        });
                    }
                }
                word_start = text_buf.items.len + 1;
                word_frame = frames_to_use[idx];
            } else if (word_start == null) {
                word_start = text_buf.items.len;
                word_frame = frames_to_use[idx];
            }

            try text_buf.appendSlice(self.allocator, slice);
        }

        if (word_start) |ws| {
            if (text_buf.items.len > ws) {
                try words.append(self.allocator, .{
                    .text_start = ws,
                    .text_end = text_buf.items.len,
                    .frame = word_frame,
                });
            }
        }

        if (flush) self.resetSegment();

        return .{
            .text = try self.allocator.dupe(u8, text_buf.items),
            .words = try self.allocator.dupe(utils.TimedWord, words.items),
            .tokens = try self.allocator.dupe(c.whisper_token, tokens_to_decode),
            .token_frames = try self.allocator.dupe(usize, frames_to_use),
            .was_rewind = false,
            .timing = timing,
        };
    }
};

/// Count tokens up to the last complete word boundary.
/// Returns the number of tokens to keep (0 if no complete word found).
fn truncateLastWord(ctx: *c.whisper_context, tokens: []const c.whisper_token) usize {
    if (tokens.len <= 1) return 0;

    var last_word_start: ?usize = null;
    for (0..tokens.len) |i| {
        const str = c.whisper_token_to_str(ctx, tokens[i]);
        if (str != null) {
            const slice = std.mem.span(str);
            if (slice.len > 0 and slice[0] == ' ') {
                last_word_start = i;
            }
        }
    }

    if (last_word_start) |start| {
        if (start == 0) return 0;
        return start;
    }
    return 0;
}
