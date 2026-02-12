const std = @import("std");
const c = @import("whisper_c.zig");
const alignatt = @import("alignatt.zig");
const utils = @import("utils.zig");

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
    was_rewind: bool,
    timing: Timing,
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    ctx: *c.whisper_context,
    state: *c.whisper_state,
    config: alignatt.Config,
    n_threads: c_int,

    // Special tokens
    sot: c.whisper_token,
    lang_en: c.whisper_token,
    tok_transcribe: c.whisper_token,
    notimestamps: c.whisper_token,
    eot: c.whisper_token,
    n_vocab: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *c.whisper_context,
        config: alignatt.Config,
        n_threads: c_int,
    ) !Pipeline {
        const state = c.whisper_init_state(ctx) orelse return error.StateInitFailed;

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .state = state,
            .config = config,
            .n_threads = n_threads,
            .sot = c.whisper_token_sot(ctx),
            .lang_en = c.whisper_token_lang(ctx, c.whisper_lang_id("en")),
            .tok_transcribe = c.whisper_token_transcribe(ctx),
            .notimestamps = c.whisper_token_not(ctx),
            .eot = c.whisper_token_eot(ctx),
            .n_vocab = @intCast(c.whisper_n_vocab(ctx)),
        };
    }

    pub fn deinit(self: *Pipeline) void {
        c.whisper_free_state(self.state);
    }

    fn msFromNs(start: i128) f64 {
        const elapsed: i128 = std.time.nanoTimestamp() - start;
        return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
    }

    /// Transcribe audio samples using AlignAtt streaming policy.
    /// Each call is a fresh decode — no state persists between calls.
    /// is_last=true uses a tighter stopping threshold and skips word truncation.
    pub fn transcribe(
        self: *Pipeline,
        samples: []const f32,
        is_last: bool,
    ) !?TranscribeResult {
        const t_total = std.time.nanoTimestamp();
        var timing = Timing{};

        // Fresh state for each transcription
        const t_state = std.time.nanoTimestamp();
        c.whisper_free_state(self.state);
        self.state = c.whisper_init_state(self.ctx) orelse return error.StateInitFailed;
        timing.state_init_ms = msFromNs(t_state);

        // Whisper expects 30-second (480000 sample) input. Short audio gets
        // immediate EOT from the decoder because the encoder output is too short.
        // Pad with silence (zeros) like whisper_full does internally.
        const whisper_n_samples: usize = 480000; // 30 seconds at 16kHz
        const padded = if (samples.len < whisper_n_samples) blk: {
            const buf = try self.allocator.alloc(f32, whisper_n_samples);
            @memcpy(buf[0..samples.len], samples);
            @memset(buf[samples.len..], 0);
            break :blk buf;
        } else null;
        defer if (padded) |p| self.allocator.free(p);

        const mel_samples = padded orelse samples;

        // Step 1: Mel spectrogram
        const t_mel = std.time.nanoTimestamp();
        if (c.whisper_pcm_to_mel_with_state(self.ctx, self.state, mel_samples.ptr, @intCast(mel_samples.len), self.n_threads) != 0) {
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

        // Step 3: Build prompt: [sot] [lang_en] [transcribe] [notimestamps]
        var prompt = [_]c.whisper_token{ self.sot, self.lang_en, self.tok_transcribe, self.notimestamps };

        // Decode prompt in two parts: batch the first N-1 tokens, then decode the
        // last token separately. whisper.cpp only populates logits for the last token
        // in a batch, but whisper_get_logits_from_state always reads from offset 0.
        // Decoding the last token alone ensures logits[0..n_vocab] is correct.
        const t_prompt = std.time.nanoTimestamp();
        if (c.whisper_decode_with_state_and_aheads(
            self.ctx, self.state, &prompt, @intCast(prompt.len - 1), 0, self.n_threads,
        ) != 0) {
            return error.PromptDecodeFailed;
        }
        var last_prompt = [_]c.whisper_token{prompt[prompt.len - 1]};
        if (c.whisper_decode_with_state_and_aheads(
            self.ctx, self.state, &last_prompt, 1, @intCast(prompt.len - 1), self.n_threads,
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

        var n_past: c_int = @intCast(prompt.len);
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
            std.debug.print("    [pipeline] null result ({s}) | state={d:.0}ms mel={d:.0}ms enc={d:.0}ms dec={d:.0}ms total={d:.0}ms\n", .{
                timing.stop_reason, timing.state_init_ms, timing.mel_ms, timing.encode_ms, timing.decode_ms, timing.total_ms,
            });
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
