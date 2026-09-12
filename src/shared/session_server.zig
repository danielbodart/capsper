// src/shared/session_server.zig — browsing and playing back recorded sessions.
//
// Runs whenever meeting capture is on, and serves one page: every session
// listed newest first, and whichever one you pick playing against its
// transcript. Sessions are directories of files and stay that way -- this
// reads them, and writes nothing the recording does not already contain.
//
// It binds to loopback unless told otherwise. These are recordings of private
// conversations, and reaching them from the network should take saying so.

const std = @import("std");
const net = std.net;
const http = std.http;

const utils = @import("utils.zig");

const log = std.log.scoped(.sessions);

/// The page, embedded so a running capsper needs nothing fetched to serve it.
const index_html = @embedFile("player.html");

/// Enough for any request line and headers a browser sends.
const head_buffer_bytes = 16 * 1024;
/// Media is streamed through this rather than read whole: an hour of stereo is
/// 230 MB and nothing is served by holding it in memory.
const body_buffer_bytes = 64 * 1024;

/// The most of a file to send for one range request. Browsers ask for
/// `bytes=0-` on a media element and are perfectly happy to be given a prefix
/// and come back for more, which is what keeps memory flat on a long session.
const max_range_bytes: u64 = 4 * 1024 * 1024;

pub const Options = struct {
    /// The sessions directory, already tilde-expanded.
    root: []const u8,
    port: u16,
    bind: []const u8,
};

/// Start serving in the background. Returns once the socket is listening, so a
/// failure to bind is reported before anything else claims to be ready.
pub fn start(gpa: std.mem.Allocator, opts: Options) !void {
    const address = net.Address.parseIp(opts.bind, opts.port) catch |err| {
        log.err("cannot use bind address '{s}': {}", .{ opts.bind, err });
        return err;
    };

    var listener = address.listen(.{ .reuse_address = true }) catch |err| {
        log.err("cannot listen on {s}:{d}: {}", .{ opts.bind, opts.port, err });
        return err;
    };

    const state = try gpa.create(State);
    state.* = .{
        .gpa = gpa,
        .listener = listener,
        .root = try gpa.dupe(u8, opts.root),
    };

    const thread = std.Thread.spawn(.{}, acceptLoop, .{state}) catch |err| {
        listener.deinit();
        gpa.free(state.root);
        gpa.destroy(state);
        return err;
    };
    thread.detach();

    std.debug.print("Sessions at http://{s}:{d}\n", .{ opts.bind, listener.listen_address.getPort() });
}

const State = struct {
    gpa: std.mem.Allocator,
    listener: net.Server,
    root: []const u8,
};

fn acceptLoop(state: *State) void {
    while (true) {
        const conn = state.listener.accept() catch |err| {
            log.warn("accept failed: {}", .{err});
            continue;
        };
        // One thread each, so streaming an hour of audio does not stop the
        // session list from loading in another tab.
        const thread = std.Thread.spawn(.{}, serve, .{ state, conn }) catch |err| {
            log.warn("cannot handle connection: {}", .{err});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn serve(state: *State, conn: net.Server.Connection) void {
    defer conn.stream.close();

    const gpa = state.gpa;
    const in = gpa.alloc(u8, head_buffer_bytes) catch return;
    defer gpa.free(in);
    const out = gpa.alloc(u8, body_buffer_bytes) catch return;
    defer gpa.free(out);

    var reader = conn.stream.reader(in);
    var writer = conn.stream.writer(out);
    var server = http.Server.init(reader.interface(), &writer.interface);

    while (true) {
        var request = server.receiveHead() catch return;
        route(state, &request) catch |err| {
            // A client that navigated away mid-download is ordinary, not an
            // error worth a line in the log.
            if (err != error.WriteFailed) log.warn("{s}: {}", .{ request.head.target, err });
            return;
        };
        // Only keep the connection when the reader is ready for another
        // request; anything else means this one is finished with.
        if (server.reader.state != .ready) return;
    }
}

fn route(state: *State, request: *http.Server.Request) !void {
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        return request.respond(index_html, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/sessions.json")) return sessionsJson(state, request);

    if (std.mem.startsWith(u8, path, "/s/")) return sessionFile(state, request, path[3..]);

    return request.respond("not found\n", .{ .status = .not_found });
}

// ─── The session list ────────────────────────────────────────────────────────

const Session = struct {
    /// Relative to the sessions root, e.g. `2026/09/12/T063554Z`.
    path: []const u8,
    audio: []const u8,
    seconds: f64,
};

fn sessionsJson(state: *State, request: *http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sessions = collect(arena, state.root) catch |err| {
        log.warn("cannot read sessions from '{s}': {}", .{ state.root, err });
        return request.respond("[]", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };

    var body: std.ArrayListUnmanaged(u8) = .{};
    const w = body.writer(arena);

    try w.writeByte('[');
    for (sessions, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        // The fields are all machine-generated: a path this walk produced and
        // a number. No escaping needed, and none pretended.
        try w.print(
            "{{\"path\":\"{s}\",\"audio\":\"{s}\",\"seconds\":{d:.2}}}",
            .{ s.path, s.audio, s.seconds },
        );
    }
    try w.writeByte(']');

    return request.respond(body.items, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

/// Every session under the root, newest first.
///
/// Found by walking for the audio file rather than by parsing directory names,
/// so a session is whatever actually has a recording in it. The dated layout
/// means sorting the paths descending is already newest-first, which is one of
/// the reasons the leaf is an ISO timestamp.
fn collect(arena: std.mem.Allocator, root: []const u8) ![]Session {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var found: std.ArrayListUnmanaged(Session) = .{};

    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.basename, "audio.")) continue;
        if (std.mem.endsWith(u8, entry.basename, ".vtt")) continue;

        const parent = std.fs.path.dirname(entry.path) orelse continue;

        try found.append(arena, .{
            .path = try arena.dupe(u8, parent),
            .audio = try arena.dupe(u8, entry.basename),
            .seconds = durationSeconds(dir, entry.path),
        });
    }

    const sessions = try found.toOwnedSlice(arena);
    std.mem.sort(Session, sessions, {}, struct {
        fn newestFirst(_: void, a: Session, b: Session) bool {
            return std.mem.order(u8, a.path, b.path) == .gt;
        }
    }.newestFirst);
    return sessions;
}

/// Length from the WAV header, or zero for anything that is not one. Only ever
/// used to label a row in the list, so an unknown length costs nothing.
fn durationSeconds(dir: std.fs.Dir, path: []const u8) f64 {
    var file = dir.openFile(path, .{}) catch return 0;
    defer file.close();

    // Generously more than the 44 bytes capsper writes: a WAV from anything
    // else may carry LIST or fact chunks before the data chunk, and the header
    // parser has to reach the data chunk to find its size.
    var header: [4096]u8 = undefined;
    const n = file.readAll(&header) catch return 0;

    const parsed = utils.parseWavHeader(header[0..n]) catch return 0;
    const bytes_per_second: f64 = @floatFromInt(16000 * 2 * @as(u32, parsed.channels));
    if (bytes_per_second == 0) return 0;
    return @as(f64, @floatFromInt(parsed.data_size)) / bytes_per_second;
}

// ─── Session files ───────────────────────────────────────────────────────────

fn sessionFile(state: *State, request: *http.Server.Request, rel: []const u8) !void {
    if (!isSafe(rel)) return request.respond("no\n", .{ .status = .forbidden });

    var dir = std.fs.cwd().openDir(state.root, .{}) catch
        return request.respond("not found\n", .{ .status = .not_found });
    defer dir.close();

    var file = dir.openFile(rel, .{}) catch
        return request.respond("not found\n", .{ .status = .not_found });
    defer file.close();

    const size = (file.stat() catch return request.respond("not found\n", .{ .status = .not_found })).size;

    const requested = parseRange(request) orelse Range{ .start = 0, .end = size };
    if (requested.start >= size and size > 0) {
        return request.respond("range not satisfiable\n", .{ .status = .range_not_satisfiable });
    }

    const from = @min(requested.start, size);
    const to = @min(@min(requested.end, size), from + max_range_bytes);
    const length = to - from;

    file.seekTo(from) catch return request.respond("not found\n", .{ .status = .not_found });

    var content_range_buf: [96]u8 = undefined;
    const content_range = try std.fmt.bufPrint(
        &content_range_buf,
        "bytes {d}-{d}/{d}",
        .{ from, if (to == 0) 0 else to - 1, size },
    );

    const partial = from != 0 or to != size;
    const headers: []const http.Header = if (partial) &.{
        .{ .name = "content-type", .value = contentType(rel) },
        .{ .name = "accept-ranges", .value = "bytes" },
        .{ .name = "content-range", .value = content_range },
    } else &.{
        .{ .name = "content-type", .value = contentType(rel) },
        .{ .name = "accept-ranges", .value = "bytes" },
    };

    var send_buffer: [body_buffer_bytes]u8 = undefined;
    var body = try request.respondStreaming(&send_buffer, .{
        .content_length = length,
        .respond_options = .{
            .status = if (partial) .partial_content else .ok,
            .extra_headers = headers,
        },
    });

    var remaining = length;
    var chunk: [body_buffer_bytes]u8 = undefined;
    while (remaining > 0) {
        const want = @min(remaining, chunk.len);
        const n = try file.read(chunk[0..want]);
        if (n == 0) break;
        try body.writer.writeAll(chunk[0..n]);
        remaining -= n;
    }
    try body.end();
}

/// Refuse anything that could climb out of the sessions directory. Only ever
/// asked to serve paths this server itself advertised, so being strict costs
/// nothing.
fn isSafe(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (std.fs.path.isAbsolute(rel)) return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return false;

    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".vtt")) return "text/vtt";
    if (std.mem.endsWith(u8, path, ".wav")) return "audio/wav";
    if (std.mem.endsWith(u8, path, ".opus")) return "audio/ogg";
    return "application/octet-stream";
}

const Range = struct { start: u64, end: u64 };

/// `Range: bytes=START-END`, the only form a media element sends. `END` is
/// inclusive on the wire and exclusive here.
fn parseRange(request: *http.Server.Request) ?Range {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "range")) continue;
        return parseRangeValue(header.value);
    }
    return null;
}

fn parseRangeValue(value: []const u8) ?Range {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, value, prefix)) return null;

    const spec = value[prefix.len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;

    // A suffix range (`bytes=-500`) asks for the last N bytes. No media
    // element sends one, so it is declined rather than guessed at.
    if (dash == 0) return null;

    const first = std.fmt.parseInt(u64, spec[0..dash], 10) catch return null;
    const rest = spec[dash + 1 ..];
    if (rest.len == 0) return .{ .start = first, .end = std.math.maxInt(u64) };

    const last = std.fmt.parseInt(u64, rest, 10) catch return null;
    if (last < first) return null;
    return .{ .start = first, .end = last + 1 };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a path that climbs out of the sessions directory is refused" {
    try testing.expect(!isSafe("../../etc/passwd"));
    try testing.expect(!isSafe("2026/../../../etc/passwd"));
    try testing.expect(!isSafe("/etc/passwd"));
    try testing.expect(!isSafe("2026//audio.wav"));
    try testing.expect(!isSafe("."));
    try testing.expect(!isSafe(""));
}

test "an ordinary session path is allowed" {
    try testing.expect(isSafe("2026/09/12/T063554Z/audio.wav"));
    try testing.expect(isSafe("2026/09/12/T063554Z/audio.vtt"));
}

test "range headers parse the way a media element sends them" {
    // The open-ended form every browser opens a media file with.
    const all = parseRangeValue("bytes=0-").?;
    try testing.expectEqual(@as(u64, 0), all.start);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), all.end);

    // Inclusive on the wire, exclusive here.
    const seek = parseRangeValue("bytes=1024-2047").?;
    try testing.expectEqual(@as(u64, 1024), seek.start);
    try testing.expectEqual(@as(u64, 2048), seek.end);
}

test "ranges that cannot be honoured are declined rather than guessed at" {
    try testing.expect(parseRangeValue("bytes=-500") == null); // suffix range
    try testing.expect(parseRangeValue("items=0-10") == null); // not bytes
    try testing.expect(parseRangeValue("bytes=500-100") == null); // backwards
    try testing.expect(parseRangeValue("bytes=abc-") == null);
    try testing.expect(parseRangeValue("") == null);
}

test "content types are the ones a browser needs to play the files" {
    // text/vtt in particular: a track element ignores anything else.
    try testing.expectEqualStrings("text/vtt", contentType("2026/x/audio.vtt"));
    try testing.expectEqualStrings("audio/wav", contentType("2026/x/audio.wav"));
    try testing.expectEqualStrings("audio/ogg", contentType("2026/x/audio.opus"));
}
