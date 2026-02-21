const std = @import("std");
const pw = @import("pipewire_c.zig");
const posix = std.posix;

const log = std.log.scoped(.audio_capture);

/// Shared state between main thread and PipeWire callback thread.
/// Heap-allocated so the pointer remains stable for the stream's lifetime.
const StreamData = struct {
    stream: ?*pw.pw_stream = null,
    pipe_write_fd: posix.fd_t,
};

pub const AudioCapture = struct {
    thread_loop: *pw.pw_thread_loop,
    stream: *pw.pw_stream,
    stream_data: *StreamData,
    channel_position: u32,
    pipe_read_fd: posix.fd_t,
    pipe_write_fd: posix.fd_t,

    const stream_events = pw.pw_stream_events{
        .version = 2, // PW_VERSION_STREAM_EVENTS
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

    pub fn init(target: ?[:0]const u8, channel_position: u32) !AudioCapture {
        // Create pipe for passing PCM from PipeWire thread to main thread
        const pipe_fds = try posix.pipe();
        // zwanzig-disable: store-violations-engine
        errdefer {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
        }
        // zwanzig-enable: store-violations-engine

        // Initialize PipeWire library
        pw.pw_init(null, null);

        // Allocate callback data on heap (stable pointer for stream lifetime)
        const stream_data = try std.heap.page_allocator.create(StreamData);
        stream_data.* = .{ .pipe_write_fd = pipe_fds[1] };
        errdefer std.heap.page_allocator.destroy(stream_data);

        // Create thread loop (PipeWire manages the thread)
        const thread_loop = pw.pw_thread_loop_new("capsper", null) orelse {
            log.err("Failed to create PipeWire thread loop", .{});
            return error.PipeWireInitFailed;
        };
        errdefer pw.pw_thread_loop_destroy(thread_loop);

        const loop = pw.pw_thread_loop_get_loop(thread_loop);

        // Build stream properties
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

        if (props == null) {
            log.err("Failed to create PipeWire properties", .{});
            return error.PipeWireInitFailed;
        }

        // Create stream (takes ownership of props). Not connected yet —
        // call setActive(true) to connect and start streaming.
        const stream = pw.pw_stream_new_simple(
            loop,
            "capsper",
            props,
            &stream_events,
            stream_data,
        ) orelse {
            log.err("Failed to create PipeWire stream", .{});
            return error.PipeWireInitFailed;
        };
        errdefer pw.pw_stream_destroy(stream);

        // Store stream pointer so the callback can access it
        stream_data.stream = stream;

        // Start the thread loop
        const start_result = pw.pw_thread_loop_start(thread_loop);
        if (start_result < 0) {
            log.err("Failed to start PipeWire thread loop: {d}", .{start_result});
            return error.PipeWireInitFailed;
        }

        if (target) |t| {
            log.info("PipeWire capture ready (target={s}, channel=0x{x})", .{ t, channel_position });
        } else {
            log.info("PipeWire capture ready (default source, channel=0x{x})", .{channel_position});
        }

        return .{
            .thread_loop = thread_loop,
            .stream = stream,
            .stream_data = stream_data,
            .channel_position = channel_position,
            .pipe_read_fd = pipe_fds[0],
            .pipe_write_fd = pipe_fds[1],
        };
    }

    /// Connect or disconnect the PipeWire stream. When disconnected, no
    /// source-output exists so the desktop microphone indicator disappears.
    pub fn setActive(self: *AudioCapture, active: bool) void {
        pw.pw_thread_loop_lock(self.thread_loop);
        defer pw.pw_thread_loop_unlock(self.thread_loop);
        if (active) {
            _ = pw.pw_connect_capture(self.stream, 16000, self.channel_position);
        } else {
            _ = pw.pw_stream_disconnect(self.stream);
        }
    }

    /// Set software gain on the PipeWire capture stream (1.0 = unity, 4.0 = ~12 dB boost).
    pub fn setGain(self: *AudioCapture, gain: f32) void {
        pw.pw_thread_loop_lock(self.thread_loop);
        defer pw.pw_thread_loop_unlock(self.thread_loop);
        _ = pw.pw_set_stream_gain(self.stream, gain, 1);
    }

    /// Cork or uncork the stream. The stream stays connected (mic indicator
    /// remains visible) but audio delivery is paused/resumed. Much faster
    /// than connect/disconnect (~2ms vs ~1300ms).
    pub fn setCork(self: *AudioCapture, corked: bool) void {
        pw.pw_thread_loop_lock(self.thread_loop);
        defer pw.pw_thread_loop_unlock(self.thread_loop);
        _ = pw.pw_stream_set_active(self.stream, !corked);
    }

    pub fn getFd(self: *const AudioCapture) posix.fd_t {
        return self.pipe_read_fd;
    }

    pub fn deinit(self: *AudioCapture) void {
        pw.pw_thread_loop_stop(self.thread_loop);
        pw.pw_stream_destroy(self.stream);
        pw.pw_thread_loop_destroy(self.thread_loop);
        posix.close(self.pipe_read_fd);
        posix.close(self.pipe_write_fd);
        std.heap.page_allocator.destroy(self.stream_data);
        pw.pw_deinit();
    }
};

/// PipeWire process callback — runs in PipeWire's realtime thread.
/// Dequeues captured audio buffers and writes raw S16_LE PCM to the pipe.
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

    // Write to pipe — non-blocking best-effort. If the pipe is full,
    // the main thread isn't reading fast enough and we drop this buffer.
    _ = posix.write(data.pipe_write_fd, audio_data) catch {};
}
