// src/platform/linux/lid.zig — noticing the lid being shut.
//
// Shutting the laptop is a way of saying stop, and the room recording is the
// one mode that would not otherwise hear it: the keep-awake lock does not
// hold the lid, so the machine sleeps, wakes, and carries on recording as if
// nothing happened. With an external display attached it does not even
// sleep, and records the inside of a closed laptop until the limit runs out.
//
// The lid is an evdev switch like any other, so it is read the way the
// keyboards are, with one difference that matters: it is never grabbed.
// logind reads the same device to decide whether to suspend, and a grab would
// take that away from it.
//
// Finding it reads sysfs only. Opening every event node to ask what it is
// costs an RCU grace period per close, and sysfs already says which one
// carries `SW_LID`.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.lid);

const EV_SW: u16 = 0x05;
const SW_LID: u16 = 0x00;

/// `struct input_event` on 64-bit Linux, as `input.zig` has it. Declared here
/// rather than imported so this file needs no C headers to test.
const Event = extern struct {
    tv_sec: isize,
    tv_usec: isize,
    type: u16,
    code: u16,
    value: i32,

    comptime {
        std.debug.assert(@sizeOf(Event) == 24);
    }
};

pub const Lid = struct {
    fd: posix.fd_t,

    /// Open the lid switch, or null when there is none to open -- a desktop,
    /// or a machine that does not report one. Either way the recording goes
    /// on without it, so this says why and carries on rather than failing.
    ///
    /// Only what happens after the open is ever read, so a lid shut before
    /// the session started -- a laptop docked and closed -- does not end it.
    pub fn open() ?Lid {
        var sys = std.fs.cwd().openDir("/sys/class/input", .{ .iterate = true }) catch |err| {
            log.warn("could not look for a lid switch: {}", .{err});
            return null;
        };
        defer sys.close();

        var path_buf: [64]u8 = undefined;
        const path = find(sys, &path_buf) orelse {
            log.info("no lid switch, so closing the lid will not stop the recording", .{});
            return null;
        };

        const fd = posix.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |err| {
            log.warn("could not open the lid switch {s}, so closing the lid will not stop the recording: {}", .{ path, err });
            return null;
        };
        return .{ .fd = fd };
    }

    pub fn close(self: *Lid) void {
        posix.close(self.fd);
    }

    /// Read everything waiting. True when the lid was shut in it.
    pub fn shut(self: *Lid) bool {
        var buf: [16]Event = undefined;
        var seen = false;
        while (true) {
            const n = posix.read(self.fd, std.mem.sliceAsBytes(&buf)) catch return seen;
            if (n == 0) return seen;
            if (shutIn(buf[0 .. n / @sizeOf(Event)])) seen = true;
        }
    }
};

/// Whether any of `events` is the lid shutting. Opening it says nothing: the
/// session it would have stopped is already gone.
fn shutIn(events: []const Event) bool {
    for (events) |e| {
        if (e.type == EV_SW and e.code == SW_LID and e.value == 1) return true;
    }
    return false;
}

/// The device node of the first input device whose switches include the lid,
/// written into `buf`. `sys` is `/sys/class/input`.
fn find(sys: std.fs.Dir, buf: []u8) ?[]const u8 {
    var it = sys.iterate();
    while (it.next() catch return null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "event")) continue;

        var caps_path: [96]u8 = undefined;
        const caps_name = std.fmt.bufPrint(&caps_path, "{s}/device/capabilities/sw", .{entry.name}) catch continue;
        var caps_buf: [256]u8 = undefined;
        const caps = sys.readFile(caps_name, &caps_buf) catch continue;
        if (!hasLid(caps)) continue;

        return std.fmt.bufPrint(buf, "/dev/input/{s}", .{entry.name}) catch null;
    }
    return null;
}

/// Whether a sysfs switch bitmap has `SW_LID`. The bitmap is hex words,
/// most significant first, so the lid is the lowest bit of the last word.
fn hasLid(caps: []const u8) bool {
    const trimmed = std.mem.trim(u8, caps, " \n");
    const last = trimmed[(std.mem.lastIndexOfScalar(u8, trimmed, ' ') orelse return parseLowBit(trimmed)) + 1 ..];
    return parseLowBit(last);
}

fn parseLowBit(word: []const u8) bool {
    const bits = std.fmt.parseInt(u64, word, 16) catch return false;
    return bits & (@as(u64, 1) << SW_LID) != 0;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn sw(code: u16, value: i32) Event {
    return .{ .tv_sec = 0, .tv_usec = 0, .type = EV_SW, .code = code, .value = value };
}

test "the lid shutting is what stops, and nothing else" {
    const syn: Event = .{ .tv_sec = 0, .tv_usec = 0, .type = 0, .code = 0, .value = 0 };
    try testing.expect(shutIn(&.{ sw(SW_LID, 1), syn }));
    try testing.expect(!shutIn(&.{ sw(SW_LID, 0), syn }));
    // A headphone jack is a switch too, and must not end the recording.
    try testing.expect(!shutIn(&.{ sw(0x02, 1), syn }));
    try testing.expect(!shutIn(&.{}));
}

test "the lid bit is read from the last word of the bitmap" {
    // As this Blade reports them: the lid, a mic jack, HDMI audio.
    try testing.expect(hasLid("1\n"));
    try testing.expect(!hasLid("10\n"));
    try testing.expect(!hasLid("140\n"));
    try testing.expect(hasLid("0 1\n"));
    try testing.expect(!hasLid("1 0\n"));
    try testing.expect(!hasLid("0\n"));
    try testing.expect(!hasLid(""));
}

test "the lid is found among the other switches" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    for ([_]struct { []const u8, []const u8 }{
        .{ "event13", "140\n" },
        .{ "event6", "1\n" },
        .{ "event20", "4\n" },
        .{ "mouse0", "1\n" },
    }) |dev| {
        var dir_buf: [64]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "{s}/device/capabilities", .{dev[0]});
        try tmp.dir.makePath(dir);
        var sub = try tmp.dir.openDir(dir, .{});
        defer sub.close();
        try sub.writeFile(.{ .sub_path = "sw", .data = dev[1] });
    }

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/dev/input/event6", find(tmp.dir, &buf).?);
}

test "no lid is no lid" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("event3/device/capabilities");
    var buf: [64]u8 = undefined;
    try testing.expect(find(tmp.dir, &buf) == null);
}
