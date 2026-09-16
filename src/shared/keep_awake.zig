// src/shared/keep_awake.zig — holding the machine awake while something is recorded.
//
// Nothing here knows how to stop a machine sleeping. Every platform already
// has a command for that -- `systemd-inhibit` on Linux, `caffeinate` on macOS
// -- and linking the thing behind either would buy a D-Bus client or IOKit
// for one lock. So the lock is a command, run for the life of a session: it
// starts when the session opens, and when it stops the lock goes with it.
//
// A lock is held, not fired, which is why this is one long-running command
// rather than a pair of hooks. A start script and a stop script would have to
// hand a process between them, and a capsper that crashed in the middle would
// leave the machine unable to sleep ever again.
//
// Two things end the command. Closing the session closes its standard input
// and terminates its process group. A capsper that dies without closing
// anything still closes that pipe, because the kernel does, so a command that
// reads its input to the end -- both defaults do, through `cat` -- lets go on
// its own rather than outliving the process that started it.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.keep_awake);

/// How long a command is given to leave after being asked, before it is
/// told. Both defaults leave at once; this is for a hand-written one that
/// ignores SIGTERM, which would otherwise hang the session's close forever.
const term_grace_ms: u64 = 1000;

pub const Hold = struct {
    child: std.process.Child,
    /// Set once the command has been reaped, so it is never reaped twice.
    exited: bool = false,

    /// Run `command` through `/bin/sh`, in a process group of its own so the
    /// whole of it can be ended at once -- `systemd-inhibit` runs its command
    /// as a child, and a lock is only released when both are gone.
    pub fn start(gpa: std.mem.Allocator, command: []const u8) !Hold {
        var child = std.process.Child.init(&.{ "/bin/sh", "-c", command }, gpa);
        child.stdin_behavior = .Pipe;
        child.pgid = 0;
        try child.spawn();
        log.info("keeping the machine awake: {s}", .{command});
        return .{ .child = child };
    }

    /// Notice a command that has already gone, and say so once.
    ///
    /// Cheap enough to call every pass: a `waitpid` that does not wait. What
    /// it catches is the lock that was never taken -- a command that is not
    /// installed, or one refused -- which otherwise looks exactly like one
    /// that is working until the machine goes to sleep.
    pub fn check(self: *Hold) void {
        if (self.exited) return;
        const res = posix.waitpid(self.child.id, posix.W.NOHANG);
        if (res.pid == 0) return;
        self.exited = true;
        log.warn("the keep-awake command exited ({f}) with the session still open: the machine is free to sleep", .{
            ExitStatus{ .status = res.status },
        });
    }

    /// End the command and wait for it to be gone.
    pub fn stop(self: *Hold) void {
        if (self.child.stdin) |f| f.close();
        self.child.stdin = null;
        if (self.exited) return;

        // The process as well as the group: straight after a spawn the child
        // may not have moved into its group yet, and a kill of a group that
        // does not exist reaches nobody.
        posix.kill(self.child.id, posix.SIG.TERM) catch {};
        posix.kill(-self.child.id, posix.SIG.TERM) catch {};

        var waited_ms: u64 = 0;
        while (waited_ms < term_grace_ms) : (waited_ms += 10) {
            if (posix.waitpid(self.child.id, posix.W.NOHANG).pid != 0) {
                self.exited = true;
                return;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        log.warn("the keep-awake command ignored SIGTERM; killing it", .{});
        posix.kill(-self.child.id, posix.SIG.KILL) catch {};
        posix.kill(self.child.id, posix.SIG.KILL) catch {};
        _ = posix.waitpid(self.child.id, 0);
        self.exited = true;
    }
};

const ExitStatus = struct {
    status: u32,

    pub fn format(self: ExitStatus, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (posix.W.IFEXITED(self.status)) {
            try w.print("status {d}", .{posix.W.EXITSTATUS(self.status)});
        } else if (posix.W.IFSIGNALED(self.status)) {
            try w.print("signal {d}", .{posix.W.TERMSIG(self.status)});
        } else {
            try w.print("wait status {d}", .{self.status});
        }
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Whether `pid` names a live process. A zombie counts as gone: it holds no
/// lock and runs no code, it is only waiting for someone to read its status.
fn alive(pid: posix.pid_t) bool {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch unreachable;
    const stat = std.fs.cwd().readFileAlloc(testing.allocator, path, 4096) catch return false;
    defer testing.allocator.free(stat);
    const state_at = (std.mem.lastIndexOfScalar(u8, stat, ')') orelse return false) + 2;
    return stat[state_at] != 'Z';
}

/// Read the pid a test command wrote, waiting for it to be written.
fn readPid(dir: std.fs.Dir, name: []const u8) !posix.pid_t {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        var buf: [32]u8 = undefined;
        if (dir.readFile(name, &buf)) |text| {
            const trimmed = std.mem.trim(u8, text, " \n");
            if (trimmed.len > 0) return try std.fmt.parseInt(posix.pid_t, trimmed, 10);
        } else |_| {}
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.NeverWritten;
}

fn waitGone(pid: posix.pid_t) bool {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (!alive(pid)) return true;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

test "closing the session ends the command, and whatever it started" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    // A grandchild, the way `systemd-inhibit` runs `cat`: the lock lives as
    // long as either does.
    const command = try std.fmt.allocPrint(testing.allocator, "sleep 30 & echo $! > '{s}/pid'; wait", .{dir_path});
    defer testing.allocator.free(command);

    var hold = try Hold.start(testing.allocator, command);
    const grandchild = try readPid(tmp.dir, "pid");
    hold.check();
    try testing.expect(!hold.exited);
    try testing.expect(alive(grandchild));

    hold.stop();
    try testing.expect(hold.exited);
    try testing.expect(waitGone(grandchild));
}

test "a capsper that dies still lets go, through the pipe" {
    // Only the pipe closes -- no signal -- which is all a crash leaves behind.
    var hold = try Hold.start(testing.allocator, "exec cat");
    hold.check();
    try testing.expect(!hold.exited);

    hold.child.stdin.?.close();
    hold.child.stdin = null;
    const res = posix.waitpid(hold.child.id, 0);
    hold.exited = true;
    try testing.expect(posix.W.IFEXITED(res.status));
    try testing.expectEqual(@as(u32, 0), posix.W.EXITSTATUS(res.status));
}

test "a command that could not take the lock is noticed while the session runs" {
    var hold = try Hold.start(testing.allocator, "exit 3");
    var tries: usize = 0;
    while (!hold.exited and tries < 200) : (tries += 1) {
        hold.check();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expect(hold.exited);
    // Closing after the command has already gone must not wait on it again.
    hold.stop();
}

test "a command that ignores SIGTERM does not hang the close" {
    var hold = try Hold.start(testing.allocator, "trap '' TERM; while :; do sleep 0.05; done");
    std.Thread.sleep(100 * std.time.ns_per_ms);
    hold.stop();
    try testing.expect(hold.exited);
}
