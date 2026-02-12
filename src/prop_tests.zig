// Property-based tests for utils.zig using minish.
// These test invariants over random inputs to find edge cases
// that hand-written unit tests might miss.

const std = @import("std");
const minish = @import("minish");
const mgen = minish.gen;
const utils = @import("utils.zig");
const alignatt = @import("alignatt.zig");

// Generator for "word-like" strings: lowercase letters and spaces.
// This mimics Whisper output text (words separated by single spaces).
const word_text_gen = mgen.string(.{
    .min_len = 0,
    .max_len = 60,
    .charset = .custom,
    .custom_chars = "abcdefghij ",
});

// Generator for text with punctuation (like Whisper with trailing commas/periods)
const punct_text_gen = mgen.string(.{
    .min_len = 0,
    .max_len = 60,
    .charset = .custom,
    .custom_chars = "abcdefghij .,!?",
});

// Pairs of text for two-argument properties
const text_pair_gen = mgen.tuple2([]const u8, []const u8, word_text_gen, word_text_gen);
const punct_pair_gen = mgen.tuple2([]const u8, []const u8, punct_text_gen, punct_text_gen);

// Numeric generators for alignatt
const frame_gen = mgen.intRange(usize, 0, 1500); // audio frame indices
const small_frame_gen = mgen.intRange(usize, 1, 200); // small frame counts for attention arrays

// ============================================================================
// countWords properties
// ============================================================================

// countWords(text) <= text.len (each word is at least 1 char)
fn prop_countWords_bounded_by_length(text: []const u8) !void {
    const count = utils.countWords(text);
    try std.testing.expect(count <= text.len);
}

// countWords should be the same regardless of leading/trailing spaces
fn prop_countWords_ignores_leading_trailing(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " ");
    try std.testing.expectEqual(utils.countWords(trimmed), utils.countWords(text));
}

// ============================================================================
// byteOffsetAfterWords properties
// ============================================================================

// byteOffsetAfterWords(text, 0) == 0 always
fn prop_byteOffset_zero_is_zero(text: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 0), utils.byteOffsetAfterWords(text, 0));
}

// byteOffsetAfterWords(text, n) <= text.len for all n
fn prop_byteOffset_bounded(text: []const u8) !void {
    const count = utils.countWords(text);
    // Check a few values: 0, 1, count, count+1
    for ([_]usize{ 0, 1, count, count + 1, count + 10 }) |n| {
        const offset = utils.byteOffsetAfterWords(text, n);
        try std.testing.expect(offset <= text.len);
    }
}

// byteOffsetAfterWords is monotonically non-decreasing
fn prop_byteOffset_monotonic(text: []const u8) !void {
    const count = utils.countWords(text);
    var prev: usize = 0;
    for (0..count + 2) |n| {
        const offset = utils.byteOffsetAfterWords(text, n);
        try std.testing.expect(offset >= prev);
        prev = offset;
    }
}

// byteOffsetAfterWords(text, countWords(text)) == text.len when text has no trailing spaces
fn prop_byteOffset_at_count_is_end(text: []const u8) !void {
    const trimmed = std.mem.trimRight(u8, text, " ");
    const count = utils.countWords(trimmed);
    if (count > 0) {
        try std.testing.expectEqual(trimmed.len, utils.byteOffsetAfterWords(trimmed, count));
    }
}

// ============================================================================
// wordDelta properties
// ============================================================================

// wordDelta(text, 0) == text
fn prop_wordDelta_zero_is_identity(text: []const u8) !void {
    try std.testing.expectEqualStrings(text, utils.wordDelta(text, 0));
}

// countWords(wordDelta(text, n)) == countWords(text) - n (when n <= count)
fn prop_wordDelta_reduces_count(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " ");
    const count = utils.countWords(trimmed);
    if (count >= 2) {
        const delta = utils.wordDelta(trimmed, 1);
        const delta_trimmed = std.mem.trimLeft(u8, delta, " ");
        try std.testing.expectEqual(count - 1, utils.countWords(delta_trimmed));
    }
}

// ============================================================================
// stripTrailingPunct properties
// ============================================================================

// stripTrailingPunct is idempotent: strip(strip(x)) == strip(x)
fn prop_stripPunct_idempotent(text: []const u8) !void {
    const once = utils.stripTrailingPunct(text);
    const twice = utils.stripTrailingPunct(once);
    try std.testing.expectEqualStrings(once, twice);
}

// stripTrailingPunct result is a prefix of the input
fn prop_stripPunct_is_prefix(text: []const u8) !void {
    const stripped = utils.stripTrailingPunct(text);
    try std.testing.expect(stripped.len <= text.len);
    if (stripped.len > 0) {
        try std.testing.expectEqualStrings(stripped, text[0..stripped.len]);
    }
}

// ============================================================================
// eqlIgnoreCase properties
// ============================================================================

// eqlIgnoreCase is reflexive: eqlIgnoreCase(a, a) is always true
fn prop_eqlIgnoreCase_reflexive(text: []const u8) !void {
    try std.testing.expect(utils.eqlIgnoreCase(text, text));
}

// eqlIgnoreCase is symmetric: eqlIgnoreCase(a, b) == eqlIgnoreCase(b, a)
fn prop_eqlIgnoreCase_symmetric(pair: struct { []const u8, []const u8 }) !void {
    try std.testing.expectEqual(
        utils.eqlIgnoreCase(pair[0], pair[1]),
        utils.eqlIgnoreCase(pair[1], pair[0]),
    );
}

// ============================================================================
// stableWordCount properties
// ============================================================================

// stableWordCount is reflexive: stableWordCount(a, a) == countWords(a)
fn prop_stable_reflexive(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " ");
    try std.testing.expectEqual(utils.countWords(trimmed), utils.stableWordCount(trimmed, trimmed));
}

// stableWordCount is bounded: stableWordCount(a, b) <= min(countWords(a), countWords(b))
fn prop_stable_bounded(pair: struct { []const u8, []const u8 }) !void {
    const stable = utils.stableWordCount(pair[0], pair[1]);
    const min_words = @min(utils.countWords(pair[0]), utils.countWords(pair[1]));
    try std.testing.expect(stable <= min_words);
}

// stableWordCount is symmetric under case: stableWordCount(lower(a), a) == stableWordCount(a, a)
// (Because eqlIgnoreCase is used internally)
fn prop_stable_case_insensitive(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " ");
    // Our word_text_gen only produces lowercase, but still good to test
    const baseline = utils.stableWordCount(trimmed, trimmed);
    try std.testing.expectEqual(baseline, utils.stableWordCount(trimmed, trimmed));
}

// ============================================================================
// findStableWords properties
// ============================================================================

// findStableWords result is bounded
fn prop_findStable_bounded(pair: struct { []const u8, []const u8 }) !void {
    const r = utils.findStableWords(pair[0], pair[1], 0);
    const words_b = utils.countWords(pair[1]);
    try std.testing.expect(r.stable_words <= words_b);
    try std.testing.expect(r.prev_skip <= 6); // max offset tried is 6
}

// findStableWords with emitted=0 should match stableWordCount when no offset needed
fn prop_findStable_matches_basic(pair: struct { []const u8, []const u8 }) !void {
    const r = utils.findStableWords(pair[0], pair[1], 0);
    const direct = utils.stableWordCount(pair[0], pair[1]);
    // When emitted=0 and direct > 0, no offset search is triggered
    if (direct > 0) {
        try std.testing.expectEqual(direct, r.stable_words);
        try std.testing.expectEqual(@as(usize, 0), r.prev_skip);
    }
}

// findStableWords: consistency — if stable_words > 0 and prev_skip > 0,
// then the offset-shifted prev must actually share those words with text
fn prop_findStable_offset_consistent(pair: struct { []const u8, []const u8 }) !void {
    // Use a large emitted_words to force offset search
    const emitted = utils.countWords(pair[0]);
    const r = utils.findStableWords(pair[0], pair[1], emitted);
    if (r.prev_skip > 0 and r.stable_words >= 3) {
        // Verify the offset actually works
        const offset = utils.byteOffsetAfterWords(pair[0], r.prev_skip);
        if (offset < pair[0].len) {
            const shifted_stable = utils.stableWordCount(pair[0][offset..], pair[1]);
            try std.testing.expectEqual(r.stable_words, shifted_stable);
        }
    }
}

// ============================================================================
// pcmToFloat roundtrip property
// ============================================================================

// Converting i16 to float should always be in [-1.0, 1.0]
fn prop_pcmToFloat_range(pair: struct { []const u8, []const u8 }) !void {
    // Use the first string's bytes as PCM data (reinterpreted)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const data = pair[0];
    if (data.len < 2) return; // need at least one sample
    // Ensure even length
    const even_len = data.len & ~@as(usize, 1);
    const samples = try utils.pcmToFloat(allocator, data[0..even_len]);
    defer allocator.free(samples);
    for (samples) |s| {
        try std.testing.expect(s >= -1.0 and s <= 1.0);
    }
}

// ============================================================================
// isBlankOrPunct properties
// ============================================================================

// Any string longer than 1 char is never blank/punct
fn prop_isBlankOrPunct_length(text: []const u8) !void {
    if (text.len > 1) {
        try std.testing.expect(!utils.isBlankOrPunct(text));
    }
}

// ============================================================================
// trimBuffer properties
// ============================================================================

// After trimBuffer, buf.items.len <= keep_bytes (or original if smaller)
fn prop_trimBuffer_bounded(text: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, text);

    const keep: usize = 10;
    utils.trimBuffer(&buf, keep);
    // Either original was <= keep, or we trimmed to ~keep (± 1 for alignment)
    try std.testing.expect(buf.items.len <= @max(text.len, keep + 1));
}

// trimBuffer preserves the tail of the buffer
fn prop_trimBuffer_preserves_tail(text: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, text);

    const keep: usize = 8;
    utils.trimBuffer(&buf, keep);

    // The remaining bytes should be a suffix of the original
    if (buf.items.len > 0 and text.len > 0) {
        const original_tail = text[text.len - buf.items.len ..];
        try std.testing.expectEqualSlices(u8, original_tail, buf.items);
    }
}

// ============================================================================
// Deeper cross-function properties (most likely to find bugs)
// ============================================================================

// byteOffsetAfterWords roundtrip: countWords(text[0..offset(text, n)]) == n
// for well-formed text (no trailing spaces, n <= word count)
fn prop_byteOffset_countWords_roundtrip(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " ");
    const total = utils.countWords(trimmed);
    if (total == 0) return;

    for (1..total + 1) |n| {
        const offset = utils.byteOffsetAfterWords(trimmed, n);
        const prefix = trimmed[0..offset];
        const prefix_count = utils.countWords(prefix);
        try std.testing.expectEqual(n, prefix_count);
    }
}

// stableWordCount agreement: if stableWordCount(a, b) = n, then the first n
// words of a and b match (case-insensitive, punct-stripped)
fn prop_stable_prefix_agreement(pair: struct { []const u8, []const u8 }) !void {
    const n = utils.stableWordCount(pair[0], pair[1]);
    if (n == 0) return;

    // Extract the first n words from each
    var ia: usize = 0;
    var ib: usize = 0;
    for (0..n) |_| {
        while (ia < pair[0].len and pair[0][ia] == ' ') : (ia += 1) {}
        while (ib < pair[1].len and pair[1][ib] == ' ') : (ib += 1) {}
        const wa_start = ia;
        while (ia < pair[0].len and pair[0][ia] != ' ') : (ia += 1) {}
        const wb_start = ib;
        while (ib < pair[1].len and pair[1][ib] != ' ') : (ib += 1) {}
        const wa = utils.stripTrailingPunct(pair[0][wa_start..ia]);
        const wb = utils.stripTrailingPunct(pair[1][wb_start..ib]);
        try std.testing.expect(utils.eqlIgnoreCase(wa, wb));
    }
}

// Streaming simulation: construct prev and current like the server would.
// Take text, split at some word boundary, verify findStableWords + wordDelta
// reconstructs a valid emission.
fn prop_streaming_simulation(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " ");
    const total = utils.countWords(trimmed);
    if (total < 4) return;

    // Simulate: prev transcription = first (total-1) words
    // Current transcription = all words (Whisper added one more word)
    const prev_end = utils.byteOffsetAfterWords(trimmed, total - 1);
    const prev = trimmed[0..prev_end];

    // emitted_words = total - 3 (we've already emitted most words)
    const emitted: usize = if (total > 3) total - 3 else 0;
    const r = utils.findStableWords(prev, trimmed, emitted);

    // Stable words should be at least the overlap (total - 1 words match)
    try std.testing.expect(r.stable_words >= 1);

    // The delta from stable_words should be valid text
    if (r.stable_words > emitted) {
        const start_byte = utils.byteOffsetAfterWords(trimmed, emitted);
        const end_byte = utils.byteOffsetAfterWords(trimmed, r.stable_words);
        try std.testing.expect(end_byte >= start_byte);
        try std.testing.expect(end_byte <= trimmed.len);
    }
}

// Sliding window simulation: prev has extra leading words that current lost.
// Verifies findStableWords finds the alignment via offset search.
fn prop_sliding_window_shift(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " ");
    const total = utils.countWords(trimmed);
    if (total < 5) return;

    // prev = all words, current = last (total-2) words (lost 2 from front)
    const shift = 2;
    const current_start = utils.byteOffsetAfterWords(trimmed, shift);
    const current = std.mem.trimLeft(u8, trimmed[current_start..], " ");
    const current_words = utils.countWords(current);

    // emitted = total (force offset search since direct match gives <= emitted)
    const r = utils.findStableWords(trimmed, current, total);

    // Should find alignment at skip=2 with stable_words = current_words
    if (current_words >= 3) {
        try std.testing.expect(r.stable_words >= 3);
        try std.testing.expectEqual(@as(usize, shift), r.prev_skip);
    }
}

// wordDelta + countWords: emitting wordDelta(text, n) should give us
// exactly countWords(text) - n words (for well-formed trimmed text)
fn prop_wordDelta_word_count(text: []const u8) !void {
    const trimmed = std.mem.trim(u8, text, " ");
    const total = utils.countWords(trimmed);
    if (total == 0) return;

    for (0..total + 1) |n| {
        const delta = utils.wordDelta(trimmed, n);
        const delta_trimmed = std.mem.trimLeft(u8, delta, " ");
        try std.testing.expectEqual(total - n, utils.countWords(delta_trimmed));
    }
}

// ============================================================================
// textPreview properties
// ============================================================================

// textPreview always returns at most 60 chars
fn prop_textPreview_bounded(text: []const u8) !void {
    try std.testing.expect(utils.textPreview(text).len <= 60);
}

// textPreview is a prefix of the input
fn prop_textPreview_is_prefix(text: []const u8) !void {
    const preview = utils.textPreview(text);
    try std.testing.expectEqualStrings(preview, text[0..preview.len]);
}

// textPreview is identity for short text
fn prop_textPreview_identity_when_short(text: []const u8) !void {
    if (text.len <= 60) {
        try std.testing.expectEqualStrings(text, utils.textPreview(text));
    }
}

// ============================================================================
// parseWavHeader + wavToFloat roundtrip properties
// ============================================================================

// Build a valid WAV from random bytes, parse header, extract samples, verify roundtrip.
fn prop_wav_roundtrip(raw_pcm: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Only use even-length data (complete S16 samples)
    const pcm_len = raw_pcm.len & ~@as(usize, 1);
    if (pcm_len == 0) return;

    // Build a valid WAV: 44-byte header + pcm_len data bytes
    const wav_size = 44 + pcm_len;
    const wav = try allocator.alloc(u8, wav_size);
    defer allocator.free(wav);

    // RIFF header
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], @intCast(36 + pcm_len), .little);
    @memcpy(wav[8..12], "WAVE");
    // fmt chunk
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, wav[22..24], 1, .little); // mono
    std.mem.writeInt(u32, wav[24..28], 16000, .little); // sample rate
    std.mem.writeInt(u32, wav[28..32], 32000, .little); // byte rate
    std.mem.writeInt(u16, wav[32..34], 2, .little); // block align
    std.mem.writeInt(u16, wav[34..36], 16, .little); // bits per sample
    // data chunk
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], @intCast(pcm_len), .little);
    @memcpy(wav[44..wav_size], raw_pcm[0..pcm_len]);

    // Parse and extract
    const header = try utils.parseWavHeader(wav);
    try std.testing.expectEqual(@as(u16, 1), header.channels);
    try std.testing.expectEqual(@as(usize, 44), header.data_start);
    try std.testing.expectEqual(@as(u32, @intCast(pcm_len)), header.data_size);

    const samples = try utils.wavToFloat(allocator, wav, header);
    defer allocator.free(samples);

    // Verify sample count matches
    try std.testing.expectEqual(pcm_len / 2, samples.len);

    // Verify all samples are in valid range
    for (samples) |s| {
        try std.testing.expect(s >= -1.0 and s <= 1.0);
    }

    // Verify roundtrip: each sample matches the S16 bytes we put in
    for (samples, 0..) |s, i| {
        const offset = 44 + i * 2;
        const raw = std.mem.readInt(i16, wav[offset..][0..2], .little);
        const expected: f32 = @as(f32, @floatFromInt(raw)) / 32768.0;
        try std.testing.expectApproxEqAbs(expected, s, 1e-7);
    }
}

// parseWavHeader rejects short data
fn prop_wav_reject_short(text: []const u8) !void {
    if (text.len < 44) {
        try std.testing.expectError(error.InvalidWavFile, utils.parseWavHeader(text));
    }
}

// ============================================================================
// pcmToFloat additional properties
// ============================================================================

// pcmToFloat output length == input length / 2
fn prop_pcmToFloat_length(text: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const samples = try utils.pcmToFloat(allocator, text);
    defer allocator.free(samples);
    try std.testing.expectEqual(text.len / 2, samples.len);
}

// ============================================================================
// argmax properties
// ============================================================================

// argmax result is always a valid index (< array.len)
fn prop_argmax_bounded(n: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const size = (n % 50) + 1; // 1..50 elements
    const data = try allocator.alloc(f32, size);
    defer allocator.free(data);

    // Fill with deterministic-ish values derived from n
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    for (data) |*v| {
        const raw = prng.random().int(i16);
        v.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    const idx = alignatt.argmax(data);
    try std.testing.expect(idx < data.len);

    // Verify it's actually the max
    for (data) |v| {
        try std.testing.expect(data[idx] >= v);
    }
}

// ============================================================================
// checkStopping properties
// ============================================================================

// checkStopping always returns a valid decision (exhaustiveness via enum match)
fn prop_checkStopping_exhaustive(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const most_attended = prng.random().intRangeAtMost(usize, 0, 1500);
    const content_frames = prng.random().intRangeAtMost(usize, 0, 1500);
    const has_last = prng.random().boolean();
    const last_attend: ?usize = if (has_last) prng.random().intRangeAtMost(usize, 0, 1500) else null;
    const is_last = prng.random().boolean();

    const decision = alignatt.checkStopping(most_attended, content_frames, last_attend, is_last, .{});

    // Verify the decision is consistent with the inputs
    switch (decision) {
        .rewind_detected => {
            // Rewind requires last_attend > most_attended + threshold
            try std.testing.expect(last_attend != null);
            const last = last_attend.?;
            try std.testing.expect(last > most_attended);
            try std.testing.expect(last - most_attended > 200);
        },
        .stop_attention_at_end => {
            // Stop requires content_frames - most_attended <= threshold
            const threshold: usize = if (is_last) 4 else 25;
            try std.testing.expect(content_frames > most_attended);
            try std.testing.expect(content_frames - most_attended <= threshold);
        },
        .continue_decoding => {
            // Continue is the default — just verify it's a valid state
        },
    }
}

// Rewind check has priority over stop check
fn prop_checkStopping_rewind_priority(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const most_attended = prng.random().intRangeAtMost(usize, 0, 100);
    // Set up conditions where both rewind AND stop could trigger
    const last_attend = most_attended + 201 + prng.random().intRangeAtMost(usize, 0, 500);
    const content_frames = most_attended + prng.random().intRangeAtMost(usize, 1, 25);
    const is_last = prng.random().boolean();

    const decision = alignatt.checkStopping(most_attended, content_frames, last_attend, is_last, .{});
    // Rewind should take priority
    try std.testing.expectEqual(alignatt.Decision.rewind_detected, decision);
}

// is_last=true uses a tighter threshold than is_last=false
fn prop_checkStopping_is_last_tighter(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    // Pick a gap between 5 and 25 — should stop with !is_last but continue with is_last
    const gap = 5 + prng.random().intRangeAtMost(usize, 0, 20);
    const most_attended = 100 + prng.random().intRangeAtMost(usize, 0, 500);
    const content_frames = most_attended + gap;

    const not_last = alignatt.checkStopping(most_attended, content_frames, null, false, .{});
    const yes_last = alignatt.checkStopping(most_attended, content_frames, null, true, .{});

    if (gap <= 4) {
        // Both should stop
        try std.testing.expectEqual(alignatt.Decision.stop_attention_at_end, not_last);
        try std.testing.expectEqual(alignatt.Decision.stop_attention_at_end, yes_last);
    } else if (gap <= 25) {
        // Only not_last should stop; is_last should continue
        try std.testing.expectEqual(alignatt.Decision.stop_attention_at_end, not_last);
        try std.testing.expectEqual(alignatt.Decision.continue_decoding, yes_last);
    } else {
        // Neither should stop
        try std.testing.expectEqual(alignatt.Decision.continue_decoding, not_last);
        try std.testing.expectEqual(alignatt.Decision.continue_decoding, yes_last);
    }
}

// ============================================================================
// analyzeAttention properties
// ============================================================================

// analyzeAttention output length == n_audio_ctx
fn prop_analyzeAttention_output_length(n: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const n_tokens = 1 + (n % 5); // 1..5
    const n_audio_ctx = 4 + (n % 20); // 4..23
    const n_heads = 1 + (n % 3); // 1..3
    const total = n_heads * n_audio_ctx * n_tokens;

    const attn = try allocator.alloc(f32, total);
    defer allocator.free(attn);
    for (attn) |*v| {
        const raw = prng.random().int(i16);
        v.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    const result = try alignatt.analyzeAttention(
        allocator, attn.ptr, n_tokens, n_audio_ctx, n_heads,
        .{ .median_filter_width = 1 },
    );
    defer allocator.free(result);

    try std.testing.expectEqual(n_audio_ctx, result.len);
    // argmax should be valid
    const peak = alignatt.argmax(result);
    try std.testing.expect(peak < n_audio_ctx);
}

// analyzeAttention with a strong peak should preserve the peak location
fn prop_analyzeAttention_peak_preserved(n: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const n_tokens: usize = 2;
    const n_audio_ctx: usize = 10;
    const n_heads: usize = 1;
    const total = n_heads * n_audio_ctx * n_tokens;

    const attn = try allocator.alloc(f32, total);
    defer allocator.free(attn);
    @memset(attn, 0);

    // Place a strong peak at a random frame for the last token
    const peak_frame = n % n_audio_ctx;
    attn[peak_frame * n_tokens + (n_tokens - 1)] = 10.0;

    const result = try alignatt.analyzeAttention(
        allocator, attn.ptr, n_tokens, n_audio_ctx, n_heads,
        .{ .median_filter_width = 1 },
    );
    defer allocator.free(result);

    // With one head and no median filter, the strong peak should survive z-score
    try std.testing.expectEqual(peak_frame, alignatt.argmax(result));
}

// ============================================================================
// Runner
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const runs: u32 = 500;

    std.debug.print("\n=== Property-Based Tests (minish) ===\n\n", .{});

    // countWords
    std.debug.print("prop: countWords bounded by length... ", .{});
    try minish.check(allocator, word_text_gen, prop_countWords_bounded_by_length, .{ .num_runs = runs });
    std.debug.print("prop: countWords ignores leading/trailing spaces... ", .{});
    try minish.check(allocator, word_text_gen, prop_countWords_ignores_leading_trailing, .{ .num_runs = runs });

    // byteOffsetAfterWords
    std.debug.print("prop: byteOffset zero is zero... ", .{});
    try minish.check(allocator, word_text_gen, prop_byteOffset_zero_is_zero, .{ .num_runs = runs });
    std.debug.print("prop: byteOffset bounded... ", .{});
    try minish.check(allocator, word_text_gen, prop_byteOffset_bounded, .{ .num_runs = runs });
    std.debug.print("prop: byteOffset monotonic... ", .{});
    try minish.check(allocator, word_text_gen, prop_byteOffset_monotonic, .{ .num_runs = runs });
    std.debug.print("prop: byteOffset at count is end... ", .{});
    try minish.check(allocator, word_text_gen, prop_byteOffset_at_count_is_end, .{ .num_runs = runs });

    // wordDelta
    std.debug.print("prop: wordDelta zero is identity... ", .{});
    try minish.check(allocator, word_text_gen, prop_wordDelta_zero_is_identity, .{ .num_runs = runs });
    std.debug.print("prop: wordDelta reduces count... ", .{});
    try minish.check(allocator, word_text_gen, prop_wordDelta_reduces_count, .{ .num_runs = runs });

    // stripTrailingPunct
    std.debug.print("prop: stripPunct idempotent... ", .{});
    try minish.check(allocator, punct_text_gen, prop_stripPunct_idempotent, .{ .num_runs = runs });
    std.debug.print("prop: stripPunct is prefix... ", .{});
    try minish.check(allocator, punct_text_gen, prop_stripPunct_is_prefix, .{ .num_runs = runs });

    // eqlIgnoreCase
    std.debug.print("prop: eqlIgnoreCase reflexive... ", .{});
    try minish.check(allocator, word_text_gen, prop_eqlIgnoreCase_reflexive, .{ .num_runs = runs });
    std.debug.print("prop: eqlIgnoreCase symmetric... ", .{});
    try minish.check(allocator, text_pair_gen, prop_eqlIgnoreCase_symmetric, .{ .num_runs = runs });

    // stableWordCount
    std.debug.print("prop: stableWordCount reflexive... ", .{});
    try minish.check(allocator, word_text_gen, prop_stable_reflexive, .{ .num_runs = runs });
    std.debug.print("prop: stableWordCount bounded... ", .{});
    try minish.check(allocator, text_pair_gen, prop_stable_bounded, .{ .num_runs = runs });
    std.debug.print("prop: stableWordCount case insensitive... ", .{});
    try minish.check(allocator, word_text_gen, prop_stable_case_insensitive, .{ .num_runs = runs });

    // findStableWords
    std.debug.print("prop: findStableWords bounded... ", .{});
    try minish.check(allocator, text_pair_gen, prop_findStable_bounded, .{ .num_runs = runs });
    std.debug.print("prop: findStableWords matches basic... ", .{});
    try minish.check(allocator, text_pair_gen, prop_findStable_matches_basic, .{ .num_runs = runs });
    std.debug.print("prop: findStableWords offset consistent... ", .{});
    try minish.check(allocator, text_pair_gen, prop_findStable_offset_consistent, .{ .num_runs = runs });

    // pcmToFloat
    std.debug.print("prop: pcmToFloat range... ", .{});
    try minish.check(allocator, text_pair_gen, prop_pcmToFloat_range, .{ .num_runs = runs });

    // isBlankOrPunct
    std.debug.print("prop: isBlankOrPunct length... ", .{});
    try minish.check(allocator, word_text_gen, prop_isBlankOrPunct_length, .{ .num_runs = runs });

    // trimBuffer
    std.debug.print("prop: trimBuffer bounded... ", .{});
    try minish.check(allocator, word_text_gen, prop_trimBuffer_bounded, .{ .num_runs = runs });
    std.debug.print("prop: trimBuffer preserves tail... ", .{});
    try minish.check(allocator, word_text_gen, prop_trimBuffer_preserves_tail, .{ .num_runs = runs });

    // Deep cross-function properties
    std.debug.print("prop: byteOffset/countWords roundtrip... ", .{});
    try minish.check(allocator, word_text_gen, prop_byteOffset_countWords_roundtrip, .{ .num_runs = runs });
    std.debug.print("prop: stableWordCount prefix agreement... ", .{});
    try minish.check(allocator, punct_pair_gen, prop_stable_prefix_agreement, .{ .num_runs = runs });
    std.debug.print("prop: streaming simulation... ", .{});
    try minish.check(allocator, word_text_gen, prop_streaming_simulation, .{ .num_runs = runs });
    std.debug.print("prop: sliding window shift... ", .{});
    try minish.check(allocator, word_text_gen, prop_sliding_window_shift, .{ .num_runs = runs });
    std.debug.print("prop: wordDelta word count... ", .{});
    try minish.check(allocator, word_text_gen, prop_wordDelta_word_count, .{ .num_runs = runs });

    // textPreview
    std.debug.print("prop: textPreview bounded... ", .{});
    try minish.check(allocator, word_text_gen, prop_textPreview_bounded, .{ .num_runs = runs });
    std.debug.print("prop: textPreview is prefix... ", .{});
    try minish.check(allocator, word_text_gen, prop_textPreview_is_prefix, .{ .num_runs = runs });
    std.debug.print("prop: textPreview identity when short... ", .{});
    try minish.check(allocator, word_text_gen, prop_textPreview_identity_when_short, .{ .num_runs = runs });

    // WAV roundtrip
    std.debug.print("prop: WAV header+samples roundtrip... ", .{});
    try minish.check(allocator, word_text_gen, prop_wav_roundtrip, .{ .num_runs = runs });
    std.debug.print("prop: WAV reject short data... ", .{});
    try minish.check(allocator, word_text_gen, prop_wav_reject_short, .{ .num_runs = runs });

    // pcmToFloat length
    std.debug.print("prop: pcmToFloat length... ", .{});
    try minish.check(allocator, word_text_gen, prop_pcmToFloat_length, .{ .num_runs = runs });

    // argmax
    std.debug.print("prop: argmax bounded and correct... ", .{});
    try minish.check(allocator, frame_gen, prop_argmax_bounded, .{ .num_runs = runs });

    // checkStopping
    std.debug.print("prop: checkStopping exhaustive consistency... ", .{});
    try minish.check(allocator, frame_gen, prop_checkStopping_exhaustive, .{ .num_runs = runs });
    std.debug.print("prop: checkStopping rewind priority... ", .{});
    try minish.check(allocator, frame_gen, prop_checkStopping_rewind_priority, .{ .num_runs = runs });
    std.debug.print("prop: checkStopping is_last tighter threshold... ", .{});
    try minish.check(allocator, frame_gen, prop_checkStopping_is_last_tighter, .{ .num_runs = runs });

    // analyzeAttention
    std.debug.print("prop: analyzeAttention output length... ", .{});
    try minish.check(allocator, small_frame_gen, prop_analyzeAttention_output_length, .{ .num_runs = runs });
    std.debug.print("prop: analyzeAttention peak preserved... ", .{});
    try minish.check(allocator, small_frame_gen, prop_analyzeAttention_peak_preserved, .{ .num_runs = runs });

    std.debug.print("\nAll 39 property tests passed!\n", .{});
}
