const std = @import("std");
const vad = @import("vad.zig");
const utils = @import("utils.zig");

const VadFilter = vad.VadFilter;
const VadBackend = vad.VadBackend;
const SileroVad = vad.SileroVad;
const TenVadGgml = vad.TenVadGgml;

const sample_rate: u32 = 16000;
const bytes_per_sec: u32 = sample_rate * 2; // S16_LE

/// Per-chunk metadata collected during processing
const ChunkInfo = struct {
    byte_offset: usize, // position in original PCM
    prob: f32,
    triggered: bool,
    rms: f32,
};

/// A detected speech segment
const SpeechSegment = struct {
    start_byte: usize,
    end_byte: usize,

    fn startSec(self: SpeechSegment) f32 {
        return @as(f32, @floatFromInt(self.start_byte)) / @as(f32, @floatFromInt(bytes_per_sec));
    }

    fn endSec(self: SpeechSegment) f32 {
        return @as(f32, @floatFromInt(self.end_byte)) / @as(f32, @floatFromInt(bytes_per_sec));
    }

    fn durationSec(self: SpeechSegment) f32 {
        return self.endSec() - self.startSec();
    }
};

const tail_pad_ms: u32 = 200; // keep 200ms of trailing audio after last speech chunk
const tail_pad_bytes: usize = tail_pad_ms * bytes_per_sec / 1000;

const VadChoice = enum { ten, silero };

const Args = struct {
    input_path: []const u8,
    output_dir: ?[]const u8,
    threshold: f32,
    threshold_off: f32,
    min_silence_ms: u32,
    vad_choice: VadChoice,
};

fn parseArgs() Args {
    var iter = std.process.args();
    _ = iter.next(); // skip argv[0]

    var input_path: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var threshold_val: f32 = VadFilter.default_threshold;
    var threshold_off_val: f32 = VadFilter.default_threshold_off;
    var min_silence_ms: u32 = 1000;
    var vad_choice: VadChoice = .ten;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--output-dir")) {
            output_dir = iter.next() orelse fatal("--output-dir requires a value");
        } else if (std.mem.eql(u8, arg, "--threshold")) {
            const val = iter.next() orelse fatal("--threshold requires a value");
            threshold_val = std.fmt.parseFloat(f32, val) catch fatal("invalid --threshold value");
        } else if (std.mem.eql(u8, arg, "--threshold-off")) {
            const val = iter.next() orelse fatal("--threshold-off requires a value");
            threshold_off_val = std.fmt.parseFloat(f32, val) catch fatal("invalid --threshold-off value");
        } else if (std.mem.eql(u8, arg, "--min-silence-ms")) {
            const val = iter.next() orelse fatal("--min-silence-ms requires a value");
            min_silence_ms = std.fmt.parseInt(u32, val, 10) catch fatal("invalid --min-silence-ms value");
        } else if (std.mem.eql(u8, arg, "--vad")) {
            const val = iter.next() orelse fatal("--vad requires a value (ten or silero)");
            if (std.mem.eql(u8, val, "ten")) {
                vad_choice = .ten;
            } else if (std.mem.eql(u8, val, "silero")) {
                vad_choice = .silero;
            } else {
                fatal("invalid --vad value, expected 'ten' or 'silero'");
            }
        } else if (arg[0] != '-') {
            input_path = arg;
        } else {
            printUsage();
            std.process.exit(1);
        }
    }

    if (input_path == null) {
        printUsage();
        std.process.exit(1);
    }

    return .{
        .input_path = input_path.?,
        .output_dir = output_dir,
        .threshold = threshold_val,
        .threshold_off = threshold_off_val,
        .min_silence_ms = min_silence_ms,
        .vad_choice = vad_choice,
    };
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("{s}\n", .{msg});
    std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\Usage: vad-filter-test <input.wav> [options]
        \\
        \\Options:
        \\  --output-dir <dir>       Output directory (default: test/results/vad-segments/<stem>/)
        \\  --threshold <f32>        Onset threshold (default: {d:.3})
        \\  --threshold-off <f32>    Offset threshold (default: {d:.3})
        \\  --min-silence-ms <ms>    Min silence to split segments (default: 1000)
        \\  --vad ten|silero         VAD backend (default: ten)
        \\
    , .{ VadFilter.default_threshold, VadFilter.default_threshold_off });
}

/// Compute RMS for a chunk of S16_LE PCM bytes
fn chunkRms(pcm: []const u8) f32 {
    const n_samples = pcm.len / 2;
    if (n_samples == 0) return 0;
    var sum_sq: f64 = 0;
    for (0..n_samples) |i| {
        const offset = i * 2;
        if (offset + 2 > pcm.len) break;
        const raw = std.mem.readInt(i16, pcm[offset..][0..2], .little);
        const norm: f64 = @as(f64, @floatFromInt(raw)) / 32768.0;
        sum_sq += norm * norm;
    }
    return @floatCast(@sqrt(sum_sq / @as(f64, @floatFromInt(n_samples))));
}

/// Extract the stem (filename without extension) from a path
fn pathStem(path: []const u8) []const u8 {
    // Find last '/'
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/') start = i + 1;
    }
    const basename = path[start..];
    // Find last '.'
    var dot: usize = basename.len;
    var i: usize = basename.len;
    while (i > 0) {
        i -= 1;
        if (basename[i] == '.') {
            dot = i;
            break;
        }
    }
    return basename[0..dot];
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = parseArgs();

    // Build all output in a buffer, write at the end
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    // Load input WAV
    const input_data = std.fs.cwd().readFileAlloc(allocator, args.input_path, 100 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ args.input_path, err });
        std.process.exit(1);
    };
    defer allocator.free(input_data);

    const wav_header = utils.parseWavHeader(input_data) catch |err| {
        std.debug.print("Error parsing WAV header: {}\n", .{err});
        std.process.exit(1);
    };

    const pcm_data = input_data[wav_header.data_start .. wav_header.data_start + wav_header.data_size];
    const total_duration = @as(f32, @floatFromInt(pcm_data.len)) / @as(f32, @floatFromInt(bytes_per_sec));
    const stem = pathStem(args.input_path);

    try w.print("{s}  ({d:.1}s, {d}kHz", .{ args.input_path, total_duration, sample_rate / 1000 });
    if (wav_header.channels == 1) {
        try w.print(" mono)\n\n", .{});
    } else {
        try w.print(" {d}ch)\n\n", .{wav_header.channels});
    }

    // Set up output directory
    const output_dir_owned = if (args.output_dir == null)
        try std.fmt.allocPrint(allocator, "test/results/vad-segments/{s}", .{stem})
    else
        null;
    defer if (output_dir_owned) |d| allocator.free(d);
    const output_dir = args.output_dir orelse output_dir_owned.?;

    // Create output directory
    std.fs.cwd().makePath(output_dir) catch |err| {
        std.debug.print("Error creating output dir {s}: {}\n", .{ output_dir, err });
        std.process.exit(1);
    };

    // Initialize VAD backend
    var silero_vad: SileroVad = undefined;
    var ten_vad_ggml_ctx: TenVadGgml = undefined;
    var backend: VadBackend = undefined;

    switch (args.vad_choice) {
        .ten => {
            const model: [:0]const u8 = "dist/models/ten-vad-ggml.bin";
            ten_vad_ggml_ctx = TenVadGgml.init(allocator, model) catch |err| {
                std.debug.print("Error loading TEN-VAD model {s}: {}\n", .{ model, err });
                std.process.exit(1);
            };
            backend = .{ .ten_vad_ggml = &ten_vad_ggml_ctx };
        },
        .silero => {
            const model: [:0]const u8 = "dist/models/ggml-silero-v5.1.2.bin";
            silero_vad = SileroVad.init(model) catch |err| {
                std.debug.print("Error loading Silero VAD model {s}: {}\n", .{ model, err });
                std.process.exit(1);
            };
            backend = .{ .silero = &silero_vad };
        },
    }
    defer switch (args.vad_choice) {
        .ten => ten_vad_ggml_ctx.deinit(),
        .silero => silero_vad.deinit(),
    };

    // Process audio chunk-by-chunk, collecting metadata
    const chunk_size = backend.chunkBytes();
    const min_silence_bytes_override: usize = @as(usize, args.min_silence_ms) * bytes_per_sec / 1000;

    var chunks = std.ArrayListUnmanaged(ChunkInfo){};
    defer chunks.deinit(allocator);

    var segments = std.ArrayListUnmanaged(SpeechSegment){};
    defer segments.deinit(allocator);

    // State machine with configurable thresholds (mirrors VadFilter logic)
    var triggered = false;
    var silence_bytes: usize = 0;
    var segment_start: usize = 0;

    var pos: usize = 0;
    while (pos + chunk_size <= pcm_data.len) {
        const chunk = pcm_data[pos..][0..chunk_size];

        // Get probability via the VadBackend
        const prob = backend.chunkProb(chunk);

        const rms = chunkRms(chunk);

        // State machine with configurable thresholds
        if (!triggered) {
            if (prob >= args.threshold) {
                triggered = true;
                silence_bytes = 0;
                segment_start = pos;
            }
        } else {
            if (prob >= args.threshold_off) {
                silence_bytes = 0;
            } else {
                silence_bytes += chunk_size;
                if (silence_bytes >= min_silence_bytes_override) {
                    // End segment where silence began + tail pad to avoid clipping
                    const silence_start = pos + chunk_size - silence_bytes;
                    const seg_end = @min(silence_start + tail_pad_bytes, pos + chunk_size);
                    if (seg_end > segment_start) {
                        try segments.append(allocator, .{
                            .start_byte = segment_start,
                            .end_byte = seg_end,
                        });
                    }
                    triggered = false;
                }
            }
        }

        try chunks.append(allocator, .{
            .byte_offset = pos,
            .prob = prob,
            .triggered = triggered,
            .rms = rms,
        });

        pos += chunk_size;
    }

    // Close any open segment at the end
    if (triggered and pos > segment_start) {
        try segments.append(allocator, .{
            .start_byte = segment_start,
            .end_byte = pos,
        });
    }

    // Print thresholds used
    try w.print("Thresholds: onset={d:.4}  offset={d:.4}  min_silence={d}ms\n\n", .{
        args.threshold, args.threshold_off, args.min_silence_ms,
    });

    // ASCII visualization
    try printVisualization(w, chunks.items, segments.items, total_duration);

    // Print segment summary and write WAVs
    try w.print("\nSegments: {d}\n", .{segments.items.len});

    var total_speech: f32 = 0;
    for (segments.items, 0..) |seg, idx| {
        const seg_num = idx + 1;
        const seg_pcm = pcm_data[seg.start_byte..seg.end_byte];
        const filename = try std.fmt.allocPrint(allocator, "segment-{d:0>3}.wav", .{seg_num});
        defer allocator.free(filename);
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, filename });
        defer allocator.free(filepath);

        // Write segment WAV via in-memory buffer then file
        var wav_buf = std.ArrayListUnmanaged(u8){};
        defer wav_buf.deinit(allocator);
        try utils.writeWav(wav_buf.writer(allocator), seg_pcm);
        const file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        try file.writeAll(wav_buf.items);

        total_speech += seg.durationSec();
        try w.print("  {d}: {d:.1}s - {d:.1}s  ({d:.1}s)  {s}\n", .{
            seg_num, seg.startSec(), seg.endSec(), seg.durationSec(), filename,
        });
    }

    // Print gaps between segments
    if (segments.items.len > 1) {
        try w.print("Gaps:\n", .{});
        for (1..segments.items.len) |idx| {
            const gap = segments.items[idx].startSec() - segments.items[idx - 1].endSec();
            try w.print("  {d}->{d}: {d:.1}s\n", .{ idx, idx + 1, gap });
        }
    }

    const total_silence = total_duration - total_speech;
    const speech_pct = if (total_duration > 0) total_speech / total_duration * 100 else 0;
    const silence_pct = if (total_duration > 0) total_silence / total_duration * 100 else 0;
    try w.print("Speech: {d:.1}s ({d:.1}%)  Silence: {d:.1}s ({d:.1}%)\n", .{
        total_speech, speech_pct, total_silence, silence_pct,
    });
    try w.print("Output: {s}/\n", .{output_dir});

    // Write all output to stdout
    const posix = std.posix;
    _ = posix.write(posix.STDOUT_FILENO, out.items) catch {};
}

fn printVisualization(
    w: anytype,
    chunks: []const ChunkInfo,
    segments: []const SpeechSegment,
    total_duration: f32,
) !void {
    // Target width: ~72 columns for the visualization area
    const viz_width: usize = 72;
    if (total_duration <= 0) return;
    const secs_per_col: f32 = total_duration / @as(f32, @floatFromInt(viz_width));

    // Build per-column data by averaging chunks that fall in each column
    var col_rms: [viz_width]f32 = @splat(0);
    var col_prob: [viz_width]f32 = @splat(0);
    var col_triggered: [viz_width]bool = @splat(false);
    var col_counts: [viz_width]u32 = @splat(0);

    for (chunks) |chunk| {
        const time_s = @as(f32, @floatFromInt(chunk.byte_offset)) / @as(f32, @floatFromInt(bytes_per_sec));
        const col_f = time_s / secs_per_col;
        const col: usize = @min(@as(usize, @intFromFloat(col_f)), viz_width - 1);
        col_rms[col] += chunk.rms;
        col_prob[col] += chunk.prob;
        if (chunk.triggered) col_triggered[col] = true;
        col_counts[col] += 1;
    }

    // Normalize averages
    var max_rms: f32 = 0;
    var max_prob: f32 = 0;
    for (0..viz_width) |ci| {
        if (col_counts[ci] > 0) {
            col_rms[ci] /= @floatFromInt(col_counts[ci]);
            col_prob[ci] /= @floatFromInt(col_counts[ci]);
        }
        if (col_rms[ci] > max_rms) max_rms = col_rms[ci];
        if (col_prob[ci] > max_prob) max_prob = col_prob[ci];
    }
    if (max_rms == 0) max_rms = 1;
    if (max_prob == 0) max_prob = 1;

    const blocks = [_][]const u8{ " ", "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}" };

    // Time axis
    try w.print("Time(s) ", .{});
    {
        var next_mark: f32 = 0;
        for (0..viz_width) |col| {
            const t = @as(f32, @floatFromInt(col)) * secs_per_col;
            if (t >= next_mark) {
                var label_buf: [8]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "{d:.0}", .{next_mark}) catch "?";
                try w.print("{s}", .{label});
                next_mark += 5;
            } else {
                try w.print(" ", .{});
            }
        }
    }
    try w.print("\n", .{});

    // Amplitude row
    try w.print("Ampl  : ", .{});
    for (0..viz_width) |col| {
        const norm = col_rms[col] / max_rms;
        const level: usize = @min(@as(usize, @intFromFloat(norm * 8)), 8);
        try w.print("{s}", .{blocks[level]});
    }
    try w.print("\n", .{});

    // VAD probability row
    try w.print("VAD   : ", .{});
    for (0..viz_width) |col| {
        const norm = col_prob[col] / max_prob;
        const level: usize = @min(@as(usize, @intFromFloat(norm * 8)), 8);
        try w.print("{s}", .{blocks[level]});
    }
    try w.print("\n", .{});

    // Trigger row
    try w.print("Trigger: ", .{});
    for (0..viz_width) |col| {
        if (col_triggered[col]) {
            try w.print("\u{2588}", .{});
        } else {
            try w.print("_", .{});
        }
    }
    try w.print("\n", .{});

    // Segment markers
    try w.print("Segments:", .{});
    var seg_row: [viz_width]u8 = @splat(' ');
    for (segments, 0..) |seg, idx| {
        const start_col_f = seg.startSec() / secs_per_col;
        const end_col_f = seg.endSec() / secs_per_col;
        const start_col: usize = @min(@as(usize, @intFromFloat(start_col_f)), viz_width - 1);
        const end_col: usize = @min(@as(usize, @intFromFloat(end_col_f)), viz_width - 1);

        if (start_col < viz_width) seg_row[start_col] = '[';
        if (end_col < viz_width) seg_row[end_col] = ']';
        // Fill with segment number
        const digit: u8 = if (idx < 9) @intCast('1' + idx) else '?';
        const fill_start = @min(start_col + 1, viz_width);
        const fill_end = @min(end_col, viz_width);
        if (fill_end > fill_start) {
            for (fill_start..fill_end) |c_idx| {
                seg_row[c_idx] = digit;
            }
        }
    }
    try w.print("{s}\n", .{&seg_row});
}
