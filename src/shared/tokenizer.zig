/// SentencePiece detokenizer for Nemotron RNNT.
///
/// Converts token IDs to text using a vocabulary loaded from tokens.txt.
/// The ▁ character (U+2581, bytes 0xE2 0x96 0x81) marks word boundaries
/// and is replaced with a space.
const std = @import("std");

pub const VOCAB_SIZE: usize = 1024;
pub const BLANK_ID: i32 = @intCast(VOCAB_SIZE);

pub const TokenMap = [VOCAB_SIZE + 1][]const u8;

/// Load token map from a tokens.txt file.
/// Format: "token_text token_id\n" per line (last space separates text from ID).
/// The returned slices point into `data` — caller must keep `data` alive.
pub fn loadTokenMap(data: []const u8) TokenMap {
    var map: TokenMap = undefined;
    for (&map) |*t| t.* = "";

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.lastIndexOfScalar(u8, line, ' ')) |sep| {
            const id = std.fmt.parseInt(usize, line[sep + 1 ..], 10) catch continue;
            if (id < map.len) map[id] = line[0..sep];
        }
    }

    return map;
}

/// Detokenize a single token: append its text to `out`, replacing ▁ with space.
pub fn detokenize(token_map: *const TokenMap, token_id: i32, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (token_id < 0 or token_id >= @as(i32, @intCast(token_map.len))) return;
    const tok_text = token_map[@intCast(token_id)];
    if (tok_text.len == 0) return;

    try out.ensureUnusedCapacity(allocator, tok_text.len);
    var i: usize = 0;
    while (i < tok_text.len) : (i += 1) {
        // ▁ (U+2581) = 0xE2 0x96 0x81 → replace with space
        if (i + 2 < tok_text.len and
            tok_text[i] == 0xe2 and tok_text[i + 1] == 0x96 and tok_text[i + 2] == 0x81)
        {
            out.appendAssumeCapacity(' ');
            i += 2; // loop increment adds 1 more
        } else {
            out.appendAssumeCapacity(tok_text[i]);
        }
    }
}

/// Detokenize a sequence of token IDs into a string.
pub fn detokenizeAll(token_map: *const TokenMap, tokens: []const i32, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    for (tokens) |tok| {
        try detokenize(token_map, tok, &out, allocator);
    }

    return out.toOwnedSlice(allocator);
}

/// Returns true if this token is punctuation-only (no letters/digits).
/// Used by context biasing to skip punctuation when advancing the trie,
/// so ", you know" still matches the phrase "you know".
pub fn isPunctuation(token_map: *const TokenMap, token_id: i32) bool {
    if (token_id < 0 or token_id >= @as(i32, @intCast(token_map.len))) return false;
    const text = token_map[@intCast(token_id)];
    if (text.len == 0) return false;
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch)) return false;
        // ▁ prefix bytes (0xE2 0x96 0x81) are not alphanumeric, that's fine
    }
    return true;
}

/// Tokenize a text string into SentencePiece token IDs using greedy longest-match.
/// Input text should be a plain phrase (e.g. "hello world"). The function prepends
/// ▁ to each word to match SentencePiece's word-initial convention, then greedily
/// matches the longest token at each position.
pub fn tokenize(token_map: *const TokenMap, text: []const u8, allocator: std.mem.Allocator) ![]i32 {
    // Build the ▁-prefixed representation: "hello world" → "▁hello ▁world"
    // In SentencePiece, ▁ replaces spaces and is prepended to the first word.
    var sp_text: std.ArrayListUnmanaged(u8) = .{};
    defer sp_text.deinit(allocator);

    // Prepend ▁ to the first word
    try sp_text.appendSlice(allocator, &.{ 0xe2, 0x96, 0x81 });
    for (text) |ch| {
        if (ch == ' ') {
            // Space → ▁ (word boundary)
            try sp_text.appendSlice(allocator, &.{ 0xe2, 0x96, 0x81 });
        } else {
            try sp_text.append(allocator, ch);
        }
    }

    // Greedy longest-match tokenization
    var tokens: std.ArrayListUnmanaged(i32) = .{};
    errdefer tokens.deinit(allocator);

    var pos: usize = 0;
    while (pos < sp_text.items.len) {
        var best_len: usize = 0;
        var best_id: i32 = -1;
        // Try all token lengths from longest to shortest
        const max_len = @min(sp_text.items.len - pos, 64); // cap token length
        for (0..VOCAB_SIZE) |id| {
            const tok = token_map[id];
            if (tok.len == 0 or tok.len > max_len) continue;
            if (tok.len > best_len and std.mem.eql(u8, sp_text.items[pos .. pos + tok.len], tok)) {
                best_len = tok.len;
                best_id = @intCast(id);
            }
        }
        if (best_len == 0) {
            // Unknown byte — skip it
            pos += 1;
        } else {
            try tokens.append(allocator, best_id);
            pos += best_len;
        }
    }

    return tokens.toOwnedSlice(allocator);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "detokenize ▁hello → ' hello'" {
    const allocator = std.testing.allocator;
    // ▁hello = 0xE2 0x96 0x81 'h' 'e' 'l' 'l' 'o'
    const tok_text = "\xe2\x96\x81hello";
    var map: TokenMap = undefined;
    for (&map) |*t| t.* = "";
    map[42] = tok_text;

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try detokenize(&map, 42, &out, allocator);

    try std.testing.expectEqualStrings(" hello", out.items);
}

test "detokenize continuation token (no ▁)" {
    const allocator = std.testing.allocator;
    var map: TokenMap = undefined;
    for (&map) |*t| t.* = "";
    map[10] = "tion";

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try detokenize(&map, 10, &out, allocator);

    try std.testing.expectEqualStrings("tion", out.items);
}

test "detokenize blank token → no output" {
    const allocator = std.testing.allocator;
    var map: TokenMap = undefined;
    for (&map) |*t| t.* = "";

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try detokenize(&map, BLANK_ID, &out, allocator);

    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "loadTokenMap parses correctly" {
    const data = "▁the 0\n▁a 1\ntion 2\n<blank> 1024\n";
    const map = loadTokenMap(data);

    try std.testing.expectEqualStrings("▁the", map[0]);
    try std.testing.expectEqualStrings("▁a", map[1]);
    try std.testing.expectEqualStrings("tion", map[2]);
    try std.testing.expectEqualStrings("<blank>", map[1024]);
}

test "detokenizeAll multiple tokens" {
    const allocator = std.testing.allocator;
    var map: TokenMap = undefined;
    for (&map) |*t| t.* = "";
    map[0] = "\xe2\x96\x81the";
    map[1] = "\xe2\x96\x81cat";

    const tokens = [_]i32{ 0, 1 };
    const text = try detokenizeAll(&map, &tokens, allocator);
    defer allocator.free(text);

    try std.testing.expectEqualStrings(" the cat", text);
}
