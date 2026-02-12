const std = @import("std");
const c = @cImport({
    @cInclude("whisper.h");
});
const Vad = @import("vad.zig").Vad;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var model_path: [:0]const u8 = "whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin";
    var audio_path: [:0]const u8 = "jfk.wav";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i < args.len) model_path = args[i];
        } else if (std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i < args.len) audio_path = args[i];
        } else {
            std.debug.print("Usage: whisper-dictate [--model PATH] [--file PATH]\n", .{});
            return;
        }
    }

    // Load audio
    std.debug.print("Loading audio: {s}\n", .{audio_path});
    const samples = try loadWav(allocator, audio_path);
    defer allocator.free(samples);
    std.debug.print("Loaded {d} samples ({d:.1}s)\n", .{ samples.len, @as(f64, @floatFromInt(samples.len)) / 16000.0 });

    // --- VAD test ---
    std.debug.print("\n--- VAD Test ---\n", .{});
    var vad = Vad.init("whisper.cpp/models/ggml-silero-v5.1.2.bin") catch |err| {
        std.debug.print("Failed to init VAD: {}\n", .{err});
        return;
    };
    defer vad.deinit();

    const has_speech = vad.hasSpeech(samples);
    std.debug.print("Has speech: {}\n", .{has_speech});

    const segments = vad.getSegments(samples) catch |err| {
        std.debug.print("Failed to get VAD segments: {}\n", .{err});
        return;
    };
    std.debug.print("Speech segments: {d}\n", .{segments.len});
    for (segments, 0..) |seg, si| {
        std.debug.print("  segment {d}: {d:.2}s - {d:.2}s\n", .{ si, seg.start_s, seg.end_s });
    }

    // --- Whisper test ---
    // Initialize whisper with DTW enabled (required for cross-attention capture)
    // flash_attn must be false — incompatible with DTW
    std.debug.print("\nLoading model: {s}\n", .{model_path});
    var cparams = c.whisper_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = false;
    cparams.dtw_token_timestamps = true;
    cparams.dtw_aheads_preset = c.WHISPER_AHEADS_LARGE_V3_TURBO;

    const ctx = c.whisper_init_from_file_with_params(model_path.ptr, cparams);
    if (ctx == null) {
        std.debug.print("Failed to load model\n", .{});
        return;
    }
    defer c.whisper_free(ctx);
    std.debug.print("Model loaded\n", .{});

    const state = c.whisper_init_state(ctx);
    if (state == null) {
        std.debug.print("Failed to init state\n", .{});
        return;
    }
    defer c.whisper_free_state(state);

    // Step 1: Convert PCM to mel spectrogram
    std.debug.print("Computing mel spectrogram...\n", .{});
    if (c.whisper_pcm_to_mel_with_state(ctx, state, samples.ptr, @intCast(samples.len), 4) != 0) {
        std.debug.print("whisper_pcm_to_mel_with_state() failed\n", .{});
        return;
    }

    // Step 2: Encode
    std.debug.print("Encoding...\n", .{});
    if (c.whisper_encode_with_state(ctx, state, 0, 4) != 0) {
        std.debug.print("whisper_encode_with_state() failed\n", .{});
        return;
    }

    // Step 3: Decode token by token with cross-attention capture
    // Build initial prompt: [sot, lang_en, transcribe, notimestamps]
    const sot = c.whisper_token_sot(ctx);
    const lang_en = c.whisper_token_lang(ctx, c.whisper_lang_id("en"));
    const transcribe = c.whisper_token_transcribe(ctx);
    const notimestamps = c.whisper_token_not(ctx);
    const eot = c.whisper_token_eot(ctx);
    const n_vocab = c.whisper_n_vocab(ctx);

    std.debug.print("Special tokens: sot={d}, lang_en={d}, transcribe={d}, notimestamps={d}, eot={d}\n", .{ sot, lang_en, transcribe, notimestamps, eot });

    // Decode the prompt tokens
    var prompt = [_]c.whisper_token{ sot, lang_en, transcribe, notimestamps };
    std.debug.print("Decoding prompt ({d} tokens)...\n", .{prompt.len});
    if (c.whisper_decode_with_state_and_aheads(ctx, state, &prompt, @intCast(prompt.len), 0, 4) != 0) {
        std.debug.print("whisper_decode_with_state_and_aheads() failed on prompt\n", .{});
        return;
    }

    // Generate tokens autoregressively
    var generated = std.ArrayListUnmanaged(c.whisper_token){};
    defer generated.deinit(allocator);

    const max_tokens: usize = 100;
    var n_past: c_int = @intCast(prompt.len);

    std.debug.print("\nGenerating tokens (max {d})...\n", .{max_tokens});

    for (0..max_tokens) |step| {
        // Get logits and sample greedily
        const logits = c.whisper_get_logits_from_state(state);
        if (logits == null) {
            std.debug.print("Failed to get logits\n", .{});
            break;
        }

        // Find argmax token (greedy)
        var best_token: c.whisper_token = 0;
        var best_logit: f32 = -std.math.inf(f32);
        for (0..@intCast(n_vocab)) |vi| {
            if (logits[vi] > best_logit) {
                best_logit = logits[vi];
                best_token = @intCast(vi);
            }
        }

        if (best_token == eot) {
            std.debug.print("  [{d}] EOT\n", .{step});
            break;
        }

        const token_str = c.whisper_token_to_str(ctx, best_token);
        if (token_str != null) {
            std.debug.print("  [{d}] token={d} \"{s}\"\n", .{ step, best_token, std.mem.span(token_str) });
        }

        try generated.append(allocator, best_token);

        // Decode next token with cross-attention capture
        var next_token = [_]c.whisper_token{best_token};
        if (c.whisper_decode_with_state_and_aheads(ctx, state, &next_token, 1, n_past, 4) != 0) {
            std.debug.print("whisper_decode_with_state_and_aheads() failed at step {d}\n", .{step});
            break;
        }
        n_past += 1;

        // Read cross-attention data
        var n_tokens_out: c_int = 0;
        var n_audio_ctx: c_int = 0;
        var n_heads: c_int = 0;
        const attn_data = c.whisper_state_get_aheads_cross_qks(state, &n_tokens_out, &n_audio_ctx, &n_heads);

        if (attn_data != null) {
            if (step == 0) {
                std.debug.print("  Cross-attention shape: [{d} tokens x {d} audio_ctx x {d} heads]\n", .{ n_tokens_out, n_audio_ctx, n_heads });
            }

            // For the last token, find the most-attended audio frame (argmax across averaged heads)
            const last_token_idx: usize = @intCast(n_tokens_out - 1);
            const audio_ctx: usize = @intCast(n_audio_ctx);
            const heads: usize = @intCast(n_heads);

            // Average attention across heads for last token, then argmax
            var best_frame: usize = 0;
            var best_attn: f32 = -std.math.inf(f32);
            for (0..audio_ctx) |frame| {
                var avg: f32 = 0;
                for (0..heads) |head| {
                    // Layout: [n_tokens][n_audio_ctx][n_heads] — but after transpose it's
                    // actually [n_tokens_out * n_audio_ctx * n_heads] with strides
                    const idx = head * audio_ctx * @as(usize, @intCast(n_tokens_out)) + frame * @as(usize, @intCast(n_tokens_out)) + last_token_idx;
                    avg += attn_data[idx];
                }
                avg /= @floatFromInt(heads);
                if (avg > best_attn) {
                    best_attn = avg;
                    best_frame = frame;
                }
            }
            std.debug.print("         attn -> frame {d}/{d} (attn={d:.4})\n", .{ best_frame, n_audio_ctx, best_attn });
        } else {
            std.debug.print("  WARNING: no cross-attention data available\n", .{});
        }
    }

    // Print full transcription
    std.debug.print("\n--- Full transcription ---\n", .{});
    for (generated.items) |token| {
        const text = c.whisper_token_to_str(ctx, token);
        if (text != null) {
            std.debug.print("{s}", .{std.mem.span(text)});
        }
    }
    std.debug.print("\n", .{});
}

/// Read a WAV file and return float32 samples normalized to [-1, 1].
fn loadWav(allocator: std.mem.Allocator, path: [:0]const u8) ![]f32 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // max 100MB
    defer allocator.free(data);

    if (data.len < 44) return error.InvalidWavFile;

    // RIFF header
    if (!std.mem.eql(u8, data[0..4], "RIFF")) return error.InvalidWavFile;
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return error.InvalidWavFile;

    // Parse chunks
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
            if (audio_format != 1) return error.UnsupportedWavFormat; // PCM only
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

    const bytes_per_sample = channels * (bits_per_sample / 8);
    const n_samples = data_size / bytes_per_sample;
    const samples = try allocator.alloc(f32, n_samples);
    errdefer allocator.free(samples);

    const pcm_data = data[data_start..];
    for (samples, 0..) |*sample, idx| {
        const byte_offset = idx * bytes_per_sample;
        if (byte_offset + 2 > pcm_data.len) break;
        const raw = std.mem.readInt(i16, pcm_data[byte_offset..][0..2], .little);
        sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    std.debug.print("WAV: {d}ch, {d}bit, {d} samples\n", .{ channels, bits_per_sample, n_samples });

    return samples;
}
