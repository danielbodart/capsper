const std = @import("std");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;

pub const EndReason = enum {
    flush,
    timeout,
    pause,

    pub fn label(self: EndReason) []const u8 {
        return switch (self) {
            .flush => "flush",
            .timeout => "timeout",
            .pause => "pause",
        };
    }
};

pub const Recorder = struct {
    allocator: Allocator,
    dir: std.fs.Dir,
    keep: usize,
    seq: usize,
    diag_buf: std.ArrayListUnmanaged(u8),
    emit_buf: std.ArrayListUnmanaged(u8),
    rec_buf: std.ArrayListUnmanaged(u8),
    active: bool,
    utterance_start_ns: i128,

    pub fn init(allocator: Allocator, dir_path: []const u8, keep: usize) !Recorder {
        const dir = try std.fs.cwd().openDir(dir_path, .{});
        return .{
            .allocator = allocator,
            .dir = dir,
            .keep = keep,
            .seq = 0,
            .diag_buf = .{},
            .emit_buf = .{},
            .rec_buf = .{},
            .active = false,
            .utterance_start_ns = 0,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.diag_buf.deinit(self.allocator);
        self.emit_buf.deinit(self.allocator);
        self.rec_buf.deinit(self.allocator);
        self.dir.close();
    }

    /// Called on idle→speaking. Seeds rec_buf with current pcm_buf (which contains
    /// the pre-speech audio that triggered VAD) so the recording captures the full
    /// utterance from the start, not just audio arriving after the state transition.
    pub fn startUtterance(self: *Recorder, initial_pcm: []const u8) void {
        self.rec_buf.clearRetainingCapacity();
        self.rec_buf.appendSlice(self.allocator, initial_pcm) catch {};
        self.diag_buf.clearRetainingCapacity();
        self.emit_buf.clearRetainingCapacity();
        self.active = true;
        self.utterance_start_ns = std.time.nanoTimestamp();
    }

    /// Called on each recv_buf read during active utterance. Appends PCM to rec_buf.
    pub fn recordPcm(self: *Recorder, data: []const u8) void {
        if (!self.active) return;
        self.rec_buf.appendSlice(self.allocator, data) catch {};
    }

    /// Called after each transcription cycle.
    pub fn logCycle(
        self: *Recorder,
        start_ns: i128,
        cycle: usize,
        state_name: []const u8,
        buf_ms: usize,
        word_count: usize,
        text: []const u8,
    ) void {
        if (!self.active) return;
        var ts_buf: [32]u8 = undefined;
        const ts = formatElapsed(&ts_buf, start_ns);
        const w = self.diag_buf.writer(self.allocator);
        std.fmt.format(w, "[{s}s] cycle={d} {s} buf={d}ms words={d} | \"{s}\"\n", .{
            ts, cycle, state_name, buf_ms, word_count, utils.textPreview(text),
        }) catch {};
    }

    /// Called after each emitDelta.
    pub fn logEmit(self: *Recorder, text: []const u8) void {
        if (!self.active) return;
        const w = self.diag_buf.writer(self.allocator);
        std.fmt.format(w, "  \xe2\x86\x92 emit: \"{s}\"\n", .{text}) catch {};
        self.emit_buf.appendSlice(self.allocator, text) catch {};
    }

    /// Called at utterance end. Writes NNN.wav + NNN.log, advances seq.
    pub fn endUtterance(self: *Recorder, reason: EndReason) !void {
        if (!self.active) return;
        self.active = false;

        const idx = self.seq % self.keep;
        self.seq += 1;

        // Write WAV: build in memory, then write atomically
        var wav_name_buf: [16]u8 = undefined;
        const wav_name = std.fmt.bufPrint(&wav_name_buf, "{d:0>3}.wav", .{idx}) catch return;
        {
            var wav_buf = std.ArrayListUnmanaged(u8){};
            defer wav_buf.deinit(self.allocator);
            try utils.writeWav(wav_buf.writer(self.allocator), self.rec_buf.items);
            var file = try self.dir.createFile(wav_name, .{});
            defer file.close();
            try file.writeAll(wav_buf.items);
        }

        // Write log: build in memory, then write atomically
        var log_name_buf: [16]u8 = undefined;
        const log_name = std.fmt.bufPrint(&log_name_buf, "{d:0>3}.log", .{idx}) catch return;
        {
            var log_buf = std.ArrayListUnmanaged(u8){};
            defer log_buf.deinit(self.allocator);
            const w = log_buf.writer(self.allocator);
            const duration_ms = self.utteranceDurationMs();
            std.fmt.format(w, "=== Capsper Recording {d:0>3} ===\n", .{self.seq - 1}) catch {};
            std.fmt.format(w, "Duration: {d}.{d}s ({d} bytes)\n", .{
                duration_ms / 1000, (duration_ms % 1000) / 100, self.rec_buf.items.len,
            }) catch {};
            std.fmt.format(w, "End reason: {s}\n", .{reason.label()}) catch {};
            w.writeAll("\n--- Emitted Text ---\n") catch {};
            w.writeAll(self.emit_buf.items) catch {};
            w.writeAll("\n\n--- Cycle Log ---\n") catch {};
            w.writeAll(self.diag_buf.items) catch {};
            var file = try self.dir.createFile(log_name, .{});
            defer file.close();
            try file.writeAll(log_buf.items);
        }

        std.debug.print("[rec] wrote {s} + {s} ({d} bytes audio)\n", .{
            wav_name, log_name, self.rec_buf.items.len,
        });
    }

    fn utteranceDurationMs(self: *const Recorder) u64 {
        const elapsed_ns = std.time.nanoTimestamp() - self.utterance_start_ns;
        return @intCast(@max(0, @divTrunc(elapsed_ns, 1_000_000)));
    }
};

fn formatElapsed(buf: []u8, start_ns: i128) []u8 {
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    const elapsed_ms: u64 = @intCast(@max(0, @divTrunc(elapsed_ns, 1_000_000)));
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ elapsed_ms / 1000, (elapsed_ms % 1000) / 100 }) catch buf[0..3];
}
