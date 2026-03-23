const std = @import("std");
const pw = @import("pipewire_c.zig");
const utils = @import("../../shared/utils.zig");
const posix = std.posix;

const log = std.log.scoped(.pw_detect);

/// Shared state between main thread and PipeWire callback thread.
const StreamData = struct {
    stream: ?*pw.pw_stream = null,
    pipe_write_fd: posix.fd_t,
};

/// Full setup wizard: enumerate devices, let user pick, record silence,
/// record speech, detect channel, calibrate gain — all in one interactive flow.
/// If target is provided, skip device selection.
/// Writes CHANNEL=... and GAIN=... to stdout for install.sh to parse.
pub fn detectChannel(allocator: std.mem.Allocator, target: ?[:0]const u8, duration: u32) void {
    std.debug.print("=== PipeWire Setup ===\n\n", .{});

    // Enumerate sources
    var results: [64]pw.pw_source_info = undefined;
    const count = pw.pw_enumerate_sources(&results, 64);

    if (count < 0) {
        std.debug.print("Failed to enumerate PipeWire sources. Is PipeWire running?\n", .{});
        return;
    }

    const n: usize = @intCast(count);
    var num_channels: u32 = 2;

    // Device selection
    var owned_target: ?[:0]const u8 = null;
    defer if (owned_target) |t| allocator.free(t);

    var chosen_target: ?[:0]const u8 = target;

    if (chosen_target) |t| {
        // Use specified --pw-target, look up its channel count
        for (results[0..n]) |info| {
            const name = std.mem.sliceTo(&info.name, 0);
            if (std.mem.eql(u8, name, t)) {
                if (info.channels > 0) num_channels = info.channels;
                std.debug.print("Using device: {s} ({d} channels)\n\n", .{ name, num_channels });
                break;
            }
        }
    } else {
        // Interactive device selection
        if (n == 0) {
            std.debug.print("No PipeWire audio sources found. Is PipeWire running?\n", .{});
            return;
        }

        if (n == 1) {
            const info = results[0];
            const name = std.mem.sliceTo(&info.name, 0);
            const desc = std.mem.sliceTo(&info.description, 0);
            if (info.channels > 0) num_channels = info.channels;
            std.debug.print("Auto-selecting only available source: {s} — {s}\n\n", .{ name, desc });
            owned_target = allocator.dupeZ(u8, name) catch null;
            chosen_target = owned_target;
        } else {
            std.debug.print("Available audio sources:\n\n", .{});
            for (results[0..n], 0..) |info, idx| {
                const name = std.mem.sliceTo(&info.name, 0);
                const desc = std.mem.sliceTo(&info.description, 0);
                if (info.channels > 0) {
                    std.debug.print("  {d}) {s:<40} {d}ch   {s}\n", .{ idx + 1, name, info.channels, desc });
                } else {
                    std.debug.print("  {d}) {s:<40} ?ch   {s}\n", .{ idx + 1, name, desc });
                }
            }
            std.debug.print("\n", .{});
            std.debug.print("Select a device [1-{d}] (Enter = default): ", .{n});

            var input_buf: [256]u8 = undefined;
            const raw = readLine(&input_buf) orelse "";
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");

            var selected_idx: usize = 0;
            if (trimmed.len > 0) {
                if (std.fmt.parseInt(usize, trimmed, 10)) |choice| {
                    if (choice >= 1 and choice <= n) {
                        selected_idx = choice - 1;
                    } else {
                        std.debug.print("Invalid choice, using first device.\n", .{});
                    }
                } else |_| {
                    std.debug.print("Invalid input, using first device.\n", .{});
                }
            }

            const info = results[selected_idx];
            const name = std.mem.sliceTo(&info.name, 0);
            if (info.channels > 0) num_channels = info.channels;
            std.debug.print("Selected: {s}\n\n", .{name});
            owned_target = allocator.dupeZ(u8, name) catch null;
            chosen_target = owned_target;
        }
    }

    // Phase 1: Record silence
    std.debug.print("Press ENTER to record SILENCE (stay quiet)...", .{});
    waitForEnter();
    std.debug.print("Recording {d}s of silence...\n", .{duration});
    const silence_pcm = captureMultiChannel(allocator, chosen_target, num_channels, duration) catch |err| {
        std.debug.print("Capture failed: {}\n", .{err});
        return;
    };
    defer allocator.free(silence_pcm);
    std.debug.print("Done.\n\n", .{});

    // Phase 2: Record speech (flows directly into gain calibration)
    std.debug.print("Press ENTER to record SPEECH and calibrate gain (talk normally, keep talking)...", .{});
    waitForEnter();
    std.debug.print("Recording {d}s of speech...\n", .{duration});
    const speech_pcm = captureMultiChannel(allocator, chosen_target, num_channels, duration) catch |err| {
        std.debug.print("Capture failed: {}\n", .{err});
        return;
    };
    defer allocator.free(speech_pcm);

    // Analyze channels (displayed while user keeps talking)
    std.debug.print("\n=== Channel Analysis ===\n", .{});
    std.debug.print("  {s:<10} | {s:>12} | {s:>12} | {s:>8}\n", .{ "Channel", "Silence (dB)", "Speech (dB)", "Delta" });
    std.debug.print("  {s:-<10}─┼─{s:-<12}─┼─{s:-<12}─┼─{s:-<8}\n", .{ "", "", "", "" });

    var best_ch: u32 = 0;
    var best_delta: f64 = -999;
    const nc: u16 = @intCast(num_channels);

    for (0..num_channels) |ch_idx| {
        const ch: u16 = @intCast(ch_idx);
        const sil_rms = utils.channelRms(silence_pcm, nc, ch);
        const sp_rms = utils.channelRms(speech_pcm, nc, ch);
        const sil_db = utils.rmsToDb(sil_rms);
        const sp_db = utils.rmsToDb(sp_rms);
        const delta = sp_db - sil_db;

        const name = channelName(ch_idx, num_channels);
        const marker: []const u8 = if (delta > 3) " <--" else "";
        std.debug.print("  {s:<10} | {d:>12.1} | {d:>12.1} | {d:>7.1}{s}\n", .{ name, sil_db, sp_db, delta, marker });

        if (delta > best_delta) {
            best_delta = delta;
            best_ch = @intCast(ch_idx);
        }
    }
    std.debug.print("\n", .{});

    const best_name = channelName(best_ch, num_channels);
    const sp_db = utils.rmsToDb(utils.channelRms(speech_pcm, nc, @intCast(best_ch)));

    var chosen_name: []const u8 = undefined;
    if (best_delta < 3) {
        std.debug.print("WARNING: No channel showed significant speech activity (delta < 3 dB).\n", .{});
        std.debug.print("Make sure you spoke during the speech recording phase.\n", .{});
        std.debug.print("Falling back to FL.\n\n", .{});
        chosen_name = "FL";
        best_ch = 0;
    } else {
        std.debug.print("Recommended channel: {s} (speech: {d:.1} dB, delta: {d:.1} dB)\n\n", .{ best_name, sp_db, best_delta });
        chosen_name = best_name;
        if (sp_db < -30) {
            std.debug.print("Note: Signal is quiet ({d:.1} dB). Check your hardware gain settings.\n\n", .{sp_db});
        }
    }

    // Phase 3: Gain calibration — seamless, user keeps talking
    const channel_pos = channelPositionFromIndex(best_ch, num_channels);
    std.debug.print("Calibrating auto-gain (keep talking)...\n", .{});
    const cal = calibrateGain(chosen_target, channel_pos, duration) catch |err| {
        std.debug.print("Gain calibration failed: {}\n", .{err});
        // Still emit parseable output so install.sh isn't broken
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\nCHANNEL={s}\nGAIN=1.0\n", .{chosen_name}) catch "\nCHANNEL=FL\nGAIN=1.0\n";
        _ = posix.write(posix.STDOUT_FILENO, line) catch {};
        return;
    };

    std.debug.print("Auto-gain: {d:.1}x (target: -15 dB)\n", .{cal.gain});
    if (cal.gain <= 1.01) {
        std.debug.print("Level OK — no gain boost needed.\n", .{});
    }

    std.debug.print("\n  --pw-channel {s} --pw-gain {d:.1}\n", .{ chosen_name, cal.gain });

    // Write parseable output to stdout for install.sh
    var out_buf: [64]u8 = undefined;
    const out_line = std.fmt.bufPrint(&out_buf, "\nCHANNEL={s}\nGAIN={d:.1}\n", .{ chosen_name, cal.gain }) catch "\nCHANNEL=FL\nGAIN=1.0\n";
    _ = posix.write(posix.STDOUT_FILENO, out_line) catch {};
}

// ─── Channel helpers ────────────────────────────────────────────────────────

/// Map channel index to name (FL, FR for stereo; AUX0+ for multi-channel).
/// Uses a static buffer — only valid until the next call.
var channel_name_buf: [8]u8 = undefined;
fn channelName(ch: anytype, total: anytype) []const u8 {
    if (total <= 2) {
        return if (ch == 0) "FL" else "FR";
    }
    return std.fmt.bufPrint(&channel_name_buf, "AUX{d}", .{ch}) catch "AUX?";
}

/// Map a channel index to a PipeWire SPA channel position.
fn channelPositionFromIndex(ch: u32, total: u32) u32 {
    if (total <= 2) return if (ch == 0) pw.SPA_AUDIO_CHANNEL_FL else pw.SPA_AUDIO_CHANNEL_FR;
    return pw.spaAudioChannelAux(ch);
}

// ─── I/O helpers ────────────────────────────────────────────────────────────

/// Wait for the user to press Enter on stdin.
fn waitForEnter() void {
    var buf: [64]u8 = undefined;
    _ = posix.read(posix.STDIN_FILENO, &buf) catch {};
}

/// Read a line from stdin. Returns the content (without trailing newline) or null on error.
fn readLine(buf: []u8) ?[]const u8 {
    const n = posix.read(posix.STDIN_FILENO, buf) catch return null;
    if (n == 0) return null;
    return std.mem.trimRight(u8, buf[0..n], "\r\n");
}

// ─── Gain calibration ───────────────────────────────────────────────────────

const CalibrationResult = struct {
    gain: f32,
    speech_db: f64,
};

/// Capture mono audio on the selected channel and compute the gain needed
/// to reach target_db. Open-loop: measures raw speech level, computes gain
/// directly. Does NOT apply gain via PipeWire (pw_set_stream_gain may not
/// work on short-lived capture streams).
fn calibrateGain(target: ?[:0]const u8, channel_position: u32, duration_secs: u32) !CalibrationResult {
    const target_db: f32 = -15.0;
    const max_gain: f32 = 10.0; // PipeWire caps software gain at 10x
    const sample_rate: u32 = 16000;
    const expected_bytes: usize = sample_rate * 2 * duration_secs; // mono S16_LE

    const pipe_fds = try posix.pipe();
    errdefer {
        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);
    }

    pw.pw_init(null, null);

    const stream_data = try std.heap.page_allocator.create(StreamData);
    stream_data.* = .{ .pipe_write_fd = pipe_fds[1] };

    const thread_loop = pw.pw_thread_loop_new("pw-gain-cal", null) orelse
        return error.PipeWireInitFailed;

    const loop = pw.pw_thread_loop_get_loop(thread_loop);

    const stream_events = pw.pw_stream_events{
        .version = 2,
        .process = onProcess,
        .destroy = null,
        .state_changed = null,
        .control_info = null,
        .io_changed = null,
        .param_changed = null,
        .add_buffer = null,
        .remove_buffer = null,
        .drained = null,
        .command = null,
        .trigger_done = null,
    };

    const props = if (target) |t|
        pw.pw_properties_new(
            pw.PW_KEY_MEDIA_TYPE,     "Audio",
            pw.PW_KEY_MEDIA_CATEGORY, "Capture",
            pw.PW_KEY_MEDIA_ROLE,     "Communication",
            pw.PW_KEY_TARGET_OBJECT,  t.ptr,
            @as(?[*]const u8, null),
        )
    else
        pw.pw_properties_new(
            pw.PW_KEY_MEDIA_TYPE,     "Audio",
            pw.PW_KEY_MEDIA_CATEGORY, "Capture",
            pw.PW_KEY_MEDIA_ROLE,     "Communication",
            @as(?[*]const u8, null),
        );

    if (props == null) return error.PipeWireInitFailed;

    const stream = pw.pw_stream_new_simple(loop, "pw-gain-cal", props, &stream_events, stream_data) orelse
        return error.PipeWireInitFailed;

    stream_data.stream = stream;

    const connect_result = pw.pw_connect_capture(stream, sample_rate, channel_position);
    if (connect_result < 0) return error.PipeWireConnectFailed;

    const start_result = pw.pw_thread_loop_start(thread_loop);
    if (start_result < 0) return error.PipeWireInitFailed;

    // Measure raw speech level (open-loop — no gain applied)
    var recv_buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    var sum_db: f64 = 0;
    var n_speech_chunks: usize = 0;

    const deadline_ns: i128 = std.time.nanoTimestamp() + @as(i128, duration_secs) * std.time.ns_per_s;

    while (total_read < expected_bytes) {
        if (std.time.nanoTimestamp() >= deadline_ns) break;

        const n = posix.read(pipe_fds[0], &recv_buf) catch |err| {
            if (err == error.WouldBlock) continue;
            break;
        };
        if (n == 0) break;
        total_read += n;

        const rms = utils.channelRms(recv_buf[0..n], 1, 0);
        const db = utils.rmsToDb(rms);
        if (db > -50) {
            sum_db += db;
            n_speech_chunks += 1;
        }
    }

    // Cleanup
    pw.pw_thread_loop_stop(thread_loop);
    pw.pw_stream_destroy(stream);
    pw.pw_thread_loop_destroy(thread_loop);
    posix.close(pipe_fds[0]);
    posix.close(pipe_fds[1]);
    std.heap.page_allocator.destroy(stream_data);
    pw.pw_deinit();

    // Compute gain from average speech level
    if (n_speech_chunks == 0) return .{ .gain = 1.0, .speech_db = -100 };

    const avg_db: f32 = @floatCast(sum_db / @as(f64, @floatFromInt(n_speech_chunks)));
    const needed_gain = std.math.pow(f32, 10.0, (target_db - avg_db) / 20.0);
    const gain = @min(@max(needed_gain, 1.0), max_gain);

    return .{ .gain = gain, .speech_db = avg_db };
}

// ─── Multi-channel capture ──────────────────────────────────────────────────

/// PipeWire process callback for multi-channel capture.
fn onProcess(userdata: ?*anyopaque) callconv(.c) void {
    const data: *StreamData = @ptrCast(@alignCast(userdata orelse return));
    const stream = data.stream orelse return;

    const pw_buf: *pw.pw_buffer = pw.pw_stream_dequeue_buffer(stream) orelse return;
    defer _ = pw.pw_stream_queue_buffer(stream, pw_buf);

    const spa_buf = pw_buf.buffer orelse return;
    if (spa_buf.*.n_datas == 0) return;

    const d = &spa_buf.*.datas[0];
    const chunk = d.chunk orelse return;
    if (chunk.*.size == 0) return;

    const base: [*]u8 = @ptrCast(d.data orelse return);
    const audio_data = base[chunk.*.offset..][0..chunk.*.size];

    _ = posix.write(data.pipe_write_fd, audio_data) catch {};
}

/// Capture multi-channel audio for a fixed duration. Returns interleaved S16_LE PCM.
fn captureMultiChannel(
    allocator: std.mem.Allocator,
    target: ?[:0]const u8,
    num_channels: u32,
    duration_secs: u32,
) ![]u8 {
    const sample_rate: u32 = 48000;
    const bytes_per_frame = num_channels * 2; // S16_LE
    const expected_bytes = sample_rate * bytes_per_frame * duration_secs;

    const pipe_fds = try posix.pipe();
    errdefer {
        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);
    }

    pw.pw_init(null, null);

    const stream_data = try std.heap.page_allocator.create(StreamData);
    stream_data.* = .{ .pipe_write_fd = pipe_fds[1] };

    const thread_loop = pw.pw_thread_loop_new("pw-detect", null) orelse
        return error.PipeWireInitFailed;

    const loop = pw.pw_thread_loop_get_loop(thread_loop);

    const stream_events = pw.pw_stream_events{
        .version = 2,
        .process = onProcess,
        .destroy = null,
        .state_changed = null,
        .control_info = null,
        .io_changed = null,
        .param_changed = null,
        .add_buffer = null,
        .remove_buffer = null,
        .drained = null,
        .command = null,
        .trigger_done = null,
    };

    const props = if (target) |t|
        pw.pw_properties_new(
            pw.PW_KEY_MEDIA_TYPE,     "Audio",
            pw.PW_KEY_MEDIA_CATEGORY, "Capture",
            pw.PW_KEY_MEDIA_ROLE,     "Communication",
            pw.PW_KEY_TARGET_OBJECT,  t.ptr,
            @as(?[*]const u8, null),
        )
    else
        pw.pw_properties_new(
            pw.PW_KEY_MEDIA_TYPE,     "Audio",
            pw.PW_KEY_MEDIA_CATEGORY, "Capture",
            pw.PW_KEY_MEDIA_ROLE,     "Communication",
            @as(?[*]const u8, null),
        );

    if (props == null) return error.PipeWireInitFailed;

    const stream = pw.pw_stream_new_simple(loop, "pw-detect", props, &stream_events, stream_data) orelse
        return error.PipeWireInitFailed;

    stream_data.stream = stream;

    const connect_result = pw.pw_connect_capture_multi(stream, sample_rate, num_channels);
    if (connect_result < 0) return error.PipeWireConnectFailed;

    const start_result = pw.pw_thread_loop_start(thread_loop);
    if (start_result < 0) return error.PipeWireInitFailed;

    var buf = try allocator.alloc(u8, expected_bytes);
    errdefer allocator.free(buf);
    var total_read: usize = 0;

    const deadline_ns: i128 = std.time.nanoTimestamp() + @as(i128, duration_secs) * std.time.ns_per_s;

    while (total_read < expected_bytes) {
        if (std.time.nanoTimestamp() >= deadline_ns) break;

        const remaining = expected_bytes - total_read;
        const n = posix.read(pipe_fds[0], buf[total_read..][0..remaining]) catch |err| {
            if (err == error.WouldBlock) continue;
            break;
        };
        if (n == 0) break;
        total_read += n;
    }

    // Cleanup PipeWire
    pw.pw_thread_loop_stop(thread_loop);
    pw.pw_stream_destroy(stream);
    pw.pw_thread_loop_destroy(thread_loop);
    posix.close(pipe_fds[0]);
    posix.close(pipe_fds[1]);
    std.heap.page_allocator.destroy(stream_data);
    pw.pw_deinit();

    // Return only what we actually read, truncated to frame boundary
    const usable = (total_read / (num_channels * 2)) * (num_channels * 2);
    if (usable < buf.len) {
        const result = try allocator.alloc(u8, usable);
        @memcpy(result, buf[0..usable]);
        allocator.free(buf);
        return result;
    }
    return buf;
}
