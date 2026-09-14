// src/shared/session.zig — push-to-talk session logic, off to the side.
//
// The core streaming loop (server.zig) is data-driven and must stay that way:
// TCP throughput drives test speed, so no wall-clock timeouts leak into it.
// All PTT concerns — press/release, segmentation, and recording — live here as
// a pure state machine driven by an Event stream. TCP's EventSource emits only
// `audio`/`eof`, so it is structurally impossible for PTT/recording/timeout
// logic to affect the TCP path.
//
// The driver is pure: it consumes an Event and returns Actions. The caller
// (server.zig) executes Actions against the real Pipeline/Recorder/fd. Tests
// drive a ScriptedEventSource and execute Actions against a real Recorder —
// no keyboard, no clock, no sockets, no GPU.

const std = @import("std");
const posix = std.posix;
const Recorder = @import("recorder.zig").Recorder;

/// Input to the session driver. The *source* of these events is pluggable
/// (see EventSource): TCP yields only `audio`/`eof`; local PTT capture also
/// yields `press`/`release`/`timeout`; tests yield a scripted sequence.
pub const Event = union(enum) {
    audio: []const u8, // a chunk of PCM to pump into the pipeline (+ record)
    press, // PTT pressed — begin an utterance
    release, // PTT released — end the utterance
    timeout, // safety net (lost release / stuck key) — treated like release
    eof, // audio source ended — flush and stop
};

/// What the driver decides should happen, for the caller to execute. Keeps the
/// driver free of I/O, the Pipeline, and the GPU so it is trivially testable.
pub const Action = union(enum) {
    reset_segment, // start a fresh ASR segment
    start_recording, // begin capturing audio to the recorder
    record: []const u8, // tap these exact bytes to the recorder
    transcribe: struct { audio: []const u8, flush: bool }, // pump into pipeline
    end_recording, // flush the recording to disk (writes the .wav)
    stop, // exit the session loop (eof)
};

/// Fixed-capacity action list — the driver emits at most 3 actions per event,
/// so no allocation is needed. Mirrors the CharEvents pattern in input.zig.
pub const ActionList = struct {
    items: [4]Action = undefined,
    len: usize = 0,

    fn push(self: *ActionList, a: Action) void {
        self.items[self.len] = a;
        self.len += 1;
    }

    pub fn slice(self: *const ActionList) []const Action {
        return self.items[0..self.len];
    }
};

/// Pure input-level monitor: fed one chunk's RMS (in dBFS) at a time while a
/// PTT utterance is live, it emits a transition ONLY when a rolling average
/// crosses a hysteresis threshold — so it reports "audio" vs "silence" without
/// spamming on every chunk or flapping around the boundary. Kept pure (no I/O,
/// no clock) so it is unit-testable; the caller logs the returned transition.
///
/// Rolling average is an EMA; with ~560ms chunks, alpha=0.3 gives a ~2s time
/// constant. The 10 dB gap between enter/exit thresholds plus that smoothing
/// means normal pauses between words never trip it. Reset on each PTT press.
pub const InputLevelMonitor = struct {
    ema_db: f64 = 0,
    warmup: u8 = 0,
    silent: bool = false,

    const alpha: f64 = 0.3;
    const warmup_chunks: u8 = 3; // ~1.7s before the first evaluation
    const silence_enter_db: f64 = -60.0;
    const audio_enter_db: f64 = -50.0;

    pub const Transition = enum { audio, silence };

    /// Start a fresh evaluation window (call on PTT press).
    pub fn reset(self: *InputLevelMonitor) void {
        self.* = .{};
    }

    /// Feed one chunk's RMS level in dBFS. Returns a transition if the smoothed
    /// level newly crossed a threshold, else null. Values are seeded during a
    /// short warmup so a genuinely-silent start fires once (not on chunk 1).
    pub fn update(self: *InputLevelMonitor, db: f64) ?Transition {
        if (self.warmup < warmup_chunks) {
            self.ema_db = if (self.warmup == 0) db else self.ema_db * (1 - alpha) + db * alpha;
            self.warmup += 1;
            return null;
        }
        self.ema_db = self.ema_db * (1 - alpha) + db * alpha;
        if (!self.silent and self.ema_db < silence_enter_db) {
            self.silent = true;
            return .silence;
        }
        if (self.silent and self.ema_db > audio_enter_db) {
            self.silent = false;
            return .audio;
        }
        return null;
    }

    pub fn levelDb(self: *const InputLevelMonitor) f64 {
        return self.ema_db;
    }
};

/// What the microphone actually delivered across one capture window.
///
/// `InputLevelMonitor` answers "is this quiet?" while audio flows, which leaves
/// the worse failure unreported: when the device stops delivering there are no
/// chunks, so nothing reaches a per-chunk detector and the window ends with
/// nothing said about it. That is what a USB interface that has dropped out
/// looks like from in here, and to the user it reads as capsper being broken —
/// they restart capsper, which cannot help, rather than the interface, which
/// would.
///
/// Deliberately narrow: every verdict below is one a working microphone cannot
/// produce. A warning that cries wolf on a press where nobody got round to
/// speaking is worse than no warning at all, so "quiet" is left to the monitor
/// above and this reports only "nothing at all".
pub const CaptureReport = struct {
    bytes: usize = 0,
    peak: u16 = 0,

    /// 16 kHz mono S16 — the only format that reaches here.
    const bytes_per_ms: u64 = 32;

    /// Audio missing from the head of a window that the device is not to blame
    /// for: outside low-latency mode the PipeWire stream is connected per press
    /// and takes roughly this long to hand over its first buffer.
    const connect_allowance_ms: u64 = 1500;

    /// Shorter than this and there is nothing to judge — a quick tap ends
    /// before the stream has produced anything, which is ordinary.
    const min_window_ms: u64 = 2000;

    pub const Verdict = union(enum) {
        /// Not one byte arrived.
        no_audio,
        /// Audio arrived and every sample of it was exactly zero. A live
        /// converter always dithers; only a stopped or muted one reads as
        /// true digital zero.
        digital_silence,
        /// Far less audio than the window lasted, in milliseconds captured.
        starved: u64,
    };

    /// Begin a fresh window (call on PTT press).
    pub fn start(self: *CaptureReport) void {
        self.* = .{};
    }

    /// Feed one chunk of captured PCM.
    pub fn feed(self: *CaptureReport, pcm: []const u8) void {
        self.bytes += pcm.len;

        var i: usize = 0;
        while (i + 1 < pcm.len) : (i += 2) {
            const sample = std.mem.readInt(i16, pcm[i..][0..2], .little);
            // Negated as i32: -32768 has no positive i16 counterpart.
            const magnitude: u16 = @intCast(@abs(@as(i32, sample)));
            if (magnitude > self.peak) self.peak = magnitude;
        }
    }

    /// What to say about the window just ended, or null if there is nothing
    /// wrong with it worth saying.
    pub fn verdict(self: *const CaptureReport, window_ms: u64) ?Verdict {
        if (window_ms < min_window_ms) return null;
        if (self.bytes == 0) return .no_audio;
        if (self.peak == 0) return .digital_silence;

        const captured_ms = self.bytes / bytes_per_ms;
        const owed_ms = window_ms - connect_allowance_ms;
        // Half, not all: the allowance above is a typical connect time rather
        // than a bound, and this should fire on a device that has stopped, not
        // on one that was slow to start.
        if (captured_ms * 2 < owed_ms) return .{ .starved = captured_ms };

        return null;
    }
};

/// Pure PTT/segmentation/recording state machine. `live` tracks whether an
/// utterance is in progress. Every transition that ends an utterance
/// (release/timeout/eof) flushes the pipeline AND ends the recording — the two
/// were previously only reachable on a code path that cork-mode starved, which
/// is why recordings were never written and segments never reset.
pub const SessionDriver = struct {
    live: bool,

    /// `live_at_start`: TCP connections start live (always-on); local PTT
    /// starts not-live (waiting for the first press).
    pub fn init(live_at_start: bool) SessionDriver {
        return .{ .live = live_at_start };
    }

    pub fn step(self: *SessionDriver, ev: Event) ActionList {
        var out = ActionList{};
        switch (ev) {
            .press => {
                if (!self.live) {
                    self.live = true;
                    out.push(.reset_segment);
                    out.push(.start_recording);
                }
            },
            .audio => |bytes| {
                if (self.live) {
                    out.push(.{ .record = bytes });
                    out.push(.{ .transcribe = .{ .audio = bytes, .flush = false } });
                }
            },
            .release, .timeout => {
                if (self.live) {
                    self.live = false;
                    out.push(.{ .transcribe = .{ .audio = &.{}, .flush = true } });
                    out.push(.end_recording);
                }
            },
            .eof => {
                if (self.live) {
                    self.live = false;
                    out.push(.{ .transcribe = .{ .audio = &.{}, .flush = true } });
                    out.push(.end_recording);
                }
                out.push(.stop);
            },
        }
        return out;
    }
};

/// Pluggable source of Events. Fat-pointer vtable (per the project's Zig-0.15
/// convention), like std.mem.Allocator. Implementations: TcpEventSource and
/// LocalPttEventSource (in server.zig, where the fds live) and
/// ScriptedEventSource (below, for tests).
pub const EventSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque) anyerror!Event,
    };

    pub fn next(self: EventSource) !Event {
        return self.vtable.next(self.ptr);
    }
};

/// Test-only EventSource that replays a fixed slice of Events, then `eof`.
pub const ScriptedEventSource = struct {
    events: []const Event,
    idx: usize = 0,

    pub fn source(self: *ScriptedEventSource) EventSource {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = EventSource.VTable{ .next = nextImpl };

    fn nextImpl(ptr: *anyopaque) anyerror!Event {
        const self: *ScriptedEventSource = @ptrCast(@alignCast(ptr));
        if (self.idx >= self.events.len) return .eof;
        const e = self.events[self.idx];
        self.idx += 1;
        return e;
    }
};

/// EventSource for local push-to-talk capture. Multiplexes two fds with a
/// blocking `poll` (no timeout — wakes only when something happens, so no
/// wall-clock is baked into the hot path):
///   - `audio_fd`: the PCM pipe from the capture thread → `audio` events.
///   - `ptt_fd`: a pipe the input thread writes on each PTT transition
///     (byte 1 = press, 0 = release) → `press`/`release` events.
///
/// PTT is checked before audio so a release is delivered promptly even mid
/// audio — crucially, it is NOT starved when the capture stream corks on
/// release (the bug that stopped recordings and let one segment run forever).
/// Partial sub-chunk audio tails are held until they fill (same as the old
/// ChunkedReader), so no full chunk is ever split.
pub const LocalPttEventSource = struct {
    audio_fd: posix.fd_t,
    ptt_fd: posix.fd_t,
    chunk_size: usize,
    skip_digital_zero: bool,
    buf: [32768]u8 = undefined,
    buffered: usize = 0,
    offset: usize = 0,
    saw_eof: bool = false,

    pub fn init(audio_fd: posix.fd_t, ptt_fd: posix.fd_t, chunk_size: usize, skip_digital_zero: bool) LocalPttEventSource {
        return .{ .audio_fd = audio_fd, .ptt_fd = ptt_fd, .chunk_size = chunk_size, .skip_digital_zero = skip_digital_zero };
    }

    pub fn source(self: *LocalPttEventSource) EventSource {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = EventSource.VTable{ .next = nextImpl };

    fn nextImpl(ptr: *anyopaque) anyerror!Event {
        const self: *LocalPttEventSource = @ptrCast(@alignCast(ptr));
        while (true) {
            // Yield any buffered full chunk first (skipping all-zero chunks).
            while (self.buffered - self.offset >= self.chunk_size) {
                const start = self.offset;
                self.offset += self.chunk_size;
                const chunk = self.buf[start .. start + self.chunk_size];
                if (self.skip_digital_zero and std.mem.allEqual(u8, chunk, 0)) continue;
                return .{ .audio = chunk };
            }
            // Compact consumed bytes to the front so the next read has room.
            if (self.offset > 0) {
                const rem = self.buffered - self.offset;
                if (rem > 0) std.mem.copyForwards(u8, self.buf[0..rem], self.buf[self.offset..self.buffered]);
                self.buffered = rem;
                self.offset = 0;
            }
            if (self.saw_eof) return .eof;

            var fds = [_]posix.pollfd{
                .{ .fd = self.ptt_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.audio_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = try posix.poll(&fds, -1);

            // PTT first — a release must not wait behind buffered audio.
            if (fds[0].revents & posix.POLL.IN != 0) {
                var b: [1]u8 = undefined;
                const n = posix.read(self.ptt_fd, &b) catch 0;
                if (n == 1) return if (b[0] != 0) Event.press else Event.release;
                // n == 0: ptt pipe closed — ignore, fall through to audio.
            }

            // Audio — accumulate; the top of the loop yields once a chunk fills.
            if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
                const n = posix.read(self.audio_fd, self.buf[self.buffered..]) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => return err,
                };
                if (n == 0) {
                    self.saw_eof = true;
                    continue;
                }
                self.buffered += n;
            }
        }
    }
};

// ──────────────────────────── tests ────────────────────────────

const testing = std.testing;

fn expectTags(actions: []const Action, tags: []const std.meta.Tag(Action)) !void {
    try testing.expectEqual(tags.len, actions.len);
    for (actions, tags) |a, t| try testing.expectEqual(t, std.meta.activeTag(a));
}

test "driver: press while idle resets segment and starts recording" {
    var d = SessionDriver.init(false);
    const acts = d.step(.press);
    try expectTags(acts.slice(), &.{ .reset_segment, .start_recording });
    try testing.expect(d.live);
}

test "driver: press while already live is idempotent" {
    var d = SessionDriver.init(false);
    _ = d.step(.press);
    const acts = d.step(.press);
    try testing.expectEqual(@as(usize, 0), acts.len);
    try testing.expect(d.live);
}

test "driver: audio while live records then transcribes" {
    var d = SessionDriver.init(false);
    _ = d.step(.press);
    const acts = d.step(.{ .audio = "abcd" });
    try expectTags(acts.slice(), &.{ .record, .transcribe });
    try testing.expectEqualStrings("abcd", acts.items[0].record);
    try testing.expect(!acts.items[1].transcribe.flush);
}

test "driver: audio while not live is discarded" {
    var d = SessionDriver.init(false);
    const acts = d.step(.{ .audio = "abcd" });
    try testing.expectEqual(@as(usize, 0), acts.len);
}

// Regression for the never-cork low-latency change: the capture stream now stays
// continuously active, so `audio` events arrive even between presses and across a
// rapid release→re-press (previously cork paused the stream, and uncork-from-
// suspend dropped the first seconds of audio). The software gate must discard
// non-live audio and give each press a fresh segment.
test "driver: rapid re-press gates interleaved audio and resets each segment" {
    var d = SessionDriver.init(false);

    // First utterance.
    try expectTags(d.step(.press).slice(), &.{ .reset_segment, .start_recording });
    try expectTags(d.step(.{ .audio = "aaaa" }).slice(), &.{ .record, .transcribe });
    try expectTags(d.step(.release).slice(), &.{ .transcribe, .end_recording });

    // Audio keeps flowing while not live (stream stays active) — must be discarded.
    try testing.expectEqual(@as(usize, 0), d.step(.{ .audio = "----" }).len);
    try testing.expect(!d.live);

    // Rapid re-press: fresh segment + recording, then live audio again.
    try expectTags(d.step(.press).slice(), &.{ .reset_segment, .start_recording });
    try expectTags(d.step(.{ .audio = "bbbb" }).slice(), &.{ .record, .transcribe });
    try expectTags(d.step(.release).slice(), &.{ .transcribe, .end_recording });
}

// The core regression: release, timeout AND eof must each flush the pipeline
// and end the recording. The old bug was that NONE of these reached the
// endRecording call (cork starved the loop; the EOF path omitted it).
test "driver: release while live flushes and ends recording" {
    var d = SessionDriver.init(false);
    _ = d.step(.press);
    const acts = d.step(.release);
    try expectTags(acts.slice(), &.{ .transcribe, .end_recording });
    try testing.expect(acts.items[0].transcribe.flush);
    try testing.expect(!d.live);
}

test "driver: timeout while live flushes and ends recording (safety net)" {
    var d = SessionDriver.init(false);
    _ = d.step(.press);
    const acts = d.step(.timeout);
    try expectTags(acts.slice(), &.{ .transcribe, .end_recording });
    try testing.expect(!d.live);
}

test "driver: release while not live is a no-op" {
    var d = SessionDriver.init(false);
    const acts = d.step(.release);
    try testing.expectEqual(@as(usize, 0), acts.len);
}

test "driver: eof while live flushes, ends recording, then stops" {
    var d = SessionDriver.init(false);
    _ = d.step(.press);
    const acts = d.step(.eof);
    try expectTags(acts.slice(), &.{ .transcribe, .end_recording, .stop });
}

test "driver: eof while idle just stops" {
    var d = SessionDriver.init(true); // TCP starts live
    // simulate a release having already happened
    _ = d.step(.release);
    const acts = d.step(.eof);
    try expectTags(acts.slice(), &.{.stop});
}

test "level monitor: warmup swallows the first few chunks (no transition)" {
    var m = InputLevelMonitor{};
    // Even dead-silent input must not fire during warmup.
    for (0..InputLevelMonitor.warmup_chunks) |_| {
        try testing.expectEqual(@as(?InputLevelMonitor.Transition, null), m.update(-90));
    }
}

test "level monitor: steady audio never reports silence" {
    var m = InputLevelMonitor{};
    var fired: usize = 0;
    for (0..50) |_| {
        if (m.update(-35) != null) fired += 1;
    }
    try testing.expectEqual(@as(usize, 0), fired);
}

test "level monitor: sustained quiet fires silence exactly once" {
    var m = InputLevelMonitor{};
    var silences: usize = 0;
    for (0..50) |_| {
        if (m.update(-85)) |t| {
            try testing.expectEqual(InputLevelMonitor.Transition.silence, t);
            silences += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), silences); // once, not per chunk
    try testing.expect(m.silent);
}

test "level monitor: silence then audio yields one of each, in order" {
    var m = InputLevelMonitor{};
    var seq: [2]InputLevelMonitor.Transition = undefined;
    var n: usize = 0;
    for (0..30) |_| if (m.update(-85)) |t| {
        seq[n] = t;
        n += 1;
    };
    for (0..30) |_| if (m.update(-30)) |t| {
        seq[n] = t;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(InputLevelMonitor.Transition.silence, seq[0]);
    try testing.expectEqual(InputLevelMonitor.Transition.audio, seq[1]);
}

test "level monitor: hysteresis — dithering in the dead band does not flap" {
    var m = InputLevelMonitor{};
    // Settle into audio well above the audio-enter threshold.
    for (0..10) |_| _ = m.update(-30);
    // Now dither between the two thresholds (-60..-50): must stay quiet.
    var fired: usize = 0;
    for (0..40) |i| {
        const db: f64 = if (i % 2 == 0) -52 else -58; // both inside the dead band
        if (m.update(db) != null) fired += 1;
    }
    try testing.expectEqual(@as(usize, 0), fired);
    try testing.expect(!m.silent);
}

test "level monitor: reset re-arms warmup" {
    var m = InputLevelMonitor{};
    for (0..20) |_| _ = m.update(-85); // becomes silent
    try testing.expect(m.silent);
    m.reset();
    try testing.expectEqual(@as(u8, 0), m.warmup);
    try testing.expect(!m.silent);
    // Post-reset warmup swallows again.
    try testing.expectEqual(@as(?InputLevelMonitor.Transition, null), m.update(-85));
}

// End-to-end: drive a scripted PTT session and execute the recorder-relevant
// actions against a REAL Recorder in a temp dir. Proves recording actually
// writes a .wav — the thing that has been silently broken — with no keyboard,
// clock, socket, or GPU. `transcribe` actions are no-ops here (no pipeline).
fn expectTag(e: Event, tag: std.meta.Tag(Event)) !void {
    try testing.expectEqual(tag, std.meta.activeTag(e));
}

// LocalPttEventSource multiplexes a PTT pipe and an audio pipe with real fds
// (no hardware). Proves a release is delivered even though audio is present,
// full chunks are yielded, and audio-pipe EOF surfaces as `.eof`.
// ──── CaptureReport ────
//
// The numbers below are the ones from the morning a Vocaster stopped
// delivering mid-session: capsper wrote three recordings, reported success for
// all three, and said nothing at all about the microphone having died.

/// `ms` of 16 kHz mono S16 at a constant amplitude.
fn tone(buf: []u8, amplitude: i16) []u8 {
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 2) {
        std.mem.writeInt(i16, buf[i..][0..2], amplitude, .little);
    }
    return buf;
}

test "capture report: a healthy press says nothing" {
    var buf: [3000 * 32]u8 = undefined;
    var r = CaptureReport{};
    r.feed(tone(&buf, 8000));
    try std.testing.expectEqual(@as(?CaptureReport.Verdict, null), r.verdict(3800));
}

test "capture report: 008.wav — a long press that captured nothing at all" {
    var r = CaptureReport{};
    try std.testing.expectEqual(CaptureReport.Verdict.no_audio, r.verdict(2400).?);
}

test "capture report: a quick tap is too short to judge" {
    // 008 itself was a 0.2s tap; ending before the stream produces anything is
    // ordinary and must not warn.
    var r = CaptureReport{};
    try std.testing.expectEqual(@as(?CaptureReport.Verdict, null), r.verdict(200));
}

test "capture report: a device streaming pure zeros is not a quiet room" {
    var buf: [3000 * 32]u8 = undefined;
    var r = CaptureReport{};
    r.feed(tone(&buf, 0));
    try std.testing.expectEqual(CaptureReport.Verdict.digital_silence, r.verdict(3800).?);
}

test "capture report: 007.wav — 0.56s of audio in a 3.8s press" {
    var buf: [560 * 32]u8 = undefined;
    var r = CaptureReport{};
    r.feed(tone(&buf, 102)); // the measured peak: noise floor, but not zero
    try std.testing.expectEqual(CaptureReport.Verdict{ .starved = 560 }, r.verdict(3800).?);
}

test "capture report: a slow stream start is not starvation" {
    // 2.0s of audio in a 3.8s press — the head lost to connecting the stream.
    var buf: [2000 * 32]u8 = undefined;
    var r = CaptureReport{};
    r.feed(tone(&buf, 8000));
    try std.testing.expectEqual(@as(?CaptureReport.Verdict, null), r.verdict(3800));
}

test "capture report: peak survives a quiet chunk after a loud one" {
    var loud: [100 * 32]u8 = undefined;
    var quiet: [2900 * 32]u8 = undefined;
    var r = CaptureReport{};
    r.feed(tone(&loud, -32768)); // the sample with no positive counterpart
    r.feed(tone(&quiet, 0));
    try std.testing.expectEqual(@as(u16, 32768), r.peak);
    try std.testing.expectEqual(@as(?CaptureReport.Verdict, null), r.verdict(3000));
}

test "capture report: start clears the previous window" {
    var buf: [3000 * 32]u8 = undefined;
    var r = CaptureReport{};
    r.feed(tone(&buf, 8000));
    r.start();
    try std.testing.expectEqual(@as(usize, 0), r.bytes);
    try std.testing.expectEqual(CaptureReport.Verdict.no_audio, r.verdict(2400).?);
}

test "LocalPttEventSource: multiplexes PTT and audio over real pipes" {
    const audio = try posix.pipe();
    defer posix.close(audio[0]);
    const ptt = try posix.pipe();
    defer posix.close(ptt[0]);
    defer posix.close(ptt[1]);

    var impl = LocalPttEventSource.init(audio[0], ptt[0], 320, true);
    const src = impl.source();

    // press
    _ = try posix.write(ptt[1], &[_]u8{1});
    try expectTag(try src.next(), .press);

    // one full audio chunk
    const chunk = [_]u8{0x22} ** 320;
    _ = try posix.write(audio[1], &chunk);
    const a = try src.next();
    try expectTag(a, .audio);
    try testing.expectEqual(@as(usize, 320), a.audio.len);

    // an all-zero chunk is skipped, and a release behind it still arrives
    const zeros = [_]u8{0} ** 320;
    _ = try posix.write(audio[1], &zeros);
    _ = try posix.write(ptt[1], &[_]u8{0});
    try expectTag(try src.next(), .release); // zeros skipped, release delivered

    // audio pipe EOF → .eof
    posix.close(audio[1]);
    try expectTag(try src.next(), .eof);
}

test "scripted PTT session writes a recording and its transcript" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var rec = try Recorder.init(allocator, dir_path, 10, "test", .debug);
    defer rec.deinit();

    // Two 320-byte chunks of non-zero S16 PCM (0x1111 samples).
    const chunk = [_]u8{0x11} ** 320;
    var script = ScriptedEventSource{ .events = &.{
        .press,
        .{ .audio = &chunk },
        .{ .audio = &chunk },
        .release,
        .eof,
    } };
    const src = script.source();

    var driver = SessionDriver.init(false);
    var saw_file_before_end = false;
    var position_ms: u64 = 0;

    loop: while (true) {
        const ev = try src.next();
        const acts = driver.step(ev);
        for (acts.slice()) |a| switch (a) {
            .start_recording => rec.startRecording(),
            .record => |bytes| rec.recordPcm(bytes),
            .end_recording => try rec.endRecording(),
            .reset_segment => {},
            // No pipeline here, so the text a real one would have produced is
            // supplied directly. That is all the recorder ever sees of it.
            .transcribe => rec.logEmit("hello"),
            .stop => break :loop,
        };
        if (ev == .audio) {
            // One chunk of audio, loud, carrying whatever was just emitted.
            const next_ms = position_ms + 10;
            rec.markChunk(position_ms, next_ms, 0.5);
            position_ms = next_ms;

            // Before release, nothing should be flushed to disk yet.
            tmp.dir.access("000.wav", .{}) catch {
                saw_file_before_end = false;
                continue;
            };
            saw_file_before_end = true;
        }
    }

    // The recording must exist now, and must not have appeared mid-utterance.
    try testing.expect(!saw_file_before_end);
    const st = try tmp.dir.statFile("000.wav");
    try testing.expectEqual(@as(u64, 44 + 2 * 320), st.size); // 44-byte header + PCM

    // The transcript beside it is a real WebVTT file: a header note saying
    // what wrote it, and a cue carrying the text against its audio position.
    const vtt = try tmp.dir.readFileAlloc(allocator, "000.vtt", 64 * 1024);
    defer allocator.free(vtt);

    try testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n"));
    try testing.expect(std.mem.indexOf(u8, vtt, "NOTE capsper recording 000 (vtest)") != null);
    try testing.expect(std.mem.indexOf(u8, vtt, "<v Near>hellohello") != null);
    try testing.expect(std.mem.indexOf(u8, vtt, "00:00:00.000 --> 00:00:00.020") != null);
}
