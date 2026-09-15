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
const source = @import("source.zig");
const opus = @import("opus.zig");
const server_mod = @import("server.zig");
const PipelineFactory = server_mod.PipelineFactory;
const Pipeline = @import("../backend/pipeline.zig").Pipeline;
const AudioCapture = @import("../platform/audio.zig").AudioCapture;
const sink_mod = @import("../platform/sink.zig");
const SinkWatch = sink_mod.SinkWatch;
const EchoCanceller = sink_mod.EchoCanceller;
const vad_backend = @import("../backend/vad.zig");
const AutoGain = @import("auto_gain.zig").AutoGain;
const MicLevel = @import("../platform/mic_level.zig").MicLevel;
const status = @import("status.zig");

const log = std.log.scoped(.meeting);

/// How often gate 1 is polled. A long interval for an event loop and the right
/// one here: what is being waited for is a meeting, the debounce is measured
/// in tens of seconds, and a watcher that wakes constantly to learn nothing is
/// the cost this whole design set out to avoid.
const poll_interval_ms: i32 = 200;

/// One second of the format every capture here produces: 16 kHz, 16-bit, mono.
const bytes_per_second: usize = 32_000;

/// One session's audio file, written as it is captured rather than held in
/// memory: an hour of stereo is 230 MB, and a session that is lost because
/// capsper was killed is a session that never happened.
pub const SessionFile = struct {
    dir: std.fs.Dir,
    file: std.fs.File,

    /// Two for a call, one for a room. Kept because the WAV header is
    /// rewritten at close and the duration is bytes divided by this.
    channels: u8,

    /// Opus for a meeting, which is hours kept indefinitely; WAV when the
    /// setting asks for it. Either way the audio is never gated -- it has to
    /// line up with the cue timestamps, which is the whole reason it is kept.
    encoder: union(config.AudioFormat) {
        wav: struct { bytes: u32 = 0 },
        opus: opus.Writer,
    },

    pub fn create(
        root: []const u8,
        rel_path: []const u8,
        gpa: std.mem.Allocator,
        format: config.AudioFormat,
        channels: u8,
    ) !SessionFile {
        var root_dir = try std.fs.cwd().makeOpenPath(root, .{});
        defer root_dir.close();

        // Fail rather than invent a name. Two sessions cannot start in the
        // same second given the idle window, so a collision means something
        // is wrong that a suffix would only hide.
        //
        // Asked rather than caught, because `makePath` reports a directory
        // that already exists as success -- catching `PathAlreadyExists` here
        // never fired. That was survivable when the worst case was two
        // sessions sharing a directory; it stopped being survivable when a
        // session that heard nothing began deleting its own directory, since
        // the one it deleted might be the other's.
        const made = root_dir.makePathStatus(rel_path) catch |err| switch (err) {
            error.PathAlreadyExists => return error.SessionAlreadyExists,
            else => return err,
        };
        if (made == .existed) return error.SessionAlreadyExists;
        var dir = try root_dir.openDir(rel_path, .{});
        errdefer dir.close();

        const file = try dir.createFile(audioName(format), .{});
        errdefer file.close();

        switch (format) {
            .wav => {
                // Placeholder sizes; a session's length is not known when it
                // starts, so the header is rewritten on close.
                var header: std.ArrayListUnmanaged(u8) = .{};
                defer header.deinit(gpa);
                try utils.writeWavHeader(header.writer(gpa), 0, channels);
                try file.writeAll(header.items);
                return .{ .dir = dir, .file = file, .channels = channels, .encoder = .{ .wav = .{} } };
            },
            .opus => return .{
                .dir = dir,
                .file = file,
                .channels = channels,
                .encoder = .{ .opus = try opus.Writer.create(gpa, file, channels, opus.default_bitrate) },
            },
        }
    }

    /// The audio file's name, which the transcript beside it shares: media
    /// players pair a subtitle file with a media file by matching basenames.
    pub fn audioName(format: config.AudioFormat) [:0]const u8 {
        return switch (format) {
            .wav => "audio.wav",
            .opus => "audio.opus",
        };
    }

    pub fn append(self: *SessionFile, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        switch (self.encoder) {
            .wav => |*w| {
                try self.file.writeAll(bytes);
                w.bytes +|= @intCast(bytes.len);
            },
            .opus => |*w| try w.write(bytes),
        }
    }

    pub fn finish(self: *SessionFile, gpa: std.mem.Allocator) void {
        switch (self.encoder) {
            .wav => |w| {
                var header: std.ArrayListUnmanaged(u8) = .{};
                defer header.deinit(gpa);
                if (utils.writeWavHeader(header.writer(gpa), w.bytes, self.channels)) {
                    self.file.seekTo(0) catch {};
                    self.file.writeAll(header.items) catch {};
                } else |_| {}
            },
            .opus => |*w| w.finish(),
        }
        self.file.close();
        self.dir.close();
    }

    pub fn durationSeconds(self: *const SessionFile) f64 {
        return switch (self.encoder) {
            // 16 kHz, two bytes a sample, and however many channels this is.
            .wav => |w| @as(f64, @floatFromInt(w.bytes)) /
                (32_000.0 * @as(f64, @floatFromInt(self.channels))),
            .opus => |w| w.durationSeconds(),
        };
    }
};

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
    // Up only between sessions, while gate 1 still says an application holds
    // the sink but gate 1b has decided nobody is on the other end.
    var listener: ?FarListener = null;
    defer if (session) |*s| s.close(gpa);
    defer if (listener) |*l| l.deinit(gpa);

    std.debug.print("Meeting sink '{s}' is up; select it as your output.\n", .{cfg.meeting.sink_name});

    while (true) {
        // Saving settings from the console ends the process, and a call being
        // recorded at that moment should survive it as a finished file. The
        // `defer` above closes the session; returning is what reaches it.
        if (status.stop_requested.load(.acquire)) {
            if (session != null) log.info("closing the session before restarting", .{});
            return;
        }

        const now: u64 = @intCast(std.time.nanoTimestamp());
        switch (gate.update(watch.activeStreams(), now)) {
            .none => {},
            .opened => {
                session = Session.open(gpa, cfg, audio_channel, factory, &watch) catch |err| blk: {
                    log.err("could not start a session: {}", .{err});
                    // Give up on this one rather than retrying every poll; the
                    // next call will try again from scratch.
                    _ = gate.finish();
                    break :blk null;
                };
            },
            .closed => {
                // The application finally let go of the sink. That ends the
                // episode outright, including anything gate 1b concluded
                // during it -- a fresh connection gets a fresh session.
                if (session) |*s| s.close(gpa);
                session = null;
                if (listener) |*l| l.deinit(gpa);
                listener = null;
            },
        }

        if (session) |*s| {
            const far_gone = s.pump(gpa) catch |err| blk: {
                log.err("capture failed, closing the session: {}", .{err});
                s.close(gpa);
                session = null;
                break :blk false;
            };

            // Gate 1b. Note what is deliberately *not* done here: `gate` is
            // left alone. It still believes a session is open, which is what
            // stops it opening another one on the very next poll -- the
            // application is still holding the sink, and if gate 1 could
            // re-arm on that we would record the same nothing again, forever,
            // in ten-minute files. Only the far track carrying something
            // starts the next session, and the listener below is what waits
            // for it.
            if (far_gone) {
                if (session) |*live| live.close(gpa);
                session = null;

                log.info(
                    "nothing from the far end for {d}s; closing, and listening for it to come back",
                    .{cfg.meeting.far_silence_close_seconds},
                );

                listener = FarListener.open(cfg) catch |err| blk: {
                    // Fails closed: nothing further is recorded until the
                    // application lets go of the sink and takes it again.
                    // Safe, but silent enough to be worth saying out loud.
                    log.err("cannot listen for the call resuming: {}", .{err});
                    break :blk null;
                };
            }
        } else if (listener) |*l| {
            const resumed = l.poll(gpa) catch |err| blk: {
                log.warn("far listener failed: {}", .{err});
                break :blk null;
            };

            if (resumed) |preroll| {
                if (Session.open(gpa, cfg, audio_channel, factory, &watch)) |opened| {
                    var started = opened;
                    started.feedPreroll(gpa, preroll) catch |err| {
                        log.warn("could not carry the pre-roll into the session: {}", .{err});
                    };
                    // Only after `feedPreroll`, which reads the listener's buffer.
                    l.deinit(gpa);
                    listener = null;
                    session = started;
                } else |err| {
                    // Keep listening rather than tearing the listener down. It
                    // is the only thing that can start a session while the
                    // application still holds the sink, so dropping it here
                    // would mean nothing is recorded again until the call
                    // disconnects entirely.
                    log.err("could not start a session, still listening: {}", .{err});
                }
            }
        } else {
            std.Thread.sleep(@as(u64, poll_interval_ms) * std.time.ns_per_ms);
        }
    }
}

/// Load the voice activity model from the models directory, beside the ASR
/// model it gates. Null when it is missing or the backend has no gate; that is a
/// cost, not a failure, so nothing here reports it as one.
pub fn loadVad(gpa: std.mem.Allocator, cfg: *const config.Config) ?*vad_backend.Vad {
    const bin_dir = std.fs.selfExeDirPathAlloc(gpa) catch return null;
    defer gpa.free(bin_dir);
    const path = std.fs.path.joinZ(gpa, &.{ bin_dir, "../models/silero_vad.onnx" }) catch return null;
    defer gpa.free(path);

    return vad_backend.load(gpa, path, .{
        .onset = cfg.meeting.vad.onset,
        .offset = cfg.meeting.vad.offset,
        .min_silence_ms = cfg.meeting.vad.min_silence_ms,
    });
}

/// The transcription half of one track: its own pipeline, its own cue
/// builder, and its own count of the audio that has reached it.
///
/// One pipeline each rather than one shared, because an RNNT decoder carries
/// per-utterance state and two conversations through one would interleave into
/// nonsense. Concurrency is already linear and the model itself is shared, so
/// two tracks cost two pipelines' state, not two models.
pub const TrackAsr = struct {
    voice: webvtt.Voice,
    pipeline: *Pipeline,
    cues: webvtt.CueBuilder,

    /// One gate per track, because each carries its own recurrent state and
    /// the two sides go quiet at different times. Null when there is no model
    /// -- everything still works, it just costs more.
    vad: ?*vad_backend.Vad,

    /// Whether the gate has ever opened on this track.
    ///
    /// Only a statement about speech where there *is* a gate. With `vad` null
    /// every chunk is wanted, so this goes true on the first chunk that is not
    /// digital zero -- and a session is then never discarded for silence,
    /// which is the only honest answer when nothing was listening for speech.
    /// A missing `silero_vad.onnx` must cost encoder passes and nothing else;
    /// it must never cost a recording.
    vad_fired: bool = false,

    /// The level of the last chunk the gate accepted as speech, for whatever
    /// wants to level this track. Null when the last chunk was not speech.
    ///
    /// A level controller must only ever see speech. Fed silence it decides
    /// the track is too quiet and winds the gain up, and on a meeting that
    /// means winding up the room tone between sentences and, with an echo
    /// canceller in front, the residual it just removed. Measured: feeding it
    /// every chunk lifted the echo left on the near track from -34.8 dBFS to
    /// -21.1. Dictation avoids this by only adapting while the key is held,
    /// which is the same rule expressed by the only gate a meeting has.
    speech_rms: ?f64 = null,

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

    pub fn init(
        gpa: std.mem.Allocator,
        voice: webvtt.Voice,
        factory: PipelineFactory,
        cfg: *const config.Config,
    ) !TrackAsr {
        const pipeline = try factory.create(gpa);
        errdefer {
            pipeline.deinit();
            gpa.destroy(pipeline);
        }
        pipeline.resetSegment();

        return .{
            .voice = voice,
            .pipeline = pipeline,
            .cues = webvtt.CueBuilder.init(gpa, voice),
            .vad = if (cfg.meeting.vad.enabled) loadVad(gpa, cfg) else null,
        };
    }

    pub fn deinit(self: *TrackAsr, gpa: std.mem.Allocator) void {
        if (self.vad) |v| v.deinit();
        self.cues.deinit();
        self.buffer.deinit(gpa);
        self.pipeline.deinit();
        gpa.destroy(self.pipeline);
    }

    /// Feed arriving PCM, and write any cue it completed.
    pub fn feed(self: *TrackAsr, gpa: std.mem.Allocator, pcm: []const u8, out: *webvtt.Transcript) !void {
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

        // The voice activity gate, where there is one. It answers for the whole
        // chunk, because the encoder is fed whole chunks.
        const wanted = if (self.vad) |v| v.shouldEncode(pcm) else true;

        // The same answer drives the level controller, so it adapts to speech
        // and to nothing else. See `speech_rms`.
        self.speech_rms = if (wanted) rms else null;

        const silent = std.mem.allEqual(u8, pcm, 0);

        // What the discard rule reads at close. Digital zero is excluded
        // deliberately: with no gate loaded every chunk is "wanted", and
        // counting zeros would mark a track live on audio that is provably
        // nothing at all.
        if (wanted and !silent) self.vad_fired = true;

        // Digital zero is never speech, so it is not worth an encoder pass.
        // Skipping it is the same rule `ChunkedReader` applies to every other
        // transport, so the encoder sees what the regression corpus has always
        // validated rather than something new. Measured here, a minute of
        // digital zero costs 0.20 CPU-seconds per audio-second against 1.13
        // for room tone.
        //
        // How much this actually saves during a meeting is NOT known. What was
        // measured is a sink nobody is holding, which produces exact zeros --
        // so this certainly covers the gaps between calls and the debounce
        // window at the end of one. Whether a conferencing app holding the
        // sink also sends exact zeros while the far end is quiet, or sends
        // comfort noise, has not been tested, and cannot be tested with
        // anything but a real call. If it sends comfort noise this saves
        // nothing during the call itself and the near-end gate is doing all
        // the work.
        //
        // The position still advances below, which is the part that matters:
        // audio skipped before the encoder must still move the recording's
        // clock, or every cue after it drifts early.
        if (wanted and !silent) {
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
    pub fn finish(self: *TrackAsr, gpa: std.mem.Allocator, out: *webvtt.Transcript) !void {
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
    /// Up only while this session is. Null when cancellation was not asked
    /// for, or was and could not be had.
    aec: ?EchoCanceller,
    mixer: meeting.TrackMixer,
    file: SessionFile,
    transcript: Transcript,
    near_asr: TrackAsr,
    far_asr: TrackAsr,

    /// The microphone.s own level, or null where levelling is unavailable.
    /// Held for the session, because it also reports the desktop.s default
    /// input moving, which is how a microphone switch mid-call is noticed.
    level: ?MicLevel,

    /// The figure to start from, and to return to when the microphone
    /// changes. Kept because the config is not held past `open`.
    configured_gain: f32,

    /// Levelling for the near track, or null when auto-gain is switched off.
    ///
    /// Near only. The far end arrives from the call already levelled by
    /// whatever the other side is running, and a second controller on top of
    /// theirs would be two loops chasing the same signal.
    near_gain: ?AutoGain,

    /// Gate 1b: how long the far track has carried nothing at all. Fed on
    /// every poll, so it measures elapsed time rather than arriving bytes.
    far_silence: meeting.FarSilence,

    /// Whether anything reached the far track since the last poll. Set as the
    /// bytes arrive, read and cleared once per poll.
    ///
    /// Taken from the capture rather than from the file, and that distinction
    /// is load-bearing: `TrackMixer` pads a lagging track with zeros, so a
    /// stalled far capture and a departed far end are identical in the
    /// recording. Read there, a PipeWire hiccup would close live meetings.
    far_signal: bool = false,

    /// Whether the far track has been digital zero for this session's entire
    /// life. If it still is at the end, nothing was ever on the other side and
    /// the session is deleted rather than kept.
    ///
    /// Deliberately not "did the far end ever speak". Someone sitting there
    /// saying nothing still sends their microphone's noise floor, which is
    /// signal; a session recorded while presenting to a silent audience is a
    /// real meeting and must survive. Only the complete absence of a stream
    /// says nobody was there.
    far_all_zero: bool = true,

    /// This session's directory, relative to the sessions root, kept from open
    /// rather than recomputed at close -- a path derived from the clock twice
    /// is a path that can differ twice, and the second use is a delete.
    rel_path: [64]u8 = undefined,
    rel_len: usize = 0,
    sessions_root: []const u8,

    pending: std.ArrayListUnmanaged(u8) = .{},
    read_buf: [8192]u8 = undefined,

    fn open(
        gpa: std.mem.Allocator,
        cfg: *const config.Config,
        audio_channel: u32,
        factory: PipelineFactory,
        watch: *const SinkWatch,
    ) !Session {
        var path_buf: [64]u8 = undefined;
        const rel = try meeting.sessionPath(&path_buf, std.time.timestamp());

        var file = try SessionFile.create(cfg.meeting.dir, rel, gpa, cfg.meeting.audio_format, 2);
        errdefer file.finish(gpa);

        var transcript = try Transcript.create(
            gpa,
            file.dir,
            cfg.meeting.detail,
            SessionFile.audioName(cfg.meeting.audio_format),
            "near end (microphone) = left, far end (call) = right",
        );
        errdefer transcript.deinit();

        // Before anything else is set up, because what is being recorded is
        // the graph that opened the session and a browser will not hold it
        // still while a model loads.
        writeSourceMetadata(gpa, file.dir, watch, cfg);

        var near_asr = try TrackAsr.init(gpa, .near, factory, cfg);
        errdefer near_asr.deinit(gpa);
        var far_asr = try TrackAsr.init(gpa, .far, factory, cfg);
        errdefer far_asr.deinit(gpa);

        // Echo cancellation comes up with the session and goes away with it,
        // so an idle machine is not processing audio for a call that is not
        // happening. Its absence is a cost rather than a failure -- said once
        // and then not mentioned again, the same shape as a missing voice
        // activity model -- because a recorded meeting with echo in it is
        // worth far more than no recording at all.
        var aec: ?EchoCanceller = if (cfg.meeting.aec.enabled)
            EchoCanceller.init(
                cfg.meeting.sink_name,
                cfg.meeting.sink_description,
                cfg.meetingNear(),
            ) catch |err| blk: {
                log.warn("no echo cancellation ({s}); the near track will hear the speakers", .{@errorName(err)});
                break :blk null;
            }
        else
            null;
        errdefer if (aec) |*a| a.deinit();

        // The near end reads the echo-cancelled microphone when there is one,
        // and the microphone itself when there is not. Both cases are one
        // capture on one target, so everything downstream is identical: the
        // recording and the encoder are fed from the same pipe, which is what
        // keeps the audio a check on the transcript rather than a second
        // opinion about it.
        //
        // MONO on the cleaned source because it is stereo, being built from a
        // stereo reference, and the channel has already been chosen upstream
        // by whatever the canceller was pointed at. Only the raw microphone
        // needs `audio_channel`, where it picks one input of a multi-channel
        // interface.
        //
        // Without a target the raw case follows whatever the desktop's input
        // is set to, which is the same selection the user already made for
        // every other application.
        var near = try AudioCapture.init(if (aec) |a| .{
            .target = a.mic,
            .channel = AudioCapture.mono_channel,
        } else .{
            .target = cfg.meetingNear(),
            .channel = audio_channel,
        });
        errdefer near.deinit();
        near.setActive(true);

        // The microphone's own level, on the node rather than on this capture
        // of it. `meetingNear()` null means follow the desktop's default input
        // and keep following it, which is what makes switching microphones
        // mid-call work.
        //
        // Deliberately not fatal. A meeting recorded at the wrong level is
        // worth having; one that refuses to start is not.
        var level: ?MicLevel = MicLevel.init(cfg.meetingNear()) catch |err| blk: {
            log.warn("levelling the microphone is unavailable: {}", .{err});
            break :blk null;
        };
        errdefer if (level) |*l| l.deinit();

        // The calibrated figure, applied before a word is spoken. Without it
        // the near track sits at whatever the microphone was left at, which
        // measured 20 dB below the same voice dictating.
        if (level) |*l| {
            status.meeting_near.reportDevice(l.nodeName());
            status.meeting_near.reportGain(cfg.audio.gain);
            if (cfg.audio.gain > 1.01) _ = l.set(cfg.audio.gain);
        }

        // The far end is the sink's monitor. `capture_sink` is what makes that
        // the monitor rather than the default microphone.
        //
        // MONO rather than the FL the near end uses, and the difference is not
        // cosmetic. PipeWire's converter routes by channel position, so asking
        // a stereo monitor for FL hands back the left channel alone and
        // discards the right entirely -- measured at -91 dBFS against -17.6
        // for a tone panned hard right. Asking for MONO makes it downmix
        // instead, so a meeting app that pans, or sends one speaker per
        // channel, is heard rather than half-heard. The near end keeps FL
        // because there the channel is a deliberate choice of one input on a
        // multi-channel interface, where a downmix would be a mixture of every
        // microphone on the device.
        var far = try AudioCapture.init(.{
            .target = cfg.meeting.sink_name,
            .channel = AudioCapture.mono_channel,
            .capture_sink = true,
        });
        errdefer far.deinit();
        far.setActive(true);

        status.meeting.opened(rel, @intCast(std.time.nanoTimestamp()));
        std.debug.print("[meeting] session opened: {s}\n", .{rel});
        var out: Session = .{
            .near = near,
            .far = far,
            .aec = aec,
            .mixer = .{},
            .file = file,
            .transcript = transcript,
            .near_asr = near_asr,
            .far_asr = far_asr,
            // Runs whether or not the echo canceller does. It lifts the
            // residual along with the speech, so it cannot improve the ratio
            // between them, but a meeting recorded too quietly to hear is the
            // problem actually worth solving and the canceller's own tests
            // pin this off so they measure cancellation rather than levelling.
            .level = level,
            .configured_gain = cfg.audio.gain,
            .near_gain = if (cfg.audio.auto_gain)
                AutoGain{ .current_gain = cfg.audio.gain }
            else
                null,
            .far_silence = meeting.FarSilence.init(cfg.meeting.far_silence_close_seconds),
            .sessions_root = cfg.meeting.dir,
        };
        @memcpy(out.rel_path[0..rel.len], rel);
        out.rel_len = rel.len;
        return out;
    }

    /// Read whatever both captures have ready, transcribe it, and write the
    /// stereo frames that result. Blocks for at most one poll interval, so the
    /// caller's loop keeps ticking even while a track is silent.
    ///
    /// True when the far track has carried nothing for long enough that the
    /// session is over -- gate 1b. The caller closes; deciding is all that
    /// happens here.
    fn pump(self: *Session, gpa: std.mem.Allocator) !bool {
        var fds = [_]posix.pollfd{
            .{ .fd = self.near.pipe_read_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.far.pipe_read_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        // A failed poll still has to reach the gate below: an error here means
        // no audio, and no audio is exactly what gate 1b is counting.
        _ = posix.poll(&fds, poll_interval_ms) catch {};

        try self.readInto(gpa, fds[0], .near);
        try self.readInto(gpa, fds[1], .far);

        self.pending.clearRetainingCapacity();
        try self.mixer.drain(gpa, &self.pending);
        try self.file.append(self.pending.items);

        const signal = self.far_signal;
        self.far_signal = false;
        return self.far_silence.update(signal, @intCast(std.time.nanoTimestamp()));
    }

    fn readInto(self: *Session, gpa: std.mem.Allocator, fd: posix.pollfd, track: meeting.Track) !void {
        if (fd.revents & posix.POLL.IN == 0) return;
        const n = posix.read(fd.fd, &self.read_buf) catch return;
        if (n == 0) return;
        const pcm = self.read_buf[0..n];

        // Gate 1b, read here rather than anywhere downstream: this is the last
        // point at which the bytes are what the far end actually sent. One
        // non-zero byte is signal -- no threshold, no model, no opinion about
        // what kind of sound it was.
        if (track == .far and !std.mem.allEqual(u8, pcm, 0)) {
            self.far_signal = true;
            self.far_all_zero = false;
        }

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

        // Levelling, after transcription rather than before it, because the
        // voice activity gate is what says whether this was speech and the
        // controller must see nothing else. A new gain takes effect on the
        // audio that follows, which is what a level controller always does.
        if (track == .near) self.levelNear();

        // Put whatever that completed on disk, so the session being recorded
        // reads back as it happens rather than only once it has closed.
        self.transcript.saveIfChanged();
    }

    /// Feed the far track audio that arrived before this session existed --
    /// the pre-roll the listener held while waiting for the call to resume.
    ///
    /// Treated exactly as if it had just been read: recorded, transcribed, and
    /// counted as signal. The near track has no counterpart for that stretch,
    /// because nothing was capturing a microphone while no session was open,
    /// so `TrackMixer` pads it to match. That padding is honest -- it says the
    /// near end was not being recorded then, which is true.
    fn feedPreroll(self: *Session, gpa: std.mem.Allocator, pcm: []const u8) !void {
        if (pcm.len == 0) return;

        if (!std.mem.allEqual(u8, pcm, 0)) {
            self.far_signal = true;
            self.far_all_zero = false;
        }
        try self.mixer.push(gpa, .far, pcm);
        self.far_asr.feed(gpa, pcm, &self.transcript.doc) catch |err| {
            log.warn("transcription failed on the far pre-roll: {}", .{err});
        };
    }

    /// Track the level of the near end and adjust the microphone to suit.
    ///
    /// Driven by the voice activity gate rather than by every chunk, because a
    /// level controller must only ever see speech. Fed silence it decides the
    /// track is too quiet and winds the gain up, which on a meeting means
    /// winding up the room tone between sentences and, with an echo canceller
    /// in front, the residual it just removed.
    ///
    /// Near only. The far end arrives from the call already levelled by
    /// whatever the other side is running.
    fn levelNear(self: *Session) void {
        var level = &(self.level orelse return);
        const gain = &(self.near_gain orelse return);

        // A different microphone is a different problem, so the controller
        // starts again from the configured figure rather than carrying the old
        // device's across. A quiet interface and a headset worn against the
        // mouth are nowhere near each other.
        if (level.tookChange()) {
            gain.* = .{ .current_gain = self.configured_gain };
            _ = level.set(self.configured_gain);
            status.meeting_near.reportDevice(level.nodeName());
            status.meeting_near.reportGain(self.configured_gain);
            log.info("microphone changed to '{s}', levelling from {d:.1}x again", .{
                level.nodeName(), self.configured_gain,
            });
            self.near_asr.speech_rms = null;
            return;
        }

        const rms = self.near_asr.speech_rms orelse return;
        self.near_asr.speech_rms = null;
        status.meeting_near.reportLevel(@floatCast(utils.rmsToDb(rms)));
        if (gain.update(rms)) |new_gain| {
            _ = level.set(new_gain);
            status.meeting_near.reportGain(new_gain);
        }
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
        // After the captures, so nothing is reading the cleaned microphone
        // when it leaves the graph.
        if (self.level) |*l| l.deinit();
        if (self.aec) |*a| a.deinit();

        self.near_asr.finish(gpa, &self.transcript.doc) catch {};
        self.far_asr.finish(gpa, &self.transcript.doc) catch {};
        // Read before the tracks are torn down, and after `finish`, which
        // pushes the tail through the gate and can be what opens it.
        const heard_speech = self.near_asr.vad_fired or self.far_asr.vad_fired;
        self.near_asr.deinit(gpa);
        self.far_asr.deinit(gpa);

        self.transcript.finish();
        self.mixer.deinit(gpa);
        self.pending.deinit(gpa);

        const seconds = self.file.durationSeconds();
        self.file.finish(gpa);
        status.meeting.closed();

        if (self.far_all_zero) {
            self.discard(seconds, "nothing ever arrived from the far end");
            return;
        }
        // Nobody spoke on either side. A meeting app can hold the sink over a
        // room that is empty, or over one where the only sound is someone
        // else's conversation two desks away -- audio both times, a meeting
        // neither time. The gate is the thing that already knows the
        // difference, so it is the thing that is asked.
        if (!heard_speech) {
            self.discard(seconds, "no speech on either track");
            return;
        }
        std.debug.print("[meeting] session closed ({d:.1}s of audio)\n", .{seconds});
    }

    /// Remove a session that recorded no meeting, for one of the two reasons
    /// that can be known only once it is over: nothing ever arrived from the
    /// far end, or nothing either side said was speech. The first case was
    /// five hours of dictation that had nothing to do with any meeting; the
    /// second is a call left open over an empty room.
    ///
    /// `why` is said out loud rather than inferred from the file, because the
    /// two rules fail in different directions and an operator looking at a
    /// missing recording needs to know which one to distrust.
    ///
    /// Safe to remove whole rather than file by file: `SessionFile.create`
    /// refuses to reuse an existing directory, so nothing under `rel_path` was
    /// written by anything but this session, and `sessionPath` builds the path
    /// from formatted integers alone -- it can hold no `..` and no separator
    /// that was not put there deliberately.
    ///
    /// Said out loud on both the console and the journal. Deleting quietly is
    /// the one thing here that could destroy a real recording if the rule is
    /// ever wrong, and an operator who cannot see it happen cannot tell us.
    fn discard(self: *Session, seconds: f64, why: []const u8) void {
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

        log.info("discarded {s}: {s}", .{ rel, why });
        std.debug.print(
            "[meeting] session discarded ({d:.1}s, {s}): {s}\n",
            .{ seconds, why, rel },
        );
    }
};

/// What watches the far track between sessions.
///
/// When gate 1b closes a session, gate 1 is still reporting a stream -- the
/// application never let go of the sink, which is the entire reason gate 1b
/// had to exist. So gate 1 cannot be what notices the call resuming, and
/// something has to keep listening or a meeting that restarts is simply lost.
///
/// Deliberately the cheapest thing that could work: one capture on the
/// monitor, one `allEqual` per read, and a few seconds of audio kept so the
/// session that starts begins before the sound that started it. No pipeline,
/// no model, no transcript, no files. That cheapness is why gate 1b compares
/// bytes instead of running a VAD -- the idle path is the one that runs for
/// hours, and this one costs nothing to leave running.
const FarListener = struct {
    far: AudioCapture,
    signal: meeting.FarSignal,

    /// The most recent `limit` bytes of far audio, in order. Trimmed from the
    /// front as it fills, so what it holds is always the tail.
    preroll: std.ArrayListUnmanaged(u8) = .{},
    limit: usize,

    read_buf: [8192]u8 = undefined,

    fn open(cfg: *const config.Config) !FarListener {
        var far = try AudioCapture.init(.{
            .target = cfg.meeting.sink_name,
            .channel = AudioCapture.mono_channel,
            .capture_sink = true,
        });
        errdefer far.deinit();
        far.setActive(true);

        return .{
            .far = far,
            .signal = .{ .needed = cfg.meeting.far_signal_chunks },
            .limit = @as(usize, cfg.meeting.far_preroll_seconds) * bytes_per_second,
        };
    }

    fn deinit(self: *FarListener, gpa: std.mem.Allocator) void {
        self.far.setActive(false);
        self.far.deinit();
        self.preroll.deinit(gpa);
    }

    /// Poll once. Returns the audio to start the next session with, once the
    /// far track has carried signal for long enough.
    fn poll(self: *FarListener, gpa: std.mem.Allocator) !?[]const u8 {
        var fds = [_]posix.pollfd{
            .{ .fd = self.far.pipe_read_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, poll_interval_ms) catch {};

        var signal = false;
        if (fds[0].revents & posix.POLL.IN != 0) {
            if (posix.read(fds[0].fd, &self.read_buf)) |n| {
                if (n > 0) {
                    const pcm = self.read_buf[0..n];
                    signal = !std.mem.allEqual(u8, pcm, 0);
                    try self.keep(gpa, pcm);
                }
            } else |_| {}
        }

        if (!self.signal.update(signal)) return null;
        return self.preroll.items;
    }

    /// Hold the tail of the far track, dropping whatever no longer fits.
    ///
    /// `trimBuffer` rather than a trim written here, for the sample alignment:
    /// a read can end on an odd byte, and dropping an odd number of bytes
    /// swaps the halves of every s16 sample after it.
    fn keep(self: *FarListener, gpa: std.mem.Allocator, pcm: []const u8) !void {
        if (self.limit == 0) return;
        try self.preroll.appendSlice(gpa, pcm);
        utils.trimBuffer(&self.preroll, self.limit);
    }
};

/// Where the process table lives. A constant rather than a setting: the
/// alternative is somewhere this cannot read, and then there is nothing to
/// configure it to.
const proc_root = "/proc";

/// Record who was playing into the sink as the session opened, in
/// `audio.json` beside the audio and the transcript.
///
/// Best effort from top to bottom. A recording with nothing beside it saying
/// where it came from is worth enormously more than no recording, so every
/// failure here is logged and stepped over rather than returned.
fn writeSourceMetadata(
    gpa: std.mem.Allocator,
    dir: std.fs.Dir,
    watch: *const SinkWatch,
    cfg: *const config.Config,
) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const streams = watch.snapshot(arena) catch |err| {
        log.warn("could not read who is playing into the sink: {}", .{err});
        return;
    };
    const wanted: source.Wanted = .{
        .near = cfg.meetingNear(),
        .output = cfg.meeting.output,
    };
    const doc = source.capture(arena, streams, wanted, proc_root) catch |err| {
        log.warn("could not read the processes behind the call: {}", .{err});
        return;
    };
    const bytes = source.render(arena, doc) catch |err| {
        log.warn("could not render audio.json: {}", .{err});
        return;
    };

    if (dir.createFile("audio.json", .{})) |out| {
        defer out.close();
        out.writeAll(bytes) catch |err| log.err("could not write audio.json: {}", .{err});
    } else |err| log.err("could not create audio.json: {}", .{err});
}

/// The session's `transcript.vtt`.
///
/// Held in memory and rewritten whole every time a cue completes, so a meeting
/// in progress can be read while it is still running rather than only once it
/// has ended.
///
/// Whole rather than appended, because cues from the two tracks have to be
/// merged by audio position: a cue completes when its own track goes quiet, so
/// they finish out of order and a far cue can belong above a near cue already
/// on disk. Rendering the lot costs nothing at these sizes -- an hour of
/// transcript is tens of kilobytes, against hundreds of megabytes of audio
/// beside it -- and it is the only version that is always correct.
pub const Transcript = struct {
    doc: webvtt.Transcript,
    dir: std.fs.Dir,

    /// How many cues the file on disk holds. An audio chunk that completed no
    /// cue changes nothing, and most do not, so this is what keeps the
    /// rewrite to once per cue rather than once per chunk.
    written_cues: usize = 0,

    /// So a recording found in two years says which side is which without
    /// needing this repository to explain it.
    channels_note: []const u8,

    /// What kind of transcript this is, as the file's first note.
    kind_note: []const u8 = "capsper meeting transcript",

    /// `layout` says what the channels of `audio_name` are, in the words a
    /// person reading the file in two years needs -- "near end (microphone) =
    /// left, far end (call) = right" for a call, "one microphone, the room"
    /// for a room. Given rather than derived, because only the caller knows
    /// what it recorded.
    pub fn create(
        gpa: std.mem.Allocator,
        dir: std.fs.Dir,
        detail: config.Detail,
        audio_name: []const u8,
        layout: []const u8,
    ) !Transcript {
        return .{
            .doc = webvtt.Transcript.init(gpa, switch (detail) {
                .minimal => .minimal,
                .debug => .debug,
            }),
            .dir = dir,
            .channels_note = try std.fmt.allocPrint(gpa, "{s}: {s}", .{ audio_name, layout }),
        };
    }

    /// Rewrite the file if a cue has completed since the last time.
    ///
    /// Called after every audio chunk, which is why the cheap check comes
    /// first: transcribing a chunk usually extends the cue being built rather
    /// than finishing one, and a render and a write per chunk would be
    /// hundreds of times the work for the same bytes.
    pub fn saveIfChanged(self: *Transcript) void {
        if (self.doc.cues.items.len == self.written_cues) return;
        self.save();
    }

    /// Render the whole transcript and put it in place atomically.
    ///
    /// Written to a temporary name and renamed, because the session server may
    /// be serving this file to a browser at any moment and a reader that
    /// arrives mid-write would get a truncated transcript. `rename` within a
    /// directory is atomic, so a reader sees either the previous version or
    /// the new one.
    ///
    /// The temporary name starts with a dot rather than with `audio.`, which
    /// is not cosmetic: the session server finds sessions by looking for a
    /// file called `audio.something`, and a stray `audio.vtt.tmp` would be
    /// collected as if it were a recording.
    fn save(self: *Transcript) void {
        const tmp = ".audio.vtt.tmp";
        const header_notes = [_][]const u8{ self.kind_note, self.channels_note };

        const bytes = self.doc.render(&header_notes) catch |err| {
            log.err("could not render the transcript: {}", .{err});
            return;
        };
        defer self.doc.gpa.free(bytes);

        if (self.dir.createFile(tmp, .{})) |file| {
            defer file.close();
            file.writeAll(bytes) catch |err| {
                log.err("could not write the transcript: {}", .{err});
                return;
            };
        } else |err| {
            log.err("could not create the transcript: {}", .{err});
            return;
        }

        self.dir.rename(tmp, "audio.vtt") catch |err| {
            log.err("could not put audio.vtt in place: {}", .{err});
            return;
        };
        self.written_cues = self.doc.cues.items.len;
    }

    pub fn finish(self: *Transcript) void {
        defer self.doc.gpa.free(self.channels_note);
        // Unconditional rather than saveIfChanged: closing flushes the cue
        // each track still had open, and those are exactly the ones a running
        // save has never seen.
        self.save();
        self.doc.deinit();
    }

    pub fn deinit(self: *Transcript) void {
        self.doc.gpa.free(self.channels_note);
        self.doc.deinit();
    }
};
