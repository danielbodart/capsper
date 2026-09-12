// src/shared/source.zig — what the machine knew about whoever was on the call.
//
// A meeting session records two tracks of audio and a transcript, and until
// now nothing about where the audio came from. That is the question a
// recording found later cannot answer for itself: this was a call, but a call
// in what, with what, started by which window.
//
// PipeWire answers more of it than one might expect. Every stream carries the
// properties its client declared -- the application's name, the binary behind
// it, the process id, what that client calls the stream -- and the process id
// leads to the command line the process was started with, which for a browser
// names the profile and sometimes the app. None of it is authoritative: the
// properties are self-reported through the PulseAudio compatibility layer and
// a client may say whatever it likes. They are good metadata and bad evidence.
//
// So nothing here interprets. No field is promoted, renamed, or parsed into a
// tidier shape, because the shape that survives is the one that was actually
// observed, and a guess made now about which parts matter is a guess made
// before the question is known. What is written is the raw pairs, verbatim,
// for a person or a model reading it later to reconcile against whatever they
// are trying to work out.
//
// The result is `audio.json`, beside `audio.opus` and `audio.vtt`, sharing
// their basename for the same reason they share it with each other.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One property exactly as the graph reported it.
pub const Prop = struct {
    key: []const u8,
    value: []const u8,
};

/// One audio stream belonging to the call.
pub const Stream = struct {
    /// True for a stream feeding the sink, which is the call being recorded.
    /// False for one pulled in because it shares a process with such a
    /// stream, which in practice is the microphone the same application is
    /// capturing: the clearest sign in the graph that this is a conversation
    /// and not a video playing into the sink.
    linked: bool,
    props: []const Prop,
    /// What the connection behind the stream declared, kept apart from the
    /// node's own properties rather than merged, because which of the two
    /// said a thing is part of what it is worth. The node repeats whatever
    /// the application claims about itself; the client carries the peer
    /// credentials of its socket, which the kernel supplied.
    client: []const Prop = &.{},
};

/// A process behind one of those streams, or an ancestor of one.
///
/// The stream's own process is rarely the interesting one. A browser routes
/// every tab's audio through a single utility process whose command line says
/// nothing; its parent is the browser itself, and that command line carries
/// the profile and, when the window was launched as an app, the address it
/// was launched with. So the chain is walked rather than the process alone.
pub const Process = struct {
    pid: u32,
    ppid: ?u32,
    /// Where the executable lives, as the kernel reports it.
    exe: ?[]const u8,
    /// Split on the NUL bytes the file already separates arguments with,
    /// which is reading the format rather than parsing the content.
    cmdline: []const []const u8,
};

pub const Document = struct {
    streams: []const Stream = &.{},
    /// Child first, each naming its parent, so the tree can be rebuilt
    /// without this having to choose a shape for it.
    processes: []const Process = &.{},
};

/// What an application says its own process id is. Self-reported through the
/// PulseAudio compatibility layer, and absent entirely from a native PipeWire
/// client, which sets no application properties at all.
const pid_key = "application.process.id";

/// The peer credential of the client's socket. Attested rather than claimed,
/// but for anything connecting through pipewire-pulse it names the pulse
/// server and not the application, so it is only worth following when the
/// application said nothing about itself.
const client_pid_key = "pipewire.sec.pid";

/// How far up the process tree to walk.
///
/// A browser needs two steps: the audio service, then the browser itself,
/// where the profile and the app address live. Everything above that is the
/// desktop session -- a terminal, a shell, systemd -- which says nothing
/// about the call and would drag whatever unrelated command line happened to
/// launch it into a file about a meeting. So the walk stops just past where
/// the answers are.
const max_ancestors = 4;

/// A command line over this is not telling us anything the first 64 KiB did
/// not, and the session directory is not the place to discover an edge case.
const max_file_bytes = 64 * 1024;

/// Gather everything known about `streams` right now. `proc_root` is `/proc`
/// in the real thing and a fixture directory in tests; a root that does not
/// exist yields no processes rather than an error, because metadata is worth
/// having incomplete and never worth failing a recording over.
pub fn capture(arena: Allocator, streams: []const Stream, proc_root: []const u8) !Document {
    var processes: std.ArrayListUnmanaged(Process) = .{};
    var seen: std.AutoHashMapUnmanaged(u32, void) = .{};

    for (streams) |stream| {
        const pid = streamPid(stream) orelse continue;

        var next: ?u32 = pid;
        var depth: usize = 0;
        while (next) |current| : (depth += 1) {
            if (depth >= max_ancestors or current <= 1) break;
            if ((try seen.getOrPut(arena, current)).found_existing) break;

            const process = readProcess(arena, proc_root, current) orelse break;
            try processes.append(arena, process);
            next = process.ppid;
        }
    }

    return .{ .streams = streams, .processes = try processes.toOwnedSlice(arena) };
}

/// The process worth walking up from: what the application claimed, and
/// failing that what its socket proved.
fn streamPid(stream: Stream) ?u32 {
    return lookupPid(stream.props, pid_key) orelse lookupPid(stream.client, client_pid_key);
}

fn lookupPid(props: []const Prop, key: []const u8) ?u32 {
    for (props) |prop| {
        if (!std.mem.eql(u8, prop.key, key)) continue;
        return std.fmt.parseInt(u32, std.mem.trim(u8, prop.value, " \t"), 10) catch null;
    }
    return null;
}

/// Null when the process is gone, which is ordinary: a call being torn down
/// while this runs is a race nothing can win, and losing one entry is better
/// than losing the recording.
fn readProcess(arena: Allocator, proc_root: []const u8, pid: u32) ?Process {
    var path_buf: [64]u8 = undefined;
    const rel = std.fmt.bufPrint(&path_buf, "{d}", .{pid}) catch return null;

    var root = std.fs.cwd().openDir(proc_root, .{}) catch return null;
    defer root.close();
    var dir = root.openDir(rel, .{}) catch return null;
    defer dir.close();

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: ?[]const u8 = if (dir.readLink("exe", &exe_buf)) |link|
        arena.dupe(u8, link) catch null
    else |_|
        null;

    return .{
        .pid = pid,
        .ppid = readPpid(arena, dir),
        .exe = exe,
        .cmdline = readCmdline(arena, dir) catch &.{},
    };
}

/// `/proc/<pid>/status` rather than `stat`, whose second field is the command
/// name unescaped and may itself contain the spaces and brackets that field
/// splitting relies on.
fn readPpid(arena: Allocator, dir: std.fs.Dir) ?u32 {
    const text = readAll(arena, dir, "status") catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "PPid:")) continue;
        const rest = std.mem.trim(u8, line["PPid:".len..], " \t\r");
        return std.fmt.parseInt(u32, rest, 10) catch null;
    }
    return null;
}

/// Arguments are NUL-separated in the file and there is a trailing NUL, so the
/// final split yields an empty piece that is not an argument.
fn readCmdline(arena: Allocator, dir: std.fs.Dir) ![]const []const u8 {
    const text = try readAll(arena, dir, "cmdline");

    var args: std.ArrayListUnmanaged([]const u8) = .{};
    var parts = std.mem.splitScalar(u8, text, 0);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try args.append(arena, part);
    }
    return args.toOwnedSlice(arena);
}

fn readAll(arena: Allocator, dir: std.fs.Dir, name: []const u8) ![]const u8 {
    var file = try dir.openFile(name, .{});
    defer file.close();
    return file.readToEndAlloc(arena, max_file_bytes);
}

/// The document as the file on disk, indented because a person opening it to
/// see what was on the other end should not have to pipe it through anything.
pub fn render(gpa: Allocator, doc: Document) ![]u8 {
    var out: std.io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };

    try json.beginObject();

    try json.objectField("streams");
    try json.beginArray();
    for (doc.streams) |stream| {
        try json.beginObject();
        try json.objectField("linked");
        try json.write(stream.linked);
        try json.objectField("props");
        try writeProps(&json, stream.props);
        try json.objectField("client");
        try writeProps(&json, stream.client);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("processes");
    try json.beginArray();
    for (doc.processes) |process| {
        try json.beginObject();
        try json.objectField("pid");
        try json.write(process.pid);
        try json.objectField("ppid");
        try json.write(process.ppid);
        try json.objectField("exe");
        try json.write(process.exe);
        try json.objectField("cmdline");
        try json.write(process.cmdline);
        try json.endObject();
    }
    try json.endArray();

    try json.endObject();
    try out.writer.writeByte('\n');

    return out.toOwnedSlice();
}

fn writeProps(json: *std.json.Stringify, props: []const Prop) !void {
    try json.beginObject();
    for (props) |prop| {
        try json.objectField(prop.key);
        try json.write(prop.value);
    }
    try json.endObject();
}

const testing = std.testing;

/// Writes a `<pid>` directory shaped like the real thing.
fn fakeProcess(dir: std.fs.Dir, pid: u32, ppid: u32, cmdline: []const u8) !void {
    var name_buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}", .{pid});
    try dir.makePath(name);
    var proc = try dir.openDir(name, .{});
    defer proc.close();

    try proc.writeFile(.{ .sub_path = "cmdline", .data = cmdline });
    var status_buf: [128]u8 = undefined;
    try proc.writeFile(.{
        .sub_path = "status",
        .data = try std.fmt.bufPrint(&status_buf, "Name:\tchrome\nPid:\t{d}\nPPid:\t{d}\n", .{ pid, ppid }),
    });
}

test "the process behind a stream is walked up to its ancestors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The shape a browser actually presents: the stream belongs to an audio
    // service whose own command line says nothing, and the profile is on its
    // parent.
    try fakeProcess(tmp.dir, 4002, 4001, "chrome\x00--type=utility\x00--utility-sub-type=audio.mojom.AudioService\x00");
    try fakeProcess(tmp.dir, 4001, 1, "chrome\x00--profile-directory=work\x00");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const streams = [_]Stream{.{
        .linked = true,
        .props = &.{
            .{ .key = "application.name", .value = "Google Chrome" },
            .{ .key = pid_key, .value = "4002" },
        },
    }};

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const doc = try capture(arena, &streams, root);

    try testing.expectEqual(@as(usize, 2), doc.processes.len);
    try testing.expectEqual(@as(u32, 4002), doc.processes[0].pid);
    try testing.expectEqual(@as(?u32, 4001), doc.processes[0].ppid);
    try testing.expectEqual(@as(u32, 4001), doc.processes[1].pid);
    try testing.expectEqualStrings("--profile-directory=work", doc.processes[1].cmdline[1]);
}

test "a process is recorded once however many of its streams named it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeProcess(tmp.dir, 900, 1, "chrome\x00");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const props = [_]Prop{.{ .key = pid_key, .value = "900" }};
    const streams = [_]Stream{
        .{ .linked = true, .props = &props },
        .{ .linked = false, .props = &props },
    };

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const doc = try capture(arena, &streams, root);
    try testing.expectEqual(@as(usize, 1), doc.processes.len);
}

test "a native client with no declared pid is followed through its socket" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeProcess(tmp.dir, 7100, 1, "pw-play\x00tone.wav\x00");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What `pw-play` actually looks like: a name on the node and nothing
    // about the process, with the truth of it on the client instead.
    const streams = [_]Stream{.{
        .linked = true,
        .props = &.{.{ .key = "application.name", .value = "pw-play" }},
        .client = &.{.{ .key = client_pid_key, .value = "7100" }},
    }};

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const doc = try capture(arena, &streams, root);
    try testing.expectEqual(@as(usize, 1), doc.processes.len);
    try testing.expectEqual(@as(u32, 7100), doc.processes[0].pid);
}

test "what the application claims about itself is preferred to its socket" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeProcess(tmp.dir, 8100, 1, "chrome\x00");
    try fakeProcess(tmp.dir, 8200, 1, "pipewire-pulse\x00");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A browser's socket belongs to the pulse server, so following it would
    // record the sound daemon instead of the application.
    const streams = [_]Stream{.{
        .linked = true,
        .props = &.{.{ .key = pid_key, .value = "8100" }},
        .client = &.{.{ .key = client_pid_key, .value = "8200" }},
    }};

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const doc = try capture(arena, &streams, root);
    try testing.expectEqual(@as(usize, 1), doc.processes.len);
    try testing.expectEqual(@as(u32, 8100), doc.processes[0].pid);
}

test "a stream whose process is gone still records the stream" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const streams = [_]Stream{.{
        .linked = true,
        .props = &.{.{ .key = pid_key, .value = "999999" }},
    }};

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const doc = try capture(arena, &streams, root);
    try testing.expectEqual(@as(usize, 1), doc.streams.len);
    try testing.expectEqual(@as(usize, 0), doc.processes.len);
}

test "a property value that would break the file is escaped, not dropped" {
    const streams = [_]Stream{.{
        .linked = true,
        .props = &.{.{ .key = "media.name", .value = "a \"quoted\" \\ name\nsecond line" }},
    }};

    const bytes = try render(testing.allocator, .{ .streams = &streams });
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "a \\\"quoted\\\" \\\\ name\\nsecond line") != null);

    // And it is still JSON afterwards.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    const props = parsed.value.object.get("streams").?.array.items[0].object.get("props").?.object;
    try testing.expectEqualStrings("a \"quoted\" \\ name\nsecond line", props.get("media.name").?.string);
}

test "an empty document is still a readable file" {
    const bytes = try render(testing.allocator, .{});
    defer testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("streams").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("processes").?.array.items.len);
}
