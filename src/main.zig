const std = @import("std");
const c = @import("whisper_c.zig");
const Vad = @import("vad.zig").Vad;
const Pipeline = @import("pipeline.zig").Pipeline;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    // VAD
    std.debug.print("\n--- VAD ---\n", .{});
    var vad = Vad.init("whisper.cpp/models/ggml-silero-v5.1.2.bin") catch |err| {
        std.debug.print("Failed to init VAD: {}\n", .{err});
        return;
    };
    defer vad.deinit();

    const segments = vad.getSegments(samples) catch |err| {
        std.debug.print("Failed to get VAD segments: {}\n", .{err});
        return;
    };
    std.debug.print("Speech segments: {d}\n", .{segments.len});
    for (segments, 0..) |seg, si| {
        std.debug.print("  segment {d}: {d:.2}s - {d:.2}s\n", .{ si, seg.start_s, seg.end_s });
    }

    // Pipeline
    std.debug.print("\n--- AlignAtt Pipeline ---\n", .{});

    var cparams = c.whisper_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = false;
    cparams.dtw_token_timestamps = true;
    cparams.dtw_aheads_preset = c.WHISPER_AHEADS_LARGE_V3_TURBO;

    const ctx = c.whisper_init_from_file_with_params(model_path.ptr, cparams) orelse {
        std.debug.print("Failed to load model\n", .{});
        return;
    };
    defer c.whisper_free(ctx);

    var pipeline = try Pipeline.init(allocator, ctx, .{}, 4);
    defer pipeline.deinit();

    // Test: Full audio transcription
    if (try pipeline.transcribe(samples, true)) |result| {
        std.debug.print("Result: \"{s}\"\n", .{result.text});
        allocator.free(result.text);
    } else {
        std.debug.print("No output\n", .{});
    }
}

fn loadWav(allocator: std.mem.Allocator, path: [:0]const u8) ![]f32 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(data);

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

    const bytes_per_sample = channels * (bits_per_sample / 8);
    const n_samples = data_size / bytes_per_sample;
    const result = try allocator.alloc(f32, n_samples);
    errdefer allocator.free(result);

    const pcm_data = data[data_start..];
    for (result, 0..) |*sample, idx| {
        const byte_offset = idx * bytes_per_sample;
        if (byte_offset + 2 > pcm_data.len) break;
        const raw = std.mem.readInt(i16, pcm_data[byte_offset..][0..2], .little);
        sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    return result;
}
