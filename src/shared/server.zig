const std = @import("std");
const pipeline_mod = @import("../backend/pipeline.zig");
const Pipeline = pipeline_mod.Pipeline;
const backend_init = @import("../backend/init.zig");
const AudioCapture = @import("../platform/audio.zig").AudioCapture;
const AutoGain = @import("auto_gain.zig").AutoGain;
const MicLevel = @import("../platform/mic_level.zig").MicLevel;
const utils = @import("utils.zig");
const recorder_mod = @import("recorder.zig");
const Recorder = recorder_mod.Recorder;
const session = @import("session.zig");
const webvtt = @import("webvtt.zig");
const status = @import("status.zig");
const Config = @import("config.zig").Config;
const EventSource = session.EventSource;
const Event = session.Event;

const posix = std.posix;
const net = std.net;

const log = std.log.scoped(.input_level);

// 560ms chunks = 56 mel frames × 160 hop × 2 bytes/sample = 17920 bytes
const STREAMING_CHUNK_BYTES: usize = 17920;

// Global live state for local PTT mode (module-level so input handler can access it via setLive).
// Default not-live. Callers set it explicitly: main.zig for no-trigger local mode, trigger key press/release.
// TCP connections use their own per-connection atomic (always true).
pub var is_live = std.atomic.Value(bool).init(false);

// Global capture pointer — set by runLocalCapture so setLive can toggle the audio stream.
// When non-null, setLive also activates/deactivates the stream so the desktop
// microphone indicator only appears during active recording.
var capture_ptr = std.atomic.Value(?*AudioCapture).init(null);

// Low-latency mode: the capture stream is connected once and stays continuously
// active; PTT gating happens in software (SessionDriver.live) rather than by
// corking or disconnecting the stream. Set once during init, read from the input
// thread via setLive(). Corking let the PipeWire node go to `suspended`, and
// uncork from suspend (pw_stream_set_active(true)) did not reliably restart data
// flow — dropping the first seconds of audio on rapid re-press and cold starts —
// so low-latency never corks.
var stream_always_active = std.atomic.Value(bool).init(false);

// PTT latency tracking — set by input thread via setLive(), read by server loop.
// Use i64 (not i128) for atomic compatibility — nanoTimestamp fits in i64 for ~292 years.
var ptt_press_ns = std.atomic.Value(i64).init(0);
var capture_connect_done_ns = std.atomic.Value(i64).init(0);

// PTT transition pipe: setLive() (input thread) writes 1=press / 0=release;
// LocalPttEventSource reads it, so releases reach the session loop even when the
// audio stream is corked. -1 until runLocalCapture creates the pipe.
var ptt_event_write_fd = std.atomic.Value(i32).init(-1);

fn nanoTimestampI64() i64 {
    return @intCast(std.time.nanoTimestamp());
}

pub fn setLive(live: bool) void {
    if (live) ptt_press_ns.store(nanoTimestampI64(), .monotonic);
    is_live.store(live, .monotonic);
    // The same fact, somewhere the console can read it without importing the
    // audio path to get at it.
    status.live.store(live, .monotonic);
    // Deliver the transition to the local session loop (survives cork).
    const pfd = ptt_event_write_fd.load(.monotonic);
    if (pfd >= 0) {
        const byte = [_]u8{@intFromBool(live)};
        _ = posix.write(pfd, &byte) catch {};
    }
    if (capture_ptr.load(.monotonic)) |cap| {
        // Low-latency keeps the stream continuously active; the SessionDriver
        // gates on `live` in software, so we must NOT toggle the stream here.
        // Only non-low-latency mode connects/disconnects per press.
        if (!stream_always_active.load(.monotonic)) {
            cap.setActive(live);
        }
        if (live) capture_connect_done_ns.store(nanoTimestampI64(), .monotonic);
    }
}

/// Type-erased callback for injecting text (used by evdev/uinput mode).
pub const TypeCallback = struct {
    context: *anyopaque,
    func: *const fn (*anyopaque, []const u8) void,

    pub fn call(self: TypeCallback, text: []const u8) void {
        self.func(self.context, text);
    }
};

/// Chunked audio reader. Buffers raw reads and yields exactly `chunk_size`
/// bytes at a time, ensuring every transport (TCP, local audio capture, etc.)
/// delivers identical chunk boundaries to the server loop.
const ChunkedReader = struct {
    fd: posix.fd_t,
    chunk_size: usize,
    buf: [32768]u8 = undefined,
    buffered: usize = 0, // bytes available in buf[0..buffered]
    offset: usize = 0, // read cursor within buf[0..buffered]
    saw_eof: bool = false,
    skip_digital_zero: bool,

    // Cumulative counters for logging
    total_raw_reads: usize = 0,
    total_raw_bytes: usize = 0,
    total_chunks_yielded: usize = 0,
    total_chunks_bytes: usize = 0,
    total_zero_chunks_skipped: usize = 0,
    total_partial_bytes: usize = 0,

    fn init(fd: posix.fd_t, chunk_size: usize, skip_digital_zero: bool) ChunkedReader {
        return .{ .fd = fd, .chunk_size = chunk_size, .skip_digital_zero = skip_digital_zero };
    }

    /// Read exactly one chunk of audio, or empty slice on EOF.
    /// Caller does not own the returned memory.
    fn read(self: *ChunkedReader) ![]u8 {
        while (true) {
            const chunk = try self.readChunk();
            if (chunk.len == 0) return chunk; // EOF
            // Digital zero is never real audio — skip it. This strips audio system
            // pipeline latency and trailing silence from loopback teardown.
            if (self.skip_digital_zero and std.mem.allEqual(u8, chunk, 0)) {
                self.total_zero_chunks_skipped += 1;
                continue;
            }
            return chunk;
        }
    }

    fn readChunk(self: *ChunkedReader) ![]u8 {
        // Compact: move unconsumed data to front
        if (self.offset > 0 and self.buffered > self.offset) {
            const remaining = self.buffered - self.offset;
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.offset..self.buffered]);
            self.buffered = remaining;
            self.offset = 0;
        } else if (self.offset > 0) {
            self.buffered = 0;
            self.offset = 0;
        }

        // Fill buffer until we have a full chunk (or EOF)
        while (self.buffered < self.chunk_size) {
            if (self.saw_eof) return &.{};
            const n = posix.read(self.fd, self.buf[self.buffered..]) catch |err| switch (err) {
                error.ConnectionResetByPeer => return &.{},
                else => return err,
            };
            if (n == 0) {
                self.saw_eof = true;
                // Return whatever we have (partial final chunk) — S16-aligned
                if (self.buffered > self.offset) {
                    var len = self.buffered - self.offset;
                    len -= len % 2; // ensure even number of bytes
                    if (len > 0) {
                        self.total_partial_bytes += len;
                        const start = self.offset;
                        self.offset += len;
                        return self.buf[start..start + len];
                    }
                }
                return &.{};
            }
            self.total_raw_reads += 1;
            self.total_raw_bytes += n;
            self.buffered += n;
        }

        // Yield exactly one chunk
        self.total_chunks_yielded += 1;
        self.total_chunks_bytes += self.chunk_size;
        const start = self.offset;
        self.offset += self.chunk_size;
        return self.buf[start..start + self.chunk_size];
    }

    fn logSummary(self: *const ChunkedReader) void {
        std.debug.print("[chunked-reader] raw_reads={d} raw_bytes={d} ({d}ms) chunks={d} chunk_bytes={d} ({d}ms) partial={d}bytes zero_skipped={d}\n", .{
            self.total_raw_reads,
            self.total_raw_bytes,
            self.total_raw_bytes * 1000 / 32000,
            self.total_chunks_yielded,
            self.total_chunks_bytes,
            self.total_chunks_bytes * 1000 / 32000,
            self.total_partial_bytes,
            self.total_zero_chunks_skipped,
        });
    }
};

/// EventSource for TCP connections and file streams. Emits only `audio`/`eof`
/// — never press/release/timeout — so PTT/recording/timeout logic is
/// structurally unable to touch the data-driven path that keeps tests fast.
/// Blocking read, no poll, no timer: throughput is driven purely by data.
const TcpEventSource = struct {
    reader: ChunkedReader,

    fn init(fd: posix.fd_t, chunk_bytes: usize) TcpEventSource {
        return .{ .reader = ChunkedReader.init(fd, chunk_bytes, true) };
    }

    fn source(self: *TcpEventSource) EventSource {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = EventSource.VTable{ .next = nextImpl };

    fn nextImpl(ptr: *anyopaque) anyerror!Event {
        const self: *TcpEventSource = @ptrCast(@alignCast(ptr));
        const chunk = try self.reader.read();
        if (chunk.len == 0) return .eof;
        return .{ .audio = chunk };
    }
};

/// Per-connection argument struct for TCP handler threads.
const TcpConnection = struct {
    server: *Server,
    conn_fd: posix.fd_t,
};

/// Creates a fresh Pipeline for each connection.
pub const PipelineFactory = struct {
    backend: *backend_init.BackendState,

    pub fn create(self: PipelineFactory, allocator: std.mem.Allocator) !*Pipeline {
        return self.backend.createPipeline(allocator);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    pipeline_factory: PipelineFactory,
    /// Every setting the server reads. Borrowed, and outlives the server.
    cfg: *const Config,
    /// `cfg.audio.channel` resolved to this platform's channel position.
    /// Resolved once, by whoever built the config, so the server never has to
    /// deal with a name the platform cannot map.
    audio_channel: u32,
    want_local: bool,
    type_callback: ?TypeCallback,
    drop_terms: []const []const u8,
    recorder: ?*Recorder,

    /// Named rather than positional: this used to be fourteen arguments in a
    /// row, six of which were bools.
    pub const Options = struct {
        cfg: *const Config,
        audio_channel: u32,
        want_local: bool = false,
        type_callback: ?TypeCallback = null,
        drop_terms: []const []const u8 = &.{},
        recorder: ?*Recorder = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        pipeline_factory: PipelineFactory,
        opts: Options,
    ) Server {
        return .{
            .allocator = allocator,
            .pipeline_factory = pipeline_factory,
            .cfg = opts.cfg,
            .audio_channel = opts.audio_channel,
            .want_local = opts.want_local,
            .type_callback = opts.type_callback,
            .drop_terms = opts.drop_terms,
            .recorder = opts.recorder,
        };
    }

    pub fn run(self: *Server) !void {
        if (self.want_local and self.cfg.tcp_server.port != null) {
            // Both modes: spawn local capture in background, run TCP in calling thread.
            const t = std.Thread.spawn(.{}, runLocalCaptureThread, .{self});
            if (t) |thread| {
                thread.detach();
            } else |err| {
                std.debug.print("Failed to spawn local capture thread: {}\n", .{err});
                return err;
            }
            try self.runTcp();
        } else if (self.cfg.tcp_server.port != null) {
            try self.runTcp();
        } else if (self.want_local) {
            try self.runLocalCapture();
        }
    }

    fn runTcp(self: *Server) !void {
        const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, self.cfg.tcp_server.port.?);
        const listener = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 8);

        // Query actual port (needed when self.cfg.tcp_server.port == 0 for OS-assigned port)
        var bound: net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(@TypeOf(bound.any));
        try posix.getsockname(listener, &bound.any, &addr_len);
        const actual_port = bound.getPort();

        std.debug.print("Listening on port {d}\n", .{actual_port});

        while (true) {
            const conn = try posix.accept(listener, null, null, posix.SOCK.CLOEXEC);

            const args = self.allocator.create(TcpConnection) catch {
                std.debug.print("Failed to allocate TCP connection\n", .{});
                posix.close(conn);
                continue;
            };
            args.* = .{ .server = self, .conn_fd = conn };
            const t = std.Thread.spawn(.{}, tcpConnectionThread, .{args});
            if (t) |thread| {
                thread.detach();
            } else |err| {
                std.debug.print("Failed to spawn connection thread: {}\n", .{err});
                posix.close(conn);
                self.allocator.destroy(args);
            }
        }
    }

    fn tcpConnectionThread(args: *TcpConnection) void {
        defer {
            posix.close(args.conn_fd);
            args.server.allocator.destroy(args);
        }
        _ = status.tcp_clients.fetchAdd(1, .monotonic);
        defer _ = status.tcp_clients.fetchSub(1, .monotonic);
        std.debug.print("Client connected\n", .{});
        // TCP is always-live and data-driven: audio/eof only, no PTT events.
        var evsrc = TcpEventSource.init(args.conn_fd, STREAMING_CHUNK_BYTES);
        args.server.handleSession(evsrc.source(), args.conn_fd, null, null, true) catch |err| {
            std.debug.print("Connection error: {}\n", .{err});
        };
        std.debug.print("Client disconnected\n", .{});
    }

    fn runLocalCaptureThread(self: *Server) void {
        self.runLocalCapture() catch |err| {
            std.debug.print("Local capture error: {}\n", .{err});
        };
    }

    fn runLocalCapture(self: *Server) !void {
        std.debug.print("Starting local audio capture...\n", .{});

        var capture = AudioCapture.init(.{ .target = self.cfg.audio.target, .channel = self.audio_channel }) catch |err| {
            std.debug.print("Failed to start audio capture: {}\n", .{err});
            return err;
        };
        defer capture.deinit();

        // Register capture so setLive can toggle stream active state.
        capture_ptr.store(&capture, .monotonic);
        defer capture_ptr.store(null, .monotonic);

        if (self.cfg.audio.on_device_lost == .exit) {
            capture.setExitOnDeviceLost();
        }

        // The microphone's own level, set on the node rather than on this
        // capture of it, which is where meeting capture sets it too. One
        // mechanism, and the one the rest of the desktop already uses.
        //
        // A null target follows whatever the desktop calls the default input
        // and keeps following it, so unplugging one microphone and speaking
        // into another needs nothing said here.
        //
        // Not fatal when it is unavailable: dictation at the wrong level still
        // dictates.
        var level: ?MicLevel = MicLevel.init(self.cfg.audio.target) catch |err| blk: {
            log.warn("levelling the microphone is unavailable: {}", .{err});
            break :blk null;
        };
        defer if (level) |*l| l.deinit();

        if (level) |*l| {
            status.dictation.reportDevice(l.nodeName());
            status.dictation.reportGain(self.cfg.audio.gain);
            if (self.cfg.audio.gain > 1.01) {
                _ = l.set(self.cfg.audio.gain);
                std.debug.print("Auto-gain starting at {d:.1}x\n", .{self.cfg.audio.gain});
            }
        }

        if (self.cfg.trigger.low_latency) {
            // Low-latency mode: connect the stream once and leave it active for
            // the process lifetime. PTT gating is done in software by the
            // SessionDriver (non-live audio is discarded), so the stream is never
            // corked or disconnected. This avoids both the ~1.3s reconnect of
            // normal mode and the uncork-from-suspend audio loss that corking
            // caused. Mic indicator stays visible (accepted low-latency trade-off).
            stream_always_active.store(true, .monotonic);
            capture.setActive(true);
            // Stream is never corked/reconnected per press, so re-route to the
            // target device via the hotplug monitor instead (e.g. the mic is
            // powered on after login). No-op on macOS.
            capture.armTargetReconnect();
            std.debug.print("Low-latency mode: stream stays active, PTT gated in software\n", .{});
        } else if (is_live.load(.monotonic)) {
            // Normal mode: connect now (no --trigger, always live).
            capture.setActive(true);
        }

        const stdout_fd: posix.fd_t = 1; // STDOUT_FILENO
        if (self.type_callback != null) {
            std.debug.print("Capturing audio, injecting text via uinput.\n", .{});
        } else {
            std.debug.print("Capturing audio, transcribing to stdout\n", .{});
        }

        // PTT transition pipe: input thread writes press/release via setLive.
        const ptt_pipe = try posix.pipe();
        ptt_event_write_fd.store(ptt_pipe[1], .monotonic);
        defer {
            ptt_event_write_fd.store(-1, .monotonic);
            posix.close(ptt_pipe[1]);
            posix.close(ptt_pipe[0]);
        }

        var evsrc = session.LocalPttEventSource.init(capture.getFd(), ptt_pipe[0], STREAMING_CHUNK_BYTES, true);
        self.handleSession(evsrc.source(), stdout_fd, self.type_callback, if (level) |*l| l else null, is_live.load(.monotonic)) catch |err| {
            std.debug.print("Local capture error: {}\n", .{err});
            return err;
        };
    }

    /// Run a data-driven stream (a file fd or socket) through the session
    /// executor: always-live, audio/eof only, no PTT. Used by `--stream FILE`.
    pub fn handleDataStream(self: *Server, audio_fd: posix.fd_t, output_fd: posix.fd_t) !void {
        var evsrc = TcpEventSource.init(audio_fd, STREAMING_CHUNK_BYTES);
        return self.handleSession(evsrc.source(), output_fd, null, null, true);
    }

    /// Event-driven session executor. Consumes an EventSource and executes the
    /// pure SessionDriver's Actions against the real Pipeline/Recorder/output.
    /// The EventSource decides which events exist, so this one loop serves TCP
    /// (audio/eof only) and local PTT (adds press/release/timeout) identically —
    /// and PTT/recording logic can never touch a source that doesn't emit it.
    fn handleSession(
        self: *Server,
        src: EventSource,
        output_fd: posix.fd_t,
        type_cb: ?TypeCallback,
        /// The microphone's level, where one could be had. Not a capture of it:
        /// this addresses the node, which is what the level belongs on. Null
        /// for a session arriving over TCP, which owns no microphone.
        level: ?*MicLevel,
        live_at_start: bool,
    ) !void {
        const asr = try self.pipeline_factory.create(self.allocator);
        defer {
            asr.deinit();
            self.allocator.destroy(asr);
        }

        var auto_gain = AutoGain{ .current_gain = self.cfg.audio.gain };
        var driver = session.SessionDriver.init(live_at_start);
        var level_mon = session.InputLevelMonitor{};
        var total_audio_bytes: usize = 0;

        while (true) {
            const ev = try src.next();

            // Audio bookkeeping + auto-gain live at the event level; the
            // pipeline/recording decisions are the driver's job (via Actions).
            //
            // `chunk` is the span of recording this event covers, carried past
            // the action loop so the recorder can attribute whatever text the
            // chunk produced to the audio that produced it.
            var chunk: ?struct { start_ms: u64, end_ms: u64, rms: f64 } = null;
            if (ev == .audio) {
                const chunk_start_bytes = total_audio_bytes;
                total_audio_bytes += ev.audio.len;
                if (driver.live) {
                    const rms = utils.channelRms(ev.audio, 1, 0);
                    chunk = .{
                        .start_ms = webvtt.msFromBytes(chunk_start_bytes),
                        .end_ms = webvtt.msFromBytes(total_audio_bytes),
                        .rms = rms,
                    };
                    // One atomic store per chunk, on the same figure the log
                    // line below is computed from.
                    status.dictation.reportLevel(@floatCast(utils.rmsToDb(rms)));
                    // Input-level telemetry: log only on a rolling-average
                    // audio↔silence transition (never per chunk).
                    if (level_mon.update(utils.rmsToDb(rms))) |t| switch (t) {
                        .audio => log.info("audio detected ({d:.0} dBFS)", .{level_mon.levelDb()}),
                        .silence => log.info("silence detected ({d:.0} dBFS)", .{level_mon.levelDb()}),
                    };
                    if (self.cfg.audio.auto_gain) {
                        if (level) |l| {
                            // A different microphone is a different problem, so
                            // the controller starts again from the configured
                            // figure rather than carrying the old device's
                            // across. The change arrives as an event; nothing
                            // here goes looking for it.
                            if (l.tookChange()) {
                                auto_gain = .{ .current_gain = self.cfg.audio.gain };
                                _ = l.set(self.cfg.audio.gain);
                                status.dictation.reportDevice(l.nodeName());
                                status.dictation.reportGain(self.cfg.audio.gain);
                                log.info("microphone changed to '{s}', levelling from {d:.1}x again", .{
                                    l.nodeName(), self.cfg.audio.gain,
                                });
                            } else if (auto_gain.update(rms)) |new_gain| {
                                _ = l.set(new_gain);
                                status.dictation.reportGain(new_gain);
                                if (self.cfg.verbose) std.debug.print("  auto-gain: {d:.2}x\n", .{new_gain});
                            }
                        }
                    }
                }
            }

            const acts = driver.step(ev);
            for (acts.slice()) |a| switch (a) {
                .reset_segment => asr.resetSegment(),
                .start_recording => {
                    level_mon.reset();
                    if (self.recorder) |rec| rec.startRecording();
                    if (self.cfg.verbose) {
                        var ts_buf: [32]u8 = undefined;
                        std.debug.print("[{s}s] PTT press — streaming start\n", .{formatAudioTime(&ts_buf, total_audio_bytes)});
                    }
                },
                .record => |bytes| {
                    if (self.recorder) |rec| rec.recordPcm(bytes);
                },
                .transcribe => |t| try self.runTranscribe(asr, t.audio, t.flush, output_fd, type_cb, total_audio_bytes),
                .end_recording => {
                    if (self.recorder) |rec| rec.endRecording() catch {};
                },
                .stop => {
                    std.debug.print("session ended (eof)\n", .{});
                    return;
                },
            };

            // After the actions, so any text this chunk produced has already
            // reached the recorder and can be attributed to this audio.
            if (chunk) |c| {
                if (self.recorder) |rec| rec.markChunk(c.start_ms, c.end_ms, c.rms);
            }
        }
    }

    /// Transcribe one audio slice and emit any resulting text. `flush` forces
    /// the pipeline to finalize the segment (used on release/timeout/eof, where
    /// `audio` is empty — the trailing chunks already went in as `.audio`).
    fn runTranscribe(
        self: *Server,
        asr: *Pipeline,
        audio: []const u8,
        flush: bool,
        output_fd: posix.fd_t,
        type_cb: ?TypeCallback,
        total_audio_bytes: usize,
    ) !void {
        const samples = try utils.pcmToFloat(self.allocator, audio);
        defer self.allocator.free(samples);
        if (try asr.transcribe(samples, flush, null)) |result| {
            defer self.allocator.free(result.text);
            defer self.allocator.free(result.words);
            defer self.allocator.free(result.tokens);
            defer self.allocator.free(result.token_frames);
            if (result.text.len > 0 and !result.was_rewind) {
                if (!self.isDropTerm(result.text)) {
                    self.emitDelta(output_fd, total_audio_bytes, result.text, type_cb) catch return error.BrokenPipe;
                    if (self.cfg.verbose) {
                        var ts_buf: [32]u8 = undefined;
                        std.debug.print("    [{s}s] emit: \"{s}\" ({d:.0}ms)\n", .{
                            formatAudioTime(&ts_buf, total_audio_bytes),
                            utils.textPreview(result.text),
                            result.timing.total_ms,
                        });
                    }
                }
            }
        }
    }

    fn isDropTerm(self: *Server, text: []const u8) bool {
        if (self.drop_terms.len == 0) return false;
        for (self.drop_terms) |term| {
            if (std.mem.eql(u8, text, term)) return true;
            // Also match with leading space (some tokenizers prepend one)
            if (text.len == term.len + 1 and text[0] == ' ' and std.mem.eql(u8, text[1..], term)) return true;
        }
        return false;
    }

    /// Write transcription delta to the output fd (or type callback) and log it.
    fn emitDelta(self: *Server, output_fd: posix.fd_t, total_audio_bytes: usize, delta: []const u8, type_cb: ?TypeCallback) error{BrokenPipe}!void {
        if (type_cb) |cb| {
            // Inject text as keystrokes (evdev mode)
            cb.call(delta);
        } else {
            // Raw text stream — write exactly what the model produced
            _ = posix.write(output_fd, delta) catch return error.BrokenPipe;
        }
        var ts_buf: [32]u8 = undefined;
        std.debug.print("  [{s}s] >> {s}\n", .{ formatAudioTime(&ts_buf, total_audio_bytes), delta });
        if (self.recorder) |rec| rec.logEmit(delta);
    }
};

/// Format audio-position timestamp as "{s}.{tenths}" into buf.
/// Uses total audio bytes received (at 32000 bytes/sec) instead of wall-clock,
/// so timestamps are consistent across TCP fast, TCP realtime, and local capture modes.
fn formatAudioTime(buf: []u8, total_audio_bytes: usize) []u8 {
    const elapsed_ms: u64 = total_audio_bytes * 1000 / 32000;
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ elapsed_ms / 1000, (elapsed_ms % 1000) / 100 }) catch buf[0..3];
}
