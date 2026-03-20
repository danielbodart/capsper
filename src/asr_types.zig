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
    tokens: []const i32, // whisper_token is i32; empty for non-whisper backends
    token_frames: []const usize, // per-token audio frame from cross-attention; empty for non-whisper
    was_rewind: bool,
    was_rate_limited: bool = false,
    timing: Timing,
};
