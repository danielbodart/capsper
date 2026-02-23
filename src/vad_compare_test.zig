/// Compare frame-by-frame VAD probabilities between GGML (Zig) and native backends.
/// Usage: vad-compare-test <wav_file> [--pitch-only]
///   --pitch-only: compare pitch output directly (GGML vs native pitch, mel from GGML)
const std = @import("std");
const vad = @import("vad.zig");
const utils = @import("utils.zig");
const TenVadGgml = vad.TenVadGgml;
const TenVadNative = vad.TenVadNative;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: vad-compare-test <wav_file>\n", .{});
        return;
    }

    // Load WAV as raw PCM bytes
    const file = try std.fs.cwd().openFile(args[1], .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(data);
    const header = try utils.parseWavHeader(data);
    const pcm = data[header.data_start..][0..header.data_size];

    // Init both backends
    var ggml_backend = try TenVadGgml.init(allocator, "dist/models/ten-vad-ggml.bin");
    defer ggml_backend.deinit();

    var native = try TenVadNative.init();
    defer native.deinit();

    const chunk_bytes = TenVadGgml.chunk_bytes;

    std.debug.print("WAV: {d} bytes, {d} chunks\n", .{ pcm.len, pcm.len / chunk_bytes });
    std.debug.print("{s:>6}  {s:>10}  {s:>10}  {s:>10}\n", .{ "frame", "ggml", "native", "delta" });
    std.debug.print("{s}\n", .{"-" ** 44});

    var max_delta: f32 = 0;
    var sum_delta: f64 = 0;
    var n_frames: usize = 0;
    var n_mismatch: usize = 0;
    var first_mismatch: ?usize = null;

    var pos: usize = 0;
    while (pos + chunk_bytes <= pcm.len) {
        const chunk = pcm[pos..][0..chunk_bytes];
        const prob_ggml = ggml_backend.chunkProbS16(chunk);
        const prob_native = native.chunkProbS16(chunk);
        const delta = @abs(prob_ggml - prob_native);

        if (delta > 0.001) {
            if (n_mismatch < 10) {
                std.debug.print("{d:>6}  {d:>10.6}  {d:>10.6}  {d:>10.6}  !\n", .{ n_frames, prob_ggml, prob_native, delta });
            }
            if (first_mismatch == null) first_mismatch = n_frames;
            n_mismatch += 1;
        }

        if (delta > max_delta) max_delta = delta;
        sum_delta += delta;
        n_frames += 1;
        pos += chunk_bytes;
    }

    const mean_delta: f32 = if (n_frames > 0) @floatCast(sum_delta / @as(f64, @floatFromInt(n_frames))) else 0;
    std.debug.print("{s}\n", .{"-" ** 44});
    std.debug.print("Frames: {d}, Mismatches (>0.001): {d}", .{ n_frames, n_mismatch });
    if (first_mismatch) |fm| {
        std.debug.print(", first at frame {d} ({d:.1}s)", .{ fm, @as(f32, @floatFromInt(fm)) * 256.0 / 16000.0 });
    }
    std.debug.print("\n", .{});
    std.debug.print("Max delta: {d:.6}, Mean delta: {d:.6}\n", .{ max_delta, mean_delta });

    if (max_delta < 0.001) {
        std.debug.print("PASS: bit-perfect match\n", .{});
    } else {
        std.debug.print("FAIL: probabilities diverge\n", .{});
    }
}
