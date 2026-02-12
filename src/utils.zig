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

/// Strip trailing punctuation from a word for comparison purposes.
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

/// Case-insensitive byte comparison for ASCII text.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Count how many leading words are stable (present in both a and b).
/// Words are compared case-insensitively after stripping trailing punctuation.
pub fn stableWordCount(a: []const u8, b: []const u8) usize {
    var ia: usize = 0;
    var ib: usize = 0;
    var stable: usize = 0;

    while (ia < a.len and ib < b.len) {
        // skip spaces
        while (ia < a.len and a[ia] == ' ') : (ia += 1) {}
        while (ib < b.len and b[ib] == ' ') : (ib += 1) {}
        if (ia >= a.len or ib >= b.len) break;

        // extract word
        const wa_start = ia;
        while (ia < a.len and a[ia] != ' ') : (ia += 1) {}
        const wb_start = ib;
        while (ib < b.len and b[ib] != ' ') : (ib += 1) {}

        const wa = stripTrailingPunct(a[wa_start..ia]);
        const wb = stripTrailingPunct(b[wb_start..ib]);

        if (!eqlIgnoreCase(wa, wb)) break;
        stable += 1;
    }

    return stable;
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

/// Result of the flexible stability matching algorithm.
pub const StabilityResult = struct {
    stable_words: usize,
    prev_skip: usize,
};

/// Find stable words between prev and current transcription, accounting for
/// sliding window shifts. When the audio buffer is trimmed from the front,
/// the new transcription loses leading words that prev still has. This tries
/// small offsets (skip 1-6 words from prev) to find alignment.
pub fn findStableWords(prev_text: []const u8, text: []const u8, emitted_words: usize) StabilityResult {
    var stable_words = stableWordCount(prev_text, text);
    var prev_skip: usize = 0;

    if (stable_words <= emitted_words) {
        for (1..7) |skip| {
            const offset = byteOffsetAfterWords(prev_text, skip);
            if (offset >= prev_text.len) break;
            const shifted = stableWordCount(prev_text[offset..], text);
            if (shifted >= 3) {
                stable_words = shifted;
                prev_skip = skip;
                break;
            }
        }
    }

    return .{ .stable_words = stable_words, .prev_skip = prev_skip };
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

test "stripTrailingPunct: no punctuation" {
    try std.testing.expectEqualStrings("hello", stripTrailingPunct("hello"));
}

test "stripTrailingPunct: single comma" {
    try std.testing.expectEqualStrings("hello", stripTrailingPunct("hello,"));
}

test "stripTrailingPunct: multiple punctuation" {
    try std.testing.expectEqualStrings("hello", stripTrailingPunct("hello..."));
}

test "stripTrailingPunct: all punctuation" {
    try std.testing.expectEqualStrings("", stripTrailingPunct("!?."));
}

test "stripTrailingPunct: empty string" {
    try std.testing.expectEqualStrings("", stripTrailingPunct(""));
}

test "stripTrailingPunct: mixed ending" {
    try std.testing.expectEqualStrings("ok", stripTrailingPunct("ok?!"));
}

test "eqlIgnoreCase: identical" {
    try std.testing.expect(eqlIgnoreCase("hello", "hello"));
}

test "eqlIgnoreCase: different case" {
    try std.testing.expect(eqlIgnoreCase("Hello", "hello"));
    try std.testing.expect(eqlIgnoreCase("HELLO", "hello"));
}

test "eqlIgnoreCase: different strings" {
    try std.testing.expect(!eqlIgnoreCase("hello", "world"));
}

test "eqlIgnoreCase: different lengths" {
    try std.testing.expect(!eqlIgnoreCase("hello", "hell"));
}

test "eqlIgnoreCase: empty strings" {
    try std.testing.expect(eqlIgnoreCase("", ""));
}

test "stableWordCount: identical texts" {
    try std.testing.expectEqual(@as(usize, 3), stableWordCount("one two three", "one two three"));
}

test "stableWordCount: same words different punctuation" {
    try std.testing.expectEqual(@as(usize, 2), stableWordCount("hello, world.", "hello world"));
}

test "stableWordCount: same words different case" {
    try std.testing.expectEqual(@as(usize, 2), stableWordCount("Ask not", "ask not"));
}

test "stableWordCount: diverge at word 2" {
    try std.testing.expectEqual(@as(usize, 2), stableWordCount("one two three", "one two four"));
}

test "stableWordCount: first word differs" {
    try std.testing.expectEqual(@as(usize, 0), stableWordCount("hello world", "goodbye world"));
}

test "stableWordCount: empty strings" {
    try std.testing.expectEqual(@as(usize, 0), stableWordCount("", ""));
}

test "stableWordCount: one empty" {
    try std.testing.expectEqual(@as(usize, 0), stableWordCount("hello", ""));
    try std.testing.expectEqual(@as(usize, 0), stableWordCount("", "hello"));
}

test "stableWordCount: b longer than a" {
    try std.testing.expectEqual(@as(usize, 2), stableWordCount("one two", "one two three four"));
}

test "stableWordCount: a longer than b" {
    try std.testing.expectEqual(@as(usize, 2), stableWordCount("one two three four", "one two"));
}

test "stableWordCount: punctuation on different words" {
    // "so" vs "so," — trailing punct stripped
    try std.testing.expectEqual(@as(usize, 3), stableWordCount("and so it", "and so, it"));
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

// --- findStableWords tests ---

test "findStableWords: identical, no prior emission" {
    const r = findStableWords("one two three", "one two three", 0);
    try std.testing.expectEqual(@as(usize, 3), r.stable_words);
    try std.testing.expectEqual(@as(usize, 0), r.prev_skip);
}

test "findStableWords: stable exceeds emitted, no offset needed" {
    const r = findStableWords("one two three", "one two three four", 1);
    try std.testing.expectEqual(@as(usize, 3), r.stable_words);
    try std.testing.expectEqual(@as(usize, 0), r.prev_skip);
}

test "findStableWords: sliding window shift needs offset" {
    // prev had "alpha one two three", new text lost "alpha" due to trim.
    // emitted_words=4, direct stableWordCount("alpha one two three", "one two three")=0
    // With skip=1: stableWordCount("one two three", "one two three")=3 (>=3) → found
    const r = findStableWords("alpha one two three", "one two three", 4);
    try std.testing.expectEqual(@as(usize, 3), r.stable_words);
    try std.testing.expectEqual(@as(usize, 1), r.prev_skip);
}

test "findStableWords: larger offset" {
    // prev had "a b c one two three", new lost "a b c" (3 words trimmed).
    // emitted=6, direct stable=0. skip=3: "one two three" vs "one two three" = 3 → found
    const r = findStableWords("a b c one two three", "one two three", 6);
    try std.testing.expectEqual(@as(usize, 3), r.stable_words);
    try std.testing.expectEqual(@as(usize, 3), r.prev_skip);
}

test "findStableWords: no alignment possible" {
    // Completely different text — no offset will help
    const r = findStableWords("hello world foo bar", "something completely different xyz", 4);
    try std.testing.expectEqual(@as(usize, 0), r.stable_words);
    try std.testing.expectEqual(@as(usize, 0), r.prev_skip);
}

test "findStableWords: offset needed but fewer than 3 stable" {
    // After skip, only 2 stable words — below the threshold of 3
    const r = findStableWords("alpha one two xyz", "one two abc", 3);
    // Direct: stable=0. skip=1: "one two xyz" vs "one two abc" = 2 (<3, skip).
    // No offset produces >=3 stable, so falls through with original values.
    try std.testing.expectEqual(@as(usize, 0), r.stable_words);
    try std.testing.expectEqual(@as(usize, 0), r.prev_skip);
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
