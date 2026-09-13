// src/shared/http_server.zig — the console: a way in to a running capsper.
//
// Runs whenever `http.port` is set, on its own account rather than as part of
// any capture mode. A capsper that only dictates has as much to show here as
// one recording meetings: what it is listening to, what it decided the
// settings were, and whatever it has kept.
//
// Today it serves the transcripts. It starts before the model loads, so the
// page answers while a minute of model reading is still going on, and it
// holds the settings rather than a directory path because what it reports is
// the whole of what this process was told.
//
// It binds to loopback unless told otherwise. These are recordings of private
// conversations, and reaching them from the network should take saying so.

const std = @import("std");
const net = std.net;
const http = std.http;

const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const config_docs = @import("config_docs.zig");
const settings_form = @import("settings_form.zig");
const status = @import("status.zig");
const utils = @import("utils.zig");

const log = std.log.scoped(.http);

/// The transcripts page, embedded so a running capsper needs nothing fetched
/// to serve it.
const index_html = @embedFile("console.html");

/// What both pages look like. One file rather than a copy in each, because a
/// palette that has to agree in two places eventually does not.
const style_css = @embedFile("console.css");

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
    /// Every setting this process is running on, paths already expanded.
    ///
    /// Borrowed rather than copied, and borrowed whole rather than picking
    /// out the one directory this used to need. The settings are written once
    /// in `main` and never again, and they outlive every thread, so reading
    /// them from here is the same unsynchronised read of the same immutable
    /// struct that `Server` and the meeting runner already do.
    cfg: *const config.Config,
    port: u16,
    bind: []const u8,

    /// What this binary is, passed in rather than imported. `build_options`
    /// belongs to the executable, and this module is built on its own as a
    /// test target with none of the executable's dependencies -- so the three
    /// facts it wants arrive as three strings instead.
    version: []const u8,
    backend: []const u8,
    /// The model directory, as resolved. Reported while it is still being
    /// read, which is when naming it is most use.
    model: []const u8,

    /// The settings as they were written, before `expandPaths` turned every
    /// `~/` into one machine's absolute path.
    ///
    /// The form shows these and saves these. `cfg` above is what is running
    /// and is right for reading a directory; this is what belongs in a file,
    /// and saving the other one would quietly bake `/home/someone` into a
    /// setting that said `~/`. `--write-config` avoids the same trap by
    /// running before the expansion.
    as_written: *const config.Config,

    /// Where the settings came from, and so where they go back. Null when no
    /// path could be worked out at all, which is its own answer on the page.
    config_path: ?[]const u8 = null,

    /// How to find the capture devices, or null where the platform cannot.
    ///
    /// A function rather than a list, so the form offers what is plugged in
    /// now rather than what was plugged in at startup -- and injected rather
    /// than imported, because reaching PipeWire from here would drag the whole
    /// platform layer into a module that is built on its own as a test target.
    list_devices: ?*const fn (Allocator) anyerror![]const []const u8 = null,
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
        .cfg = opts.cfg,
        .as_written = opts.as_written,
        .config_path = opts.config_path,
        .list_devices = opts.list_devices,
        .build = .{ .version = opts.version, .backend = opts.backend, .model = opts.model },
    };

    const thread = std.Thread.spawn(.{}, acceptLoop, .{state}) catch |err| {
        listener.deinit();
        gpa.destroy(state);
        return err;
    };
    thread.detach();

    // The bound port rather than the requested one, because zero means
    // whatever the OS picked and that is the number you need to type.
    std.debug.print("Console at http://{s}:{d}\n", .{ opts.bind, listener.listen_address.getPort() });
}

const Build = struct {
    version: []const u8,
    backend: []const u8,
    model: []const u8,
};

const State = struct {
    gpa: std.mem.Allocator,
    listener: net.Server,
    cfg: *const config.Config,
    as_written: *const config.Config,
    config_path: ?[]const u8,
    list_devices: ?*const fn (Allocator) anyerror![]const []const u8,
    build: Build,
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

    if (std.mem.eql(u8, path, "/")) return statusPage(state, request);

    // The transcripts are an application rather than a document -- the player
    // syncs a WebVTT track to an audio element and re-reads it while a meeting
    // is still being written -- so this one page is handed out for its own
    // path and everything under it, and the script reads the address to know
    // which recording is wanted. The status page next door has no such need
    // and is plain HTML, which is the whole reason they are not one mechanism.
    if (std.mem.eql(u8, path, "/transcripts") or std.mem.startsWith(u8, path, "/transcripts/")) {
        return request.respond(index_html, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/style.css")) {
        return request.respond(style_css, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/css; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/recordings") or std.mem.startsWith(u8, path, "/recordings/")) {
        return request.respond(index_html, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/settings")) {
        return switch (request.head.method) {
            .POST => saveSettings(state, request),
            else => settingsPage(state, request, null),
        };
    }

    if (std.mem.eql(u8, path, "/sessions.json")) return sessionsJson(state, request);
    if (std.mem.eql(u8, path, "/recordings.json")) return recordingsJson(state, request);

    if (std.mem.startsWith(u8, path, "/s/")) return sessionFile(state, request, path[3..]);
    if (std.mem.startsWith(u8, path, "/d/")) return debugFile(state, request, path[3..]);

    return request.respond("not found\n", .{ .status = .not_found });
}

// ─── Status ──────────────────────────────────────────────────────────────────

/// Written here rather than fetched as JSON and assembled in the browser.
///
/// There is nothing live on this page beyond the reload: no seeking, no audio
/// graph, no track that changes while it is open. A renderer in JavaScript
/// would exist only to turn values this function already holds into the markup
/// this function already knows how to write. The transcripts next door are the
/// other case and keep their script for the reason it was written.
///
/// It refreshes on a meta tag for the same reason: five seconds of staleness
/// on a level meter costs nothing, and the alternative is a polling loop and a
/// second representation of every field.
fn statusPage(state: *State, request: *http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const now: i64 = @intCast(std.time.nanoTimestamp());
    const cfg = state.cfg;

    var body: std.ArrayListUnmanaged(u8) = .{};
    const w = body.writer(arena);

    try w.writeAll(
        \\<!doctype html>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<meta http-equiv="refresh" content="5">
        \\<title>Capsper</title>
        \\<link rel="stylesheet" href="/style.css">
        \\<main>
        \\<nav><a href="/" aria-current="page">Status</a><a href="/transcripts">Transcripts</a><a href="/recordings">Recordings</a><a href="/settings">Settings</a></nav>
        \\<h1>Capsper</h1>
        \\
    );

    // ── What it is doing ──
    try w.writeAll("<p class=\"meta\">");
    if (status.meeting.runningFor(now)) |secs| {
        try w.writeAll("Recording a meeting, ");
        try writeDuration(w, secs);
        try w.writeAll(" in.");
    } else if (status.live.load(.monotonic)) {
        try w.writeAll("Listening.");
    } else {
        try w.writeAll("Idle.");
    }
    try w.writeAll("</p>\n<div class=\"cards\">\n");

    // ── Capture ──
    try w.writeAll("<section class=\"card\"><h2>Capture</h2><dl>");
    try writeFlag(w, "Push to talk", status.live.load(.monotonic), "held", "not held");
    try w.print("<dt>Remote clients</dt><dd class=\"num\">{d}</dd>", .{status.tcp_clients.load(.monotonic)});
    if (status.meeting.runningFor(now)) |secs| {
        var path_buf: [64]u8 = undefined;
        const rel = status.meeting.path.get(&path_buf);
        try w.writeAll("<dt>Meeting</dt><dd>recording ");
        try writeDuration(w, secs);
        if (rel.len > 0) {
            try w.writeAll(" — <a href=\"/transcripts/");
            try writeEscaped(w, rel);
            try w.writeAll("\">");
            try writeEscaped(w, rel);
            try w.writeAll("</a>");
        }
        try w.writeAll("</dd>");
    } else {
        try w.print("<dt>Meeting</dt><dd class=\"off\">{s}</dd>", .{
            if (cfg.meeting.enabled) "waiting for a call" else "off",
        });
    }
    try w.writeAll("</dl></section>\n");

    // ── Audio ──
    //
    // Only the microphones something is actually listening to. A TCP-only
    // capsper has no microphone of its own -- the audio arrives down the
    // socket already captured -- and a row naming "the default input" there
    // would describe a device this process never opens.
    const captures_locally = cfg.audio.target != null or cfg.trigger.key != null;
    try w.writeAll("<section class=\"card\"><h2>Audio</h2><dl>");
    if (captures_locally) try writeInput(w, "Dictation mic", &status.dictation, cfg.audio.target);
    if (cfg.meeting.enabled) {
        try writeInput(w, "Meeting mic", &status.meeting_near, cfg.meetingNear());
        try writeFlag(w, "Sink", status.sink_up.load(.monotonic), "in the graph", "not created");
        try w.writeAll("<dt>Passing through to</dt><dd>");
        try writeEscaped(w, cfg.meeting.output orelse "the default output");
        try w.writeAll("</dd>");
    }
    if (!captures_locally and !cfg.meeting.enabled) {
        try w.writeAll("<dt>Microphone</dt><dd class=\"off\">nothing is captured here</dd>");
    }
    try w.writeAll("</dl></section>\n");

    // ── Build ──
    try w.writeAll("<section class=\"card\"><h2>Build</h2><dl>");
    try w.writeAll("<dt>Version</dt><dd>");
    try writeEscaped(w, state.build.version);
    try w.writeAll("</dd><dt>Backend</dt><dd>");
    try writeEscaped(w, state.build.backend);
    try w.writeAll("</dd><dt>Model</dt><dd>");
    try writeEscaped(w, state.build.model);
    try w.writeAll("</dd>");
    if (status.uptimeSeconds(now)) |secs| {
        try w.writeAll("<dt>Up for</dt><dd class=\"num\">");
        try writeDuration(w, secs);
        try w.writeAll("</dd>");
    }
    try w.writeAll("</dl></section>\n</div>\n</main>\n");

    return request.respond(body.items, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

/// One microphone: the node it settled on, and what is arriving on it.
///
/// `configured` is what the settings asked for, which is null when capsper was
/// told to follow the desktop's default. Saying which of those happened is the
/// point: "the default" and "this particular node" look identical on a status
/// page that only prints a name.
fn writeInput(
    w: anytype,
    label: []const u8,
    input: *status.Input,
    configured: ?[]const u8,
) !void {
    try w.writeAll("<dt>");
    try writeEscaped(w, label);
    try w.writeAll("</dt><dd>");

    var name_buf: [128]u8 = undefined;
    const device = input.device.get(&name_buf);
    if (device.len > 0) {
        try writeEscaped(w, device);
        if (configured == null) try w.writeAll(" <span class=\"off\">(following the default)</span>");
    } else if (configured) |c| {
        try writeEscaped(w, c);
        try w.writeAll(" <span class=\"off\">(not open yet)</span>");
    } else {
        try w.writeAll("<span class=\"off\">the default input</span>");
    }

    if (input.heard.load(.monotonic)) {
        try w.print(
            "<br><span class=\"num\">{d:.0} dBFS at {d:.2}×</span>",
            .{ input.level_db.load(), input.gain.load() },
        );
    } else {
        try w.print("<br><span class=\"off num\">nothing heard yet, at {d:.2}×</span>", .{input.gain.load()});
    }
    try w.writeAll("</dd>");
}

fn writeFlag(w: anytype, label: []const u8, on: bool, yes: []const u8, no: []const u8) !void {
    try w.writeAll("<dt>");
    try writeEscaped(w, label);
    try w.print("</dt><dd class=\"{s}\">", .{if (on) "on" else "off"});
    try writeEscaped(w, if (on) yes else no);
    try w.writeAll("</dd>");
}

/// A length of time as a person would say it, which is not the same as a
/// number of seconds once it passes a minute.
fn writeDuration(w: anytype, seconds: f64) !void {
    const total: u64 = @intFromFloat(@max(0, seconds));
    const h = total / 3600;
    const m = (total % 3600) / 60;
    const s = total % 60;
    if (h > 0) {
        try w.print("{d}h {d}m", .{ h, m });
    } else if (m > 0) {
        try w.print("{d}m {d}s", .{ m, s });
    } else {
        try w.print("{d}s", .{s});
    }
}

/// The five characters that change the meaning of markup.
///
/// In `utils` because the settings form needs the same guarantee about the
/// same untrusted values, and one of these is enough.
const writeEscaped = utils.writeHtml;

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

    const root = state.cfg.meeting.dir;
    const sessions = collect(arena, root) catch |err| {
        // Ordinary when meeting capture has never run: the directory is made
        // by the first session, so until then there is nothing to read and
        // nothing wrong.
        log.debug("cannot read sessions from '{s}': {}", .{ root, err });
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
        if (!isAudio(entry.basename)) continue;

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

/// The recording itself, as against the transcript and the metadata that
/// share its name.
///
/// Named outright rather than by excluding what a session is known to contain
/// besides: the exclusions were what broke when `audio.json` arrived, quietly
/// listing the metadata as the thing to play. Anything else put in a session
/// directory from now on is ignored until it is added here on purpose.
fn isAudio(basename: []const u8) bool {
    for ([_][]const u8{ "audio.wav", "audio.opus" }) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    return false;
}

/// How long a session's audio runs. Only ever used to label a row in the list,
/// so an unreadable file costs a blank cell rather than an error.
fn durationSeconds(dir: std.fs.Dir, path: []const u8) f64 {
    var file = dir.openFile(path, .{}) catch return 0;
    defer file.close();

    if (std.mem.endsWith(u8, path, ".opus")) return oggDurationSeconds(file);
    return wavDurationSeconds(file);
}

fn wavDurationSeconds(file: std.fs.File) f64 {
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

/// The granule position on the last Ogg page, which for Opus is the number of
/// 48 kHz samples the file decodes to.
///
/// Read by scanning backwards for the last page header rather than walking the
/// file forwards, because an hour of audio is a lot of pages to walk to answer
/// one question.
fn oggDurationSeconds(file: std.fs.File) f64 {
    const size = (file.stat() catch return 0).size;

    // A page header is 27 bytes plus up to 255 segments plus the body, so the
    // last one starts well inside the final 64 kB unless something is very
    // wrong.
    const window: u64 = @min(size, 64 * 1024);
    var buf: [64 * 1024]u8 = undefined;
    file.seekTo(size - window) catch return 0;
    const n = file.readAll(buf[0..window]) catch return 0;

    var i = n;
    while (i >= 4) : (i -= 1) {
        if (!std.mem.eql(u8, buf[i - 4 ..][0..4], "OggS")) continue;
        const page = buf[i - 4 ..];
        if (page.len < 14) return 0;
        const granule = std.mem.readInt(i64, page[6..14], .little);
        if (granule < 0) return 0;
        return @as(f64, @floatFromInt(granule)) / 48000.0;
    }
    return 0;
}

// ─── Settings ────────────────────────────────────────────────────────────────

/// What happened to a save, and what to tell the person who asked for it.
const Outcome = union(enum) {
    /// A field could not be read. Nothing was written.
    rejected: settings_form.Problem,
    /// The document the form made would not parse. Nothing was written. This
    /// should not happen -- every field is checked before it is written -- so
    /// the diagnostic is shown rather than summarised.
    invalid: []const u8,
    /// Written, and the process is about to leave so the new settings take.
    saved: []const u8,
    /// Correct, complete, and nowhere to put it: the settings came from a path
    /// that cannot be written, which on NixOS is every time. The ZON is handed
    /// back for the person to put where it belongs.
    unwritable: struct { path: ?[]const u8, zon: []const u8 },
};

fn settingsPage(state: *State, request: *http.Server.Request, outcome: ?Outcome) !void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Asked now rather than remembered from startup, so the list is what is
    // plugged in while the page is being read.
    const devices: []const []const u8 = if (state.list_devices) |list|
        list(arena) catch &.{}
    else
        &.{};

    var body: std.Io.Writer.Allocating = .init(arena);
    const w = &body.writer;

    try w.writeAll(
        \\<!doctype html>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>Capsper settings</title>
        \\<link rel="stylesheet" href="/style.css">
        \\<main>
        \\<nav><a href="/">Status</a><a href="/transcripts">Transcripts</a><a href="/recordings">Recordings</a><a href="/settings" aria-current="page">Settings</a></nav>
        \\<h1>Capsper settings</h1>
        \\
    );

    if (outcome) |o| try writeOutcome(w, o);

    try w.writeAll("<p class=\"meta\">Every setting capsper has, with what it means beside it. ");
    if (state.config_path) |p| {
        try w.writeAll("Saving writes <code>");
        try utils.writeHtml(w, p);
        try w.writeAll("</code> and restarts.");
    } else {
        try w.writeAll("There is nowhere to save to: no config path could be worked out.");
    }
    try w.writeAll("</p>\n<form method=\"post\" action=\"/settings\" class=\"settings\">\n");

    try settings_form.writeForm(state.as_written, devices, w);

    try w.writeAll(
        \\<div class="actions"><button type="submit">Save and restart</button></div>
        \\</form>
        \\</main>
        \\
    );

    return request.respond(body.written(), .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

fn writeOutcome(w: *std.Io.Writer, outcome: Outcome) !void {
    switch (outcome) {
        .rejected => |p| {
            try w.writeAll("<p class=\"notice bad\">Nothing was saved: <code>");
            try utils.writeHtml(w, p.path);
            try w.writeAll("</code> ");
            try utils.writeHtml(w, p.message);
            try w.writeAll(".</p>\n");
        },
        .invalid => |text| {
            try w.writeAll("<p class=\"notice bad\">Nothing was saved; the settings did not parse:</p><pre>");
            try utils.writeHtml(w, text);
            try w.writeAll("</pre>\n");
        },
        .saved => |path| {
            try w.writeAll("<p class=\"notice good\">Saved to <code>");
            try utils.writeHtml(w, path);
            try w.writeAll("</code>. Capsper is restarting; reload in a moment.</p>\n");
        },
        .unwritable => |u| {
            try w.writeAll("<p class=\"notice bad\">");
            if (u.path) |p| {
                try w.writeAll("<code>");
                try utils.writeHtml(w, p);
                try w.writeAll("</code> cannot be written");
            } else {
                try w.writeAll("There is nowhere to save these");
            }
            try w.writeAll(
                \\ — on NixOS the settings are a read-only store path, built
                \\ from your configuration. Nothing has changed here, and
                \\ capsper is still running. Put this where that file comes
                \\ from and rebuild:</p>
                \\<pre class="zon">
            );
            try utils.writeHtml(w, u.zon);
            try w.writeAll("</pre>\n");
        },
    }
}

/// Read the posted form, and act on it.
///
/// The reply is written before anything is torn down, and it is a whole page
/// rather than a redirect, because in the case that matters most -- a config
/// path that cannot be written -- the reply is the only copy of what the form
/// produced. A redirect would lose it.
fn saveSettings(state: *State, request: *http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var read_buf: [8 * 1024]u8 = undefined;
    // `readerExpectContinue` and not `readerExpectNone`. The other one asserts
    // the request carried no `Expect` header, and an assertion here is not a
    // rejected request -- it is the whole process going down, dictation and a
    // meeting in progress with it. A client is entitled to send
    // `Expect: 100-continue`, and curl does so by default once a body passes a
    // kilobyte, which this form does comfortably. So the handshake is answered
    // rather than assumed away.
    const reader = request.readerExpectContinue(&read_buf) catch
        return request.respond("cannot read the form\n", .{ .status = .bad_request });
    // A form of a few dozen fields. Generous, and bounded, because this is
    // reachable from wherever the server is bound.
    const body = reader.allocRemaining(arena, .limited(256 * 1024)) catch
        return request.respond("form too large\n", .{ .status = .payload_too_large });

    var values = try settings_form.parseBody(arena, body);

    var zon: std.Io.Writer.Allocating = .init(arena);
    if (try settings_form.writeZon(&values, &zon.writer)) |problem| {
        return settingsPage(state, request, .{ .rejected = problem });
    }
    const text = zon.written();

    // Through the same parser a hand-written file goes through. Every value
    // was already checked against its own field's type, so this should not
    // fail -- and if it ever does, that is a bug in the walk above and the
    // diagnostic is worth more than a tidy message.
    const source = try arena.dupeZ(u8, text);
    var diag: std.zon.parse.Diagnostics = .{};
    const parsed = config.parse(arena, source, &diag) catch {
        var report: std.Io.Writer.Allocating = .init(arena);
        report.writer.print("{f}", .{diag}) catch {};
        return settingsPage(state, request, .{ .invalid = report.written() });
    };

    // The text that reaches the file is written by `config_docs`, not by the
    // form walk above. That is what a form submits every field it was given,
    // ticked or not, and a file listing all of them would freeze today's
    // defaults into it -- so a later change to one would reach new users and
    // silently miss everyone who had ever pressed Save. The same writer
    // `--write-config` uses names only what differs, and puts each setting's
    // description above it.
    var settled: std.Io.Writer.Allocating = .init(arena);
    try config_docs.write(&parsed, &settled.writer);
    const file_text = settled.written();

    const path = state.config_path orelse
        return settingsPage(state, request, .{ .unwritable = .{ .path = null, .zon = file_text } });

    writeConfigFile(path, file_text) catch |err| {
        log.warn("cannot write settings to '{s}': {}", .{ path, err });
        return settingsPage(state, request, .{ .unwritable = .{ .path = path, .zon = file_text } });
    };

    // The confirmation goes first, because everything after it ends the
    // process and a browser that never saw the reply would be left looking at
    // a connection that died mid-save.
    //
    // Its failure is not allowed to cancel the restart, though. The file is
    // already written; a client that closed the tab between the write and the
    // reply would otherwise leave this process serving the old settings while
    // the file on disk says something else, until some unrelated restart
    // months later applied a change nobody remembers making. Whether anyone is
    // still listening is not what decides this.
    settingsPage(state, request, .{ .saved = path }) catch |err| {
        log.warn("settings saved, but the reply did not reach the client: {}", .{err});
    };

    status.stop_requested.store(true, .release);
    waitForMeetingToClose();
    std.process.exit(0);
}

/// Replace the settings file's contents.
///
/// Written to a neighbour and renamed over the top, so a reader -- the next
/// capsper, started by the service manager seconds from now -- never sees a
/// half-written file. The directory is created if it is not there, which is
/// the ordinary case the first time anyone saves.
fn writeConfigFile(path: []const u8, text: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    var dir = try std.fs.cwd().makeOpenPath(dir_path, .{});
    defer dir.close();

    const name = std.fs.path.basename(path);
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_buf, ".{s}.tmp", .{name});

    {
        var file = try dir.createFile(tmp_name, .{ .truncate = true });
        defer file.close();
        try file.writeAll(text);
    }
    errdefer dir.deleteFile(tmp_name) catch {};
    try dir.rename(tmp_name, name);
}

/// Give a meeting in progress the chance to finish its file.
///
/// The flag is set; the meeting loop notices it between chunks, closes the
/// session the way an idle timeout would, and says so. Waiting here means the
/// recording of a call that happened to be running is a complete file rather
/// than one that stops mid-word.
///
/// Bounded, because a save that never returns is worse than a recording that
/// loses its last second: if the meeting thread is wedged, leaving is still
/// the right answer.
fn waitForMeetingToClose() void {
    const deadline_ms = 15_000;
    var waited: u64 = 0;
    while (status.meeting.open.load(.acquire) and waited < deadline_ms) : (waited += 50) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

// ─── Debug recordings ────────────────────────────────────────────────────────

/// One of the last few dictated utterances kept on disk, which is a different
/// shape of thing from a meeting: no dated directory, one flat name, and no
/// far end -- there was only ever a microphone.
const Recording = struct {
    /// The number the ring gave it, which is also its filename stem.
    id: []const u8,
    audio: []const u8,
    seconds: f64,
    /// When it was written, in seconds. The page shows it because the number
    /// says nothing about when: the ring reuses the low ones first.
    modified: i64,
};

fn recordingsJson(state: *State, request: *http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(state.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.ArrayListUnmanaged(u8) = .{};
    const w = body.writer(arena);

    // Whether debug recording is configured at all, so the page can say "it
    // is off" rather than "there are none" -- which are different answers to
    // different questions and look identical in an empty list.
    const root = state.cfg.debug_recording.dir;
    try w.print("{{\"enabled\":{s},\"items\":[", .{if (root != null) "true" else "false"});

    if (root) |dir_path| {
        const found = collectDebug(arena, dir_path) catch &[_]Recording{};
        for (found, 0..) |r, i| {
            if (i > 0) try w.writeByte(',');
            // Every field is this walk's own: a stem of digits, a name from a
            // fixed list, and two numbers.
            try w.print(
                "{{\"id\":\"{s}\",\"audio\":\"{s}\",\"seconds\":{d:.2},\"modified\":{d}}}",
                .{ r.id, r.audio, r.seconds, r.modified },
            );
        }
    }
    try w.writeAll("]}");

    return request.respond(body.items, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

/// Whether a name is one the recorder wrote: three digits and an extension it
/// records in. Named exactly, for the same reason the session walk names its
/// audio file exactly -- a debug directory is a directory like any other and
/// may have anything else in it.
fn isDebugRecording(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const stem = name[0..dot];
    if (stem.len != 3) return false;
    for (stem) |c| if (!std.ascii.isDigit(c)) return false;

    const ext = name[dot..];
    for ([_][]const u8{ ".wav", ".opus" }) |known| {
        if (std.mem.eql(u8, ext, known)) return true;
    }
    return false;
}

/// Every debug recording, most recently written first.
///
/// By modification time, and this is the one thing about them worth knowing:
/// the recorder numbers them `seq % keep`, so the ring wraps and `003.wav` is
/// routinely newer than `009.wav`. The name sorts a session directory
/// correctly because a session's name is a timestamp. Here it means nothing.
fn collectDebug(arena: std.mem.Allocator, root: []const u8) ![]Recording {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    const Timed = struct { rec: Recording, mtime: i128 };
    var found: std.ArrayListUnmanaged(Timed) = .{};

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isDebugRecording(entry.name)) continue;

        const st = dir.statFile(entry.name) catch continue;
        const name = try arena.dupe(u8, entry.name);
        try found.append(arena, .{
            .rec = .{
                .id = name[0..3],
                .audio = name,
                .seconds = durationSeconds(dir, name),
                .modified = @intCast(@divTrunc(st.mtime, std.time.ns_per_s)),
            },
            .mtime = st.mtime,
        });
    }

    std.mem.sort(Timed, found.items, {}, struct {
        fn newestFirst(_: void, a: Timed, b: Timed) bool {
            return a.mtime > b.mtime;
        }
    }.newestFirst);

    const out = try arena.alloc(Recording, found.items.len);
    for (found.items, 0..) |t, i| out[i] = t.rec;
    return out;
}

// ─── Serving a recording's files ─────────────────────────────────────────────

fn sessionFile(state: *State, request: *http.Server.Request, rel: []const u8) !void {
    return serveFile(request, state.cfg.meeting.dir, rel);
}

/// A debug recording's audio or transcript.
///
/// A different root and otherwise the same job, so it is the same function.
/// The prefix in the request picks the root before anything opens a directory,
/// and `isSafe` refuses to leave whichever one was picked -- so `/d/` cannot
/// be walked into the sessions tree, or the other way about, by any path.
fn debugFile(state: *State, request: *http.Server.Request, rel: []const u8) !void {
    const root = state.cfg.debug_recording.dir orelse
        return request.respond("not found\n", .{ .status = .not_found });
    return serveFile(request, root, rel);
}

fn serveFile(request: *http.Server.Request, root: []const u8, rel: []const u8) !void {
    if (!isSafe(rel)) return request.respond("no\n", .{ .status = .forbidden });

    var dir = std.fs.cwd().openDir(root, .{}) catch
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
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
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

fn escaped(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    try writeEscaped(buf.writer(gpa), text);
    return buf.toOwnedSlice(gpa);
}

test "a device name cannot close the tag it is written into" {
    // A PipeWire node name is whatever the device said it was, and it lands in
    // the middle of this page's markup. Nothing here is trusted to be inert.
    const out = try escaped(testing.allocator, "<script>alert('x')</script>");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;",
        out,
    );
}

test "an ampersand is escaped once, not twice" {
    const out = try escaped(testing.allocator, "a&b");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a&amp;b", out);
}

test "an ordinary node name comes through untouched" {
    const name = "alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source";
    const out = try escaped(testing.allocator, name);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(name, out);
}

fn duration(gpa: std.mem.Allocator, seconds: f64) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    try writeDuration(buf.writer(gpa), seconds);
    return buf.toOwnedSlice(gpa);
}

test "a length of time is said the way a person would say it" {
    const cases = [_]struct { secs: f64, want: []const u8 }{
        .{ .secs = 0, .want = "0s" },
        .{ .secs = 42.7, .want = "42s" },
        .{ .secs = 60, .want = "1m 0s" },
        .{ .secs = 154, .want = "2m 34s" },
        .{ .secs = 3600, .want = "1h 0m" },
        .{ .secs = 7_845, .want = "2h 10m" },
        // A clock that went backwards is not a negative duration.
        .{ .secs = -5, .want = "0s" },
    };
    for (cases) |c| {
        const out = try duration(testing.allocator, c.secs);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "a debug recording is three digits and an extension the recorder writes" {
    try testing.expect(isDebugRecording("003.wav"));
    try testing.expect(isDebugRecording("000.wav"));
    try testing.expect(isDebugRecording("009.opus"));

    // The transcript beside it is not the thing to play, same as a session's.
    try testing.expect(!isDebugRecording("003.vtt"));
    // Nor is anything else that happens to be in the directory.
    try testing.expect(!isDebugRecording("3.wav"));
    try testing.expect(!isDebugRecording("0003.wav"));
    try testing.expect(!isDebugRecording("notes.wav"));
    try testing.expect(!isDebugRecording("00a.wav"));
    try testing.expect(!isDebugRecording("003"));
    try testing.expect(!isDebugRecording(".wav"));
}

test "debug recordings are ordered by when they were written, not by their number" {
    // The regression this exists for. The recorder numbers by `seq % keep`, so
    // after the ring wraps the newest file has the lowest number -- and the
    // lexicographic order that is correct for a dated session directory puts
    // it last. Real files with real timestamps, because the ordering is a
    // property of the filesystem rather than of a struct.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Written oldest first, deliberately out of numeric order.
    for ([_][]const u8{ "009.wav", "000.wav", "004.wav" }) |name| {
        var f = try tmp.dir.createFile(name, .{});
        f.close();
        // A whole second apart, so the comparison cannot turn on timer
        // resolution. Slow for a unit test and the only way to be sure.
        std.Thread.sleep(std.time.ns_per_s + std.time.ns_per_ms * 50);
    }
    // Something else in the directory, to prove the walk is an allowlist.
    var vtt = try tmp.dir.createFile("004.vtt", .{});
    vtt.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = try tmp.dir.realpathAlloc(arena, ".");
    const found = try collectDebug(arena, path);

    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("004", found[0].id);
    try testing.expectEqualStrings("000", found[1].id);
    try testing.expectEqualStrings("009", found[2].id);
    try testing.expectEqualStrings("004.wav", found[0].audio);
}

test "a path that climbs out of the sessions directory is refused" {
    try testing.expect(!isSafe("../../etc/passwd"));
    try testing.expect(!isSafe("2026/../../../etc/passwd"));
    try testing.expect(!isSafe("/etc/passwd"));
    try testing.expect(!isSafe("2026//audio.wav"));
    try testing.expect(!isSafe("."));
    try testing.expect(!isSafe(""));
}

test "only the recording is listed as a session, not what sits beside it" {
    try testing.expect(isAudio("audio.wav"));
    try testing.expect(isAudio("audio.opus"));
    try testing.expect(!isAudio("audio.vtt"));
    try testing.expect(!isAudio("audio.json"));
    try testing.expect(!isAudio("notes.txt"));
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
    try testing.expectEqualStrings("application/json", contentType("2026/x/audio.json"));
    try testing.expectEqualStrings("audio/wav", contentType("2026/x/audio.wav"));
    try testing.expectEqualStrings("audio/ogg", contentType("2026/x/audio.opus"));
}
