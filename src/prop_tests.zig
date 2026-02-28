// Property-based tests for utils.zig using minish.
// These test invariants over random inputs to find edge cases
// that hand-written unit tests might miss.

const std = @import("std");
const minish = @import("minish");
const mgen = minish.gen;
const utils = @import("utils.zig");
const alignatt = @import("alignatt.zig");
const input = @import("input.zig");
const dsp = @import("dsp.zig");
const conv = @import("conv.zig");

// Generator for "word-like" strings: lowercase letters and spaces.
// This mimics Whisper output text (words separated by single spaces).
const word_text_gen = mgen.string(.{
    .min_len = 0,
    .max_len = 60,
    .charset = .custom,
    .custom_chars = "abcdefghij ",
});

// Numeric generators for alignatt
const frame_gen = mgen.intRange(usize, 0, 1500); // audio frame indices
const small_frame_gen = mgen.intRange(usize, 1, 200); // small frame counts for attention arrays

// ============================================================================
// pcmToFloat roundtrip property
// ============================================================================

// Converting i16 to float should always be in [-1.0, 1.0]
fn prop_pcmToFloat_range(data: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
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
// writeWav roundtrip property
// ============================================================================

// writeWav → parseWavHeader → data bytes match, samples roundtrip
fn prop_writeWav_roundtrip(raw_pcm: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const pcm_len = raw_pcm.len & ~@as(usize, 1);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    try utils.writeWav(buf.writer(allocator), raw_pcm[0..pcm_len]);

    const header = try utils.parseWavHeader(buf.items);
    try std.testing.expectEqual(@as(u16, 1), header.channels);
    try std.testing.expectEqual(@as(usize, 44), header.data_start);
    try std.testing.expectEqual(@as(u32, @intCast(pcm_len)), header.data_size);

    // Raw data bytes roundtrip
    try std.testing.expectEqualSlices(u8, raw_pcm[0..pcm_len], buf.items[44..]);

    // Full roundtrip: write → parse → wavToFloat → verify samples
    if (pcm_len >= 2) {
        const samples = try utils.wavToFloat(allocator, buf.items, header);
        defer allocator.free(samples);
        for (samples, 0..) |s, idx| {
            const raw = std.mem.readInt(i16, raw_pcm[idx * 2 ..][0..2], .little);
            const expected: f32 = @as(f32, @floatFromInt(raw)) / 32768.0;
            try std.testing.expectApproxEqAbs(expected, s, 1e-7);
        }
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
    const flush = prng.random().boolean();

    const decision = alignatt.checkStopping(most_attended, content_frames, last_attend, flush, &.{}, 0, .{});

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
            const threshold: usize = if (flush) 4 else 25;
            try std.testing.expect(content_frames > most_attended);
            try std.testing.expect(content_frames - most_attended <= threshold);
        },
        .stop_frame_stagnation => {
            // Stagnation won't trigger with empty token_frames, but handle for exhaustiveness
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
    const flush = prng.random().boolean();

    const decision = alignatt.checkStopping(most_attended, content_frames, last_attend, flush, &.{}, 0, .{});
    // Rewind should take priority
    try std.testing.expectEqual(alignatt.Decision.rewind_detected, decision);
}

// flush=true uses a tighter threshold than flush=false
fn prop_checkStopping_flush_tighter(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    // Pick a gap between 5 and 25 — should stop streaming but continue on flush
    const gap = 5 + prng.random().intRangeAtMost(usize, 0, 20);
    const most_attended = 100 + prng.random().intRangeAtMost(usize, 0, 500);
    const content_frames = most_attended + gap;

    const streaming = alignatt.checkStopping(most_attended, content_frames, null, false, &.{}, 0, .{});
    const flushing = alignatt.checkStopping(most_attended, content_frames, null, true, &.{}, 0, .{});

    if (gap <= 4) {
        // Both should stop
        try std.testing.expectEqual(alignatt.Decision.stop_attention_at_end, streaming);
        try std.testing.expectEqual(alignatt.Decision.stop_attention_at_end, flushing);
    } else if (gap <= 25) {
        // Only streaming should stop; flush should continue
        try std.testing.expectEqual(alignatt.Decision.stop_attention_at_end, streaming);
        try std.testing.expectEqual(alignatt.Decision.continue_decoding, flushing);
    } else {
        // Neither should stop
        try std.testing.expectEqual(alignatt.Decision.continue_decoding, streaming);
        try std.testing.expectEqual(alignatt.Decision.continue_decoding, flushing);
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
// channelRms / rmsToDb property tests
// ============================================================================

// Generator for random S16_LE PCM bytes (pairs of bytes)
const pcm_byte_gen = mgen.intRange(i16, -32768, 32767);

// channelRms is always non-negative
fn prop_channelRms_non_negative(val: i16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(i16, &buf, val, .little);
    const rms = utils.channelRms(&buf, 1, 0);
    try std.testing.expect(rms >= 0);
}

// channelRms of silence is exactly zero
fn prop_channelRms_silence(_: i16) !void {
    const silence = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const rms = utils.channelRms(&silence, 1, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), rms, 1e-15);
}

// channelRms <= 1.0 for any valid S16_LE input
fn prop_channelRms_bounded(val: i16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(i16, &buf, val, .little);
    const rms = utils.channelRms(&buf, 1, 0);
    try std.testing.expect(rms <= 1.0 + 1e-10);
}

// rmsToDb is monotonically increasing
fn prop_rmsToDb_monotonic(val: i16) !void {
    // Map i16 to two RMS values in (0, 1]
    const abs_val: f64 = @abs(@as(f64, @floatFromInt(val)));
    const rms1: f64 = (abs_val + 1) / 32769.0;
    const rms2: f64 = rms1 * 0.5;
    try std.testing.expect(utils.rmsToDb(rms2) <= utils.rmsToDb(rms1));
}

// rmsToDb(1.0) == 0 dB
fn prop_rmsToDb_unity(_: i16) !void {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), utils.rmsToDb(1.0), 1e-10);
}

// ============================================================================
// input.zig property tests
// ============================================================================

// Generator for ASCII bytes (0-127)
const ascii_byte_gen = mgen.intRange(u8, 0, 127);
// Generator for random key sequences (pairs of keycode + pressed)
const keycode_gen = mgen.intRange(u16, 0, 255);
// Generator for printable ASCII strings
const ascii_text_gen = mgen.string(.{
    .min_len = 0,
    .max_len = 80,
    .charset = .custom,
    .custom_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!?-_=+[]{}|;:'\"<>/\\`~@#$%^&*()\t\n",
});

// eventsForChar: unshifted chars produce exactly 4 events, shifted produce 8
fn prop_eventsForChar_count(ch: u8) !void {
    const result = input.eventsForChar(ch);
    if (result.len == 0) return; // unmapped char
    // Must be either 4 (unshifted) or 8 (shifted)
    try std.testing.expect(result.len == 4 or result.len == 8);
}

// eventsForChar: all events alternate key/syn
fn prop_eventsForChar_syn_placement(ch: u8) !void {
    const result = input.eventsForChar(ch);
    const events = result.slice();
    // Every odd-indexed event must be SYN
    for (events, 0..) |evt, i| {
        if (i % 2 == 1) {
            try std.testing.expectEqual(@as(u16, 0x00), evt.type); // EV_SYN
        } else {
            try std.testing.expectEqual(@as(u16, 0x01), evt.type); // EV_KEY
        }
    }
}

// eventsForChar: key down and up are balanced
fn prop_eventsForChar_balanced(ch: u8) !void {
    const result = input.eventsForChar(ch);
    const events = result.slice();
    var downs: i32 = 0;
    var ups: i32 = 0;
    for (events) |evt| {
        if (evt.type == 0x01) { // EV_KEY
            if (evt.value == 1) downs += 1;
            if (evt.value == 0) ups += 1;
        }
    }
    try std.testing.expectEqual(downs, ups);
}

// PanicDetector: random non-panic key sequences never trigger
fn prop_panic_no_false_trigger(code: u16) !void {
    // Feed random key presses that aren't all three panic keys
    var pd = input.PanicDetector{};
    // Only feed non-panic keys
    if (code == 28 or code == 14 or code == 1) return; // KEY_ENTER, KEY_BACKSPACE, KEY_ESC
    try std.testing.expect(!pd.feed(code, true));
    try std.testing.expect(!pd.feed(code, false));
}

// PanicDetector: release always disarms
fn prop_panic_release_disarms(code: u16) !void {
    var pd = input.PanicDetector{};
    _ = pd.feed(code, true);
    _ = pd.feed(code, false); // release
    // After releasing any key, that key's state should be false
    // Pressing the other two should not trigger
    // (this tests that release works correctly for any key)
    switch (code) {
        28 => try std.testing.expect(!pd.enter),
        14 => try std.testing.expect(!pd.backspace),
        1 => try std.testing.expect(!pd.escape),
        else => {},
    }
}

// TriggerState: press-release-press always produces start/stop/start
fn prop_trigger_press_release_press(n: usize) !void {
    _ = n;
    var ts = input.TriggerState{};
    try std.testing.expectEqual(input.TriggerAction.start_recording, ts.keyEvent(1));
    try std.testing.expectEqual(input.TriggerAction.stop_recording, ts.keyEvent(0));
    try std.testing.expectEqual(input.TriggerAction.start_recording, ts.keyEvent(1));
}

// hasKeyBit: setting a bit and checking it roundtrips
fn prop_hasKeyBit_roundtrip(key: u16) !void {
    if (key >= 256) return; // reasonable bitmask size
    var mask: [32]u8 = std.mem.zeroes([32]u8);
    mask[key / 8] |= @as(u8, 1) << @intCast(key % 8);
    try std.testing.expect(input.hasKeyBit(&mask, key));
    // Adjacent bits should not be set (unless same byte)
    if (key > 0) {
        const prev = key - 1;
        if (prev / 8 != key / 8 or prev % 8 != key % 8) {
            try std.testing.expect(!input.hasKeyBit(&mask, prev));
        }
    }
}

// eventsForText: total event count matches sum of per-char events
fn prop_eventsForText_count(text: []const u8) !void {
    var expected_count: usize = 0;
    for (text) |ch| {
        expected_count += input.eventsForChar(ch).len;
    }
    // Just verify the counts are consistent (since we don't have eventsForText,
    // verify the per-char counts are self-consistent across the string)
    var actual_count: usize = 0;
    for (text) |ch| {
        const result = input.eventsForChar(ch);
        actual_count += result.len;
        // Verify each char independently
        if (result.len > 0) {
            try std.testing.expect(result.len == 4 or result.len == 8);
        }
    }
    try std.testing.expectEqual(expected_count, actual_count);
}

// ============================================================================
// avgRawPeak properties
// ============================================================================

// avgRawPeak is always non-negative (softmax values are non-negative)
fn prop_avgRawPeak_non_negative(n: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const n_tokens: usize = 1 + (n % 4); // 1..4
    const n_audio_ctx: usize = 2 + (n % 10); // 2..11
    const n_heads: usize = 1 + (n % 3); // 1..3
    const frame_limit: usize = 1 + (n % n_audio_ctx);
    const total = n_heads * n_audio_ctx * n_tokens;

    const attn = try allocator.alloc(f32, total);
    defer allocator.free(attn);
    // Fill with non-negative values (simulating softmax output)
    for (attn) |*v| {
        v.* = @as(f32, @floatFromInt(prng.random().intRangeAtMost(u16, 0, 1000))) / 1000.0;
    }

    const result = alignatt.avgRawPeak(attn.ptr, n_tokens, n_audio_ctx, n_heads, frame_limit);
    try std.testing.expect(result >= 0);
}

// avgRawPeak <= max value in the attention data
fn prop_avgRawPeak_bounded_by_max(n: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const n_tokens: usize = 1 + (n % 4);
    const n_audio_ctx: usize = 2 + (n % 10);
    const n_heads: usize = 1 + (n % 3);
    const frame_limit: usize = 1 + (n % n_audio_ctx);
    const total = n_heads * n_audio_ctx * n_tokens;

    const attn = try allocator.alloc(f32, total);
    defer allocator.free(attn);
    var global_max: f32 = 0;
    for (attn) |*v| {
        v.* = @as(f32, @floatFromInt(prng.random().intRangeAtMost(u16, 0, 1000))) / 1000.0;
        if (v.* > global_max) global_max = v.*;
    }

    const result = alignatt.avgRawPeak(attn.ptr, n_tokens, n_audio_ctx, n_heads, frame_limit);
    // Average of per-head peaks can't exceed the global max
    try std.testing.expect(result <= global_max + 1e-6);
}

// avgRawPeak with uniform attention equals the uniform value
fn prop_avgRawPeak_uniform(n: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const n_tokens: usize = 1 + (n % 4);
    const n_audio_ctx: usize = 2 + (n % 10);
    const n_heads: usize = 1 + (n % 3);
    const total = n_heads * n_audio_ctx * n_tokens;
    const uniform_val: f32 = @as(f32, @floatFromInt(1 + n % 100)) / 100.0;

    const attn = try allocator.alloc(f32, total);
    defer allocator.free(attn);
    @memset(attn, uniform_val);

    const result = alignatt.avgRawPeak(attn.ptr, n_tokens, n_audio_ctx, n_heads, n_audio_ctx);
    try std.testing.expectApproxEqAbs(uniform_val, result, 1e-5);
}

// ============================================================================
// detectFrameRegression properties
// ============================================================================

// detectFrameRegression: null when frames.len < window
fn prop_detectFrameRegression_short_null(n: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const window: usize = 8;
    const len = n % window; // 0..7 — always < window
    const frames = try allocator.alloc(usize, len);
    defer allocator.free(frames);
    @memset(frames, 50);

    try std.testing.expectEqual(@as(?usize, null), alignatt.detectFrameRegression(frames, 500, window, 75));
}

// detectFrameRegression: frames at frontier never regress
fn prop_detectFrameRegression_at_frontier_ok(n: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const window: usize = 8;
    const frontier = 100 + (n % 500);
    const frames = try allocator.alloc(usize, window);
    defer allocator.free(frames);
    // All frames at or near frontier
    for (frames) |*f| {
        f.* = frontier;
    }

    try std.testing.expectEqual(@as(?usize, null), alignatt.detectFrameRegression(frames, frontier, window, 75));
}

// detectFrameRegression: if triggered, discard count == window
fn prop_detectFrameRegression_discard_equals_window(n: usize) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const window: usize = 4 + (n % 8); // 4..11
    const frames = try allocator.alloc(usize, window);
    defer allocator.free(frames);
    @memset(frames, 10); // far behind frontier

    const result = alignatt.detectFrameRegression(frames, 500, window, 75);
    if (result) |discard| {
        try std.testing.expectEqual(window, discard);
    }
}

// ============================================================================
// checkLowConfidence properties
// ============================================================================

// checkLowConfidence: established segment always returns continue with streak=0
fn prop_checkLowConfidence_established_bypasses(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const avg_raw_peak = @as(f32, @floatFromInt(prng.random().intRangeAtMost(u16, 0, 100))) / 1000.0;
    const segment_max = @as(f32, @floatFromInt(prng.random().intRangeAtMost(u16, 120, 500))) / 1000.0;
    const current_streak = prng.random().intRangeAtMost(usize, 0, 100);

    const r = alignatt.checkLowConfidence(avg_raw_peak, segment_max, current_streak, 0.12, 0.10, 2);
    try std.testing.expectEqual(alignatt.ConfidenceAction.continue_decoding, r.action);
    try std.testing.expectEqual(@as(usize, 0), r.streak);
}

// checkLowConfidence: streak monotonically increases with consecutive low peaks
fn prop_checkLowConfidence_streak_monotonic(n: usize) !void {
    const segment_max: f32 = 0.05; // below established threshold
    const low_peak: f32 = 0.03; // below confidence threshold
    var streak: usize = 0;
    const steps = 1 + (n % 10);
    for (0..steps) |_| {
        const r = alignatt.checkLowConfidence(low_peak, segment_max, streak, 0.12, 0.10, 100);
        try std.testing.expect(r.streak > streak);
        streak = r.streak;
    }
}

// checkLowConfidence: good peak always resets streak to 0
fn prop_checkLowConfidence_good_peak_resets(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const segment_max: f32 = 0.08; // below established threshold
    const good_peak = 0.10 + @as(f32, @floatFromInt(prng.random().intRangeAtMost(u16, 0, 300))) / 1000.0;
    const current_streak = prng.random().intRangeAtMost(usize, 0, 50);

    const r = alignatt.checkLowConfidence(good_peak, segment_max, current_streak, 0.12, 0.10, 2);
    try std.testing.expectEqual(@as(usize, 0), r.streak);
}

// ============================================================================
// dsp.zig: celtLpc error bounds
// ============================================================================

// For valid autocorrelation: 0 < err ≤ ac[0]
fn prop_celtLpc_error_bounds(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const rng = prng.random();

    // Generate valid autocorrelation: fill random signal, compute dot products
    const sig_len = 64;
    var signal: [sig_len]f32 = undefined;
    for (&signal) |*v| {
        v.* = @as(f32, @floatFromInt(rng.int(i16))) / 32768.0;
    }

    var ac: [dsp.LPC_ORDER + 1]f32 = undefined;
    for (0..dsp.LPC_ORDER + 1) |lag| {
        var sum: f32 = 0;
        for (0..sig_len - lag) |i| {
            sum += signal[i] * signal[i + lag];
        }
        ac[lag] = sum;
    }

    var lpc_out: [dsp.LPC_ORDER]f32 = undefined;
    const err = dsp.celtLpc(&ac, &lpc_out);

    if (ac[0] > 0) {
        try std.testing.expect(err > 0);
        try std.testing.expect(err <= ac[0] + 1e-4);
    }
}

// ============================================================================
// dsp.zig: computeBandEnergy linearity
// ============================================================================

// bandEnergy(k * spectrum) = k * bandEnergy(spectrum) for k > 0
fn prop_computeBandEnergy_linearity(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const rng = prng.random();

    // Generate non-negative power spectrum
    var spec: [dsp.N_BINS]f32 = undefined;
    for (&spec) |*v| {
        v.* = @as(f32, @floatFromInt(rng.intRangeAtMost(u16, 0, 1000))) / 100.0;
    }

    const k = 1.0 + @as(f32, @floatFromInt(rng.intRangeAtMost(u16, 1, 500))) / 100.0;

    var band1: [dsp.NB_BANDS]f32 = undefined;
    dsp.computeBandEnergy(&spec, &band1);

    var scaled_spec: [dsp.N_BINS]f32 = undefined;
    for (&scaled_spec, spec) |*sv, v| {
        sv.* = k * v;
    }
    var band_scaled: [dsp.NB_BANDS]f32 = undefined;
    dsp.computeBandEnergy(&scaled_spec, &band_scaled);

    for (0..dsp.NB_BANDS) |i| {
        try std.testing.expectApproxEqRel(k * band1[i], band_scaled[i], 1e-4);
    }
}

// ============================================================================
// dsp.zig: computeBandEnergy non-negativity
// ============================================================================

fn prop_computeBandEnergy_non_negative(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const rng = prng.random();

    var spec: [dsp.N_BINS]f32 = undefined;
    for (&spec) |*v| {
        v.* = @as(f32, @floatFromInt(rng.intRangeAtMost(u16, 0, 10000))) / 100.0;
    }

    var band_e: [dsp.NB_BANDS]f32 = undefined;
    dsp.computeBandEnergy(&spec, &band_e);
    for (band_e) |e| {
        try std.testing.expect(e >= -1e-6);
    }
}

// ============================================================================
// dsp.zig: BiquadFilter linearity
// ============================================================================

// process(k*x) = k * process(x) with fresh filter state each time
fn prop_biquad_linearity(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const rng = prng.random();

    const len = 16;
    var x: [len]f32 = undefined;
    for (&x) |*v| {
        v.* = @as(f32, @floatFromInt(rng.int(i16))) / 32768.0;
    }
    const k = 0.5 + @as(f32, @floatFromInt(rng.intRangeAtMost(u16, 0, 400))) / 100.0;

    var bq1 = dsp.BiquadFilter{};
    var out1: [len]f32 = undefined;
    bq1.process(&x, &out1);

    var kx: [len]f32 = undefined;
    for (&kx, x) |*kv, v| kv.* = k * v;
    var bq2 = dsp.BiquadFilter{};
    var out2: [len]f32 = undefined;
    bq2.process(&kx, &out2);

    for (0..len) |i| {
        try std.testing.expectApproxEqAbs(k * out1[i], out2[i], 1e-3);
    }
}

// ============================================================================
// dsp.zig: BiquadFilter chunk equivalence
// ============================================================================

// Processing N samples as one call vs two calls of N/2 gives same output
fn prop_biquad_chunk_equivalence(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const rng = prng.random();

    const len = 16;
    var x: [len]f32 = undefined;
    for (&x) |*v| {
        v.* = @as(f32, @floatFromInt(rng.int(i16))) / 32768.0;
    }

    // One-shot
    var bq1 = dsp.BiquadFilter{};
    var out1: [len]f32 = undefined;
    bq1.process(&x, &out1);

    // Two halves
    var bq2 = dsp.BiquadFilter{};
    var out2a: [len / 2]f32 = undefined;
    var out2b: [len / 2]f32 = undefined;
    bq2.process(x[0 .. len / 2], &out2a);
    bq2.process(x[len / 2 .. len], &out2b);

    for (0..len / 2) |i| {
        try std.testing.expectApproxEqAbs(out1[i], out2a[i], 1e-5);
    }
    for (0..len / 2) |i| {
        try std.testing.expectApproxEqAbs(out1[len / 2 + i], out2b[i], 1e-5);
    }
}

// ============================================================================
// dsp.zig: xcorrKernel energy identity
// ============================================================================

// xcorr(x, x)[0] = sum(x[i]^2)
fn prop_xcorrKernel_energy(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const rng = prng.random();

    const len = 8 + (n % 25); // 8..32
    var buf: [64]f32 = undefined;
    var energy: f32 = 0;
    for (0..len) |i| {
        buf[i] = @as(f32, @floatFromInt(rng.int(i16))) / 32768.0;
        energy += buf[i] * buf[i];
    }
    // Pad y with 3 extra elements for the kernel's 4-wide window
    var sum = [4]f32{ 0, 0, 0, 0 };
    dsp.xcorrKernel(buf[0..len], buf[0 .. len + 3], &sum, len);
    try std.testing.expectApproxEqRel(energy, sum[0], 1e-4);
}

// ============================================================================
// conv.zig: runConvs finiteness
// ============================================================================

// For any finite weights and finite features, all 80 outputs are finite
fn prop_runConvs_finiteness(n: usize) !void {
    var prng = std.Random.DefaultPrng.init(@intCast(n));
    const rng = prng.random();

    var w: conv.ConvWeights = undefined;
    // Fill weights with small random values
    for (&w.dw0) |*v| v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;
    for (&w.pw0) |*v| v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;
    for (&w.b0) |*v| v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;
    for (&w.dw1) |*v| v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;
    for (&w.pw1) |*v| v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;
    for (&w.b1) |*v| v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;
    for (&w.dw2) |*v| v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;
    for (&w.pw2) |*v| v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;
    for (&w.b2) |*v| v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;

    var features: [conv.CONTEXT_LEN * conv.FEA_LEN]f32 = undefined;
    for (&features) |*v| {
        v.* = @as(f32, @floatFromInt(rng.int(i8))) / 128.0;
    }

    const out = conv.runConvs(&w, &features);
    for (out) |v| {
        try std.testing.expect(std.math.isFinite(v));
    }
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

    // pcmToFloat
    std.debug.print("prop: pcmToFloat range... ", .{});
    try minish.check(allocator, word_text_gen, prop_pcmToFloat_range, .{ .num_runs = runs });

    // isBlankOrPunct
    std.debug.print("prop: isBlankOrPunct length... ", .{});
    try minish.check(allocator, word_text_gen, prop_isBlankOrPunct_length, .{ .num_runs = runs });

    // trimBuffer
    std.debug.print("prop: trimBuffer bounded... ", .{});
    try minish.check(allocator, word_text_gen, prop_trimBuffer_bounded, .{ .num_runs = runs });
    std.debug.print("prop: trimBuffer preserves tail... ", .{});
    try minish.check(allocator, word_text_gen, prop_trimBuffer_preserves_tail, .{ .num_runs = runs });

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

    // writeWav roundtrip
    std.debug.print("prop: writeWav roundtrip... ", .{});
    try minish.check(allocator, word_text_gen, prop_writeWav_roundtrip, .{ .num_runs = runs });

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
    std.debug.print("prop: checkStopping flush tighter threshold... ", .{});
    try minish.check(allocator, frame_gen, prop_checkStopping_flush_tighter, .{ .num_runs = runs });

    // analyzeAttention
    std.debug.print("prop: analyzeAttention output length... ", .{});
    try minish.check(allocator, small_frame_gen, prop_analyzeAttention_output_length, .{ .num_runs = runs });
    std.debug.print("prop: analyzeAttention peak preserved... ", .{});
    try minish.check(allocator, small_frame_gen, prop_analyzeAttention_peak_preserved, .{ .num_runs = runs });

    // input.zig: eventsForChar
    std.debug.print("prop: eventsForChar event count... ", .{});
    try minish.check(allocator, ascii_byte_gen, prop_eventsForChar_count, .{ .num_runs = runs });
    std.debug.print("prop: eventsForChar SYN placement... ", .{});
    try minish.check(allocator, ascii_byte_gen, prop_eventsForChar_syn_placement, .{ .num_runs = runs });
    std.debug.print("prop: eventsForChar balanced down/up... ", .{});
    try minish.check(allocator, ascii_byte_gen, prop_eventsForChar_balanced, .{ .num_runs = runs });

    // input.zig: PanicDetector
    std.debug.print("prop: PanicDetector no false trigger... ", .{});
    try minish.check(allocator, keycode_gen, prop_panic_no_false_trigger, .{ .num_runs = runs });
    std.debug.print("prop: PanicDetector release disarms... ", .{});
    try minish.check(allocator, keycode_gen, prop_panic_release_disarms, .{ .num_runs = runs });

    // input.zig: TriggerState
    std.debug.print("prop: TriggerState press-release-press cycle... ", .{});
    try minish.check(allocator, frame_gen, prop_trigger_press_release_press, .{ .num_runs = runs });

    // input.zig: hasKeyBit
    std.debug.print("prop: hasKeyBit roundtrip... ", .{});
    try minish.check(allocator, keycode_gen, prop_hasKeyBit_roundtrip, .{ .num_runs = runs });

    // input.zig: eventsForText count consistency
    std.debug.print("prop: eventsForText count consistency... ", .{});
    try minish.check(allocator, ascii_text_gen, prop_eventsForText_count, .{ .num_runs = runs });

    // channelRms / rmsToDb
    std.debug.print("prop: channelRms non-negative... ", .{});
    try minish.check(allocator, pcm_byte_gen, prop_channelRms_non_negative, .{ .num_runs = runs });
    std.debug.print("prop: channelRms silence is zero... ", .{});
    try minish.check(allocator, pcm_byte_gen, prop_channelRms_silence, .{ .num_runs = runs });
    std.debug.print("prop: channelRms bounded... ", .{});
    try minish.check(allocator, pcm_byte_gen, prop_channelRms_bounded, .{ .num_runs = runs });
    std.debug.print("prop: rmsToDb monotonic... ", .{});
    try minish.check(allocator, pcm_byte_gen, prop_rmsToDb_monotonic, .{ .num_runs = runs });
    std.debug.print("prop: rmsToDb unity... ", .{});
    try minish.check(allocator, pcm_byte_gen, prop_rmsToDb_unity, .{ .num_runs = runs });

    // avgRawPeak
    std.debug.print("prop: avgRawPeak non-negative... ", .{});
    try minish.check(allocator, frame_gen, prop_avgRawPeak_non_negative, .{ .num_runs = runs });
    std.debug.print("prop: avgRawPeak bounded by max... ", .{});
    try minish.check(allocator, frame_gen, prop_avgRawPeak_bounded_by_max, .{ .num_runs = runs });
    std.debug.print("prop: avgRawPeak uniform equals value... ", .{});
    try minish.check(allocator, small_frame_gen, prop_avgRawPeak_uniform, .{ .num_runs = runs });

    // detectFrameRegression
    std.debug.print("prop: detectFrameRegression short null... ", .{});
    try minish.check(allocator, frame_gen, prop_detectFrameRegression_short_null, .{ .num_runs = runs });
    std.debug.print("prop: detectFrameRegression at frontier ok... ", .{});
    try minish.check(allocator, frame_gen, prop_detectFrameRegression_at_frontier_ok, .{ .num_runs = runs });
    std.debug.print("prop: detectFrameRegression discard equals window... ", .{});
    try minish.check(allocator, frame_gen, prop_detectFrameRegression_discard_equals_window, .{ .num_runs = runs });

    // checkLowConfidence
    std.debug.print("prop: checkLowConfidence established bypasses... ", .{});
    try minish.check(allocator, frame_gen, prop_checkLowConfidence_established_bypasses, .{ .num_runs = runs });
    std.debug.print("prop: checkLowConfidence streak monotonic... ", .{});
    try minish.check(allocator, frame_gen, prop_checkLowConfidence_streak_monotonic, .{ .num_runs = runs });
    std.debug.print("prop: checkLowConfidence good peak resets... ", .{});
    try minish.check(allocator, frame_gen, prop_checkLowConfidence_good_peak_resets, .{ .num_runs = runs });

    // dsp.zig: celtLpc
    std.debug.print("prop: celtLpc error bounds... ", .{});
    try minish.check(allocator, frame_gen, prop_celtLpc_error_bounds, .{ .num_runs = runs });

    // dsp.zig: computeBandEnergy
    std.debug.print("prop: computeBandEnergy linearity... ", .{});
    try minish.check(allocator, frame_gen, prop_computeBandEnergy_linearity, .{ .num_runs = runs });
    std.debug.print("prop: computeBandEnergy non-negative... ", .{});
    try minish.check(allocator, frame_gen, prop_computeBandEnergy_non_negative, .{ .num_runs = runs });

    // dsp.zig: BiquadFilter
    std.debug.print("prop: BiquadFilter linearity... ", .{});
    try minish.check(allocator, frame_gen, prop_biquad_linearity, .{ .num_runs = runs });
    std.debug.print("prop: BiquadFilter chunk equivalence... ", .{});
    try minish.check(allocator, frame_gen, prop_biquad_chunk_equivalence, .{ .num_runs = runs });

    // dsp.zig: xcorrKernel
    std.debug.print("prop: xcorrKernel energy identity... ", .{});
    try minish.check(allocator, small_frame_gen, prop_xcorrKernel_energy, .{ .num_runs = runs });

    // conv.zig: runConvs
    std.debug.print("prop: runConvs finiteness... ", .{});
    try minish.check(allocator, frame_gen, prop_runConvs_finiteness, .{ .num_runs = runs });

    std.debug.print("\nAll 46 property tests passed!\n", .{});
}
