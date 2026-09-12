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
