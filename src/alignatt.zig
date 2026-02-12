const std = @import("std");

/// AlignAtt streaming policy parameters.
pub const Config = struct {
    frame_threshold: usize = 25, // stop if attention within this many frames of audio end
    rewind_threshold: usize = 200, // discard if attention jumps back this far
    median_filter_width: usize = 7,
};

/// Result of analyzing cross-attention after a decode step.
pub const AttentionResult = struct {
    most_attended_frame: usize,
};

/// Decision after checking attention.
pub const Decision = enum {
    continue_decoding,
    stop_attention_at_end, // attention reached end — strip last token and stop
    rewind_detected, // attention jumped backwards — discard segment
};

/// Analyze cross-attention data for the last decoded token.
///
/// attn_data layout: [n_heads][n_audio_ctx][n_tokens] (C-contiguous)
/// content_frames: number of actual audio frames (excluding padding)
/// last_attend_frame: the previous token's most-attended frame (-1 if first token)
///
/// Returns the most attended frame for the last token (after z-score + median + avg heads).
pub fn analyzeAttention(
    allocator: std.mem.Allocator,
    attn_data: [*]const f32,
    n_tokens: usize,
    n_audio_ctx: usize,
    n_heads: usize,
    config: Config,
) ![]f32 {
    // Extract last token's attention for each head: [n_heads][n_audio_ctx]
    const last_token_idx = n_tokens - 1;

    // Working buffer: [n_heads][n_audio_ctx]
    const buf = try allocator.alloc(f32, n_heads * n_audio_ctx);
    errdefer allocator.free(buf);

    // Extract and z-score normalize per head
    for (0..n_heads) |head| {
        const head_offset = head * n_audio_ctx * n_tokens;

        // Extract last token's attention for this head
        for (0..n_audio_ctx) |frame| {
            buf[head * n_audio_ctx + frame] = attn_data[head_offset + frame * n_tokens + last_token_idx];
        }

        // Z-score normalize this head
        const slice = buf[head * n_audio_ctx ..][0..n_audio_ctx];
        var sum: f64 = 0;
        for (slice) |v| sum += v;
        const mean: f32 = @floatCast(sum / @as(f64, @floatFromInt(n_audio_ctx)));

        var var_sum: f64 = 0;
        for (slice) |v| {
            const d = v - mean;
            var_sum += d * d;
        }
        const std_dev: f32 = @sqrt(@as(f32, @floatCast(var_sum / @as(f64, @floatFromInt(n_audio_ctx)))));

        if (std_dev > 1e-9) {
            for (slice) |*v| {
                v.* = (v.* - mean) / std_dev;
            }
        }
    }

    // Median filter per head (window = config.median_filter_width)
    if (config.median_filter_width > 1) {
        const half = config.median_filter_width / 2;
        const out = try allocator.alloc(f32, n_audio_ctx);
        defer allocator.free(out);
        const window_buf = try allocator.alloc(f32, config.median_filter_width);
        defer allocator.free(window_buf);

        for (0..n_heads) |head| {
            const slice = buf[head * n_audio_ctx ..][0..n_audio_ctx];

            for (0..n_audio_ctx) |frame| {
                const start = if (frame >= half) frame - half else 0;
                const end = @min(frame + half + 1, n_audio_ctx);
                const wlen = end - start;

                @memcpy(window_buf[0..wlen], slice[start..end]);
                std.mem.sort(f32, window_buf[0..wlen], {}, std.sort.asc(f32));

                out[frame] = if (wlen % 2 == 1)
                    window_buf[wlen / 2]
                else
                    (window_buf[wlen / 2 - 1] + window_buf[wlen / 2]) / 2.0;
            }

            @memcpy(slice, out[0..n_audio_ctx]);
        }
    }

    // Average across heads → [n_audio_ctx]
    const result = try allocator.alloc(f32, n_audio_ctx);
    errdefer allocator.free(result);
    const inv_heads: f32 = 1.0 / @as(f32, @floatFromInt(n_heads));

    for (0..n_audio_ctx) |frame| {
        var avg: f32 = 0;
        for (0..n_heads) |head| {
            avg += buf[head * n_audio_ctx + frame];
        }
        result[frame] = avg * inv_heads;
    }

    allocator.free(buf);
    return result;
}

/// Find the most-attended audio frame from averaged attention.
pub fn argmax(attention: []const f32) usize {
    var best_frame: usize = 0;
    var best_val: f32 = -std.math.inf(f32);
    for (attention, 0..) |v, i| {
        if (v > best_val) {
            best_val = v;
            best_frame = i;
        }
    }
    return best_frame;
}

/// Check the AlignAtt stopping conditions.
pub fn checkStopping(
    most_attended_frame: usize,
    content_frames: usize,
    last_attend_frame: ?usize,
    is_last: bool,
    config: Config,
) Decision {
    // Rewind detection: attention jumped backwards too far
    if (last_attend_frame) |last| {
        if (last > most_attended_frame and last - most_attended_frame > config.rewind_threshold) {
            return .rewind_detected;
        }
    }

    // Stopping rule: attention is close to end of audio
    const threshold = if (is_last) 4 else config.frame_threshold;
    if (content_frames > most_attended_frame and
        content_frames - most_attended_frame <= threshold)
    {
        return .stop_attention_at_end;
    }

    return .continue_decoding;
}

// ============================================================
// Tests
// ============================================================

test "argmax: basic" {
    const data = [_]f32{ 0.1, 0.5, 0.3, 0.2 };
    try std.testing.expectEqual(@as(usize, 1), argmax(&data));
}

test "argmax: single element" {
    const data = [_]f32{42.0};
    try std.testing.expectEqual(@as(usize, 0), argmax(&data));
}

test "argmax: last element is max" {
    const data = [_]f32{ 0.1, 0.2, 0.3, 0.9 };
    try std.testing.expectEqual(@as(usize, 3), argmax(&data));
}

test "argmax: negative values" {
    const data = [_]f32{ -5.0, -1.0, -3.0 };
    try std.testing.expectEqual(@as(usize, 1), argmax(&data));
}

test "checkStopping: continue when attention far from end" {
    const result = checkStopping(10, 100, null, false, .{});
    try std.testing.expectEqual(Decision.continue_decoding, result);
}

test "checkStopping: stop when attention near end (not is_last)" {
    // content_frames=100, most_attended=80, threshold=25 → 100-80=20 <= 25 → stop
    const result = checkStopping(80, 100, null, false, .{});
    try std.testing.expectEqual(Decision.stop_attention_at_end, result);
}

test "checkStopping: is_last uses threshold=4" {
    // content_frames=100, most_attended=80, threshold=4 → 100-80=20 > 4 → continue
    const result = checkStopping(80, 100, null, true, .{});
    try std.testing.expectEqual(Decision.continue_decoding, result);
}

test "checkStopping: is_last stops when very close to end" {
    // content_frames=100, most_attended=97, threshold=4 → 100-97=3 <= 4 → stop
    const result = checkStopping(97, 100, null, true, .{});
    try std.testing.expectEqual(Decision.stop_attention_at_end, result);
}

test "checkStopping: rewind detected" {
    // last=500, most_attended=100, diff=400 > rewind_threshold=200
    const result = checkStopping(100, 1000, 500, false, .{});
    try std.testing.expectEqual(Decision.rewind_detected, result);
}

test "checkStopping: small backward jump is not rewind" {
    // last=110, most_attended=100, diff=10 < rewind_threshold=200
    const result = checkStopping(100, 1000, 110, false, .{});
    try std.testing.expectEqual(Decision.continue_decoding, result);
}

test "checkStopping: forward movement is not rewind" {
    const result = checkStopping(200, 1000, 100, false, .{});
    try std.testing.expectEqual(Decision.continue_decoding, result);
}

test "analyzeAttention: single head identity peak" {
    const allocator = std.testing.allocator;
    const n_tokens: usize = 3;
    const n_audio_ctx: usize = 5;
    const n_heads: usize = 1;

    // Layout: [n_heads][n_audio_ctx][n_tokens]
    // We want the last token (idx=2) to have a strong peak at frame 2
    var attn_data: [n_heads * n_audio_ctx * n_tokens]f32 = undefined;
    @memset(&attn_data, 0);
    // Set last token attention: peak at frame 2
    attn_data[0 * n_audio_ctx * n_tokens + 0 * n_tokens + 2] = 0.0; // frame 0, token 2
    attn_data[0 * n_audio_ctx * n_tokens + 1 * n_tokens + 2] = 0.1; // frame 1, token 2
    attn_data[0 * n_audio_ctx * n_tokens + 2 * n_tokens + 2] = 1.0; // frame 2, token 2 (peak)
    attn_data[0 * n_audio_ctx * n_tokens + 3 * n_tokens + 2] = 0.1; // frame 3, token 2
    attn_data[0 * n_audio_ctx * n_tokens + 4 * n_tokens + 2] = 0.0; // frame 4, token 2

    const result = try analyzeAttention(
        allocator, &attn_data, n_tokens, n_audio_ctx, n_heads,
        .{ .median_filter_width = 1 }, // disable median filter for clarity
    );
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, n_audio_ctx), result.len);
    // After z-score normalization, frame 2 should still be the argmax
    try std.testing.expectEqual(@as(usize, 2), argmax(result));
}

test "analyzeAttention: two heads averaged" {
    const allocator = std.testing.allocator;
    const n_tokens: usize = 2;
    const n_audio_ctx: usize = 4;
    const n_heads: usize = 2;

    var attn_data: [n_heads * n_audio_ctx * n_tokens]f32 = undefined;
    @memset(&attn_data, 0);

    // Head 0: last token peaks at frame 1
    attn_data[0 * n_audio_ctx * n_tokens + 1 * n_tokens + 1] = 1.0;

    // Head 1: last token peaks at frame 1 (same)
    attn_data[1 * n_audio_ctx * n_tokens + 1 * n_tokens + 1] = 1.0;

    const result = try analyzeAttention(
        allocator, &attn_data, n_tokens, n_audio_ctx, n_heads,
        .{ .median_filter_width = 1 },
    );
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), argmax(result));
}
