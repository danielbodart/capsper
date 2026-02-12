const std = @import("std");
const c = @cImport({
    @cInclude("whisper.h");
});

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

    // Initialize whisper
    std.debug.print("Loading model: {s}\n", .{model_path});
    var cparams = c.whisper_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = true;

    const ctx = c.whisper_init_from_file_with_params(model_path.ptr, cparams);
    if (ctx == null) {
        std.debug.print("Failed to load model\n", .{});
        return;
    }
    defer c.whisper_free(ctx);
    std.debug.print("Model loaded\n", .{});

    // Run inference
    var wparams = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
    wparams.print_progress = false;
    wparams.print_special = false;
    wparams.print_realtime = false;
    wparams.print_timestamps = false;
    wparams.no_timestamps = true;
    wparams.single_segment = true;
    wparams.language = "en";
    wparams.n_threads = 4;

    std.debug.print("Running inference...\n", .{});
    const ret = c.whisper_full(ctx, wparams, samples.ptr, @intCast(samples.len));
    if (ret != 0) {
        std.debug.print("whisper_full() failed with code {d}\n", .{ret});
        return;
    }

    // Print results
    const n_segments = c.whisper_full_n_segments(ctx);
    var j: c_int = 0;
    while (j < n_segments) : (j += 1) {
        const text = c.whisper_full_get_segment_text(ctx, j);
        if (text != null) {
            const slice = std.mem.span(text);
            std.debug.print("{s}\n", .{slice});
        }
    }

    c.whisper_print_timings(ctx);
}

/// Read a WAV file and return float32 samples normalized to [-1, 1].
/// Reads the entire file into memory, parses the RIFF/WAV header, and converts S16 PCM to f32.
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
            // sample_rate at pos+4 (u32), byte_rate at pos+8 (u32), block_align at pos+12 (u16)
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
        // Read first channel's S16 sample
        const raw = std.mem.readInt(i16, pcm_data[byte_offset..][0..2], .little);
        sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    std.debug.print("WAV: {d}ch, {d}bit, {d} samples\n", .{ channels, bits_per_sample, n_samples });

    return samples;
}
