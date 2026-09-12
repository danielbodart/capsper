// src/shared/meeting.zig — when a meeting session is open, and when it closes.
//
// Gate 1 of the meeting capture plan. The platform reports one number: how
// many applications are currently playing into capsper's sink. This turns
// that number into a session, and it is pure -- no PipeWire, no clock, no
// files -- so the debounce can be tested in microseconds rather than minutes.
//
// The interesting part is the debounce, and it is asymmetric on purpose.
// Opening is immediate: audio is already arriving by the time the graph says
// so, and a late start loses the beginning of a meeting. Closing waits, because
// the graph goes quiet for reasons that are not the end of a call -- a mute, a
// screen-share renegotiation, a browser tab reloading its audio element. Those
// gaps are seconds; the wait is tens of seconds, so they are bridged rather
// than cutting one meeting into several files.

const std = @import("std");

pub const Transition = enum {
    /// Nothing changed on this update.
    none,
    /// A session just started; the caller should open one.
    opened,
    /// The idle window elapsed with nothing playing; the caller should close.
    closed,
};

pub const ArmGate = struct {
    /// How long the sink may sit unused before the session closes. Comes from
    /// `meeting.idle_close_seconds`.
    idle_close_ns: u64,

    open: bool = false,
    /// When the stream count last fell to zero, while a session is open.
    /// Null means either no session, or a session that is still busy.
    idle_since_ns: ?u64 = null,

    pub fn init(idle_close_seconds: u32) ArmGate {
        return .{ .idle_close_ns = @as(u64, idle_close_seconds) * std.time.ns_per_s };
    }

    /// Feed the current stream count and a monotonic timestamp. Call it on
    /// every poll, not only on change: closing is a function of elapsed time,
    /// so it can only be noticed by asking.
    pub fn update(self: *ArmGate, active_streams: u32, now_ns: u64) Transition {
        if (active_streams > 0) {
            // Any activity cancels a pending close, whether or not a session
            // is already open.
            self.idle_since_ns = null;
            if (!self.open) {
                self.open = true;
                return .opened;
            }
            return .none;
        }

        if (!self.open) return .none;

        const since = self.idle_since_ns orelse {
            self.idle_since_ns = now_ns;
            return .none;
        };

        // Saturating, so a clock that goes backwards delays the close rather
        // than triggering one.
        if (now_ns -| since >= self.idle_close_ns) {
            self.open = false;
            self.idle_since_ns = null;
            return .closed;
        }
        return .none;
    }

    /// Close an open session regardless of the debounce, for shutdown: a
    /// session interrupted by capsper exiting still has to be written out.
    pub fn finish(self: *ArmGate) Transition {
        if (!self.open) return .none;
        self.open = false;
        self.idle_since_ns = null;
        return .closed;
    }
};

// ─── Interleaving the two tracks ─────────────────────────────────────────────

pub const Track = enum {
    /// The microphone: everyone in the room. Left channel.
    near,
    /// What arrives from the call, captured from the sink's monitor. Right.
    far,
};

/// Interleaves two independently-arriving mono tracks into one stereo stream,
/// near on the left and far on the right.
///
/// One stereo file rather than two mono files, because channel separation is
/// lossless separation -- ffmpeg splits it back apart in one invocation -- and
/// what is gained is a single timeline. Two files have two, and if one capture
/// starts a few tens of milliseconds after the other, or takes a dropout, they
/// desync and neither file records that it happened.
///
/// Keeping that promise is this type's whole job, and it is not free. The two
/// tracks are separate PipeWire streams on separate pipes, and they stall
/// independently: the far end produces nothing at all while the sink is
/// suspended, which is most of a meeting where the near end is doing the
/// talking. Emitting only what both tracks have would let a stalled track back
/// the other one up without limit and, worse, silently shift everything after
/// the stall. So a track that falls further behind than `max_skew_bytes` is
/// padded with silence to catch up: the file keeps real time, and the cost of
/// a stall is a little silence in the right place rather than a drift in every
/// timestamp that follows.
pub const TrackMixer = struct {
    near: std.ArrayListUnmanaged(u8) = .{},
    far: std.ArrayListUnmanaged(u8) = .{},

    /// How far ahead one track may get before the other is padded. One second
    /// of 16 kHz 16-bit mono, which is far more than PipeWire's own jitter and
    /// far less than anyone would notice as a gap.
    max_skew_bytes: usize = 32_000,

    pub fn deinit(self: *TrackMixer, gpa: std.mem.Allocator) void {
        self.near.deinit(gpa);
        self.far.deinit(gpa);
    }

    pub fn push(self: *TrackMixer, gpa: std.mem.Allocator, track: Track, bytes: []const u8) !void {
        const buf = switch (track) {
            .near => &self.near,
            .far => &self.far,
        };
        try buf.appendSlice(gpa, bytes);
    }

    /// Append every stereo frame both tracks can now supply, padding a badly
    /// lagging track first. Consumes what it emits, so the buffers hold only
    /// the part that has no partner yet.
    pub fn drain(self: *TrackMixer, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        try self.padLaggard(gpa);

        // Whole samples only: half an s16 sample is not a sample, and a split
        // one would swap the channels for the rest of the file.
        const paired = @min(self.near.items.len, self.far.items.len) & ~@as(usize, 1);
        if (paired == 0) return;

        try out.ensureUnusedCapacity(gpa, paired * 2);
        var i: usize = 0;
        while (i < paired) : (i += 2) {
            out.appendSliceAssumeCapacity(self.near.items[i..][0..2]);
            out.appendSliceAssumeCapacity(self.far.items[i..][0..2]);
        }

        consume(&self.near, paired);
        consume(&self.far, paired);
    }

    fn padLaggard(self: *TrackMixer, gpa: std.mem.Allocator) !void {
        const near_len = self.near.items.len;
        const far_len = self.far.items.len;
        // Saturating, so a caller is free to pass a skew of maxInt to mean
        // "never pad" without the comparison wrapping.
        if (near_len > far_len +| self.max_skew_bytes) {
            try self.far.appendNTimes(gpa, 0, near_len - far_len - self.max_skew_bytes);
        } else if (far_len > near_len +| self.max_skew_bytes) {
            try self.near.appendNTimes(gpa, 0, far_len - near_len - self.max_skew_bytes);
        }
    }

    /// Pad both tracks out to equal length and emit the remainder, for closing
    /// a session: whatever arrived last still belongs in the file.
    pub fn flush(self: *TrackMixer, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        const longest = @max(self.near.items.len, self.far.items.len);
        try self.near.appendNTimes(gpa, 0, longest - self.near.items.len);
        try self.far.appendNTimes(gpa, 0, longest - self.far.items.len);
        // Now equal length, so `drain`'s padding step has nothing to do and
        // the whole remainder pairs up.
        try self.drain(gpa, out);
    }

    fn consume(buf: *std.ArrayListUnmanaged(u8), n: usize) void {
        const rest = buf.items.len - n;
        std.mem.copyForwards(u8, buf.items[0..rest], buf.items[n..]);
        buf.shrinkRetainingCapacity(rest);
    }
};

// ─── Session directories ─────────────────────────────────────────────────────

/// The path of one session's directory relative to the sessions root, as
/// `YYYY/MM/DD/THHMMSSZ`.
///
/// Date-nested because a year of meetings is a lot of entries in one place,
/// and `YYYY/MM/DD` is what every photo and log tool converged on. The leaf is
/// ISO 8601 basic format with its designators -- `T` marking a time, `Z` the
/// zone -- so the whole path reads as one ISO timestamp split across
/// directories and sorts correctly at every level.
///
/// Basic format rather than extended (`T143000Z`, not `T14:30:00Z`) for
/// portability, not legality. Linux takes a colon in a filename happily, but
/// Windows reserves it outright, Finder still renders it as a slash, and on
/// Unix generally it is the path-list separator -- so `scp` and `rsync` read
/// `host:path` and take the leading component for a remote host.
///
/// Times are UTC, which is what makes the `Z` honest. The tradeoff: a meeting
/// at half past midnight BST files under the previous day. The alternative,
/// local time, puts it where you would look for it but introduces an hour that
/// happens twice a year.
pub fn sessionPath(buf: []u8, unix_seconds: i64) ![]u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix_seconds) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}/{d:0>2}/{d:0>2}/T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const second = std.time.ns_per_s;

test "a stream arriving opens a session immediately" {
    var gate = ArmGate.init(30);
    try testing.expectEqual(Transition.opened, gate.update(1, 0));
    try testing.expect(gate.open);
}

test "more streams arriving does not open a second session" {
    var gate = ArmGate.init(30);
    _ = gate.update(1, 0);
    try testing.expectEqual(Transition.none, gate.update(2, second));
    try testing.expectEqual(Transition.none, gate.update(1, 2 * second));
}

test "nothing playing does not open a session" {
    var gate = ArmGate.init(30);
    try testing.expectEqual(Transition.none, gate.update(0, 0));
    try testing.expectEqual(Transition.none, gate.update(0, 1000 * second));
    try testing.expect(!gate.open);
}

test "a session closes only after the idle window has fully elapsed" {
    var gate = ArmGate.init(30);
    _ = gate.update(1, 0);

    try testing.expectEqual(Transition.none, gate.update(0, 10 * second));
    try testing.expectEqual(Transition.none, gate.update(0, 39 * second));
    try testing.expectEqual(Transition.closed, gate.update(0, 40 * second));
    try testing.expect(!gate.open);
}

test "the window is measured from when the sink went quiet, not from the open" {
    var gate = ArmGate.init(30);
    _ = gate.update(1, 0);
    // Busy for a while, so a window measured from the open would have expired.
    _ = gate.update(1, 100 * second);

    try testing.expectEqual(Transition.none, gate.update(0, 101 * second));
    try testing.expectEqual(Transition.none, gate.update(0, 130 * second));
    try testing.expectEqual(Transition.closed, gate.update(0, 131 * second));
}

test "a brief mute does not split a meeting in two" {
    var gate = ArmGate.init(30);
    _ = gate.update(1, 0);

    // Muted for ten seconds, well inside the window.
    try testing.expectEqual(Transition.none, gate.update(0, 5 * second));
    try testing.expectEqual(Transition.none, gate.update(0, 15 * second));
    // Audio comes back: same session, no transition either way.
    try testing.expectEqual(Transition.none, gate.update(1, 16 * second));
    try testing.expect(gate.open);

    // And the window starts again from here, not from the earlier mute.
    try testing.expectEqual(Transition.none, gate.update(0, 20 * second));
    try testing.expectEqual(Transition.none, gate.update(0, 49 * second));
    try testing.expectEqual(Transition.closed, gate.update(0, 51 * second));
}

test "the window runs from the first poll that saw silence" {
    // Not from the last poll that saw activity. The difference is one poll
    // interval out of tens of seconds, and counting from an observation keeps
    // the gate honest about what it actually knows.
    var gate = ArmGate.init(30);
    _ = gate.update(1, 0);

    try testing.expectEqual(Transition.none, gate.update(0, 31 * second));
    try testing.expectEqual(Transition.none, gate.update(0, 60 * second));
    try testing.expectEqual(Transition.closed, gate.update(0, 61 * second));
}

test "a closed session reopens when something plays again" {
    var gate = ArmGate.init(30);
    _ = gate.update(1, 0);
    _ = gate.update(0, second);
    try testing.expectEqual(Transition.closed, gate.update(0, 32 * second));
    try testing.expectEqual(Transition.opened, gate.update(1, 33 * second));
}

test "a zero window closes on the first quiet poll" {
    var gate = ArmGate.init(0);
    _ = gate.update(1, 0);
    // The first quiet update records the time; the next one sees zero elapsed
    // against a zero window and closes.
    try testing.expectEqual(Transition.none, gate.update(0, second));
    try testing.expectEqual(Transition.closed, gate.update(0, second));
}

test "a clock that goes backwards delays the close rather than causing one" {
    var gate = ArmGate.init(30);
    _ = gate.update(1, 100 * second);
    try testing.expectEqual(Transition.none, gate.update(0, 100 * second));
    try testing.expectEqual(Transition.none, gate.update(0, 50 * second));
    try testing.expect(gate.open);
}

test "finish closes an open session and is a no-op otherwise" {
    var gate = ArmGate.init(30);
    try testing.expectEqual(Transition.none, gate.finish());

    _ = gate.update(1, 0);
    try testing.expectEqual(Transition.closed, gate.finish());
    try testing.expectEqual(Transition.none, gate.finish());
}

// ─── TrackMixer ──────────────────────────────────────────────────────────────

/// `n` samples of a constant value, as the s16 little-endian bytes a capture
/// stream would deliver.
fn samples(comptime n: usize, value: u8) [n * 2]u8 {
    var out: [n * 2]u8 = undefined;
    for (0..n) |i| {
        out[i * 2] = value;
        out[i * 2 + 1] = 0;
    }
    return out;
}

fn drained(mixer: *TrackMixer) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    try mixer.drain(testing.allocator, &out);
    return out.toOwnedSlice(testing.allocator);
}

test "interleaves near left and far right" {
    var mixer = TrackMixer{};
    defer mixer.deinit(testing.allocator);

    try mixer.push(testing.allocator, .near, &samples(2, 0x11));
    try mixer.push(testing.allocator, .far, &samples(2, 0x22));

    const out = try drained(&mixer);
    defer testing.allocator.free(out);

    // One stereo frame is a near sample then a far sample.
    try testing.expectEqualSlices(u8, &.{
        0x11, 0x00, 0x22, 0x00,
        0x11, 0x00, 0x22, 0x00,
    }, out);
}

test "emits only what both tracks can pair, and keeps the rest" {
    var mixer = TrackMixer{};
    defer mixer.deinit(testing.allocator);

    try mixer.push(testing.allocator, .near, &samples(3, 0x11));
    try mixer.push(testing.allocator, .far, &samples(1, 0x22));

    const out = try drained(&mixer);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 4), out.len); // one stereo frame
    // The two unpaired near samples are still waiting for a partner.
    try testing.expectEqual(@as(usize, 4), mixer.near.items.len);
    try testing.expectEqual(@as(usize, 0), mixer.far.items.len);
}

test "a later push pairs with what was left over" {
    var mixer = TrackMixer{};
    defer mixer.deinit(testing.allocator);

    try mixer.push(testing.allocator, .near, &samples(2, 0x11));
    const before_far = try drained(&mixer);
    defer testing.allocator.free(before_far);
    try testing.expectEqual(@as(usize, 0), before_far.len);

    try mixer.push(testing.allocator, .far, &samples(2, 0x22));
    const after_far = try drained(&mixer);
    defer testing.allocator.free(after_far);
    try testing.expectEqual(@as(usize, 8), after_far.len);
}

test "a stalled track is padded with silence rather than stalling the file" {
    // The far end produces nothing while the sink is suspended, which is most
    // of a meeting where the near end is talking.
    var mixer = TrackMixer{ .max_skew_bytes = 8 };
    defer mixer.deinit(testing.allocator);

    try mixer.push(testing.allocator, .near, &samples(10, 0x11));
    const out = try drained(&mixer);
    defer testing.allocator.free(out);

    // 20 bytes of near, 8 allowed to run ahead, so 12 bytes get paired with
    // silence: six stereo frames.
    try testing.expectEqual(@as(usize, 24), out.len);
    for (0..6) |f| {
        try testing.expectEqual(@as(u8, 0x11), out[f * 4]);
        try testing.expectEqual(@as(u8, 0x00), out[f * 4 + 2]);
    }
    // The most recent second is still held, in case the far end catches up.
    try testing.expectEqual(@as(usize, 8), mixer.near.items.len);
}

test "padding keeps real time, so audio after a stall lands where it happened" {
    var mixer = TrackMixer{ .max_skew_bytes = 0 };
    defer mixer.deinit(testing.allocator);

    // Near runs alone for a while, then the far end starts.
    try mixer.push(testing.allocator, .near, &samples(4, 0x11));
    const stalled = try drained(&mixer);
    defer testing.allocator.free(stalled);
    try testing.expectEqual(@as(usize, 16), stalled.len);

    try mixer.push(testing.allocator, .near, &samples(2, 0x11));
    try mixer.push(testing.allocator, .far, &samples(2, 0x22));
    const after = try drained(&mixer);
    defer testing.allocator.free(after);

    // The far samples land at frame 4, where they arrived -- not at frame 0,
    // which is what holding them back would have done.
    try testing.expectEqual(@as(usize, 8), after.len);
    try testing.expectEqual(@as(u8, 0x22), after[2]);
}

test "both tracks stay in step when both are flowing" {
    var mixer = TrackMixer{};
    defer mixer.deinit(testing.allocator);

    var total: usize = 0;
    for (0..50) |_| {
        try mixer.push(testing.allocator, .near, &samples(100, 0x11));
        try mixer.push(testing.allocator, .far, &samples(100, 0x22));
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(testing.allocator);
        try mixer.drain(testing.allocator, &out);
        total += out.items.len;
    }

    // Every sample of both tracks came out, interleaved, with nothing padded.
    try testing.expectEqual(@as(usize, 50 * 100 * 4), total);
    try testing.expectEqual(@as(usize, 0), mixer.near.items.len);
    try testing.expectEqual(@as(usize, 0), mixer.far.items.len);
}

test "an odd byte is held back rather than swapping the channels" {
    var mixer = TrackMixer{};
    defer mixer.deinit(testing.allocator);

    try mixer.push(testing.allocator, .near, &.{ 0x11, 0x00, 0x33 });
    try mixer.push(testing.allocator, .far, &.{ 0x22, 0x00, 0x44 });

    const out = try drained(&mixer);
    defer testing.allocator.free(out);

    try testing.expectEqualSlices(u8, &.{ 0x11, 0x00, 0x22, 0x00 }, out);
    try testing.expectEqual(@as(usize, 1), mixer.near.items.len);
    try testing.expectEqual(@as(usize, 1), mixer.far.items.len);
}

test "flush pads both tracks level and empties them" {
    var mixer = TrackMixer{};
    defer mixer.deinit(testing.allocator);

    try mixer.push(testing.allocator, .near, &samples(3, 0x11));
    try mixer.push(testing.allocator, .far, &samples(1, 0x22));

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try mixer.flush(testing.allocator, &out);

    try testing.expectEqual(@as(usize, 12), out.items.len); // three stereo frames
    try testing.expectEqual(@as(usize, 0), mixer.near.items.len);
    try testing.expectEqual(@as(usize, 0), mixer.far.items.len);
    // The far track ran out after one sample, so frames two and three are
    // silent on the right.
    try testing.expectEqual(@as(u8, 0x22), out.items[2]);
    try testing.expectEqual(@as(u8, 0x00), out.items[6]);
    try testing.expectEqual(@as(u8, 0x00), out.items[10]);
}

test "flush on an empty mixer produces nothing" {
    var mixer = TrackMixer{};
    defer mixer.deinit(testing.allocator);

    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(testing.allocator);
    try mixer.flush(testing.allocator, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "sessionPath is one ISO timestamp split across directories" {
    var buf: [64]u8 = undefined;
    // 2026-09-11T14:30:00Z
    try testing.expectEqualStrings("2026/09/11/T143000Z", try sessionPath(&buf, 1_789_137_000));
}

test "sessionPath pads every field, so paths sort correctly" {
    var buf: [64]u8 = undefined;
    // 1970-01-01T00:00:00Z
    try testing.expectEqualStrings("1970/01/01/T000000Z", try sessionPath(&buf, 0));
    // 2001-02-03T04:05:06Z
    try testing.expectEqualStrings("2001/02/03/T040506Z", try sessionPath(&buf, 981_173_106));
}

test "sessionPath uses UTC, so a late meeting files under the previous day" {
    var buf: [64]u8 = undefined;
    // 2026-09-11T23:30:00Z — half past midnight in BST, still the 11th here.
    try testing.expectEqualStrings("2026/09/11/T233000Z", try sessionPath(&buf, 1_789_169_400));
}

test "sessionPath carries no colons, so the layout survives a Windows port" {
    var buf: [64]u8 = undefined;
    const path = try sessionPath(&buf, 1_789_137_000);
    try testing.expect(std.mem.indexOfScalar(u8, path, ':') == null);
}
