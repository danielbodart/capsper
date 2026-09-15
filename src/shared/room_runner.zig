// src/shared/room_runner.zig — recording the room you are sitting in.
//
// The third way capsper records, and the only one a person starts by hand.
// Dictation is gated by a key held down; a meeting is gated by three
// questions about a sink nobody is holding and a far end nobody is on. An
// in-person meeting trips none of that: two people around one laptop, nothing
// playing into the sink, no far end to go quiet. So the gate is the key
// itself, latched -- ctrl+trigger on, trigger off -- and the CapsLock light is
// the whole user interface.
//
// What it writes is a session directory beside the meetings, because that is
// what it is: a transcript of a conversation, dated, with its audio. One
// track, not two, and one voice in the transcript -- the vocabulary of near
// and far belongs to a call and there is no call here.
//
// Everything expensive is borrowed from `meeting_runner`: the session file,
// the per-track pipeline and its voice activity gate, the transcript writer.
// This file is the latch, one capture, and the loop between them.

const std = @import("std");
const posix = std.posix;

const config = @import("config.zig");
const meeting = @import("meeting.zig");
const meeting_runner = @import("meeting_runner.zig");
const server_mod = @import("server.zig");
const source = @import("source.zig");
const status = @import("status.zig");
const utils = @import("utils.zig");
const webvtt = @import("webvtt.zig");
const AudioCapture = @import("../platform/audio.zig").AudioCapture;
const AutoGain = @import("auto_gain.zig").AutoGain;
const MicLevel = @import("../platform/mic_level.zig").MicLevel;
const PipelineFactory = server_mod.PipelineFactory;

const log = std.log.scoped(.room);

/// Set by the input thread when the latch turns over, read here.
///
/// An atomic and nothing more, because the write happens on the thread that
/// carries every keystroke: it may not allocate, may not open anything, and
/// may certainly not wait for a microphone to come up. All of that belongs to
/// this loop, which has nobody's typing waiting on it.
var wanted: std.atomic.Value(bool) = .init(false);

/// The callback handed to the input layer. Deliberately the whole of what the
/// keystroke path does about room capture.
pub fn setWanted(on: bool) void {
    wanted.store(on, .monotonic);
}

/// How often the latch is read while nothing is recording. The same interval
/// the meeting loop idles at, for the same reason: what is being waited for is
/// a person pressing a key, and a hundred milliseconds either way is not
/// something anybody can feel.
const idle_poll_ms: u64 = 200;

/// Run until the process is killed.
pub fn run(
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    audio_channel: u32,
    factory: PipelineFactory,
) !void {
    var session: ?Session = null;
    defer if (session) |*s| s.close(gpa);

    while (true) {
        // A save from the console ends the process, and a room being recorded
        // at that moment should survive it as a finished file.
        if (status.stop_requested.load(.acquire)) {
            if (session != null) log.info("closing the session before restarting", .{});
            return;
        }

        const on = wanted.load(.monotonic);

        if (on and session == null) {
            session = Session.open(gpa, cfg, audio_channel, factory) catch |err| blk: {
                log.err("could not start recording the room: {}", .{err});
                // The latch is dropped rather than left on, so the light stops
                // claiming something is being recorded when nothing is. The
                // key is free to try again.
                setWanted(false);
                status.room_recording.store(false, .monotonic);
                break :blk null;
            };
            if (session != null) status.room_recording.store(true, .monotonic);
        } else if (!on and session != null) {
            session.?.close(gpa);
            session = null;
            status.room_recording.store(false, .monotonic);
        }

        if (session) |*s| {
            const over_time = s.pump(gpa) catch |err| blk: {
                log.err("capture failed, closing the session: {}", .{err});
                break :blk true;
            };

            // Either the limit ran out or the capture died. Both end the
            // session, and both drop the latch, because the light has to stop
            // saying "recording" the moment the recording stops.
            if (over_time) {
                s.close(gpa);
                session = null;
                setWanted(false);
                status.room_recording.store(false, .monotonic);
                log.info("the room session has closed itself", .{});
            }
        } else {
            std.Thread.sleep(idle_poll_ms * std.time.ns_per_ms);
        }
    }
}

/// One latched recording: a microphone, a file, and a transcript of one voice.
const Session = struct {
    mic: AudioCapture,
    file: meeting_runner.SessionFile,
    transcript: meeting_runner.Transcript,
    asr: meeting_runner.TrackAsr,

    /// Levelling, as the meeting's near track has. A room is the case that
    /// needs it most: two people at two distances from one microphone.
    level: ?MicLevel,
    gain: ?AutoGain,
    configured_gain: f32,

    /// When this session started, and when it must stop regardless. Null when
    /// `room.max_minutes` is zero.
    deadline_ns: ?u64,

    /// Where the session lives, kept from open rather than rebuilt at close --
    /// a path derived from the clock twice can differ twice, and the second
    /// use is a delete.
    rel_path: [64]u8 = undefined,
    rel_len: usize = 0,
    sessions_root: []const u8,

    read_buf: [8192]u8 = undefined,

    fn open(
        gpa: std.mem.Allocator,
        cfg: *const config.Config,
        audio_channel: u32,
        factory: PipelineFactory,
    ) !Session {
        var path_buf: [64]u8 = undefined;
        const rel = try meeting.sessionPath(&path_buf, std.time.timestamp());

        // Mono, and that single `1` is most of what separates this from a
        // meeting: one microphone in the room, so one channel in the file and
        // one voice in the transcript.
        var file = try meeting_runner.SessionFile.create(cfg.meeting.dir, rel, gpa, cfg.meeting.audio_format, 1);
        errdefer file.finish(gpa);

        var transcript = try meeting_runner.Transcript.create(
            gpa,
            file.dir,
            cfg.meeting.detail,
            meeting_runner.SessionFile.audioName(cfg.meeting.audio_format),
            "one microphone, the room",
        );
        errdefer transcript.deinit();
        transcript.kind_note = "capsper room transcript";

        writeSourceMetadata(gpa, file.dir, cfg);

        var asr = try meeting_runner.TrackAsr.init(gpa, .near, factory, cfg);
        errdefer asr.deinit(gpa);

        // The raw microphone. No echo canceller, because there is nothing to
        // cancel: nothing is playing, and the far end that a canceller exists
        // to subtract is sitting in the room being recorded on purpose.
        var mic = try AudioCapture.init(.{
            .target = cfg.roomSource(),
            .channel = audio_channel,
        });
        errdefer mic.deinit();
        mic.setActive(true);

        var level: ?MicLevel = MicLevel.init(cfg.roomSource()) catch |err| blk: {
            log.warn("levelling the microphone is unavailable: {}", .{err});
            break :blk null;
        };
        errdefer if (level) |*l| l.deinit();

        if (level) |*l| {
            status.meeting_near.reportDevice(l.nodeName());
            status.meeting_near.reportGain(cfg.audio.gain);
            if (cfg.audio.gain > 1.01) _ = l.set(cfg.audio.gain);
        }

        var out: Session = .{
            .mic = mic,
            .file = file,
            .transcript = transcript,
            .asr = asr,
            .level = level,
            .gain = if (cfg.audio.auto_gain) AutoGain{ .current_gain = cfg.audio.gain } else null,
            .configured_gain = cfg.audio.gain,
            .deadline_ns = if (cfg.room.max_minutes == 0) null else blk: {
                const now: u64 = @intCast(std.time.nanoTimestamp());
                break :blk now + @as(u64, cfg.room.max_minutes) * 60 * std.time.ns_per_s;
            },
            .sessions_root = cfg.meeting.dir,
        };
        @memcpy(out.rel_path[0..rel.len], rel);
        out.rel_len = rel.len;

        log.info("recording the room: {s}", .{rel});
        std.debug.print("[room] session opened: {s}\n", .{rel});
        return out;
    }

    /// One pass. True when the session has run out of time and should close.
    fn pump(self: *Session, gpa: std.mem.Allocator) !bool {
        var fds = [_]posix.pollfd{
            .{ .fd = self.mic.pipe_read_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, @intCast(idle_poll_ms)) catch |err| {
            if (err == error.Interrupted) return false;
            return err;
        };

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(self.mic.pipe_read_fd, &self.read_buf) catch |err| {
                if (err == error.WouldBlock) return self.expired();
                return err;
            };
            if (n > 0) {
                const pcm = self.read_buf[0..n];
                // The file first. Audio that reached the encoder but not the
                // recording would put every cue after it out of step with what
                // you can hear, and the recording is what the transcript is
                // checked against.
                try self.file.append(pcm);
                try self.asr.feed(gpa, pcm, &self.transcript.doc);
                self.transcript.saveIfChanged();
                self.levelUp();
            }
        }

        return self.expired();
    }

    fn expired(self: *const Session) bool {
        const deadline = self.deadline_ns orelse return false;
        const now: u64 = @intCast(std.time.nanoTimestamp());
        return now >= deadline;
    }

    /// Feed the level controller, and only ever with speech. See the note on
    /// `TrackAsr.speech_rms`: fed silence it winds the gain up on room tone.
    fn levelUp(self: *Session) void {
        const level = if (self.level) |*l| l else return;
        const gain = if (self.gain) |*g| g else return;

        if (level.tookChange()) {
            _ = level.set(self.configured_gain);
            self.gain = .{ .current_gain = self.configured_gain };
            status.meeting_near.reportDevice(level.nodeName());
            status.meeting_near.reportGain(self.configured_gain);
            log.info("microphone changed to '{s}', levelling from {d:.1}x again", .{
                level.nodeName(), self.configured_gain,
            });
            self.asr.speech_rms = null;
            return;
        }

        const rms = self.asr.speech_rms orelse return;
        self.asr.speech_rms = null;
        status.meeting_near.reportLevel(@floatCast(utils.rmsToDb(rms)));
        if (gain.update(rms)) |new_gain| {
            _ = level.set(new_gain);
            status.meeting_near.reportGain(new_gain);
        }
    }

    fn close(self: *Session, gpa: std.mem.Allocator) void {
        self.mic.setActive(false);
        self.mic.deinit();
        if (self.level) |*l| l.deinit();

        self.asr.finish(gpa, &self.transcript.doc) catch {};
        // Read after `finish`, which pushes the tail through the gate and can
        // be what opens it, and before the track is torn down.
        const heard_speech = self.asr.vad_fired;
        self.asr.deinit(gpa);

        self.transcript.finish();

        const seconds = self.file.durationSeconds();
        self.file.finish(gpa);

        if (!heard_speech) {
            self.discard(seconds);
            return;
        }
        std.debug.print("[room] session closed ({d:.1}s of audio)\n", .{seconds});
    }

    /// Remove a session nobody spoke in. The same rule a meeting applies, and
    /// it matters more here: the key is easy to press by accident and there is
    /// no call to notice it happening.
    ///
    /// Said out loud, as the meeting's is. Deleting quietly is the one thing
    /// here that could destroy a real recording if the rule is ever wrong.
    fn discard(self: *Session, seconds: f64) void {
        const rel = self.rel_path[0..self.rel_len];

        var root = std.fs.cwd().openDir(self.sessions_root, .{}) catch |err| {
            log.err("could not open '{s}' to discard {s}: {}", .{ self.sessions_root, rel, err });
            return;
        };
        defer root.close();

        root.deleteTree(rel) catch |err| {
            log.err("could not discard {s}: {}", .{ rel, err });
            return;
        };

        log.info("discarded {s}: nobody spoke", .{rel});
        std.debug.print("[room] session discarded ({d:.1}s, nobody spoke): {s}\n", .{ seconds, rel });
    }
};

/// What this session was, and which microphone it heard, in `audio.json`
/// beside the audio and the transcript.
///
/// The `mode` is what the console reads to know there is one voice here and no
/// channel to choose between, and it is the only field a room session can fill
/// that a meeting could not: there are no streams, because nothing was playing.
fn writeSourceMetadata(gpa: std.mem.Allocator, dir: std.fs.Dir, cfg: *const config.Config) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = source.capture(arena, &.{}, .{ .near = cfg.roomSource(), .output = null }, "/proc") catch |err| blk: {
        log.warn("could not read the microphone behind the session: {}", .{err});
        break :blk source.Document{};
    };
    doc.mode = "room";

    const bytes = source.render(arena, doc) catch |err| {
        log.warn("could not render audio.json: {}", .{err});
        return;
    };

    if (dir.createFile("audio.json", .{})) |out| {
        defer out.close();
        out.writeAll(bytes) catch |err| log.err("could not write audio.json: {}", .{err});
    } else |err| log.err("could not create audio.json: {}", .{err});
}
