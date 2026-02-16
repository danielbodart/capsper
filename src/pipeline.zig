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
    n_vocab: usize,

    // Domain terms pre-tokenized (owned by caller, must outlive Pipeline)
    prompt_tokens: []const c.whisper_token,

    // Accumulated tokens from previous decode cycles within the current VAD segment.
    // Fed as forced prefix (context) in subsequent transcribe() calls for consistency.
    accumulated_tokens: std.ArrayListUnmanaged(c.whisper_token) = .{},

    // Incremental mel spectrogram cache. Persists across transcribe cycles within
    // a VAD segment; reset on segment boundary or 15s buffer trim.
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
            .n_vocab = @intCast(c.whisper_n_vocab(ctx)),
            .prompt_tokens = prompt_tokens,
            .mel_buffer = try mel.MelBuffer.init(allocator, @intCast(c.whisper_model_n_mels(ctx))),
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.mel_buffer.deinit();
        self.accumulated_tokens.deinit(self.allocator);
        c.whisper_free_state(self.state);
    }

    /// Append confirmed tokens to the accumulated context.
    /// Called by the server after emitting words — the confirmed tokens become
    /// forced prefix for subsequent decode cycles, ensuring consistency.
    pub fn commitTokens(self: *Pipeline, tokens: []const c.whisper_token) !void {
        try self.accumulated_tokens.appendSlice(self.allocator, tokens);
    }

    /// Clear accumulated tokens and mel cache (on VAD segment boundary / flush / buffer trim).
    pub fn resetSegment(self: *Pipeline) void {
        self.accumulated_tokens.clearRetainingCapacity();
        self.mel_buffer.reset();
    }

    fn msFromNs(start: i128) f64 {
        const elapsed: i128 = std.time.nanoTimestamp() - start;
        return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
    }

    /// Transcribe audio samples using AlignAtt streaming policy.
    /// Uses accumulated_tokens (from previous commitTokens calls) as forced prefix
    /// for decoder consistency. is_last=true uses a tighter stopping threshold and
    /// skips word truncation.
    pub fn transcribe(
        self: *Pipeline,
        samples: []const f32,
        is_last: bool,
    ) !?TranscribeResult {
        return self.transcribeInternal(samples, is_last, self.accumulated_tokens.items);
    }

    /// Transcribe with explicit context tokens (for testing or direct control).
    pub fn transcribeWithContext(
        self: *Pipeline,
        samples: []const f32,
        is_last: bool,
        context_tokens: []const c.whisper_token,
    ) !?TranscribeResult {
        return self.transcribeInternal(samples, is_last, context_tokens);
    }

    fn transcribeInternal(
        self: *Pipeline,
        samples: []const f32,
        is_last: bool,
        context_tokens: []const c.whisper_token,
    ) !?TranscribeResult {
        const t_total = std.time.nanoTimestamp();
        var timing = Timing{};

        // Fresh state for each transcription
        const t_state = std.time.nanoTimestamp();
        c.whisper_free_state(self.state);
        self.state = c.whisper_init_state(self.ctx) orelse return error.StateInitFailed;
        timing.state_init_ms = msFromNs(t_state);

        // Step 1: Incremental mel spectrogram
        // Only computes new frames since last cycle; caches previous frames.
        const t_mel = std.time.nanoTimestamp();
        _ = try self.mel_buffer.addSamples(samples);

        // Export to whisper.cpp format: [n_mel * 3000] row-major by mel band, padded to 30s
        const n_mel = self.mel_buffer.n_mel;
        const mel_data = try self.allocator.alloc(f32, n_mel * mel.WHISPER_N_FRAMES);
        defer self.allocator.free(mel_data);
        self.mel_buffer.exportForWhisper(mel_data, mel.WHISPER_N_FRAMES);

        if (c.whisper_set_mel_with_state(self.ctx, self.state, mel_data.ptr, @intCast(mel.WHISPER_N_FRAMES), @intCast(n_mel)) != 0) {
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

        // Step 3: Build prompt:
        //   [sot_prev] [domain_terms...] [sot] [lang] [transcribe] [notimestamps] [context_tokens...]
        // domain_terms: go before [sot] in the <|startofprev|> section for conditioning.
        // context_tokens: go AFTER [notimestamps] as forced decoder output — the model
        // processes them as its own previous output, building KV cache state, so
        // autoregressive generation continues from where the previous cycle left off.
        const sot_seq = [_]c.whisper_token{ self.sot, self.lang_en, self.tok_transcribe, self.notimestamps };
        const max_forced: usize = 219; // Token budget for domain + context (448 - 4 sot_seq - 1 startofprev - 224 max_decode)
        const prompt_len = @min(self.prompt_tokens.len, max_forced);
        const max_context = max_forced - prompt_len;
        const ctx_len = @min(context_tokens.len, max_context);
        const has_domain = prompt_len > 0;
        const domain_prefix_len: usize = if (has_domain) 1 + prompt_len else 0; // 1 for startofprev

        const full_prompt = try self.allocator.alloc(c.whisper_token, domain_prefix_len + sot_seq.len + ctx_len);
        defer self.allocator.free(full_prompt);
        var pos: usize = 0;
        if (has_domain) {
            full_prompt[pos] = self.sot_prev;
            pos += 1;
            @memcpy(full_prompt[pos..][0..prompt_len], self.prompt_tokens[0..prompt_len]);
            pos += prompt_len;
        }
        @memcpy(full_prompt[pos..][0..sot_seq.len], &sot_seq);
        pos += sot_seq.len;
        if (ctx_len > 0) {
            @memcpy(full_prompt[pos..][0..ctx_len], context_tokens[context_tokens.len - ctx_len ..]);
        }

        // Decode prompt in two parts: batch the first N-1 tokens, then decode the
        // last token separately. whisper.cpp only populates logits for the last token
        // in a batch, but whisper_get_logits_from_state always reads from offset 0.
        // Decoding the last token alone ensures logits[0..n_vocab] is correct.
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

        // Parallel array: audio frame for each generated token (from cross-attention)
        var token_frames = std.ArrayListUnmanaged(usize){};
        defer token_frames.deinit(self.allocator);

        var n_past: c_int = @intCast(full_prompt.len);
        const max_tokens: usize = 224;
        var last_attend_frame: ?usize = null;
        var was_rewind = false;

        for (0..max_tokens) |step| {
            const logits = c.whisper_get_logits_from_state(self.state);
            if (logits == null) break;

            // Greedy sample
            var best_token: c.whisper_token = 0;
            var best_logit: f32 = -std.math.inf(f32);
            for (0..self.n_vocab) |vi| {
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
            // Placeholder frame — updated below after attention analysis
            try token_frames.append(self.allocator, last_attend_frame orelse 0);

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
            if (attn_data == null) continue;

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

            const decision = alignatt.checkStopping(
                most_attended, content_frames, last_attend_frame, is_last, self.config,
            );
            last_attend_frame = most_attended;

            switch (decision) {
                .stop_attention_at_end => {
                    // Strip the token that triggered the stop
                    if (generated.items.len > 0) {
                        _ = generated.pop();
                        _ = token_frames.pop();
                    }
                    timing.stop_reason = "attn_end";
                    break;
                },
                .rewind_detected => {
                    std.debug.print("    [rewind] at step {d}, frame {d}\n", .{ step, most_attended });
                    was_rewind = true;
                    timing.stop_reason = "rewind";
                    break;
                },
                .continue_decoding => {},
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

        // Step 5: Word boundary truncation (unless is_last)
        var n_tokens_to_use = generated.items.len;
        if (!is_last and n_tokens_to_use > 0) {
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
            const str = c.whisper_token_to_str(self.ctx, token);
            if (str == null) continue;
            const slice = std.mem.span(str);

            if (slice.len > 0 and slice[0] == ' ') {
                // Close previous word if any
                if (word_start) |ws| {
                    if (text_buf.items.len > ws) {
                        try words.append(self.allocator, .{
                            .text_start = ws,
                            .text_end = text_buf.items.len,
                            .frame = word_frame,
                        });
                    }
                }
                // New word starts after the space
                word_start = text_buf.items.len + 1;
                word_frame = frames_to_use[idx];
            } else if (word_start == null) {
                // First token doesn't start with space
                word_start = text_buf.items.len;
                word_frame = frames_to_use[idx];
            }

            try text_buf.appendSlice(self.allocator, slice);
        }

        // Close last word
        if (word_start) |ws| {
            if (text_buf.items.len > ws) {
                try words.append(self.allocator, .{
                    .text_start = ws,
                    .text_end = text_buf.items.len,
                    .frame = word_frame,
                });
            }
        }

        return .{
            .text = try self.allocator.dupe(u8, text_buf.items),
            .words = try self.allocator.dupe(utils.TimedWord, words.items),
            .tokens = try self.allocator.dupe(c.whisper_token, tokens_to_decode),
            .was_rewind = was_rewind,
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
