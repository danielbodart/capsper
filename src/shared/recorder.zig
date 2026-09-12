// src/shared/recorder.zig — keeping the last few utterances, for chasing bugs.
//
// A debug recording and a meeting transcript are the same artefact at two
// verbosities, so they are the same writer. What differs is exactly two
// things: this rotates through `keep` slots rather than filing into dated
// directories, and it defaults to WAV rather than Opus because these are
// seconds long, ring-bounded, and regression comparisons want the raw samples.
// Everything else -- the cue logic, the format, the NOTE blocks and the
// setting that controls them -- is shared with `meeting_runner.zig`.
//
// The `.log` file this used to write alongside the WAV is gone, replaced by a
// `.vtt` that says strictly more. Its "Emitted Text" section was one
// undifferentiated run of text with no timings at all; its "Cycle Log" section
// was always empty, because the two functions that would have filled it had no
// callers. Cues carry the timings the log only promised.

const std = @import("std");
const utils = @import("utils.zig");
const webvtt = @import("webvtt.zig");

const Allocator = std.mem.Allocator;

pub const Recorder = struct {
    allocator: Allocator,
    dir: std.fs.Dir,
    keep: usize,
    seq: usize,
    version: []const u8,
    detail: webvtt.Detail,

    rec_buf: std.ArrayListUnmanaged(u8),
    /// Text emitted since the last chunk mark, waiting to be attributed to the
    /// audio that produced it.
    pending: std.ArrayListUnmanaged(u8),
    doc: webvtt.Transcript,
    cues: webvtt.CueBuilder,

    active: bool,
    recording_start_ns: i128,

    pub fn init(
        allocator: Allocator,
        dir_path: []const u8,
        keep: usize,
        version: []const u8,
        detail: webvtt.Detail,
    ) !Recorder {
        const dir = try std.fs.cwd().openDir(dir_path, .{});
        return .{
            .allocator = allocator,
            .dir = dir,
            .keep = keep,
            .seq = 0,
            .version = version,
            .detail = detail,
            .rec_buf = .{},
            .pending = .{},
            .doc = webvtt.Transcript.init(allocator, detail),
            // Push-to-talk dictation is the microphone, so it is the near end.
            .cues = webvtt.CueBuilder.init(allocator, .near),
            .active = false,
            .recording_start_ns = 0,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.rec_buf.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.doc.deinit();
        self.cues.deinit();
        self.dir.close();
    }

    /// Called when a session begins (PTT press or TCP connect).
    pub fn startRecording(self: *Recorder) void {
        self.rec_buf.clearRetainingCapacity();
        self.pending.clearRetainingCapacity();

        self.doc.deinit();
        self.doc = webvtt.Transcript.init(self.allocator, self.detail);
        self.cues.deinit();
        self.cues = webvtt.CueBuilder.init(self.allocator, .near);

        self.active = true;
        self.recording_start_ns = std.time.nanoTimestamp();
    }

    /// Called on each read during an active utterance. Appends PCM to the
    /// recording, which is never gated: the audio has to line up with the cue
    /// timestamps, which is the whole reason it is kept.
    pub fn recordPcm(self: *Recorder, data: []const u8) void {
        if (!self.active) return;
        self.rec_buf.appendSlice(self.allocator, data) catch {};
    }

    /// Called after each emitted delta. The text is held until the chunk that
    /// produced it is marked, so it can be attributed to that audio.
    pub fn logEmit(self: *Recorder, text: []const u8) void {
        if (!self.active) return;
        self.pending.appendSlice(self.allocator, text) catch {};
    }

    /// Called once per audio chunk, after any text it produced has been
    /// emitted. This is what turns a stream of chunks into cues: text opens
    /// one, and a run of quiet chunks that emit nothing closes it.
    pub fn markChunk(self: *Recorder, start_ms: u64, end_ms: u64, rms: f64) void {
        if (!self.active) return;

        if (self.cues.push(start_ms, end_ms, rms, self.pending.items)) |maybe| {
            if (maybe) |cue| self.doc.add(cue) catch {};
        } else |_| {}
        self.pending.clearRetainingCapacity();
    }

    /// A diagnostic line for the transcript, kept only when the detail setting
    /// is `.debug`. Invisible to every renderer, so it costs a player nothing.
    pub fn note(self: *Recorder, text: []const u8) void {
        if (!self.active) return;
        self.doc.note(text) catch {};
    }

    /// Called when a session ends (PTT release or TCP disconnect).
    /// Writes NNN.wav + NNN.vtt, advances seq.
    pub fn endRecording(self: *Recorder) !void {
        if (!self.active) return;
        self.active = false;

        if (self.cues.flush()) |cue| self.doc.add(cue) catch {};

        const idx = self.seq % self.keep;
        self.seq += 1;

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

        var vtt_name_buf: [16]u8 = undefined;
        const vtt_name = std.fmt.bufPrint(&vtt_name_buf, "{d:0>3}.vtt", .{idx}) catch return;
        {
            var header_buf: [128]u8 = undefined;
            const duration_ms = self.recordingDurationMs();
            const header = std.fmt.bufPrint(
                &header_buf,
                "capsper recording {d:0>3} (v{s}) — {d}.{d}s, {d} bytes",
                .{ self.seq - 1, self.version, duration_ms / 1000, (duration_ms % 1000) / 100, self.rec_buf.items.len },
            ) catch "capsper recording";

            const bytes = try self.doc.render(&.{header});
            defer self.allocator.free(bytes);

            var file = try self.dir.createFile(vtt_name, .{});
            defer file.close();
            try file.writeAll(bytes);
        }

        std.debug.print("[rec] wrote {s} + {s} ({d} bytes audio)\n", .{
            wav_name, vtt_name, self.rec_buf.items.len,
        });
    }

    fn recordingDurationMs(self: *const Recorder) u64 {
        const elapsed_ns = std.time.nanoTimestamp() - self.recording_start_ns;
        return @intCast(@max(0, @divTrunc(elapsed_ns, 1_000_000)));
    }
};
