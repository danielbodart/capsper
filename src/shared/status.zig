// src/shared/status.zig — what capsper is doing, for anything that wants to ask.
//
// A running capsper knows a great deal that it currently only says in passing,
// as a log line nobody is watching: which microphone it settled on, how loud
// that is arriving, whether a call is being recorded right now and for how
// long. The console asks all of it on every page load, from a thread that owns
// none of it.
//
// So it is published here, by whichever thread already has the answer, as a
// side effect of work it is doing anyway. Nothing in this file asks anything of
// anyone; the capture paths write, the console reads, and neither knows the
// other exists.
//
// Plain atomics rather than one lock around a status struct, because the fields
// are written at wildly different rates by unrelated threads and nothing ever
// needs two of them to agree. A level lands on every audio chunk and is one
// instruction here; a session opens twice a day. The only pair whose order
// matters is a session's flag and the details behind it, and that one says so
// where it is written.
//
// Everything here is therefore a snapshot that may be a chunk out of date,
// which is the right currency for a page someone is reading.

const std = @import("std");

/// A name short enough to keep in the struct, written rarely and read often.
///
/// A mutex rather than an atomic scheme, because these are variable length and
/// change a handful of times an hour -- a device swap, a call starting. The
/// lock is never contended in practice and is far easier to be sure of than a
/// hand-rolled length-then-bytes dance.
fn ShortString(comptime cap: usize) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        buf: [cap]u8 = undefined,
        len: usize = 0,

        /// Truncates rather than failing. This is a label on a status page; a
        /// node name past the cap is still more useful cut short than absent.
        pub fn set(self: *Self, value: []const u8) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const n = @min(value.len, cap);
            @memcpy(self.buf[0..n], value[0..n]);
            self.len = n;
        }

        /// Copies into the caller's buffer, so the value cannot change under a
        /// reader that is still formatting it.
        pub fn get(self: *Self, out: []u8) []const u8 {
            self.mutex.lock();
            defer self.mutex.unlock();
            const n = @min(self.len, out.len);
            @memcpy(out[0..n], self.buf[0..n]);
            return out[0..n];
        }

        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len == 0;
        }
    };
}

/// Floats have no atomic type, so they travel as their bits. The cast is exact
/// in both directions and costs nothing.
pub const AtomicF32 = struct {
    bits: std.atomic.Value(u32),

    pub fn init(v: f32) AtomicF32 {
        return .{ .bits = .init(@bitCast(v)) };
    }
    pub fn store(self: *AtomicF32, v: f32) void {
        self.bits.store(@bitCast(v), .monotonic);
    }
    pub fn load(self: *const AtomicF32) f32 {
        return @bitCast(self.bits.load(.monotonic));
    }
};

/// One microphone: which one, how loud it is arriving, and what capsper has
/// decided to open it to.
pub const Input = struct {
    /// The node the level is being set on, once one has been found.
    device: ShortString(128) = .{},
    /// Signal level of the last chunk. The quiet floor rather than zero, so a
    /// page loaded before any audio shows silence rather than a reading.
    level_db: AtomicF32 = AtomicF32.init(-100.0),
    /// The multiplier in force, which auto-gain moves as it learns the voice.
    gain: AtomicF32 = AtomicF32.init(1.0),
    /// Whether anything has ever reported a level, so the console can say
    /// "nothing yet" rather than showing a floor as though it were measured.
    heard: std.atomic.Value(bool) = .init(false),

    pub fn reportDevice(self: *Input, name: []const u8) void {
        self.device.set(name);
    }

    pub fn reportLevel(self: *Input, db: f32) void {
        self.level_db.store(db);
        self.heard.store(true, .monotonic);
    }

    pub fn reportGain(self: *Input, gain: f32) void {
        self.gain.store(gain);
    }
};

/// The microphone dictation is listening to.
pub var dictation: Input = .{};
/// The microphone the meeting's near track is listening to. Separate because
/// they can genuinely be two different devices.
pub var meeting_near: Input = .{};

/// Whether the trigger is held right now, or capture is otherwise open.
pub var live: std.atomic.Value(bool) = .init(false);

/// How many remote dictation clients are connected to the TCP server.
pub var tcp_clients: std.atomic.Value(u32) = .init(0);

/// Whether the virtual sink made it into the graph.
pub var sink_up: std.atomic.Value(bool) = .init(false);

/// When the process started, for an uptime that does not need a second clock.
pub var started_at_ns: std.atomic.Value(i64) = .init(0);

/// Set when capsper is about to leave on purpose -- saving settings is the
/// only thing that sets it -- so a capture loop can finish what it is doing
/// first.
///
/// A flag rather than a signal or a join, because the only loop that needs to
/// know already wakes several times a second and the process exits either way.
/// What it buys is that a call being recorded when someone presses Save is a
/// complete file afterwards rather than one that stops mid-word.
pub var stop_requested: std.atomic.Value(bool) = .init(false);

/// A meeting being recorded, if one is.
pub const Meeting = struct {
    open: std.atomic.Value(bool) = .init(false),
    opened_at_ns: std.atomic.Value(i64) = .init(0),
    /// The session's path under the sessions root, so the console can link to
    /// the recording that is still being written.
    path: ShortString(64) = .{},

    /// The flag goes last, so a reader that sees `open` can trust everything
    /// behind it. This is the one ordering in this file that is load bearing:
    /// a session reported open with a zero start time renders as a call that
    /// has been running since 1970.
    pub fn opened(self: *Meeting, rel_path: []const u8, now_ns: i64) void {
        self.path.set(rel_path);
        self.opened_at_ns.store(now_ns, .monotonic);
        self.open.store(true, .release);
    }

    pub fn closed(self: *Meeting) void {
        self.open.store(false, .release);
    }

    /// How long the current session has been running, or null if none is.
    pub fn runningFor(self: *Meeting, now_ns: i64) ?f64 {
        if (!self.open.load(.acquire)) return null;
        const since = self.opened_at_ns.load(.monotonic);
        if (since == 0) return null;
        return @as(f64, @floatFromInt(now_ns - since)) / std.time.ns_per_s;
    }
};

pub var meeting: Meeting = .{};

/// Seconds since the process started, or null before anything set the clock.
pub fn uptimeSeconds(now_ns: i64) ?f64 {
    const since = started_at_ns.load(.monotonic);
    if (since == 0) return null;
    return @as(f64, @floatFromInt(now_ns - since)) / std.time.ns_per_s;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a name comes back as it went in" {
    var s: ShortString(16) = .{};
    try testing.expect(s.isEmpty());

    s.set("vocaster_hostmic");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("vocaster_hostmic", s.get(&buf));
    try testing.expect(!s.isEmpty());
}

test "a name past the cap is cut short rather than lost" {
    var s: ShortString(8) = .{};
    s.set("alsa_input.pci-0000_00_1f.3");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("alsa_inp", s.get(&buf));
}

test "a later name replaces the one before it" {
    var s: ShortString(32) = .{};
    s.set("a_long_device_name");
    s.set("short");
    var buf: [64]u8 = undefined;
    // Not "shortg_device_name": the length moves with the value.
    try testing.expectEqualStrings("short", s.get(&buf));
}

test "levels and gains survive the trip through their bits" {
    var in: Input = .{};
    try testing.expect(!in.heard.load(.monotonic));
    try testing.expectEqual(@as(f32, 1.0), in.gain.load());

    in.reportLevel(-23.5);
    in.reportGain(2.25);
    try testing.expectEqual(@as(f32, -23.5), in.level_db.load());
    try testing.expectEqual(@as(f32, 2.25), in.gain.load());
    try testing.expect(in.heard.load(.monotonic));
}

test "a meeting reports how long it has been running, and nothing when closed" {
    var m: Meeting = .{};
    try testing.expectEqual(@as(?f64, null), m.runningFor(1_000_000_000));

    m.opened("2026/09/13/T091500Z", 1_000_000_000);
    const running = m.runningFor(4_000_000_000).?;
    try testing.expectApproxEqAbs(@as(f64, 3.0), running, 0.001);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("2026/09/13/T091500Z", m.path.get(&buf));

    m.closed();
    try testing.expectEqual(@as(?f64, null), m.runningFor(4_000_000_000));
}

test "uptime is nothing until the clock is set" {
    started_at_ns.store(0, .monotonic);
    try testing.expectEqual(@as(?f64, null), uptimeSeconds(5_000_000_000));

    started_at_ns.store(1_000_000_000, .monotonic);
    try testing.expectApproxEqAbs(@as(f64, 4.0), uptimeSeconds(5_000_000_000).?, 0.001);
    started_at_ns.store(0, .monotonic);
}
