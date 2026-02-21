const std = @import("std");
const pw = @import("pipewire_c.zig");
const utils = @import("utils.zig");
const AutoGain = @import("auto_gain.zig").AutoGain;
const posix = std.posix;

const log = std.log.scoped(.pw_detect);

/// Shared state between main thread and PipeWire callback thread (multi-channel capture).
const StreamData = struct {
    stream: ?*pw.pw_stream = null,
    pipe_write_fd: posix.fd_t,
};

/// List all PipeWire Audio/Source nodes with their properties.
pub fn listSources() void {
    var results: [64]pw.pw_source_info = undefined;
    const count = pw.pw_enumerate_sources(&results, 64);

    if (count < 0) {
        std.debug.print("Failed to enumerate PipeWire sources.\n", .{});
        std.debug.print("Is PipeWire running?\n", .{});
        return;
    }

    if (count == 0)
        return;

    std.debug.print("\n", .{});
    std.debug.print("  {s:<40} {s:<10} {s}\n", .{ "Name", "Channels", "Description" });
    std.debug.print("  {s:-<40} {s:-<10} {s:-<30}\n", .{ "", "", "" });

    const n: usize = @intCast(count);
    for (results[0..n]) |info| {
        const name = std.mem.sliceTo(&info.name, 0);
        const desc = std.mem.sliceTo(&info.description, 0);
        if (info.channels > 0) {
            std.debug.print("  {s:<40} {d:<10} {s}\n", .{ name, info.channels, desc });
        } else {
            std.debug.print("  {s:<40} {s:<10} {s}\n", .{ name, "?", desc });
        }
    }
    std.debug.print("\n", .{});
    std.debug.print("Use --pw-target <Name> to select a source.\n", .{});
}

/// Interactive channel detection: record silence and speech, compare per-channel RMS.
pub fn detectChannel(allocator: std.mem.Allocator, target: ?[:0]const u8, duration: u32) void {
    // Find the target device and its channel count
    var results: [64]pw.pw_source_info = undefined;
    const count = pw.pw_enumerate_sources(&results, 64);

    if (count < 0) {
        std.debug.print("Failed to enumerate PipeWire sources. Is PipeWire running?\n", .{});
        return;
    }

    const n: usize = @intCast(count);
    var num_channels: u32 = 2; // fallback

    if (target) |t| {
        var found = false;
        for (results[0..n]) |info| {
            const name = std.mem.sliceTo(&info.name, 0);
            if (std.mem.eql(u8, name, t)) {
                found = true;
                if (info.channels > 0) num_channels = info.channels;
                std.debug.print("Probing device: {s} ({d} channels)\n", .{ name, num_channels });
                break;
            }
        }
        if (!found) {
            std.debug.print("Device '{s}' not found. Use --pw-list to see available sources.\n", .{t});
            return;
        }
    } else {
        std.debug.print("Probing default audio source...\n", .{});
        // Use first source's channel count if available
        if (n > 0 and results[0].channels > 0) {
            num_channels = results[0].channels;
        }
    }

    std.debug.print("Recording duration: {d}s per phase\n", .{duration});
    std.debug.print("Channels: {d}, Format: S16_LE, Rate: 48000Hz\n", .{num_channels});
    std.debug.print("\n", .{});

    // Record silence
    std.debug.print("Press ENTER to start recording SILENCE (stay quiet)...", .{});
    waitForEnter();
    std.debug.print("Recording {d}s of silence...\n", .{duration});
    const silence_pcm = captureMultiChannel(allocator, target, num_channels, duration) catch |err| {
        std.debug.print("Capture failed: {}\n", .{err});
        return;
    };
    defer allocator.free(silence_pcm);
    std.debug.print("Done.\n\n", .{});

    // Record speech
    std.debug.print("Press ENTER to start recording SPEECH (talk normally)...", .{});
    waitForEnter();
    std.debug.print("Recording {d}s of speech...\n", .{duration});
    const speech_pcm = captureMultiChannel(allocator, target, num_channels, duration) catch |err| {
        std.debug.print("Capture failed: {}\n", .{err});
        return;
    };
    defer allocator.free(speech_pcm);
    std.debug.print("Done.\n\n", .{});

    // Analyze channels
    std.debug.print("=== Channel Analysis ===\n\n", .{});
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
        std.debug.print("WARNING: No channel showed significant speech activity (delta < 3dB).\n", .{});
        std.debug.print("Make sure you spoke during the speech recording phase.\n", .{});
        std.debug.print("Falling back to FL.\n", .{});
        std.debug.print("\n  --pw-channel FL\n", .{});
        chosen_name = "FL";
        best_ch = 0;
        // CHANNEL= line goes to stdout so install.sh can parse it
        _ = posix.write(posix.STDOUT_FILENO, "\nCHANNEL=FL\n") catch {};
    } else {
        std.debug.print("Recommended channel: {s} (speech: {d:.1} dB, delta: {d:.1} dB)\n", .{ best_name, sp_db, best_delta });
        std.debug.print("\n  --pw-channel {s}\n", .{best_name});
        chosen_name = best_name;
        if (sp_db < -30) {
            std.debug.print("\nNote: Signal is quiet ({d:.1} dB). Check your hardware gain settings.\n", .{sp_db});
        }
        // CHANNEL= line goes to stdout so install.sh can parse it
        var chan_buf: [32]u8 = undefined;
        const chan_line = std.fmt.bufPrint(&chan_buf, "\nCHANNEL={s}\n", .{chosen_name}) catch "\nCHANNEL=FL\n";
        _ = posix.write(posix.STDOUT_FILENO, chan_line) catch {};
    }

    // Auto-gain calibration
    const channel_pos = channelPositionFromIndex(best_ch, num_channels);
    std.debug.print("\n=== Auto-Gain Calibration ===\n\n", .{});
    std.debug.print("Speak again — calibrating auto-gain ({d}s)...\n", .{duration});
    const cal = calibrateGain(target, channel_pos, duration) catch |err| {
        std.debug.print("Gain calibration failed: {}\n", .{err});
        return;
    };
    std.debug.print("Auto-gain: {d:.1}x (speech: {d:.0} dB, target: -15 dB)\n", .{ cal.gain, cal.speech_db });
    if (cal.gain <= 1.01) {
        std.debug.print("Level OK — no gain boost needed.\n", .{});
    }
}

/// Map channel index to name (FL, FR for stereo; AUX0+ for multi-channel).
/// Uses a static buffer — only valid until the next call.
var channel_name_buf: [8]u8 = undefined;
fn channelName(ch: anytype, total: anytype) []const u8 {
    if (total <= 2) {
        return if (ch == 0) "FL" else "FR";
    }
    return std.fmt.bufPrint(&channel_name_buf, "AUX{d}", .{ch}) catch "AUX?";
}

/// Wait for the user to press Enter on stdin.
fn waitForEnter() void {
    var buf: [64]u8 = undefined;
    _ = posix.read(posix.STDIN_FILENO, &buf) catch {};
}

/// Map a channel index to a PipeWire SPA channel position.
fn channelPositionFromIndex(ch: u32, total: u32) u32 {
    if (total <= 2) return if (ch == 0) pw.SPA_AUDIO_CHANNEL_FL else pw.SPA_AUDIO_CHANNEL_FR;
    return pw.spaAudioChannelAux(ch);
}

const CalibrationResult = struct {
    gain: f32,
    speech_db: f64,
};

/// Capture mono audio on the selected channel and run auto-gain to convergence.
fn calibrateGain(target: ?[:0]const u8, channel_position: u32, duration_secs: u32) !CalibrationResult {
    const sample_rate: u32 = 16000;
    const expected_bytes: usize = sample_rate * 2 * duration_secs; // mono S16_LE

    const pipe_fds = try posix.pipe();
    // zwanzig-disable: store-violations-engine
    errdefer {
        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);
    }
    // zwanzig-enable: store-violations-engine

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

    // Read audio and run auto-gain
    var auto_gain = AutoGain{};
    var recv_buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    var last_speech_db: f64 = -100;

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
        if (db > -50) last_speech_db = db;

        if (auto_gain.update(rms)) |new_gain| {
            pw.pw_thread_loop_lock(thread_loop);
            _ = pw.pw_set_stream_gain(stream, new_gain, 1);
            pw.pw_thread_loop_unlock(thread_loop);
        }
    }

    // Cleanup
    pw.pw_thread_loop_stop(thread_loop);
    pw.pw_stream_destroy(stream);
    pw.pw_thread_loop_destroy(thread_loop);
    posix.close(pipe_fds[0]);
    // zwanzig-disable-next-line: store-violations-engine
    posix.close(pipe_fds[1]);
    std.heap.page_allocator.destroy(stream_data);
    pw.pw_deinit();

    return .{ .gain = auto_gain.current_gain, .speech_db = last_speech_db };
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

    // Create pipe
    const pipe_fds = try posix.pipe();
    // zwanzig-disable: store-violations-engine
    errdefer {
        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);
    }
    // zwanzig-enable: store-violations-engine

    // Init PipeWire
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

    // Read audio for the specified duration
    var buf = try allocator.alloc(u8, expected_bytes);
    // zwanzig-disable-next-line: store-violations-engine
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
    // zwanzig-disable-next-line: store-violations-engine
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
