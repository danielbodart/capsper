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

/// Run until the process is killed. Returns only on a failure that makes
/// carrying on pointless.
pub fn run(gpa: std.mem.Allocator, cfg: *const config.Config, audio_channel: u32) !void {
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
                session = Session.open(gpa, cfg, audio_channel) catch |err| blk: {
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

const Session = struct {
    near: AudioCapture,
    far: AudioCapture,
    mixer: meeting.TrackMixer,
    file: SessionFile,
    pending: std.ArrayListUnmanaged(u8) = .{},
    read_buf: [8192]u8 = undefined,

    fn open(gpa: std.mem.Allocator, cfg: *const config.Config, audio_channel: u32) !Session {
        var path_buf: [64]u8 = undefined;
        const rel = try meeting.sessionPath(&path_buf, std.time.timestamp());

        var file = try SessionFile.create(cfg.meeting.dir, rel);
        errdefer file.finish();

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
        _ = gpa;
        return .{ .near = near, .far = far, .mixer = .{}, .file = file };
    }

    /// Read whatever both captures have ready and write the stereo frames that
    /// result. Blocks for at most one poll interval, so the caller's loop
    /// keeps ticking even while a track is silent.
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
        try self.mixer.push(gpa, track, self.read_buf[0..n]);
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
        self.mixer.deinit(gpa);
        self.pending.deinit(gpa);

        const seconds = self.file.durationSeconds();
        self.file.finish();
        std.debug.print("[meeting] session closed ({d:.1}s of audio)\n", .{seconds});
    }
};
