const std = @import("std");
const pipeline_mod = @import("../backend/pipeline.zig");
const Pipeline = pipeline_mod.Pipeline;
const backend_init = @import("../backend/init.zig");
const AudioCapture = @import("../platform/audio.zig").AudioCapture;
const AutoGain = @import("auto_gain.zig").AutoGain;
const utils = @import("utils.zig");
const recorder_mod = @import("recorder.zig");
const Recorder = recorder_mod.Recorder;

const posix = std.posix;
const net = std.net;

// Global live state (module-level so input handler can access it via setLive).
// Default not-live. Callers set it explicitly: runTcp on accept/disconnect,
// main.zig for no-trigger local mode, trigger key press/release.
pub var is_live = std.atomic.Value(bool).init(false);

// Global capture pointer — set by runLocal so setLive can toggle the PipeWire stream.
// When non-null, setLive also activates/deactivates the stream so the desktop
// microphone indicator only appears during active recording.
var capture_ptr = std.atomic.Value(?*AudioCapture).init(null);

// Low-latency mode: cork/uncork stream instead of connect/disconnect.
// Set once during init, read from input thread via setLive().
var use_cork_mode = std.atomic.Value(bool).init(false);

// PTT latency tracking — set by input thread via setLive(), read by server loop.
// Use i64 (not i128) for atomic compatibility — nanoTimestamp fits in i64 for ~292 years.
var ptt_press_ns = std.atomic.Value(i64).init(0);
var pw_connect_done_ns = std.atomic.Value(i64).init(0);

fn nanoTimestampI64() i64 {
    return @intCast(std.time.nanoTimestamp());
}

pub fn setLive(live: bool) void {
    if (live) ptt_press_ns.store(nanoTimestampI64(), .monotonic);
    is_live.store(live, .monotonic);
    if (capture_ptr.load(.monotonic)) |cap| {
        if (use_cork_mode.load(.monotonic)) {
            cap.setCork(!live);
        } else {
            cap.setActive(live);
        }
        if (live) pw_connect_done_ns.store(nanoTimestampI64(), .monotonic);
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
/// bytes at a time, ensuring every transport (TCP, PipeWire pipe, etc.)
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
            // Digital zero is never real audio — skip it. This strips PipeWire
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

pub const InputMode = enum { tcp, local };

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
    port: u16,
    input_mode: InputMode,
    pw_target: ?[:0]const u8,
    pw_channel: u32,
    verbose: bool,
    low_latency: bool,
    type_callback: ?TypeCallback,
    drop_terms: []const []const u8,
    recorder: ?*Recorder,
    initial_gain: f32,
    no_auto_gain: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        pipeline_factory: PipelineFactory,
        port: u16,
        input_mode: InputMode,
        pw_target: ?[:0]const u8,
        pw_channel: u32,
        verbose: bool,
        low_latency: bool,
        type_callback: ?TypeCallback,
        drop_terms: []const []const u8,
        recorder: ?*Recorder,
        initial_gain: f32,
        no_auto_gain: bool,
    ) Server {
        return .{
            .allocator = allocator,
            .pipeline_factory = pipeline_factory,
            .port = port,
            .input_mode = input_mode,
            .pw_target = pw_target,
            .pw_channel = pw_channel,
            .verbose = verbose,
            .low_latency = low_latency,
            .type_callback = type_callback,
            .drop_terms = drop_terms,
            .recorder = recorder,
            .initial_gain = initial_gain,
            .no_auto_gain = no_auto_gain,
        };
    }

    pub fn run(self: *Server) !void {
        switch (self.input_mode) {
            .tcp => try self.runTcp(),
            .local => try self.runPipeWire(),
        }
    }

    fn runTcp(self: *Server) !void {
        const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port);
        const listener = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 1);

        // Query actual port (needed when self.port == 0 for OS-assigned port)
        var bound: net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(@TypeOf(bound.any));
        try posix.getsockname(listener, &bound.any, &addr_len);
        const actual_port = bound.getPort();

        std.debug.print("Listening on port {d}\n", .{actual_port});

        while (true) {
            const conn = try posix.accept(listener, null, null, posix.SOCK.CLOEXEC);
            defer posix.close(conn);

            std.debug.print("Client connected\n", .{});
            setLive(true);
            if (self.recorder) |rec| rec.startRecording();
            self.handleConnection(conn, conn, self.type_callback) catch |err| {
                std.debug.print("Connection error: {}\n", .{err});
            };
            if (self.recorder) |rec| rec.endRecording() catch |err| {
                std.debug.print("[rec] write error: {}\n", .{err});
            };
            setLive(false);
            std.debug.print("Client disconnected\n", .{});
        }
    }

    fn runPipeWire(self: *Server) !void {
        std.debug.print("Starting local PipeWire capture...\n", .{});

        var capture = AudioCapture.init(self.pw_target, self.pw_channel) catch |err| {
            std.debug.print("Failed to start PipeWire capture: {}\n", .{err});
            return err;
        };
        defer capture.deinit();

        // Register capture so setLive can toggle stream active state.
        capture_ptr.store(&capture, .monotonic);
        defer capture_ptr.store(null, .monotonic);

        // Apply calibrated initial gain (from --pw-gain) before first audio arrives
        if (self.initial_gain > 1.01) {
            capture.setGain(self.initial_gain);
            std.debug.print("Auto-gain starting at {d:.1}x\n", .{self.initial_gain});
        }

        if (self.low_latency) {
            // Low-latency mode: connect stream once at startup, use cork/uncork for PTT.
            // Mic indicator stays visible, but avoids ~1.3s PipeWire reconnect on each press.
            use_cork_mode.store(true, .monotonic);
            capture.setActive(true);
            if (!is_live.load(.monotonic)) {
                capture.setCork(true);
            }
            std.debug.print("Low-latency mode: stream stays connected, using cork/uncork\n", .{});
        } else if (is_live.load(.monotonic)) {
            // Normal mode: connect now (no --trigger, always live).
            capture.setActive(true);
        }

        const stdout_fd: posix.fd_t = 1; // STDOUT_FILENO
        if (self.type_callback != null) {
            std.debug.print("Capturing audio, injecting text via uinput\n", .{});
        } else {
            std.debug.print("Capturing audio, transcribing to stdout\n", .{});
        }

        self.handleConnection(capture.getFd(), stdout_fd, self.type_callback) catch |err| {
            std.debug.print("Local capture error: {}\n", .{err});
            return err;
        };
    }

    /// PTT-gated streaming loop. Audio chunks go directly to the pipeline
    /// for incremental processing. No VAD — PTT press/release drives segmentation.
    pub fn handleConnection(self: *Server, audio_fd: posix.fd_t, output_fd: posix.fd_t, type_cb: ?TypeCallback) !void {
        const asr = try self.pipeline_factory.create(self.allocator);
        defer {
            asr.deinit();
            self.allocator.destroy(asr);
        }

        var auto_gain = AutoGain{ .current_gain = self.initial_gain };

        // 560ms chunks = 56 mel frames × 160 hop × 2 bytes/sample = 17920 bytes
        const streaming_chunk_bytes: usize = 17920;
        var reader = ChunkedReader.init(audio_fd, streaming_chunk_bytes, true);
        var was_live: bool = is_live.load(.monotonic);
        var total_audio_bytes: usize = 0;

        while (true) {
            const audio = try reader.read();
            const n = audio.len;

            // EOF
            if (n == 0) {
                if (was_live) {
                    // Flush any remaining audio
                    const samples = try utils.pcmToFloat(self.allocator, &.{});
                    defer self.allocator.free(samples);
                    if (try asr.transcribe(samples, true, null)) |result| {
                        defer self.allocator.free(result.text);
                        defer self.allocator.free(result.words);
                        defer self.allocator.free(result.tokens);
                        defer self.allocator.free(result.token_frames);
                        if (result.text.len > 0 and !result.was_rewind) {
                            self.emitDelta(output_fd, total_audio_bytes, result.text, type_cb) catch {};
                        }
                    }
                    asr.resetSegment();
                }
                std.debug.print("handleConnection returning (EOF path)\n", .{});
                reader.logSummary();
                return;
            }

            total_audio_bytes += n;
            const live = is_live.load(.monotonic);

            // PTT release edge: flush + reset
            if (was_live and !live) {
                // Flush pipeline
                const samples = try utils.pcmToFloat(self.allocator, audio);
                defer self.allocator.free(samples);
                if (try asr.transcribe(samples, true, null)) |result| {
                    defer self.allocator.free(result.text);
                    defer self.allocator.free(result.words);
                    defer self.allocator.free(result.tokens);
                    defer self.allocator.free(result.token_frames);
                    if (result.text.len > 0 and !result.was_rewind) {
                        self.emitDelta(output_fd, total_audio_bytes, result.text, type_cb) catch return error.BrokenPipe;
                    }
                    if (self.verbose) {
                        var ts_buf: [32]u8 = undefined;
                        std.debug.print("[{s}s] PTT release — flush: \"{s}\" ({d:.0}ms)\n", .{
                            formatAudioTime(&ts_buf, total_audio_bytes),
                            utils.textPreview(result.text),
                            result.timing.total_ms,
                        });
                    }
                }
                asr.resetSegment();
                if (self.recorder) |rec| rec.endRecording() catch {};
                was_live = false;
                continue;
            }

            // Not live: discard audio
            if (!live) {
                was_live = false;
                continue;
            }

            // PTT press edge: start fresh
            if (!was_live and live) {
                asr.resetSegment();
                was_live = true;
                if (self.recorder) |rec| rec.startRecording();
                if (self.verbose) {
                    var ts_buf: [32]u8 = undefined;
                    std.debug.print("[{s}s] PTT press — streaming start\n", .{formatAudioTime(&ts_buf, total_audio_bytes)});
                }
            }

            // Live: process chunk
            if (self.recorder) |rec| rec.recordPcm(audio);

            // Auto-gain (PipeWire only)
            if (!self.no_auto_gain) {
                if (capture_ptr.load(.monotonic)) |cap| {
                    const rms = utils.channelRms(audio, 1, 0);
                    if (auto_gain.update(rms)) |new_gain| {
                        cap.setGain(new_gain);
                        if (self.verbose) std.debug.print("  auto-gain: {d:.2}x\n", .{new_gain});
                    }
                }
            }

            const samples = try utils.pcmToFloat(self.allocator, audio);
            defer self.allocator.free(samples);

            if (try asr.transcribe(samples, false, null)) |result| {
                defer self.allocator.free(result.text);
                defer self.allocator.free(result.words);
                defer self.allocator.free(result.tokens);
                defer self.allocator.free(result.token_frames);
                if (result.text.len > 0 and !result.was_rewind) {
                    // Drop terms: check if full result text matches any drop term
                    if (!self.isDropTerm(result.text)) {
                        self.emitDelta(output_fd, total_audio_bytes, result.text, type_cb) catch return error.BrokenPipe;
                        if (self.verbose) {
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

    /// Write a timestamped delta to the output fd (or type callback) and log it.
    fn emitDelta(self: *Server, output_fd: posix.fd_t, total_audio_bytes: usize, delta: []const u8, type_cb: ?TypeCallback) error{BrokenPipe}!void {
        var ts_buf: [32]u8 = undefined;
        const ts = formatAudioTime(&ts_buf, total_audio_bytes);

        if (type_cb) |cb| {
            // Inject text as keystrokes (evdev mode)
            cb.call(delta);
        } else {
            // Write wire protocol to fd
            _ = posix.write(output_fd, ts) catch return error.BrokenPipe;
            _ = posix.write(output_fd, "\t") catch return error.BrokenPipe;
            _ = posix.write(output_fd, delta) catch return error.BrokenPipe;
            _ = posix.write(output_fd, "\n") catch return error.BrokenPipe;
        }
        std.debug.print("  [{s}s] >> {s}\n", .{ ts, delta });
        if (self.recorder) |rec| rec.logEmit(delta);
    }
};

/// Format audio-position timestamp as "{s}.{tenths}" into buf.
/// Uses total audio bytes received (at 32000 bytes/sec) instead of wall-clock,
/// so timestamps are consistent across TCP fast, TCP realtime, and PipeWire modes.
fn formatAudioTime(buf: []u8, total_audio_bytes: usize) []u8 {
    const elapsed_ms: u64 = total_audio_bytes * 1000 / 32000;
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ elapsed_ms / 1000, (elapsed_ms % 1000) / 100 }) catch buf[0..3];
}
