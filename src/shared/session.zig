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

// End-to-end: drive a scripted PTT session and execute the recorder-relevant
// actions against a REAL Recorder in a temp dir. Proves recording actually
// writes a .wav — the thing that has been silently broken — with no keyboard,
// clock, socket, or GPU. `transcribe` actions are no-ops here (no pipeline).
test "scripted PTT session writes a recording" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var rec = try Recorder.init(allocator, dir_path, 10, "test");
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

    loop: while (true) {
        const ev = try src.next();
        const acts = driver.step(ev);
        for (acts.slice()) |a| switch (a) {
            .start_recording => rec.startRecording(),
            .record => |bytes| rec.recordPcm(bytes),
            .end_recording => try rec.endRecording(),
            .reset_segment, .transcribe => {}, // no pipeline in this test
            .stop => break :loop,
        };
        // Before release, nothing should be flushed to disk yet.
        if (ev == .audio) {
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
    _ = try tmp.dir.statFile("000.log"); // sibling diagnostic log
}
