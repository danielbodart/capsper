const std = @import("std");

/// Count the number of space-separated words in text.
pub fn countWords(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and text[i] == ' ') : (i += 1) {}
        if (i >= text.len) break;
        count += 1;
        while (i < text.len and text[i] != ' ') : (i += 1) {}
    }
    return count;
}

/// Return byte offset in `text` just past the Nth word.
/// If n >= total words, returns text.len.
pub fn byteOffsetAfterWords(text: []const u8, n: usize) usize {
    if (n == 0) return 0;
    var words: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // skip spaces
        while (i < text.len and text[i] == ' ') : (i += 1) {}
        if (i >= text.len) break;
        // found a word
        words += 1;
        // skip word chars
        while (i < text.len and text[i] != ' ') : (i += 1) {}
        if (words == n) return i;
    }
    return text.len;
}

/// Get text from position after `skip_words` to end.
pub fn wordDelta(text: []const u8, skip_words: usize) []const u8 {
    return text[byteOffsetAfterWords(text, skip_words)..];
}

/// Return a short preview of text for logging (first ~60 chars).
pub fn textPreview(text: []const u8) []const u8 {
    return if (text.len <= 60) text else text[0..60];
}

/// Trim buffer to keep only the last `keep_bytes`, aligned to sample boundary (2-byte).
pub fn trimBuffer(buf: *std.ArrayListUnmanaged(u8), keep_bytes: usize) void {
    if (buf.items.len <= keep_bytes) return;
    const trim = (buf.items.len - keep_bytes) & ~@as(usize, 1);
    if (trim == 0) return;
    const remaining = buf.items.len - trim;
    std.mem.copyForwards(u8, buf.items[0..remaining], buf.items[trim..]);
    buf.items.len = remaining;
}

/// Convert S16_LE PCM bytes to float samples normalized to [-1, 1].
pub fn pcmToFloat(allocator: std.mem.Allocator, pcm_bytes: []const u8) ![]f32 {
    const n_samples = pcm_bytes.len / 2;
    const result = try allocator.alloc(f32, n_samples);
    errdefer allocator.free(result);

    for (result, 0..) |*sample, i| {
        const offset = i * 2;
        if (offset + 2 > pcm_bytes.len) break;
        const raw = std.mem.readInt(i16, pcm_bytes[offset..][0..2], .little);
        sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    return result;
}

/// Check if a token's text is blank or punctuation-only (and short).
/// Used to skip leading junk tokens in the decoder output.
pub fn isBlankOrPunct(text: []const u8) bool {
    if (text.len > 1) return false;
    for (text) |ch| {
        switch (ch) {
            ' ', '!', '.', ',' => {},
            else => return false,
        }
    }
    return true;
}

/// Strip trailing punctuation from a word for comparison.
/// Whisper may change "loop." to "loop" or "so" to "so," between cycles.
pub fn stripTrailingPunct(word: []const u8) []const u8 {
    var end = word.len;
    while (end > 0) {
        switch (word[end - 1]) {
            '.', ',', '!', '?', ';', ':' => end -= 1,
            else => break,
        }
    }
    return word[0..end];
}

/// Compare two words ignoring case and trailing punctuation.
/// Used for dedup: "loop." and "Loop" are considered the same word.
pub fn wordsMatchForDedup(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(stripTrailingPunct(a), stripTrailingPunct(b));
}

/// A word with its audio frame position from cross-attention analysis.
/// frame is in encoder frame units (50fps = 20ms/frame).
pub const TimedWord = struct {
    text_start: usize, // byte offset into result text (first char of word, after space)
    text_end: usize, // byte offset one past last char of word
    frame: usize, // audio frame (relative to PCM buffer start)
};

/// Count how many words in the contiguous prefix of `curr` have a frame-matching
/// word in `prev` (within ±tolerance frames). Stops at the first unmatched word.
pub fn findTimedStableCount(prev: []const TimedWord, curr: []const TimedWord, tolerance: usize) usize {
    var count: usize = 0;
    for (curr) |cw| {
        var matched = false;
        for (prev) |pw| {
            const diff = if (cw.frame >= pw.frame) cw.frame - pw.frame else pw.frame - cw.frame;
            if (diff <= tolerance) {
                matched = true;
                break;
            }
        }
        if (!matched) break;
        count += 1;
    }
    return count;
}

/// Parse a WAV file header from raw bytes. Returns metadata needed to extract samples.
/// Validates RIFF/WAVE structure, PCM format (audio_format=1), and 16-bit samples.
pub const WavHeader = struct {
    channels: u16,
    data_start: usize,
    data_size: u32,
};

pub fn parseWavHeader(data: []const u8) !WavHeader {
    if (data.len < 44) return error.InvalidWavFile;
    if (!std.mem.eql(u8, data[0..4], "RIFF")) return error.InvalidWavFile;
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return error.InvalidWavFile;

    var pos: usize = 12;
    var channels: u16 = 0;
    var bits_per_sample: u16 = 0;
    var data_start: usize = 0;
    var data_size: u32 = 0;
    var found_fmt = false;
    var found_data = false;

    while (pos + 8 <= data.len and !found_data) {
        const chunk_id = data[pos..][0..4];
        const chunk_size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        pos += 8;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (pos + 16 > data.len) return error.InvalidWavFile;
            const audio_format = std.mem.readInt(u16, data[pos..][0..2], .little);
            if (audio_format != 1) return error.UnsupportedWavFormat;
            channels = std.mem.readInt(u16, data[pos + 2 ..][0..2], .little);
            bits_per_sample = std.mem.readInt(u16, data[pos + 14 ..][0..2], .little);
            found_fmt = true;
            pos += chunk_size;
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_start = pos;
            data_size = chunk_size;
            found_data = true;
        } else {
            pos += chunk_size;
        }
    }

    if (!found_fmt or !found_data) return error.InvalidWavFile;
    if (bits_per_sample != 16 or channels == 0) return error.UnsupportedWavFormat;

    return .{
        .channels = channels,
        .data_start = data_start,
        .data_size = data_size,
    };
}

/// Extract float samples from WAV data using a parsed header.
/// Reads the first channel only (mono downmix for stereo).
pub fn wavToFloat(allocator: std.mem.Allocator, data: []const u8, header: WavHeader) ![]f32 {
    const bytes_per_sample = header.channels * 2; // 16-bit
    const n_samples = header.data_size / bytes_per_sample;
    const result = try allocator.alloc(f32, n_samples);
    errdefer allocator.free(result);

    const pcm_data = data[header.data_start..];
    for (result, 0..) |*sample, idx| {
        const byte_offset = idx * bytes_per_sample;
        if (byte_offset + 2 > pcm_data.len) break;
        const raw = std.mem.readInt(i16, pcm_data[byte_offset..][0..2], .little);
        sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    return result;
}

/// Compute RMS (root mean square) for a single channel from interleaved S16_LE PCM.
/// Returns a normalized value in [0, 1].
pub fn channelRms(pcm_bytes: []const u8, num_channels: u16, channel: u16) f64 {
    if (num_channels == 0) return 0;
    const bytes_per_sample: usize = 2; // S16_LE
    const frame_size = @as(usize, num_channels) * bytes_per_sample;
    const n_frames = pcm_bytes.len / frame_size;
    if (n_frames == 0) return 0;

    var sum_sq: f64 = 0;
    for (0..n_frames) |i| {
        const offset = i * frame_size + @as(usize, channel) * bytes_per_sample;
        if (offset + 2 > pcm_bytes.len) break;
        const raw = std.mem.readInt(i16, pcm_bytes[offset..][0..2], .little);
        const norm: f64 = @as(f64, @floatFromInt(raw)) / 32768.0;
        sum_sq += norm * norm;
    }
    return @sqrt(sum_sq / @as(f64, @floatFromInt(n_frames)));
}

/// Convert RMS to decibels. Returns -100 for silence.
pub fn rmsToDb(rms: f64) f64 {
    if (rms < 1e-10) return -100;
    return 20.0 * @log10(rms);
}

/// Write a RIFF/WAVE file (16kHz mono S16_LE PCM).
/// Inverse of parseWavHeader(). Takes any writer for testability.
pub fn writeWav(writer: anytype, pcm_bytes: []const u8) !void {
    const data_size: u32 = @intCast(pcm_bytes.len);
    const file_size: u32 = 36 + data_size;
    // RIFF header
    try writer.writeAll("RIFF");
    try writer.writeInt(u32, file_size, .little);
    try writer.writeAll("WAVE");
    // fmt chunk (16kHz, mono, 16-bit PCM)
    try writer.writeAll("fmt ");
    try writer.writeInt(u32, 16, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u32, 16000, .little);
    try writer.writeInt(u32, 32000, .little);
    try writer.writeInt(u16, 2, .little);
    try writer.writeInt(u16, 16, .little);
    // data chunk
    try writer.writeAll("data");
    try writer.writeInt(u32, data_size, .little);
    try writer.writeAll(pcm_bytes);
}

// ============================================================
// Tests
// ============================================================

test "countWords: empty string" {
    try std.testing.expectEqual(@as(usize, 0), countWords(""));
}

test "countWords: single word" {
    try std.testing.expectEqual(@as(usize, 1), countWords("hello"));
}

test "countWords: multiple words" {
    try std.testing.expectEqual(@as(usize, 4), countWords("the quick brown fox"));
}

test "countWords: leading and trailing spaces" {
    try std.testing.expectEqual(@as(usize, 2), countWords("  hello world  "));
}

test "countWords: multiple spaces between words" {
    try std.testing.expectEqual(@as(usize, 3), countWords("one   two   three"));
}

test "countWords: only spaces" {
    try std.testing.expectEqual(@as(usize, 0), countWords("     "));
}

test "byteOffsetAfterWords: n=0 returns 0" {
    try std.testing.expectEqual(@as(usize, 0), byteOffsetAfterWords("hello world", 0));
}

test "byteOffsetAfterWords: n=1 past first word" {
    try std.testing.expectEqual(@as(usize, 5), byteOffsetAfterWords("hello world", 1));
}

test "byteOffsetAfterWords: n=2 past second word" {
    try std.testing.expectEqual(@as(usize, 11), byteOffsetAfterWords("hello world", 2));
}

test "byteOffsetAfterWords: n exceeds words returns text.len" {
    try std.testing.expectEqual(@as(usize, 5), byteOffsetAfterWords("hello", 5));
}

test "byteOffsetAfterWords: leading spaces" {
    // "  hello world" — skip 2 spaces, "hello" is chars 2..7
    try std.testing.expectEqual(@as(usize, 7), byteOffsetAfterWords("  hello world", 1));
}

test "byteOffsetAfterWords: empty string" {
    try std.testing.expectEqual(@as(usize, 0), byteOffsetAfterWords("", 1));
}

test "wordDelta: skip 0 returns full text" {
    try std.testing.expectEqualStrings("hello world", wordDelta("hello world", 0));
}

test "wordDelta: skip 1 returns from second word" {
    try std.testing.expectEqualStrings(" world", wordDelta("hello world", 1));
}

test "wordDelta: skip all returns empty" {
    try std.testing.expectEqualStrings("", wordDelta("hello world", 2));
}

test "wordDelta: skip more than total returns empty" {
    try std.testing.expectEqualStrings("", wordDelta("hello", 5));
}

test "textPreview: short text unchanged" {
    try std.testing.expectEqualStrings("hello", textPreview("hello"));
}

test "textPreview: exactly 60 chars unchanged" {
    const s = "a" ** 60;
    try std.testing.expectEqual(@as(usize, 60), textPreview(s).len);
}

test "textPreview: long text truncated to 60" {
    const s = "a" ** 100;
    try std.testing.expectEqual(@as(usize, 60), textPreview(s).len);
}

test "textPreview: empty string" {
    try std.testing.expectEqualStrings("", textPreview(""));
}

test "trimBuffer: smaller than keep is no-op" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &[_]u8{ 1, 2, 3, 4 });
    trimBuffer(&buf, 10);
    try std.testing.expectEqual(@as(usize, 4), buf.items.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, buf.items);
}

test "trimBuffer: trims to keep_bytes" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    // 10 bytes, keep 4
    try buf.appendSlice(allocator, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });
    trimBuffer(&buf, 4);
    try std.testing.expectEqual(@as(usize, 4), buf.items.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 6, 7, 8, 9 }, buf.items);
}

test "trimBuffer: aligns to 2-byte sample boundary" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    // 7 bytes, keep 4 → trim=3, but aligned to even → trim=2, remaining=5
    try buf.appendSlice(allocator, &[_]u8{ 0, 1, 2, 3, 4, 5, 6 });
    trimBuffer(&buf, 4);
    try std.testing.expectEqual(@as(usize, 5), buf.items.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 3, 4, 5, 6 }, buf.items);
}

test "trimBuffer: equal to keep is no-op" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &[_]u8{ 1, 2, 3, 4 });
    trimBuffer(&buf, 4);
    try std.testing.expectEqual(@as(usize, 4), buf.items.len);
}

test "pcmToFloat: silence (zeros)" {
    const allocator = std.testing.allocator;
    const pcm = [_]u8{ 0, 0, 0, 0 }; // two zero samples
    const result = try pcmToFloat(allocator, &pcm);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[1], 1e-6);
}

test "pcmToFloat: max positive" {
    const allocator = std.testing.allocator;
    // 32767 in little-endian = 0xFF, 0x7F
    const pcm = [_]u8{ 0xFF, 0x7F };
    const result = try pcmToFloat(allocator, &pcm);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectApproxEqAbs(@as(f32, 32767.0 / 32768.0), result[0], 1e-6);
}

test "pcmToFloat: max negative" {
    const allocator = std.testing.allocator;
    // -32768 in little-endian = 0x00, 0x80
    const pcm = [_]u8{ 0x00, 0x80 };
    const result = try pcmToFloat(allocator, &pcm);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), result[0], 1e-6);
}

test "pcmToFloat: known value" {
    const allocator = std.testing.allocator;
    // 16384 in little-endian = 0x00, 0x40
    const pcm = [_]u8{ 0x00, 0x40 };
    const result = try pcmToFloat(allocator, &pcm);
    defer allocator.free(result);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result[0], 1e-4);
}

test "pcmToFloat: empty input" {
    const allocator = std.testing.allocator;
    const result = try pcmToFloat(allocator, &[_]u8{});
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "pcmToFloat: odd byte count truncates" {
    const allocator = std.testing.allocator;
    // 3 bytes → only 1 complete sample
    const pcm = [_]u8{ 0, 0, 0xFF };
    const result = try pcmToFloat(allocator, &pcm);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0], 1e-6);
}

// --- isBlankOrPunct tests ---

test "isBlankOrPunct: space" {
    try std.testing.expect(isBlankOrPunct(" "));
}

test "isBlankOrPunct: comma" {
    try std.testing.expect(isBlankOrPunct(","));
}

test "isBlankOrPunct: period" {
    try std.testing.expect(isBlankOrPunct("."));
}

test "isBlankOrPunct: empty string" {
    try std.testing.expect(isBlankOrPunct(""));
}

test "isBlankOrPunct: actual word" {
    try std.testing.expect(!isBlankOrPunct("hello"));
}

test "isBlankOrPunct: two-char punct rejected (len > 1)" {
    try std.testing.expect(!isBlankOrPunct(".."));
}

test "isBlankOrPunct: word starting with space" {
    try std.testing.expect(!isBlankOrPunct(" the"));
}

// --- stripTrailingPunct tests ---

test "stripTrailingPunct: no punctuation" {
    try std.testing.expectEqualStrings("hello", stripTrailingPunct("hello"));
}

test "stripTrailingPunct: single period" {
    try std.testing.expectEqualStrings("loop", stripTrailingPunct("loop."));
}

test "stripTrailingPunct: comma" {
    try std.testing.expectEqualStrings("so", stripTrailingPunct("so,"));
}

test "stripTrailingPunct: multiple punct" {
    try std.testing.expectEqualStrings("what", stripTrailingPunct("what?!"));
}

test "stripTrailingPunct: all punct" {
    try std.testing.expectEqualStrings("", stripTrailingPunct("..."));
}

test "stripTrailingPunct: empty string" {
    try std.testing.expectEqualStrings("", stripTrailingPunct(""));
}

test "stripTrailingPunct: mid-word punct preserved" {
    try std.testing.expectEqualStrings("don't", stripTrailingPunct("don't"));
}

test "stripTrailingPunct: semicolon and colon" {
    try std.testing.expectEqualStrings("note", stripTrailingPunct("note;"));
    try std.testing.expectEqualStrings("step", stripTrailingPunct("step:"));
}

// --- wordsMatchForDedup tests ---

test "wordsMatchForDedup: identical" {
    try std.testing.expect(wordsMatchForDedup("loop", "loop"));
}

test "wordsMatchForDedup: punct difference" {
    try std.testing.expect(wordsMatchForDedup("loop.", "loop"));
    try std.testing.expect(wordsMatchForDedup("loop", "loop."));
}

test "wordsMatchForDedup: case difference" {
    try std.testing.expect(wordsMatchForDedup("So", "so"));
    try std.testing.expect(wordsMatchForDedup("AND", "and"));
}

test "wordsMatchForDedup: case and punct" {
    try std.testing.expect(wordsMatchForDedup("So,", "so"));
    try std.testing.expect(wordsMatchForDedup("Good.", "good"));
}

test "wordsMatchForDedup: different words" {
    try std.testing.expect(!wordsMatchForDedup("loop", "look"));
    try std.testing.expect(!wordsMatchForDedup("the", "they"));
}

test "wordsMatchForDedup: empty strings" {
    try std.testing.expect(wordsMatchForDedup("", ""));
    // All-punct matches empty
    try std.testing.expect(wordsMatchForDedup("...", ""));
}

// --- findTimedStableCount tests ---

test "findTimedStableCount: identical words" {
    const words = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
        .{ .text_start = 4, .text_end = 7, .frame = 20 },
        .{ .text_start = 8, .text_end = 11, .frame = 30 },
    };
    try std.testing.expectEqual(@as(usize, 3), findTimedStableCount(&words, &words, 0));
}

test "findTimedStableCount: within tolerance" {
    const prev = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
        .{ .text_start = 4, .text_end = 7, .frame = 20 },
    };
    const curr = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 12 },
        .{ .text_start = 4, .text_end = 7, .frame = 24 },
    };
    try std.testing.expectEqual(@as(usize, 2), findTimedStableCount(&prev, &curr, 5));
}

test "findTimedStableCount: outside tolerance" {
    const prev = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
    };
    const curr = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 20 },
    };
    try std.testing.expectEqual(@as(usize, 0), findTimedStableCount(&prev, &curr, 5));
}

test "findTimedStableCount: stops at first unstable" {
    const prev = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
        .{ .text_start = 4, .text_end = 7, .frame = 100 },
        .{ .text_start = 8, .text_end = 11, .frame = 30 },
    };
    const curr = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
        .{ .text_start = 4, .text_end = 7, .frame = 20 },
        .{ .text_start = 8, .text_end = 11, .frame = 30 },
    };
    try std.testing.expectEqual(@as(usize, 1), findTimedStableCount(&prev, &curr, 5));
}

test "findTimedStableCount: empty prev" {
    const curr = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
    };
    try std.testing.expectEqual(@as(usize, 0), findTimedStableCount(&.{}, &curr, 5));
}

test "findTimedStableCount: empty curr" {
    const prev = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
    };
    try std.testing.expectEqual(@as(usize, 0), findTimedStableCount(&prev, &.{}, 5));
}

test "findTimedStableCount: tolerance zero requires exact match" {
    const prev = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
    };
    const curr_exact = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
    };
    const curr_off = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 11 },
    };
    try std.testing.expectEqual(@as(usize, 1), findTimedStableCount(&prev, &curr_exact, 0));
    try std.testing.expectEqual(@as(usize, 0), findTimedStableCount(&prev, &curr_off, 0));
}

test "findTimedStableCount: matches any prev word not just positional" {
    // curr[0] at frame 50 matches prev[2] at frame 50 (not positional)
    const prev = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 10 },
        .{ .text_start = 4, .text_end = 7, .frame = 30 },
        .{ .text_start = 8, .text_end = 11, .frame = 50 },
    };
    const curr = [_]TimedWord{
        .{ .text_start = 0, .text_end = 3, .frame = 50 },
        .{ .text_start = 4, .text_end = 7, .frame = 60 },
    };
    // curr[0] frame=50 matches prev[2] frame=50 → stable
    // curr[1] frame=60 no match (closest is 50, diff=10 > 5) → unstable
    try std.testing.expectEqual(@as(usize, 1), findTimedStableCount(&prev, &curr, 5));
}

// --- parseWavHeader tests ---

fn makeMinimalWav(comptime data_size: u32) [44]u8 {
    var wav: [44]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 36 + data_size, .little); // file size - 8
    @memcpy(wav[8..12], "WAVE");
    // fmt chunk
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little); // chunk size
    std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM format
    std.mem.writeInt(u16, wav[22..24], 1, .little); // mono
    std.mem.writeInt(u32, wav[24..28], 16000, .little); // sample rate
    std.mem.writeInt(u32, wav[28..32], 32000, .little); // byte rate
    std.mem.writeInt(u16, wav[32..34], 2, .little); // block align
    std.mem.writeInt(u16, wav[34..36], 16, .little); // bits per sample
    // data chunk
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], data_size, .little);
    // zwanzig-disable-next-line: stack-escape-engine
    return wav;
}

test "parseWavHeader: valid minimal WAV" {
    const wav = makeMinimalWav(0);
    const header = try parseWavHeader(&wav);
    try std.testing.expectEqual(@as(u16, 1), header.channels);
    try std.testing.expectEqual(@as(usize, 44), header.data_start);
    try std.testing.expectEqual(@as(u32, 0), header.data_size);
}

test "parseWavHeader: valid WAV with data" {
    const wav = makeMinimalWav(100);
    const header = try parseWavHeader(&wav);
    try std.testing.expectEqual(@as(u32, 100), header.data_size);
}

test "parseWavHeader: too small" {
    const wav = [_]u8{ 'R', 'I', 'F', 'F' };
    try std.testing.expectError(error.InvalidWavFile, parseWavHeader(&wav));
}

test "parseWavHeader: wrong RIFF magic" {
    var wav = makeMinimalWav(0);
    @memcpy(wav[0..4], "XXXX");
    try std.testing.expectError(error.InvalidWavFile, parseWavHeader(&wav));
}

test "parseWavHeader: wrong WAVE magic" {
    var wav = makeMinimalWav(0);
    @memcpy(wav[8..12], "XXXX");
    try std.testing.expectError(error.InvalidWavFile, parseWavHeader(&wav));
}

test "parseWavHeader: non-PCM format rejected" {
    var wav = makeMinimalWav(0);
    std.mem.writeInt(u16, wav[20..22], 3, .little); // IEEE float, not PCM
    try std.testing.expectError(error.UnsupportedWavFormat, parseWavHeader(&wav));
}

test "parseWavHeader: 8-bit samples rejected" {
    var wav = makeMinimalWav(0);
    std.mem.writeInt(u16, wav[34..36], 8, .little); // 8-bit
    try std.testing.expectError(error.UnsupportedWavFormat, parseWavHeader(&wav));
}

test "parseWavHeader: stereo parsed correctly" {
    var wav = makeMinimalWav(0);
    std.mem.writeInt(u16, wav[22..24], 2, .little); // stereo
    const header = try parseWavHeader(&wav);
    try std.testing.expectEqual(@as(u16, 2), header.channels);
}

// --- wavToFloat tests ---

test "wavToFloat: mono samples" {
    const allocator = std.testing.allocator;
    var wav_data: [48]u8 = undefined;
    const header_bytes = makeMinimalWav(4);
    @memcpy(wav_data[0..44], &header_bytes);
    // Two mono samples: 0, 16384 (0.5)
    std.mem.writeInt(i16, wav_data[44..46], 0, .little);
    std.mem.writeInt(i16, wav_data[46..48], 16384, .little);
    const header = try parseWavHeader(&wav_data);
    const samples = try wavToFloat(allocator, &wav_data, header);
    defer allocator.free(samples);
    try std.testing.expectEqual(@as(usize, 2), samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), samples[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), samples[1], 1e-4);
}

test "wavToFloat: stereo reads first channel" {
    const allocator = std.testing.allocator;
    var wav_data: [52]u8 = undefined;
    var header_bytes = makeMinimalWav(8);
    std.mem.writeInt(u16, header_bytes[22..24], 2, .little); // stereo
    @memcpy(wav_data[0..44], &header_bytes);
    // Two stereo frames: L=16384 R=-16384, L=0 R=0
    std.mem.writeInt(i16, wav_data[44..46], 16384, .little); // L
    std.mem.writeInt(i16, wav_data[46..48], -16384, .little); // R (ignored)
    std.mem.writeInt(i16, wav_data[48..50], 0, .little); // L
    std.mem.writeInt(i16, wav_data[50..52], 32767, .little); // R (ignored)
    const header = try parseWavHeader(&wav_data);
    const samples = try wavToFloat(allocator, &wav_data, header);
    defer allocator.free(samples);
    try std.testing.expectEqual(@as(usize, 2), samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), samples[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), samples[1], 1e-6);
}

// --- channelRms tests ---

test "channelRms: silence is zero" {
    const pcm = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }; // 4 mono frames of silence
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), channelRms(&pcm, 1, 0), 1e-10);
}

test "channelRms: max amplitude" {
    // 2 mono frames: +32767, -32767
    var pcm: [4]u8 = undefined;
    std.mem.writeInt(i16, pcm[0..2], 32767, .little);
    std.mem.writeInt(i16, pcm[2..4], -32767, .little);
    const rms = channelRms(&pcm, 1, 0);
    // 32767/32768 ≈ 0.99997, RMS of identical magnitude = same value
    try std.testing.expectApproxEqAbs(@as(f64, 32767.0 / 32768.0), rms, 1e-4);
}

test "channelRms: stereo picks correct channel" {
    // 2 stereo frames: L=16384 R=0, L=16384 R=0
    var pcm: [8]u8 = undefined;
    std.mem.writeInt(i16, pcm[0..2], 16384, .little); // L
    std.mem.writeInt(i16, pcm[2..4], 0, .little); // R
    std.mem.writeInt(i16, pcm[4..6], 16384, .little); // L
    std.mem.writeInt(i16, pcm[6..8], 0, .little); // R
    // Channel 0 (L) should have RMS = 0.5
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), channelRms(&pcm, 2, 0), 1e-4);
    // Channel 1 (R) should be silent
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), channelRms(&pcm, 2, 1), 1e-10);
}

test "channelRms: empty input" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), channelRms(&.{}, 1, 0), 1e-10);
}

test "channelRms: zero channels returns zero" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), channelRms(&[_]u8{ 0, 0 }, 0, 0), 1e-10);
}

// --- rmsToDb tests ---

test "rmsToDb: silence" {
    try std.testing.expectApproxEqAbs(@as(f64, -100.0), rmsToDb(0.0), 1e-10);
}

test "rmsToDb: full scale" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), rmsToDb(1.0), 1e-10);
}

test "rmsToDb: half amplitude is about -6dB" {
    try std.testing.expectApproxEqAbs(@as(f64, -6.0206), rmsToDb(0.5), 0.001);
}

test "rmsToDb: monotonically increasing" {
    try std.testing.expect(rmsToDb(0.1) < rmsToDb(0.5));
    try std.testing.expect(rmsToDb(0.5) < rmsToDb(1.0));
}

// --- writeWav tests ---

test "writeWav: roundtrip with parseWavHeader" {
    var buf: [148]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const pcm = [_]u8{ 0x00, 0x40, 0xFF, 0x7F }; // 16384, 32767 as S16_LE
    try writeWav(fbs.writer(), &pcm);
    const written = fbs.getWritten();
    const header = try parseWavHeader(written);
    try std.testing.expectEqual(@as(u16, 1), header.channels);
    try std.testing.expectEqual(@as(usize, 44), header.data_start);
    try std.testing.expectEqual(@as(u32, 4), header.data_size);
    try std.testing.expectEqualSlices(u8, &pcm, written[44..48]);
}

test "writeWav: empty PCM produces valid header" {
    var buf: [44]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeWav(fbs.writer(), &[_]u8{});
    const written = fbs.getWritten();
    try std.testing.expectEqual(@as(usize, 44), written.len);
    const header = try parseWavHeader(written);
    try std.testing.expectEqual(@as(u32, 0), header.data_size);
}

test "writeWav: header fields correct" {
    var buf: [48]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeWav(fbs.writer(), &[_]u8{ 0, 0, 0, 0 });
    const w = fbs.getWritten();
    try std.testing.expectEqualStrings("RIFF", w[0..4]);
    try std.testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, w[4..8], .little));
    try std.testing.expectEqualStrings("WAVE", w[8..12]);
    try std.testing.expectEqual(@as(u32, 16000), std.mem.readInt(u32, w[24..28], .little));
    try std.testing.expectEqual(@as(u32, 32000), std.mem.readInt(u32, w[28..32], .little));
}
