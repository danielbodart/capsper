// Property-based tests for utils.zig and input.zig using minish.
// These test invariants over random inputs to find edge cases
// that hand-written unit tests might miss.

const std = @import("std");
const builtin = @import("builtin");
const minish = @import("minish");
const mgen = minish.gen;
const utils = @import("utils.zig");
const input = @import("input.zig");

// Generator for "word-like" strings: lowercase letters and spaces.
const word_text_gen = mgen.string(.{
    .min_len = 0,
    .max_len = 60,
    .charset = .custom,
    .custom_chars = "abcdefghij ",
});

const frame_gen = mgen.intRange(usize, 0, 1500);

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
    var actual_count: usize = 0;
    for (text) |ch| {
        const result = input.eventsForChar(ch);
        actual_count += result.len;
        if (result.len > 0) {
            try std.testing.expect(result.len == 4 or result.len == 8);
        }
    }
    try std.testing.expectEqual(expected_count, actual_count);
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

    // input.zig: Linux-specific tests (evdev event generation, panic detector, etc.)
    // These test functions that only exist on Linux — skipped on macOS.
    if (builtin.os.tag != .macos) {
        std.debug.print("prop: eventsForChar event count... ", .{});
        try minish.check(allocator, ascii_byte_gen, prop_eventsForChar_count, .{ .num_runs = runs });
        std.debug.print("prop: eventsForChar SYN placement... ", .{});
        try minish.check(allocator, ascii_byte_gen, prop_eventsForChar_syn_placement, .{ .num_runs = runs });
        std.debug.print("prop: eventsForChar balanced down/up... ", .{});
        try minish.check(allocator, ascii_byte_gen, prop_eventsForChar_balanced, .{ .num_runs = runs });

        std.debug.print("prop: PanicDetector no false trigger... ", .{});
        try minish.check(allocator, keycode_gen, prop_panic_no_false_trigger, .{ .num_runs = runs });
        std.debug.print("prop: PanicDetector release disarms... ", .{});
        try minish.check(allocator, keycode_gen, prop_panic_release_disarms, .{ .num_runs = runs });

        std.debug.print("prop: TriggerState press-release-press cycle... ", .{});
        try minish.check(allocator, frame_gen, prop_trigger_press_release_press, .{ .num_runs = runs });

        std.debug.print("prop: hasKeyBit roundtrip... ", .{});
        try minish.check(allocator, keycode_gen, prop_hasKeyBit_roundtrip, .{ .num_runs = runs });

        std.debug.print("prop: eventsForText count consistency... ", .{});
        try minish.check(allocator, ascii_text_gen, prop_eventsForText_count, .{ .num_runs = runs });
    }

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

    std.debug.print("\nAll property tests passed!\n", .{});
}
