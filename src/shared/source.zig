// src/shared/source.zig — what the machine knew about whoever was on the call.
//
// A meeting session records two tracks of audio and a transcript, and until
// now nothing about where the audio came from. That is the question a
// recording found later cannot answer for itself: this was a call, but a call
// in what, recorded off which microphone.
//
// PipeWire answers more of it than one might expect. Every stream carries the
// properties its client declared -- the application's name, the binary behind
// it, the process id, what that client calls the stream -- and the process id
// leads to the command line the process was started with, which for a browser
// names the profile and sometimes the app.
//
// None of it is authoritative. The properties are self-reported through the
// PulseAudio compatibility layer and a client may say whatever it likes. They
// are good metadata and bad evidence.
//
// What is kept is chosen, and that is a change of mind worth recording. The
// first version wrote down every property of every stream and every client
// behind them, on the argument that a guess made now about which fields
// matter is a guess made before the question is known. That argument was
// right about the fields and wrong about the file: a real call produced
// hundreds of rows, most of them the sound daemon's own clock defaults
// repeated per stream, and a file nobody will read has preserved nothing.
// So there are allowlists, they are short, and everything in them earns its
// place by saying something about the source rather than about PipeWire.
//
// Within what is kept, nothing is interpreted. No value is parsed, renamed or
// tidied, because the shape that survives should be the one observed.
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

/// What a node in the snapshot is, decided by the graph rather than here.
pub const Kind = enum(u8) {
    /// Feeding the sink. This is the call.
    linked = 0,
    /// Another stream of a process that is feeding the sink.
    related = 1,
    /// A source or a sink: the hardware rather than an application.
    device = 2,
};

/// A node as the platform hands it over, before anything is chosen from it.
pub const Stream = struct {
    kind: Kind,
    props: []const Prop,
    /// What the connection behind the node declared. Only ever read for the
    /// peer credentials of its socket; nothing else here comes from it.
    client: []const Prop = &.{},
};

/// The devices capsper asked to record through, so the file can say which
/// microphone this was rather than only which application.
pub const Wanted = struct {
    /// The microphone the near track is taken from, null to follow the
    /// desktop's default.
    near: ?[]const u8 = null,
    /// Where the call is passed on to, null to follow the default output.
    output: ?[]const u8 = null,
};

/// One stream, or several identical ones, that carried the call.
pub const Source = struct {
    /// Said in words because the alternative is a flag whose meaning lives
    /// in this file rather than in the recording.
    role: []const u8,
    /// How many streams collapsed into this entry. A browser opens one per
    /// tab and one per capture, and after the uninteresting properties are
    /// dropped they are the same entry several times over.
    count: u32,
    props: []const Prop,
    /// The process id the kernel supplied for the socket, when there is one.
    /// Kept apart from the properties above because those are claims and
    /// this is not.
    client: []const Prop,
};

/// A microphone or an output, named by the role capsper wanted it for.
pub const Device = struct {
    role: []const u8,
    /// What capsper asked for. Null means it followed the desktop's choice,
    /// and in that case the graph cannot say afterwards what that was.
    requested: ?[]const u8,
    props: []const Prop,
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
    streams: []const Source = &.{},
    devices: []const Device = &.{},
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

const media_class_key = "media.class";
const node_name_key = "node.name";

/// What is kept from a stream, in the order it is written, which is the order
/// someone reading the file will want it in.
///
/// Everything here says something about the application. What was dropped
/// said something about PipeWire -- buffer attributes, quantum limits, object
/// serials, the loop a node runs on -- and repeated itself on every stream.
const stream_props = [_][]const u8{
    "application.name",
    "media.name",
    "application.process.binary",
    pid_key,
    "application.icon-name",
    "media.role",
    "media.filename",
    "media.software",
    // Whether the properties above reached us through the PulseAudio
    // compatibility layer or from a native client, which is to say how much
    // of the rest of this list to believe.
    "client.api",
};

/// The one thing a client cannot make up about itself.
const client_props = [_][]const u8{client_pid_key};

/// What is kept from a device: what it is, what it is plugged into, and what
/// a person would call it.
const device_props = [_][]const u8{
    node_name_key,
    "node.description",
    "device.api",
    "device.bus",
    "alsa.mixer_name",
    "audio.channels",
    "audio.position",
};

/// How far up the process tree to walk.
///
/// A browser needs two steps: the audio service, then the browser itself,
/// where the profile and the app address live. Everything above that is the
/// desktop session -- a terminal, a shell, systemd -- which says nothing
/// about the call and would drag whatever unrelated command line happened to
/// launch it into a file about a meeting. So the walk stops one step past
/// where the answers are, and no further.
const max_ancestors = 3;

/// A command line over this is not telling us anything the first 64 KiB did
/// not, and the session directory is not the place to discover an edge case.
const max_file_bytes = 64 * 1024;

/// Gather everything worth keeping about `streams` right now. `proc_root` is
/// `/proc` in the real thing and a fixture directory in tests; a root that
/// does not exist yields no processes rather than an error, because metadata
/// is worth having incomplete and never worth failing a recording over.
pub fn capture(
    arena: Allocator,
    streams: []const Stream,
    wanted: Wanted,
    proc_root: []const u8,
) !Document {
    return .{
        .streams = try collectSources(arena, streams),
        .devices = try collectDevices(arena, streams, wanted),
        .processes = try collectProcesses(arena, streams, proc_root),
    };
}

/// The streams that carried the call, filtered and then folded together.
fn collectSources(arena: Allocator, streams: []const Stream) ![]const Source {
    var out: std.ArrayListUnmanaged(Source) = .{};

    for (streams) |stream| {
        if (stream.kind == .device) continue;

        const entry: Source = .{
            .role = roleOf(stream),
            .count = 1,
            .props = try filter(arena, stream.props, &stream_props),
            .client = try filter(arena, stream.client, &client_props),
        };

        if (findSame(out.items, entry)) |same| {
            same.count += 1;
        } else {
            try out.append(arena, entry);
        }
    }

    return out.toOwnedSlice(arena);
}

/// An existing entry this one adds nothing to, or null.
fn findSame(items: []Source, entry: Source) ?*Source {
    for (items) |*existing| {
        if (!std.mem.eql(u8, existing.role, entry.role)) continue;
        if (!sameProps(existing.props, entry.props)) continue;
        if (!sameProps(existing.client, entry.client)) continue;
        return existing;
    }
    return null;
}

fn sameProps(a: []const Prop, b: []const Prop) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.key, y.key)) return false;
        if (!std.mem.eql(u8, x.value, y.value)) return false;
    }
    return true;
}

/// What this stream was doing, in the words the file will use.
fn roleOf(stream: Stream) []const u8 {
    if (stream.kind == .linked) return "playing into the sink";

    const class = lookup(stream.props, media_class_key) orelse "";
    return if (std.mem.indexOf(u8, class, "Input") != null)
        "capturing, same process"
    else
        "also playing, same process";
}

/// The devices capsper asked to record through, matched to the graph by name.
fn collectDevices(arena: Allocator, streams: []const Stream, wanted: Wanted) ![]const Device {
    var out: std.ArrayListUnmanaged(Device) = .{};

    for ([_]struct { role: []const u8, name: ?[]const u8 }{
        .{ .role = "microphone", .name = wanted.near },
        .{ .role = "output", .name = wanted.output },
    }) |want| {
        try out.append(arena, .{
            .role = want.role,
            .requested = want.name,
            .props = if (want.name) |name|
                try filter(arena, deviceNamed(streams, name), &device_props)
            else
                &.{},
        });
    }

    return out.toOwnedSlice(arena);
}

fn deviceNamed(streams: []const Stream, name: []const u8) []const Prop {
    for (streams) |stream| {
        if (stream.kind != .device) continue;
        const node = lookup(stream.props, node_name_key) orelse continue;
        if (std.mem.eql(u8, node, name)) return stream.props;
    }
    return &.{};
}

/// The keys from `allow` that `props` actually has, in the order `allow`
/// gives them rather than the order the graph happened to.
fn filter(arena: Allocator, props: []const Prop, allow: []const []const u8) ![]const Prop {
    var out: std.ArrayListUnmanaged(Prop) = .{};
    for (allow) |key| {
        const value = lookup(props, key) orelse continue;
        try out.append(arena, .{ .key = key, .value = value });
    }
    return out.toOwnedSlice(arena);
}

fn lookup(props: []const Prop, key: []const u8) ?[]const u8 {
    for (props) |prop| {
        if (std.mem.eql(u8, prop.key, key)) return prop.value;
    }
    return null;
}

fn collectProcesses(arena: Allocator, streams: []const Stream, proc_root: []const u8) ![]const Process {
    var out: std.ArrayListUnmanaged(Process) = .{};
    var seen: std.AutoHashMapUnmanaged(u32, void) = .{};

    for (streams) |stream| {
        if (stream.kind == .device) continue;
        const pid = streamPid(stream) orelse continue;

        var next: ?u32 = pid;
        var depth: usize = 0;
        while (next) |current| : (depth += 1) {
            if (depth >= max_ancestors or current <= 1) break;
            if ((try seen.getOrPut(arena, current)).found_existing) break;

            const process = readProcess(arena, proc_root, current) orelse break;
            try out.append(arena, process);
            next = process.ppid;
        }
    }

    return out.toOwnedSlice(arena);
}

/// The process worth walking up from: what the application claimed, and
/// failing that what its socket proved.
fn streamPid(stream: Stream) ?u32 {
    return parsePid(lookup(stream.props, pid_key)) orelse
        parsePid(lookup(stream.client, client_pid_key));
}

fn parsePid(text: ?[]const u8) ?u32 {
    const value = text orelse return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t"), 10) catch null;
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
        return parsePid(std.mem.trim(u8, line["PPid:".len..], " \t\r"));
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
        try json.objectField("role");
        try json.write(stream.role);
        try json.objectField("count");
        try json.write(stream.count);
        try json.objectField("props");
        try writeProps(&json, stream.props);
        try json.objectField("client");
        try writeProps(&json, stream.client);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("devices");
    try json.beginArray();
    for (doc.devices) |device| {
        try json.beginObject();
        try json.objectField("role");
        try json.write(device.role);
        try json.objectField("requested");
        try json.write(device.requested);
        try json.objectField("props");
        try writeProps(&json, device.props);
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
        .kind = .linked,
        .props = &.{
            .{ .key = "application.name", .value = "Google Chrome" },
            .{ .key = pid_key, .value = "4002" },
        },
    }};

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const doc = try capture(arena, &streams, .{}, root);

    try testing.expectEqual(@as(usize, 2), doc.processes.len);
    try testing.expectEqual(@as(u32, 4002), doc.processes[0].pid);
    try testing.expectEqual(@as(?u32, 4001), doc.processes[0].ppid);
    try testing.expectEqualStrings("--profile-directory=work", doc.processes[1].cmdline[1]);
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
        .kind = .linked,
        .props = &.{.{ .key = "application.name", .value = "pw-play" }},
        .client = &.{.{ .key = client_pid_key, .value = "7100" }},
    }};

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const doc = try capture(arena, &streams, .{}, root);
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
        .kind = .linked,
        .props = &.{.{ .key = pid_key, .value = "8100" }},
        .client = &.{.{ .key = client_pid_key, .value = "8200" }},
    }};

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const doc = try capture(arena, &streams, .{}, root);
    try testing.expectEqual(@as(usize, 1), doc.processes.len);
    try testing.expectEqual(@as(u32, 8100), doc.processes[0].pid);
}

test "only the properties that say something about the source are kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const streams = [_]Stream{.{
        .kind = .linked,
        .props = &.{
            .{ .key = "media.name", .value = "Playback" },
            .{ .key = "pulse.attr.maxlength", .value = "4194304" },
            .{ .key = "application.name", .value = "Google Chrome" },
            .{ .key = "clock.quantum-limit", .value = "8192" },
            .{ .key = "object.serial", .value = "253" },
        },
        .client = &.{
            .{ .key = client_pid_key, .value = "4847" },
            .{ .key = "default.clock.rate", .value = "48000" },
        },
    }};

    const doc = try capture(arena, &streams, .{}, "/nonexistent");
    const kept = doc.streams[0].props;

    // Written in the order the list gives, not the order the graph did.
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("application.name", kept[0].key);
    try testing.expectEqualStrings("media.name", kept[1].key);

    try testing.expectEqual(@as(usize, 1), doc.streams[0].client.len);
    try testing.expectEqualStrings(client_pid_key, doc.streams[0].client[0].key);
}

test "streams that say the same thing are counted, not repeated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two of a browser's capture streams, which differ only in the buffer
    // size that is no longer kept.
    const props = [_]Prop{
        .{ .key = "application.name", .value = "Google Chrome input" },
        .{ .key = media_class_key, .value = "Stream/Input/Audio" },
    };
    const streams = [_]Stream{
        .{ .kind = .linked, .props = &.{.{ .key = "application.name", .value = "Google Chrome" }} },
        .{ .kind = .related, .props = &props },
        .{ .kind = .related, .props = &props },
    };

    const doc = try capture(arena, &streams, .{}, "/nonexistent");
    try testing.expectEqual(@as(usize, 2), doc.streams.len);
    try testing.expectEqualStrings("playing into the sink", doc.streams[0].role);
    try testing.expectEqual(@as(u32, 1), doc.streams[0].count);
    try testing.expectEqualStrings("capturing, same process", doc.streams[1].role);
    try testing.expectEqual(@as(u32, 2), doc.streams[1].count);
}

test "the microphone is recorded by the name capsper asked for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const streams = [_]Stream{.{
        .kind = .device,
        .props = &.{
            .{ .key = node_name_key, .value = "alsa_input.pci-0000_00_1f.3.HiFi__Mic1__source" },
            .{ .key = "node.description", .value = "Built-in Audio Stereo Microphone" },
            .{ .key = "device.bus", .value = "pci" },
            .{ .key = "alsa.card_name", .value = "sof-hda-dsp" },
        },
    }};

    const doc = try capture(arena, &streams, .{
        .near = "alsa_input.pci-0000_00_1f.3.HiFi__Mic1__source",
    }, "/nonexistent");

    // A device is never a source of the call, however it arrived.
    try testing.expectEqual(@as(usize, 0), doc.streams.len);

    try testing.expectEqual(@as(usize, 2), doc.devices.len);
    try testing.expectEqualStrings("microphone", doc.devices[0].role);
    try testing.expectEqualStrings("Built-in Audio Stereo Microphone", doc.devices[0].props[1].value);

    // Following the desktop's choice is recorded as such rather than omitted.
    try testing.expectEqualStrings("output", doc.devices[1].role);
    try testing.expectEqual(@as(?[]const u8, null), doc.devices[1].requested);
    try testing.expectEqual(@as(usize, 0), doc.devices[1].props.len);
}

test "a property value that would break the file is escaped, not dropped" {
    const streams = [_]Source{.{
        .role = "playing into the sink",
        .count = 1,
        .props = &.{.{ .key = "media.name", .value = "a \"quoted\" \\ name\nsecond line" }},
        .client = &.{},
    }};

    const bytes = try render(testing.allocator, .{ .streams = &streams });
    defer testing.allocator.free(bytes);

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
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("devices").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("processes").?.array.items.len);
}
