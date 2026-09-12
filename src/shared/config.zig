// src/shared/config.zig — the settings capsper runs on, and the two ways to say them.
//
// There is one settings type, `Config`. A ZON file fills it in, then command
// line flags overwrite whatever they name, so a flag always wins for one run.
// That ordering is the whole merge strategy: because the file is parsed first
// and the flags are applied on top of the same struct, no "was this flag
// given?" bookkeeping is needed anywhere.
//
// ZON rather than JSON because a hand-edited file needs comments, and
// `std.zon.parse` puts the schema in the type: an unknown field or a mistyped
// enum literal is a parse error with a line number rather than a silent
// default. `build.zig.zon` is already ZON, so this is one format to know.
//
// One-shot commands (--version, --transcribe FILE, ...) are not settings and
// live in `Cli`. A config file describes a running service; it has no business
// saying "and also, exit after printing the version".

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Audio file container, selectable per output path.
pub const AudioFormat = enum { wav, opus };

/// How much diagnostic detail a transcript carries. `.debug` adds the NOTE
/// blocks holding per-cycle decoder state; `.minimal` writes cues only.
pub const Detail = enum { minimal, debug };

/// What to do when the capture device disappears.
pub const OnDeviceLost = enum { wait, exit };

/// Keys that can be held to talk. Not every key exists on every platform --
/// `pause` and `f21`-`f24` are Linux only -- so the mapping to a real keycode
/// is the platform's job and can still fail; see `platform/input.zig`.
pub const TriggerKey = enum {
    capslock,
    scrolllock,
    numlock,
    pause,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
};

/// Which channel of the capture device to listen to.
///
/// Generated rather than written out because the 64 AUX positions are
/// otherwise 64 lines of noise around the three that anyone types. The tag
/// names are what matter: `@tagName` feeds the platform's existing
/// `parseChannelName`, so this enum adds ZON's compile-time checking without
/// a second copy of the name-to-position mapping.
pub const Channel = blk: {
    const named = [_][:0]const u8{ "MONO", "FL", "FR" };
    var fields: [named.len + 64]std.builtin.Type.EnumField = undefined;
    for (named, 0..) |name, i| fields[i] = .{ .name = name, .value = i };
    for (0..64) |n| {
        // Spelled out rather than formatted: `comptimePrint` 64 times costs
        // more comptime branches than the whole rest of this file.
        const name: [:0]const u8 = if (n < 10)
            &[_:0]u8{ 'A', 'U', 'X', '0' + n }
        else
            &[_:0]u8{ 'A', 'U', 'X', '0' + n / 10, '0' + n % 10 };
        fields[named.len + n] = .{ .name = name, .value = named.len + n };
    }
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u8,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const Audio = struct {
    /// Capture device node name. Null follows the desktop's default input.
    target: ?[:0]const u8 = null,
    channel: Channel = .FL,
    gain: f32 = 1.0,
    auto_gain: bool = true,
    on_device_lost: OnDeviceLost = .wait,
    detect_duration: u32 = 5,
};

pub const Trigger = struct {
    /// Push-to-talk key. Null disables push-to-talk.
    key: ?TriggerKey = null,
    passthrough: bool = false,
    /// Named for its unit, because a bare number in a file has no usage text
    /// beside it to say what the number means.
    type_delay_us: u64 = 12_000,
    low_latency: bool = false,
};

pub const TcpServer = struct {
    /// Null means no server. Zero means an OS-assigned port.
    port: ?u16 = null,
};

pub const DebugRecording = struct {
    /// Null disables recording.
    dir: ?[:0]const u8 = null,
    /// Ring size: recordings are numbered `seq % keep`, so the last `keep`
    /// survive and older ones are overwritten.
    keep: usize = 10,
    /// WAV here because these are seconds long, ring-bounded, and regression
    /// comparisons want the raw samples.
    audio_format: AudioFormat = .wav,
    detail: Detail = .debug,
};

/// Browsing and playing back recorded sessions.
pub const MeetingHttp = struct {
    /// Null disables the server. Runs whenever meeting capture is on, because
    /// a pile of session directories you have to find yourself is not much of
    /// a feature.
    port: ?u16 = 43008,
    /// Loopback only by default. These are recordings of private
    /// conversations; reaching them from the network should take saying so.
    bind: [:0]const u8 = "127.0.0.1",
};

pub const Meeting = struct {
    enabled: bool = false,
    /// The name this appears under in the desktop's output picker.
    sink_name: [:0]const u8 = "capsper_call",
    dir: [:0]const u8 = "~/.local/share/capsper/sessions",
    /// Opus here because these are hours of audio, kept indefinitely.
    audio_format: AudioFormat = .opus,
    /// How long a sink can sit idle before the session is closed. Long enough
    /// to survive a screen-share renegotiation or a brief mute.
    idle_close_seconds: u32 = 30,
    detail: Detail = .minimal,
    http: MeetingHttp = .{},
};

pub const Config = struct {
    /// Null resolves to `../models/nemotron` relative to the binary, which is
    /// what makes an unpacked dist tarball run without configuring anything.
    model: ?[:0]const u8 = null,
    verbose: bool = false,
    drop_terms: ?[:0]const u8 = null,

    audio: Audio = .{},
    trigger: Trigger = .{},
    tcp_server: TcpServer = .{},
    debug_recording: DebugRecording = .{},
    meeting: Meeting = .{},

    /// Expand a leading `~/` in every field that names a path. Done once,
    /// after the file and the flags have both been applied, so nothing
    /// downstream has to remember which strings are paths.
    ///
    /// `audio.target` is deliberately absent: it is a PipeWire node name, not
    /// a path, and a node is entitled to a leading tilde.
    pub fn expandPaths(self: *Config, arena: Allocator) !void {
        self.model = try expandTilde(arena, self.model);
        self.drop_terms = try expandTilde(arena, self.drop_terms);
        self.debug_recording.dir = try expandTilde(arena, self.debug_recording.dir);
        self.meeting.dir = (try expandTilde(arena, self.meeting.dir)).?;
    }
};

/// One-shot actions and the config location. None of these are settings, so
/// none of them appear in the file.
pub const Cli = struct {
    config_path: ?[:0]const u8 = null,
    show_version: bool = false,
    dry_run: bool = false,
    audio_detect: bool = false,
    stream: ?[:0]const u8 = null,
    transcribe: ?[:0]const u8 = null,
};

// ─── Argument parsing ────────────────────────────────────────────────────────

/// A flag that could not be understood. Returned rather than printed so the
/// parser stays quiet in tests; `reportArgError` does the formatting.
pub const ArgError = struct {
    kind: Kind,
    flag: []const u8,
    value: []const u8,

    pub const Kind = enum {
        invalid_channel,
        invalid_trigger_key,
        invalid_on_device_lost,
        invalid_number,
    };
};

/// Find `--config PATH` and nothing else.
///
/// Separate from `parseArgs` because the config file has to be read before the
/// flags are applied over it, and running the whole parser twice would warn
/// about every unknown flag twice.
pub fn configPathFromArgs(args: []const [:0]const u8) ?[:0]const u8 {
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 1) {
        if (eql(args[i], "--config")) return args[i + 1];
    }
    return null;
}

/// Apply command line flags over `cfg`, which should already hold whatever the
/// config file said. Returns the first flag that could not be understood, or
/// null if every flag was applied.
///
/// Unknown flags are a warning rather than an error, and always have been: old
/// service files carry flags that no longer exist, and refusing to start is a
/// worse answer than ignoring them.
pub fn parseArgs(cfg: *Config, cli: *Cli, args: []const [:0]const u8) ?ArgError {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Flags taking a value. `value` is null at the end of the argument
        // list, in which case the flag is ignored rather than misreading the
        // next flag as its argument.
        const value: ?[:0]const u8 = if (i + 1 < args.len) args[i + 1] else null;

        if (eql(arg, "--version")) {
            cli.show_version = true;
        } else if (eql(arg, "--verbose") or eql(arg, "-v")) {
            cfg.verbose = true;
        } else if (eql(arg, "--dry-run")) {
            cli.dry_run = true;
        } else if (eql(arg, "--audio-detect") or eql(arg, "--pw-detect")) {
            cli.audio_detect = true;
        } else if (eql(arg, "--trigger-passthrough")) {
            cfg.trigger.passthrough = true;
        } else if (eql(arg, "--low-latency")) {
            cfg.trigger.low_latency = true;
        } else if (eql(arg, "--no-auto-gain")) {
            cfg.audio.auto_gain = false;
        } else if (eql(arg, "--config")) {
            if (value) |v| cli.config_path = v;
            i += 1;
        } else if (eql(arg, "--model") or eql(arg, "-m")) {
            if (value) |v| cfg.model = v;
            i += 1;
        } else if (eql(arg, "--drop-terms")) {
            if (value) |v| cfg.drop_terms = v;
            i += 1;
        } else if (eql(arg, "--stream") or eql(arg, "--stream-wav")) {
            if (value) |v| cli.stream = v;
            i += 1;
        } else if (eql(arg, "--transcribe")) {
            if (value) |v| cli.transcribe = v;
            i += 1;
        } else if (eql(arg, "--audio-target") or eql(arg, "--pw-target")) {
            if (value) |v| cfg.audio.target = v;
            i += 1;
        } else if (eql(arg, "--record-dir")) {
            if (value) |v| cfg.debug_recording.dir = v;
            i += 1;
        } else if (eql(arg, "--port") or eql(arg, "-p")) {
            if (value) |v| cfg.tcp_server.port = parseNum(u16, v) orelse
                return .{ .kind = .invalid_number, .flag = arg, .value = v };
            i += 1;
        } else if (eql(arg, "--type-delay")) {
            if (value) |v| cfg.trigger.type_delay_us = parseNum(u64, v) orelse
                return .{ .kind = .invalid_number, .flag = arg, .value = v };
            i += 1;
        } else if (eql(arg, "--detect-duration")) {
            if (value) |v| cfg.audio.detect_duration = parseNum(u32, v) orelse
                return .{ .kind = .invalid_number, .flag = arg, .value = v };
            i += 1;
        } else if (eql(arg, "--record-keep")) {
            if (value) |v| cfg.debug_recording.keep = parseNum(usize, v) orelse
                return .{ .kind = .invalid_number, .flag = arg, .value = v };
            i += 1;
        } else if (eql(arg, "--audio-gain") or eql(arg, "--pw-gain")) {
            if (value) |v| cfg.audio.gain = std.fmt.parseFloat(f32, v) catch
                return .{ .kind = .invalid_number, .flag = arg, .value = v };
            i += 1;
        } else if (eql(arg, "--audio-channel") or eql(arg, "--pw-channel")) {
            if (value) |v| cfg.audio.channel = parseChannel(v) orelse
                return .{ .kind = .invalid_channel, .flag = arg, .value = v };
            i += 1;
        } else if (eql(arg, "--trigger")) {
            if (value) |v| cfg.trigger.key = parseTriggerKey(v) orelse
                return .{ .kind = .invalid_trigger_key, .flag = arg, .value = v };
            i += 1;
        } else if (eql(arg, "--on-device-lost")) {
            if (value) |v| cfg.audio.on_device_lost = parseOnDeviceLost(v) orelse
                return .{ .kind = .invalid_on_device_lost, .flag = arg, .value = v };
            i += 1;
        } else {
            std.debug.print("Warning: unknown option '{s}' will be ignored\n", .{arg});
            // Skip what looks like this flag's argument, so an unrecognised
            // `--foo bar` does not then warn about `bar` as well.
            if (value) |v| {
                if (v.len > 0 and v[0] != '-') i += 1;
            }
        }
    }
    return null;
}

/// Print an unparseable flag the way the old inline checks did, including the
/// list of what would have been accepted.
pub fn reportArgError(err: ArgError) void {
    switch (err.kind) {
        .invalid_channel => {
            std.debug.print("Invalid channel value '{s}'\n", .{err.value});
            std.debug.print("Expected: MONO, FL, FR, AUX0-AUX63\n", .{});
        },
        .invalid_trigger_key => {
            std.debug.print("Unknown trigger key '{s}'\n", .{err.value});
            std.debug.print("Supported: capslock, scrolllock, numlock, pause, f13-f24\n", .{});
        },
        .invalid_on_device_lost => {
            std.debug.print("Invalid --on-device-lost value '{s}', expected 'exit' or 'wait'\n", .{err.value});
        },
        .invalid_number => {
            std.debug.print("Invalid {s} value '{s}': expected a number\n", .{ err.flag, err.value });
        },
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseNum(comptime T: type, text: []const u8) ?T {
    return std.fmt.parseInt(T, text, 10) catch null;
}

/// Case-insensitive so `--audio-channel fl` keeps working; the enum tag itself
/// is upper case because that is how channels are written everywhere else.
pub fn parseChannel(name: []const u8) ?Channel {
    inline for (@typeInfo(Channel).@"enum".fields) |f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

pub fn parseTriggerKey(name: []const u8) ?TriggerKey {
    inline for (@typeInfo(TriggerKey).@"enum".fields) |f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

fn parseOnDeviceLost(name: []const u8) ?OnDeviceLost {
    if (eql(name, "wait")) return .wait;
    if (eql(name, "exit")) return .exit;
    return null;
}

// ─── Loading ─────────────────────────────────────────────────────────────────

/// Parse ZON source into a `Config`. Every field has a default, so a file
/// naming one setting is valid and the rest stay as they are here.
///
/// Unknown fields are deliberately an error: a typo that silently did nothing
/// is the failure mode a config file exists to avoid.
///
/// `arena` must be an arena, and the returned config is only valid for as long
/// as it is. A `Config` mixes allocated strings with the static defaults of
/// whichever fields the file left out, and nothing in the value records which
/// is which -- so `std.zon.parse.free` would try to free a string literal.
/// Freeing the arena sidesteps that distinction entirely.
pub fn parse(
    arena: Allocator,
    source: [:0]const u8,
    diag: ?*std.zon.parse.Diagnostics,
) !Config {
    return std.zon.parse.fromSlice(Config, arena, source, diag, .{});
}

/// Read and parse a config file. Returns null if the file is not there, which
/// is not an error -- it means defaults.
///
/// Parse failures print the diagnostic, which carries a line and column, and
/// are returned as errors: a config that does not mean what it says should
/// stop the service rather than start it with silent defaults.
pub fn load(arena: Allocator, path: []const u8) !?Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const source = try file.readToEndAllocOptions(arena, 1024 * 1024, null, .of(u8), 0);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena);
    return parse(arena, source, &diag) catch |err| {
        std.debug.print("{s}:\n{f}", .{ path, diag });
        return err;
    };
}
/// Where the config lives when `--config` does not say otherwise:
/// `$XDG_CONFIG_HOME/capsper/config.zon`, falling back to the base directory
/// spec's own default of `~/.config` when that variable is unset.
///
/// Returns null when neither variable is set, which means there is nowhere to
/// look and therefore nothing to read.
pub fn defaultPath(arena: Allocator) !?[:0]const u8 {
    if (std.process.getEnvVarOwned(arena, "XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return try std.fs.path.joinZ(arena, &.{ xdg, "capsper", "config.zon" });
    } else |_| {}

    if (std.process.getEnvVarOwned(arena, "HOME")) |home| {
        if (home.len > 0) return try std.fs.path.joinZ(arena, &.{ home, ".config", "capsper", "config.zon" });
    } else |_| {}

    return null;
}

/// Expand a leading `~/` against `$HOME`. A bare `~` with nothing after it is
/// left alone: it is far more likely to be a real relative filename than an
/// attempt to name the home directory.
fn expandTilde(arena: Allocator, path: ?[:0]const u8) !?[:0]const u8 {
    const p = path orelse return null;
    if (!std.mem.startsWith(u8, p, "~/")) return p;

    const home = std.process.getEnvVarOwned(arena, "HOME") catch return p;
    return try std.fs.path.joinZ(arena, &.{ home, p[2..] });
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parse ZON in a throwaway arena, the way `main` does. Callers keep the
/// arena alive for as long as they use the result.
fn parseIn(arena: *std.heap.ArenaAllocator, source: [:0]const u8) !Config {
    return parse(arena.allocator(), source, null);
}

/// Build the `[]const [:0]const u8` that `parseArgs` wants out of string
/// literals, including the argv[0] it skips.
fn argv(comptime items: []const [:0]const u8) []const [:0]const u8 {
    return items;
}

test "defaults match the documented schema" {
    const cfg = Config{};
    try testing.expect(cfg.model == null);
    try testing.expect(!cfg.verbose);
    try testing.expectEqual(Channel.FL, cfg.audio.channel);
    try testing.expectEqual(@as(f32, 1.0), cfg.audio.gain);
    try testing.expect(cfg.audio.auto_gain);
    try testing.expectEqual(OnDeviceLost.wait, cfg.audio.on_device_lost);
    try testing.expect(cfg.trigger.key == null);
    try testing.expectEqual(@as(u64, 12_000), cfg.trigger.type_delay_us);
    try testing.expect(cfg.tcp_server.port == null);
    try testing.expectEqual(AudioFormat.wav, cfg.debug_recording.audio_format);
    try testing.expectEqual(AudioFormat.opus, cfg.meeting.audio_format);
    try testing.expect(!cfg.meeting.enabled);
}

test "an empty file leaves every default in place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseIn(&arena, ".{}");
    try testing.expectEqual(Config{}, cfg);
}

test "a file naming one setting leaves the rest alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseIn(&arena, ".{ .verbose = true }");
    try testing.expect(cfg.verbose);
    try testing.expectEqual(Channel.FL, cfg.audio.channel);
}

test "nested groups and enum literals parse" {
    const source =
        \\.{
        \\    // Comments are the reason this is ZON and not JSON.
        \\    .audio = .{ .channel = .FR, .gain = 2.5, .on_device_lost = .exit },
        \\    .trigger = .{ .key = .f13, .low_latency = true },
        \\    .tcp_server = .{ .port = 43007 },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseIn(&arena, source);

    try testing.expectEqual(Channel.FR, cfg.audio.channel);
    try testing.expectEqual(@as(f32, 2.5), cfg.audio.gain);
    try testing.expectEqual(OnDeviceLost.exit, cfg.audio.on_device_lost);
    try testing.expectEqual(TriggerKey.f13, cfg.trigger.key.?);
    try testing.expect(cfg.trigger.low_latency);
    try testing.expectEqual(@as(u16, 43007), cfg.tcp_server.port.?);
}

test "strings parse and keep their sentinel" {
    const source =
        \\.{
        \\    .model = "/opt/models/nemotron",
        \\    .audio = .{ .target = "my-mic" },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseIn(&arena, source);

    try testing.expectEqualStrings("/opt/models/nemotron", cfg.model.?);
    try testing.expectEqualStrings("my-mic", cfg.audio.target.?);
    try testing.expectEqual(@as(u8, 0), cfg.model.?[cfg.model.?.len]);
}

test "an unknown field is an error rather than a silent default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ParseZon, parseIn(&arena, ".{ .verbos = true }"));
}

test "a mistyped enum literal is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ParseZon, parseIn(&arena, ".{ .audio = .{ .channel = .FRONT_LEFT } }"));
}

test "a parse error reports a line and column" {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    const source =
        \\.{
        \\    .verbose = false,
        \\    .nonsense = 1,
        \\}
    ;
    try testing.expectError(error.ParseZon, parse(testing.allocator, source, &diag));

    var buf: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try testing.expect(std.mem.startsWith(u8, rendered, "3:"));
}

test "AUX channels exist across the full range" {
    try testing.expectEqual(Channel.AUX0, parseChannel("AUX0").?);
    try testing.expectEqual(Channel.AUX63, parseChannel("aux63").?);
    try testing.expect(parseChannel("AUX64") == null);
    try testing.expectEqualStrings("AUX7", @tagName(Channel.AUX7));
}

test "channel and trigger names parse case-insensitively" {
    try testing.expectEqual(Channel.FL, parseChannel("fl").?);
    try testing.expectEqual(Channel.MONO, parseChannel("Mono").?);
    try testing.expectEqual(TriggerKey.capslock, parseTriggerKey("CapsLock").?);
    try testing.expect(parseTriggerKey("shift") == null);
}

test "flags set every setting they name" {
    var cfg = Config{};
    var cli = Cli{};
    const err = parseArgs(&cfg, &cli, argv(&.{
        "capsper",
        "--trigger",         "capslock",
        "--audio-target",    "my-mic",
        "--audio-channel",   "FR",
        "--audio-gain",      "2.0",
        "--no-auto-gain",
        "--on-device-lost",  "exit",
        "--port",            "43007",
        "--type-delay",      "5000",
        "--record-dir",      "/tmp/rec",
        "--record-keep",     "3",
        "--detect-duration", "9",
        "--drop-terms",      "drop.txt",
        "--model",           "/opt/m",
        "--low-latency",
        "--trigger-passthrough",
        "--verbose",
    }));
    try testing.expect(err == null);

    try testing.expectEqual(TriggerKey.capslock, cfg.trigger.key.?);
    try testing.expectEqualStrings("my-mic", cfg.audio.target.?);
    try testing.expectEqual(Channel.FR, cfg.audio.channel);
    try testing.expectEqual(@as(f32, 2.0), cfg.audio.gain);
    try testing.expect(!cfg.audio.auto_gain);
    try testing.expectEqual(OnDeviceLost.exit, cfg.audio.on_device_lost);
    try testing.expectEqual(@as(u16, 43007), cfg.tcp_server.port.?);
    try testing.expectEqual(@as(u64, 5000), cfg.trigger.type_delay_us);
    try testing.expectEqualStrings("/tmp/rec", cfg.debug_recording.dir.?);
    try testing.expectEqual(@as(usize, 3), cfg.debug_recording.keep);
    try testing.expectEqual(@as(u32, 9), cfg.audio.detect_duration);
    try testing.expectEqualStrings("drop.txt", cfg.drop_terms.?);
    try testing.expectEqualStrings("/opt/m", cfg.model.?);
    try testing.expect(cfg.trigger.low_latency);
    try testing.expect(cfg.trigger.passthrough);
    try testing.expect(cfg.verbose);
}

test "the pw aliases still mean what they always did" {
    var cfg = Config{};
    var cli = Cli{};
    const err = parseArgs(&cfg, &cli, argv(&.{
        "capsper",
        "--pw-target",  "mic",
        "--pw-channel", "MONO",
        "--pw-gain",    "3.0",
        "--pw-detect",
    }));
    try testing.expect(err == null);
    try testing.expectEqualStrings("mic", cfg.audio.target.?);
    try testing.expectEqual(Channel.MONO, cfg.audio.channel);
    try testing.expectEqual(@as(f32, 3.0), cfg.audio.gain);
    try testing.expect(cli.audio_detect);
}

test "a flag overrides what the file said" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg = try parseIn(&arena, ".{ .audio = .{ .gain = 4.0, .channel = .FR } }");

    var cli = Cli{};
    const err = parseArgs(&cfg, &cli, argv(&.{ "capsper", "--audio-gain", "1.5" }));
    try testing.expect(err == null);

    try testing.expectEqual(@as(f32, 1.5), cfg.audio.gain);
    // Untouched by the flags, so the file still wins here.
    try testing.expectEqual(Channel.FR, cfg.audio.channel);
}

test "one-shot commands land in Cli, not Config" {
    var cfg = Config{};
    var cli = Cli{};
    const err = parseArgs(&cfg, &cli, argv(&.{
        "capsper", "--dry-run", "--transcribe", "a.wav", "--config", "/etc/c.zon", "--version",
    }));
    try testing.expect(err == null);
    try testing.expect(cli.dry_run);
    try testing.expect(cli.show_version);
    try testing.expectEqualStrings("a.wav", cli.transcribe.?);
    try testing.expectEqualStrings("/etc/c.zon", cli.config_path.?);
    try testing.expectEqual(Config{}, cfg);
}

test "configPathFromArgs finds the file without touching anything else" {
    try testing.expectEqualStrings(
        "/etc/c.zon",
        configPathFromArgs(argv(&.{ "capsper", "--verbose", "--config", "/etc/c.zon", "--port", "1" })).?,
    );
    try testing.expect(configPathFromArgs(argv(&.{ "capsper", "--verbose" })) == null);
    // A trailing --config names nothing, so there is nothing to return.
    try testing.expect(configPathFromArgs(argv(&.{ "capsper", "--config" })) == null);
}

test "--stream-wav is still a spelling of --stream" {
    var cfg = Config{};
    var cli = Cli{};
    _ = parseArgs(&cfg, &cli, argv(&.{ "capsper", "--stream-wav", "x.wav" }));
    try testing.expectEqualStrings("x.wav", cli.stream.?);
}

test "an unparseable value names the flag that carried it" {
    var cfg = Config{};
    var cli = Cli{};

    const bad_channel = parseArgs(&cfg, &cli, argv(&.{ "capsper", "--audio-channel", "SIDEWAYS" })).?;
    try testing.expectEqual(ArgError.Kind.invalid_channel, bad_channel.kind);
    try testing.expectEqualStrings("SIDEWAYS", bad_channel.value);

    const bad_key = parseArgs(&cfg, &cli, argv(&.{ "capsper", "--trigger", "escape" })).?;
    try testing.expectEqual(ArgError.Kind.invalid_trigger_key, bad_key.kind);

    const bad_port = parseArgs(&cfg, &cli, argv(&.{ "capsper", "--port", "http" })).?;
    try testing.expectEqual(ArgError.Kind.invalid_number, bad_port.kind);
    try testing.expectEqualStrings("--port", bad_port.flag);

    const bad_mode = parseArgs(&cfg, &cli, argv(&.{ "capsper", "--on-device-lost", "panic" })).?;
    try testing.expectEqual(ArgError.Kind.invalid_on_device_lost, bad_mode.kind);
}

test "a value-taking flag at the end of the line is ignored, not misread" {
    var cfg = Config{};
    var cli = Cli{};
    const err = parseArgs(&cfg, &cli, argv(&.{ "capsper", "--audio-target" }));
    try testing.expect(err == null);
    try testing.expect(cfg.audio.target == null);
}

test "the retired no-ops warn and do not stop anything else applying" {
    var cfg = Config{};
    var cli = Cli{};
    const err = parseArgs(&cfg, &cli, argv(&.{
        "capsper", "--domain-terms", "terms.txt", "--no-warmup", "--verbose",
    }));
    try testing.expect(err == null);
    try testing.expect(cfg.verbose);
}

test "expandPaths rewrites a leading tilde and leaves everything else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = Config{ .model = "~/models/n", .drop_terms = "./drop.txt" };
    try cfg.expandPaths(arena);

    const home = std.process.getEnvVarOwned(arena, "HOME") catch null;
    if (home) |h| {
        try testing.expect(std.mem.startsWith(u8, cfg.model.?, h));
        try testing.expect(std.mem.endsWith(u8, cfg.model.?, "/models/n"));
    }
    try testing.expectEqualStrings("./drop.txt", cfg.drop_terms.?);
}

test "a bare tilde is treated as a filename, not a home directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var cfg = Config{ .model = "~" };
    try cfg.expandPaths(arena_state.allocator());
    try testing.expectEqualStrings("~", cfg.model.?);
}
