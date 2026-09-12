// src/shared/meeting_runner.zig — the unattended capture loop.
//
// Holds the pieces together: gate 1 says when a call is happening
// (`platform/sink.zig`), the debounce and the interleaving are pure and live
// in `meeting.zig`, and this drives both against real audio and real files.
//
// The division of labour is deliberate. Everything with a decision in it is
// next door and unit-tested; what is here is I/O -- open two captures, poll
// two pipes, write a file -- so the parts that are hard to get right are not
// also the parts that need a microphone to exercise.

const std = @import("std");
const posix = std.posix;

const config = @import("config.zig");
const meeting = @import("meeting.zig");
const utils = @import("utils.zig");
const webvtt = @import("webvtt.zig");
const server_mod = @import("server.zig");
const PipelineFactory = server_mod.PipelineFactory;
const Pipeline = @import("../backend/pipeline.zig").Pipeline;
const AudioCapture = @import("../platform/audio.zig").AudioCapture;
const SinkWatch = @import("../platform/sink.zig").SinkWatch;

const log = std.log.scoped(.meeting);

/// How often gate 1 is polled. A long interval for an event loop and the right
/// one here: what is being waited for is a meeting, the debounce is measured
/// in tens of seconds, and a watcher that wakes constantly to learn nothing is
/// the cost this whole design set out to avoid.
const poll_interval_ms: i32 = 200;

/// One session's audio file, written as it is captured rather than held in
/// memory: an hour of stereo is 230 MB, and a session that is lost because
/// capsper was killed is a session that never happened.
const SessionFile = struct {
    dir: std.fs.Dir,
    file: std.fs.File,
    bytes_written: u32 = 0,

    fn create(root: []const u8, rel_path: []const u8) !SessionFile {
        var root_dir = try std.fs.cwd().makeOpenPath(root, .{});
        defer root_dir.close();

        // Fail rather than invent a name. Two sessions cannot start in the
        // same second given the idle window, so a collision means something
        // is wrong that a suffix would only hide.
        root_dir.makePath(rel_path) catch |err| switch (err) {
            error.PathAlreadyExists => return error.SessionAlreadyExists,
            else => return err,
        };
        var dir = try root_dir.openDir(rel_path, .{});
        errdefer dir.close();

        const file = try dir.createFile("audio.wav", .{});
        errdefer file.close();

        try writePlayer(dir, "audio.wav");

        // Placeholder sizes; a session's length is not known when it starts.
        var header: std.ArrayListUnmanaged(u8) = .{};
        defer header.deinit(std.heap.page_allocator);
        try utils.writeWavHeader(header.writer(std.heap.page_allocator), 0, 2);
        try file.writeAll(header.items);

        return .{ .dir = dir, .file = file };
    }

    fn append(self: *SessionFile, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.file.writeAll(bytes);
        self.bytes_written +|= @intCast(bytes.len);
    }

    /// Rewrite the header with the real sizes, then close.
    fn finish(self: *SessionFile) void {
        var header: std.ArrayListUnmanaged(u8) = .{};
        defer header.deinit(std.heap.page_allocator);
        if (utils.writeWavHeader(header.writer(std.heap.page_allocator), self.bytes_written, 2)) {
            self.file.seekTo(0) catch {};
            self.file.writeAll(header.items) catch {};
        } else |_| {}
        self.file.close();
        self.dir.close();
    }

    fn durationSeconds(self: *const SessionFile) f64 {
        // 16 kHz, two channels, two bytes a sample.
        return @as(f64, @floatFromInt(self.bytes_written)) / 64_000.0;
    }
};

/// The page that plays a session: the audio, the transcript scrolling in step
/// with it, and a control that routes either hard-panned channel to both ears.
///
/// Embedded rather than built, so it stays an ordinary HTML file that can be
/// opened and edited on its own, and so a session directory needs nothing
/// fetched to be useful.
const player_template = @embedFile("player.html");

/// Written when the session is created rather than when it closes, so a
/// session interrupted by a kill is still playable.
///
/// It assumes it is served over HTTP. Capsper ships no server -- point any
/// static file server at the sessions directory. The page says so itself when
/// opened from the filesystem, because that case fails silently rather than
/// loudly: browsers treat every `file://` URL as its own opaque origin, so
/// reading the audio for the channel control returns zeroes instead of an
/// error.
fn writePlayer(dir: std.fs.Dir, audio_name: []const u8) !void {
    const marker = "__AUDIO_FILE__";
    // Every occurrence, not the first. The first version of this substituted
    // only once and silently filled in a mention of the marker in a comment,
    // leaving the audio element pointing at the placeholder -- a page that
    // rendered its transcript perfectly and played nothing.
    if (std.mem.indexOf(u8, player_template, marker) == null) return error.PlayerTemplateBroken;

    var file = try dir.createFile("index.html", .{});
    defer file.close();

    var rest: []const u8 = player_template;
    while (std.mem.indexOf(u8, rest, marker)) |cut| {
        try file.writeAll(rest[0..cut]);
        try file.writeAll(audio_name);
        rest = rest[cut + marker.len ..];
    }
    try file.writeAll(rest);
}

/// Run until the process is killed. Returns only on a failure that makes
/// carrying on pointless.
pub fn run(
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    audio_channel: u32,
    factory: PipelineFactory,
) !void {
    var watch = SinkWatch.init(cfg.meeting.sink_name) catch |err| {
        log.err("cannot watch sink '{s}': {}", .{ cfg.meeting.sink_name, err });
        return;
    };
    defer watch.deinit();

    var gate = meeting.ArmGate.init(cfg.meeting.idle_close_seconds);
    var session: ?Session = null;
    defer if (session) |*s| s.close(gpa);

    std.debug.print("Meeting sink '{s}' is up; select it as your output.\n", .{cfg.meeting.sink_name});

    while (true) {
        const now: u64 = @intCast(std.time.nanoTimestamp());
        switch (gate.update(watch.activeStreams(), now)) {
            .none => {},
            .opened => {
                session = Session.open(gpa, cfg, audio_channel, factory) catch |err| blk: {
                    log.err("could not start a session: {}", .{err});
                    // Give up on this one rather than retrying every poll; the
                    // next call will try again from scratch.
                    _ = gate.finish();
                    break :blk null;
                };
            },
            .closed => {
                if (session) |*s| s.close(gpa);
                session = null;
            },
        }

        if (session) |*s| {
            s.pump(gpa) catch |err| {
                log.err("capture failed, closing the session: {}", .{err});
                s.close(gpa);
                session = null;
            };
        } else {
            std.Thread.sleep(@as(u64, poll_interval_ms) * std.time.ns_per_ms);
        }
    }
}

/// The transcription half of one track: its own pipeline, its own cue
/// builder, and its own count of the audio that has reached it.
///
/// One pipeline each rather than one shared, because an RNNT decoder carries
/// per-utterance state and two conversations through one would interleave into
/// nonsense. Concurrency is already linear and the model itself is shared, so
/// two tracks cost two pipelines' state, not two models.
const TrackAsr = struct {
    voice: webvtt.Voice,
    pipeline: *Pipeline,
    cues: webvtt.CueBuilder,

    /// Audio that has reached this track, counted on arrival -- ahead of the
    /// encoder, and ahead of anything that might one day elide audio before
    /// it. Today everything received is fed through, so this and the encoder's
    /// own position agree. The moment a VAD sits in front of the encoder they
    /// diverge, and a position taken from the encoder would put every cue
    /// after the first pause progressively further out, until the end of an
    /// hour-long meeting is minutes wrong. Counting here makes that
    /// impossible rather than merely unlikely.
    bytes_arrived: u64 = 0,

    /// Where the chunk currently being transcribed begins. Advances by every
    /// byte handed to the encoder, elided or not, so it stays a position in
    /// the recording rather than a position in the encoder's input.
    bytes_started: u64 = 0,

    /// Whole chunks only: the pipeline is fed the same 560 ms the rest of
    /// capsper uses, so a meeting and a dictation see identical boundaries.
    buffer: std.ArrayListUnmanaged(u8) = .{},

    const chunk_bytes: usize = 17_920;

    fn init(gpa: std.mem.Allocator, voice: webvtt.Voice, factory: PipelineFactory) !TrackAsr {
        const pipeline = try factory.create(gpa);
        errdefer {
            pipeline.deinit();
            gpa.destroy(pipeline);
        }
        pipeline.resetSegment();
        return .{ .voice = voice, .pipeline = pipeline, .cues = webvtt.CueBuilder.init(gpa, voice) };
    }

    fn deinit(self: *TrackAsr, gpa: std.mem.Allocator) void {
        self.cues.deinit();
        self.buffer.deinit(gpa);
        self.pipeline.deinit();
        gpa.destroy(self.pipeline);
    }

    /// Feed arriving PCM, and write any cue it completed.
    fn feed(self: *TrackAsr, gpa: std.mem.Allocator, pcm: []const u8, out: *webvtt.Transcript) !void {
        self.bytes_arrived += pcm.len;
        try self.buffer.appendSlice(gpa, pcm);

        while (self.buffer.items.len >= chunk_bytes) {
            const chunk = self.buffer.items[0..chunk_bytes];
            try self.runChunk(gpa, chunk, false, out);

            const rest = self.buffer.items.len - chunk_bytes;
            std.mem.copyForwards(u8, self.buffer.items[0..rest], self.buffer.items[chunk_bytes..]);
            self.buffer.shrinkRetainingCapacity(rest);
        }
    }

    fn runChunk(
        self: *TrackAsr,
        gpa: std.mem.Allocator,
        pcm: []const u8,
        flush: bool,
        out: *webvtt.Transcript,
    ) !void {
        const rms = utils.channelRms(pcm, 1, 0);

        var text: []const u8 = "";
        var owned: ?[]const u8 = null;
        defer if (owned) |t| gpa.free(t);

        // Digital zero is never speech, and on the far track it is most of a
        // meeting: a sink nobody is playing into produces exact zeros, not
        // room tone. Measured, an idle monitor yields not one non-zero byte.
        //
        // Skipping it is the same rule `ChunkedReader` applies to every other
        // transport, so the encoder sees what the regression corpus has always
        // validated rather than something new. Measured on this machine, a
        // minute of digital zero costs 0.20 CPU-seconds per audio-second
        // against 1.13 for room tone, so this is the whole of the far track's
        // idle cost and none of the near track's.
        //
        // The position still advances below, which is the part that matters:
        // audio skipped before the encoder must still move the recording's
        // clock, or every cue after it drifts early.
        if (!std.mem.allEqual(u8, pcm, 0)) {
            const samples = try utils.pcmToFloat(gpa, pcm);
            defer gpa.free(samples);

            if (self.pipeline.transcribe(samples, flush, null) catch null) |result| {
                gpa.free(result.words);
                gpa.free(result.tokens);
                gpa.free(result.token_frames);
                owned = result.text;
                text = result.text;
            }
        }

        // The span of recording this chunk covers, which is where any text
        // it produced is attributed.
        const chunk_start_ms = webvtt.msFromBytes(self.bytes_started);
        self.bytes_started += pcm.len;
        const chunk_end_ms = webvtt.msFromBytes(self.bytes_started);

        if (try self.cues.push(chunk_start_ms, chunk_end_ms, rms, text)) |cue| {
            try out.add(cue);
        }
    }

    /// Push the tail through and close any open cue.
    fn finish(self: *TrackAsr, gpa: std.mem.Allocator, out: *webvtt.Transcript) !void {
        if (self.buffer.items.len > 0) {
            const tail = try gpa.dupe(u8, self.buffer.items);
            defer gpa.free(tail);
            self.buffer.clearRetainingCapacity();
            try self.runChunk(gpa, tail, true, out);
        }
        if (self.cues.flush()) |cue| try out.add(cue);
    }
};

const Session = struct {
    near: AudioCapture,
    far: AudioCapture,
    mixer: meeting.TrackMixer,
    file: SessionFile,
    transcript: Transcript,
    near_asr: TrackAsr,
    far_asr: TrackAsr,
    pending: std.ArrayListUnmanaged(u8) = .{},
    read_buf: [8192]u8 = undefined,

    fn open(
        gpa: std.mem.Allocator,
        cfg: *const config.Config,
        audio_channel: u32,
        factory: PipelineFactory,
    ) !Session {
        var path_buf: [64]u8 = undefined;
        const rel = try meeting.sessionPath(&path_buf, std.time.timestamp());

        var file = try SessionFile.create(cfg.meeting.dir, rel);
        errdefer file.finish();

        var transcript = try Transcript.create(gpa, file.dir, cfg.meeting.detail);
        errdefer transcript.deinit();

        var near_asr = try TrackAsr.init(gpa, .near, factory);
        errdefer near_asr.deinit(gpa);
        var far_asr = try TrackAsr.init(gpa, .far, factory);
        errdefer far_asr.deinit(gpa);

        // The near end follows whatever the desktop's input is set to when no
        // target is configured, which is the same selection the user already
        // made for every other application.
        var near = try AudioCapture.init(.{
            .target = cfg.audio.target,
            .channel = audio_channel,
        });
        errdefer near.deinit();
        near.setActive(true);

        // The far end is the sink's monitor. `capture_sink` is what makes that
        // the monitor rather than the default microphone.
        var far = try AudioCapture.init(.{
            .target = cfg.meeting.sink_name,
            .channel = AudioCapture.default_channel,
            .capture_sink = true,
        });
        errdefer far.deinit();
        far.setActive(true);

        std.debug.print("[meeting] session opened: {s}\n", .{rel});
        return .{
            .near = near,
            .far = far,
            .mixer = .{},
            .file = file,
            .transcript = transcript,
            .near_asr = near_asr,
            .far_asr = far_asr,
        };
    }

    /// Read whatever both captures have ready, transcribe it, and write the
    /// stereo frames that result. Blocks for at most one poll interval, so the
    /// caller's loop keeps ticking even while a track is silent.
    fn pump(self: *Session, gpa: std.mem.Allocator) !void {
        var fds = [_]posix.pollfd{
            .{ .fd = self.near.pipe_read_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.far.pipe_read_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, poll_interval_ms) catch return;

        try self.readInto(gpa, fds[0], .near);
        try self.readInto(gpa, fds[1], .far);

        self.pending.clearRetainingCapacity();
        try self.mixer.drain(gpa, &self.pending);
        try self.file.append(self.pending.items);
    }

    fn readInto(self: *Session, gpa: std.mem.Allocator, fd: posix.pollfd, track: meeting.Track) !void {
        if (fd.revents & posix.POLL.IN == 0) return;
        const n = posix.read(fd.fd, &self.read_buf) catch return;
        if (n == 0) return;
        const pcm = self.read_buf[0..n];

        // Recording first, and never gated: the audio file has to line up with
        // the cue timestamps, which is the whole reason it is kept.
        try self.mixer.push(gpa, track, pcm);

        const asr = switch (track) {
            .near => &self.near_asr,
            .far => &self.far_asr,
        };
        asr.feed(gpa, pcm, &self.transcript.doc) catch |err| {
            log.warn("transcription failed on the {s} track: {}", .{ @tagName(track), err });
        };
    }

    fn close(self: *Session, gpa: std.mem.Allocator) void {
        // Whatever arrived last still belongs in the file.
        self.pending.clearRetainingCapacity();
        self.mixer.flush(gpa, &self.pending) catch {};
        self.file.append(self.pending.items) catch {};

        self.near.setActive(false);
        self.far.setActive(false);
        self.near.deinit();
        self.far.deinit();

        self.near_asr.finish(gpa, &self.transcript.doc) catch {};
        self.far_asr.finish(gpa, &self.transcript.doc) catch {};
        self.near_asr.deinit(gpa);
        self.far_asr.deinit(gpa);

        self.transcript.finish();
        self.mixer.deinit(gpa);
        self.pending.deinit(gpa);

        const seconds = self.file.durationSeconds();
        self.file.finish();
        std.debug.print("[meeting] session closed ({d:.1}s of audio)\n", .{seconds});
    }
};

/// The session's `transcript.vtt`.
///
/// Collected in memory and written when the session closes, because cues from
/// the two tracks have to be merged by audio position before anything is
/// written -- a cue completes when its own track goes quiet, so they finish
/// out of order. An hour of transcript is tens of kilobytes, nothing beside
/// the audio it accompanies.
const Transcript = struct {
    doc: webvtt.Transcript,
    dir: std.fs.Dir,

    // So a recording found in two years says which side is which without
    // needing this repository to explain it.
    const header_notes = [_][]const u8{
        "capsper meeting transcript",
        "audio.wav: near end (microphone) = left, far end (call) = right",
    };

    fn create(gpa: std.mem.Allocator, dir: std.fs.Dir, detail: config.Detail) !Transcript {
        return .{
            .doc = webvtt.Transcript.init(gpa, switch (detail) {
                .minimal => .minimal,
                .debug => .debug,
            }),
            .dir = dir,
        };
    }

    fn finish(self: *Transcript) void {
        if (self.doc.render(&header_notes)) |bytes| {
            defer self.doc.gpa.free(bytes);
            if (self.dir.createFile("transcript.vtt", .{})) |file| {
                defer file.close();
                file.writeAll(bytes) catch |err| log.err("could not write transcript.vtt: {}", .{err});
            } else |err| log.err("could not create transcript.vtt: {}", .{err});
        } else |err| log.err("could not render the transcript: {}", .{err});
        self.doc.deinit();
    }

    fn deinit(self: *Transcript) void {
        self.doc.deinit();
    }
};
