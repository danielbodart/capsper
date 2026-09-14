// src/shared/config_docs.zig — the settings, their defaults and what they mean,
// in one place.
//
// `config.zig` holds the settings type, and the doc comment beside each field
// holds the prose describing it. `@typeInfo` can see the first and not the
// second, so `build/gen_config_docs.zig` reads the source at build time and
// hands the prose back as data. This is where the two meet: a walk of the real
// types, with each field's description attached.
//
// Every field in the settings tree must carry a doc comment. A missing one is
// a compile error naming the field, which is what stops the descriptions
// rotting quietly behind the type as fields are added.
//
// What it offers is a walk rather than a table: `sectionType` says whether a
// field groups other settings, and `docFor` hands back the prose beside it.
// `write` below uses both to put the settings out as ZON with each
// description above it, which is what `--write-config` prints and what the
// console writes when it saves a form. `settings_form.zig` uses the same two
// to build that form.
//
// It was a table once -- every setting flattened to a dotted path, built at
// comptime. Both consumers turned out to want the real types rather than a
// description of them: one to compare a value against its default, the other
// to know that a field holds an enum and which tags it has. So the table went
// and the two functions behind it stayed.

const std = @import("std");
const config = @import("config.zig");
const generated = @import("config_field_docs");

const Config = config.Config;

// ─── Reading the tree ────────────────────────────────────────────────────────

/// The struct behind an optional, or null if the field is not one. Optional
/// sections are not a shape the settings use; optional leaves are everywhere.
pub fn sectionType(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"struct" => T,
        else => null,
    };
}

/// `config.Audio` as the generator wrote it: `Audio`.
fn containerName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// The doc comment for one field, or a compile error saying which one is
/// missing. A description that only exists for some fields is worse than none:
/// the gap is invisible until someone reads the output and finds a setting
/// with nothing beside it.
///
/// The body is one `comptime` block rather than plain function code, and that
/// is load bearing. Called from a runtime function, the search would be
/// analysed as a runtime loop whose `return` the compiler cannot prove is
/// reached -- so it would fall through to the `@compileError` every time and
/// report every setting as undocumented, however many doc comments there are.
pub fn docFor(comptime T: type, comptime field_name: []const u8, comptime path: []const u8) []const u8 {
    return comptime found: {
        // A linear scan of every harvested field, once per setting. Small
        // numbers either way, but their product is past the default quota.
        @setEvalBranchQuota(100_000);
        const container = containerName(T);
        for (generated.fields) |f| {
            if (std.mem.eql(u8, f.container, container) and std.mem.eql(u8, f.name, field_name)) {
                if (f.doc.len == 0) break;
                break :found f.doc;
            }
        }
        @compileError("setting '" ++ path ++ "' has no doc comment in config.zig. " ++
            "Every setting needs one: it is what --write-config puts beside it.");
    };
}

// ─── Writing ─────────────────────────────────────────────────────────────────

/// Where a comment line wraps. Narrow enough that an indented setting deep in
/// the tree still fits an eighty column terminal.
const wrap_columns = 76;

/// Write `cfg` as ZON, naming only the settings that differ from their
/// defaults and putting each one's description above it as a comment.
///
/// Only the differences, because a config file should record what you chose.
/// Writing every field out would freeze today's defaults into the file, so a
/// later change to one of them would reach new users and silently miss
/// everyone who had ever run this.
///
/// The structure and the comments are written here and the leaf values by
/// `std.zon.stringify`, because a comment is not something a serializer emits
/// and the escaping of a string or the spelling of an enum literal is not
/// something worth reimplementing.
///
/// Call this before `expandPaths`. Afterwards `~/` has already become an
/// absolute path, and writing that into a file is a worse answer than the
/// tilde the user would have typed.
pub fn write(cfg: *const Config, writer: *std.Io.Writer) !void {
    try writer.writeAll(".{\n");
    try writeFields(Config, cfg.*, .{}, "", 1, writer);
    try writer.writeAll("}\n");
}

/// Whether any setting in `value` differs from `default`, so a section with
/// nothing chosen in it costs no lines.
fn differs(comptime T: type, value: T, default: T) bool {
    return !equal(T, value, default);
}

/// Equality that reads a string as its characters.
///
/// `std.meta.eql` compares a slice by pointer, which was good enough while the
/// only caller was `--write-config` on settings that had just been parsed
/// straight from a file: a default that was never overwritten still pointed at
/// the static default. It stopped being good enough when the console began
/// saving a form, because every value there arrives from a fresh allocation --
/// so every string setting looked changed, and a file would have been written
/// naming all of them.
///
/// That is the failure this whole "only what differs" rule exists to prevent:
/// a file listing every string setting freezes today's defaults into it, and a
/// later change to one reaches new users while silently missing everyone who
/// had ever pressed Save.
fn equal(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .optional => |o| if (a) |av| {
            if (b) |bv| return equal(o.child, av, bv) else return false;
        } else b == null,
        .pointer => |p| if (p.size == .slice and p.child == u8)
            std.mem.eql(u8, a, b)
        else
            std.meta.eql(a, b),
        .@"struct" => |s| inline for (s.fields) |f| {
            if (!equal(f.type, @field(a, f.name), @field(b, f.name))) break false;
        } else true,
        else => a == b,
    };
}

fn writeFields(
    comptime T: type,
    value: T,
    default: T,
    comptime prefix: []const u8,
    comptime depth: usize,
    writer: *std.Io.Writer,
) !void {
    const pad = "    " ** depth;

    inline for (@typeInfo(T).@"struct".fields) |f| {
        const v = @field(value, f.name);
        const d = @field(default, f.name);

        if (differs(f.type, v, d)) {
            const path = if (prefix.len == 0) f.name else prefix ++ "." ++ f.name;
            try writeComment(docFor(T, f.name, path), pad, writer);

            if (sectionType(f.type)) |S| {
                try writer.print("{s}.{s} = .{{\n", .{ pad, f.name });
                try writeFields(S, v, d, path, depth + 1, writer);
                try writer.print("{s}}},\n", .{pad});
            } else {
                try writer.print("{s}.{s} = ", .{ pad, f.name });
                try std.zon.stringify.serialize(v, .{}, writer);
                try writer.writeAll(",\n");
            }
        }
    }
}

/// A description as wrapped `//` lines at the current indent.
fn writeComment(doc: []const u8, comptime pad: []const u8, writer: *std.Io.Writer) !void {
    try writeWrapped(doc, pad ++ "// ", true, writer);
}

/// Text wrapped to `wrap_columns`, with `prefix` before every line.
///
/// Breaks only between words, and lets a word longer than the line stand off
/// the right margin rather than splitting it: the long ones here are node
/// names and paths, and a broken path is worse than a ragged edge.
///
/// `prefix_first` is false where the caller has already put the cursor past
/// the prefix, which is how a flag's first line of description sits beside
/// its name rather than under it.
fn writeWrapped(
    text: []const u8,
    prefix: []const u8,
    prefix_first: bool,
    writer: *std.Io.Writer,
) !void {
    const width = wrap_columns - prefix.len;

    var rest = std.mem.trim(u8, text, " ");
    var first = true;
    while (rest.len > 0) {
        if (!first or prefix_first) try writer.writeAll(prefix);
        first = false;

        var take = rest.len;
        if (take > width) {
            take = if (std.mem.lastIndexOfScalar(u8, rest[0 .. width + 1], ' ')) |space|
                space
            else
                std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        }
        try writer.print("{s}\n", .{std.mem.trimRight(u8, rest[0..take], " ")});
        rest = std.mem.trimLeft(u8, rest[take..], " ");
    }
}

// ─── The usage message ───────────────────────────────────────────────────────

/// Where a flag's description starts, so the descriptions stand in a column of
/// their own. A flag whose name and placeholder reach past this takes the line
/// to itself and its description starts on the next one.
const description_column = 32;
const description_pad = " " ** description_column;

/// The part of the usage that belongs to no particular flag. Everything else
/// is read out of `config.flags` and the doc comments in `config.zig`.
const preamble =
    \\Usage: capsper [options]
    \\
    \\Push-to-talk dictation and meeting capture. It needs something to do: a
    \\trigger key, a capture device, a TCP port, the console, or meeting capture.
    \\
    \\Settings are read from the config file first -- $XDG_CONFIG_HOME/capsper/
    \\config.zon, or wherever --config names -- and the flags below are applied
    \\over it, so a flag wins for one run. The file holds settings that have no
    \\flag, meeting capture and the console among them, and --write-config prints
    \\what a run would use, ready to save as that file.
    \\
;

const examples =
    \\
    \\Examples:
    \\  capsper --trigger capslock --audio-target my-mic
    \\  capsper --trigger capslock --audio-target my-mic --port 43007
    \\  capsper --port 0
    \\  capsper --stream recording.wav
    \\  capsper --trigger capslock --write-config > ~/.config/capsper/config.zon
    \\
;

/// Every flag capsper accepts: what it does, the setting it writes, and what
/// that setting is when nobody says otherwise.
///
/// There is no list of flags in this file. `config.flags` is the list, the
/// prose is the doc comment on the setting each flag writes, and the default
/// is read off the settings type -- so this cannot describe a flag that does
/// not exist, miss one that does, or quote a default that has since changed.
/// It was a hand-written block of text in `main.zig` until it had drifted
/// from all three.
pub fn writeUsage(w: *std.Io.Writer) !void {
    try w.writeAll(preamble);

    try w.writeAll("\nCommands (each does its one thing and exits):\n");
    inline for (config.flags) |f| {
        if (f.root == .cli) try writeFlag(f, w);
    }

    try w.writeAll("\nSettings:\n");
    inline for (config.flags, 0..) |f, i| {
        if (f.root == .config) {
            const section = comptime sectionOf(f.path);
            if (comptime !std.mem.eql(u8, section, sectionBefore(i))) try writeSection(section, w);
            try writeFlag(f, w);
        }
    }

    try w.writeAll(examples);
}

/// The group a setting belongs to: `audio` for `audio.channel`, and the empty
/// string for one that sits at the top of the file.
fn sectionOf(comptime path: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return "";
    return path[0..dot];
}

/// The section of the last setting printed before flag `i`, so a heading is
/// written where the group changes and nowhere else. `"\x00"` before the
/// first one, which no real section can equal.
fn sectionBefore(comptime i: usize) []const u8 {
    comptime {
        var j = i;
        while (j > 0) {
            j -= 1;
            if (config.flags[j].root == .config) return sectionOf(config.flags[j].path);
        }
        return "\x00";
    }
}

/// A group's heading, which is the group's own name and the doc comment
/// beside it. Wrapped as one piece, name included, so a long description does
/// not run the first line off the terminal.
fn writeSection(comptime section: []const u8, w: *std.Io.Writer) !void {
    if (section.len == 0) return;
    try w.writeAll("\n");
    try writeWrapped(
        comptime section ++ " -- " ++ firstSentence(docFor(Config, section, section)),
        "  ",
        true,
        w,
    );
}

/// One flag: its name, what the setting behind it means, where that setting
/// lives in the file, its default, and any older spellings still accepted.
fn writeFlag(comptime f: config.Flag, w: *std.Io.Writer) !void {
    const head = comptime "    " ++ f.name ++ (if (f.takesValue()) " " ++ f.placeholder() else "");

    try w.writeAll(head);
    if (head.len + 2 > description_column) {
        try w.writeAll("\n");
        try w.writeAll(description_pad);
    } else {
        try w.splatByteAll(' ', description_column - head.len);
    }

    try writeWrapped(comptime flagDescription(f), description_pad, false, w);

    try writeWrapped(comptime meta(f), description_pad, true, w);
}

/// What a flag's line should say it does.
///
/// Normally the prose beside the setting, which is where descriptions live so
/// that there is exactly one per setting. A flag that turns a setting off
/// cannot borrow it: that prose argues for the behaviour, so printing it under
/// `--no-...` describes the opposite of what the flag does, and the only thing
/// correcting it is the `= false` on the line below. Negated flags say what
/// they do themselves, and must — one without a `describes` is a compile error
/// naming it, so the next `--no-` flag cannot quietly inherit the same
/// contradiction.
fn flagDescription(comptime f: config.Flag) []const u8 {
    comptime {
        if (f.describes) |d| return d;
        if (!f.takesValue() and !f.value) @compileError(
            "the flag " ++ f.name ++ " turns " ++ f.path ++ " off, so it needs a `describes`:" ++
                " the prose beside that setting describes turning it on",
        );
        const Holder = config.Holder(f.RootType(), f.path);
        return firstSentence(docFor(Holder, config.leafName(f.path), f.path));
    }
}

/// The line under a flag's description: the setting it writes, what that
/// setting is by default, and any older spellings of the flag.
///
/// The setting is named because moving a service file full of flags into a
/// config file is otherwise a translation exercise. A command writes no
/// setting, so it has only its aliases to declare -- and an alias nobody can
/// discover is a trap for whoever inherits a service file full of them.
fn meta(comptime f: config.Flag) []const u8 {
    comptime {
        var parts: []const u8 = "";
        if (f.root == .config) {
            // A switch says the value it sets rather than a default, because
            // its default is the state it exists to leave.
            parts = if (f.Type() == bool)
                f.path ++ " = " ++ (if (f.value) "true" else "false")
            else
                f.path ++ ", default " ++ defaultText(f);
        }
        for (f.aliases, 0..) |a, i| {
            parts = parts ++ (if (parts.len == 0) "also " else if (i == 0) ", also " else ", ") ++ a;
        }
        return parts;
    }
}

/// What a setting is when nobody says otherwise, as the usage should show it.
/// Read off the settings type, so it cannot quote a default that has changed.
fn defaultText(comptime f: config.Flag) []const u8 {
    comptime {
        const T = f.Type();
        const defaults = config.Holder(f.RootType(), f.path){};
        const value = @field(defaults, config.leafName(f.path));
        const v = if (@typeInfo(T) == .optional) (value orelse return "unset") else value;

        return switch (@typeInfo(@TypeOf(v))) {
            .@"enum" => @tagName(v),
            .pointer => "\"" ++ v ++ "\"",
            else => std.fmt.comptimePrint("{d}", .{v}),
        };
    }
}

/// The first sentence of a description, which is what a terminal has room
/// for. The rest of the prose stays in the config file, beside the setting.
///
/// A sentence ends at a full stop followed by a space and a capital, so
/// `../models/nemotron` and `0.3` do not end one.
fn firstSentence(comptime doc: []const u8) []const u8 {
    comptime {
        var i: usize = 0;
        while (i + 2 < doc.len) : (i += 1) {
            if (doc[i] == '.' and doc[i + 1] == ' ' and std.ascii.isUpper(doc[i + 2])) {
                return doc[0 .. i + 1];
            }
        }
        return doc;
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn writeToString(arena: std.mem.Allocator, cfg: *const Config) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(arena);
    try write(cfg, &buf.writer);
    return buf.written();
}

test "a string equal to its default is not a change" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The shape the console's save produces: every value a fresh allocation,
    // none of them pointing at the static defaults. Nothing was changed, so
    // nothing may be written -- a comparison by pointer would name every
    // string setting here.
    var cfg = Config{};
    cfg.meeting.sink_name = try arena.dupeZ(u8, cfg.meeting.sink_name);
    cfg.meeting.sink_description = try arena.dupeZ(u8, cfg.meeting.sink_description);
    cfg.meeting.dir = try arena.dupeZ(u8, cfg.meeting.dir);
    cfg.http.bind = try arena.dupeZ(u8, cfg.http.bind);

    try testing.expectEqualStrings(".{\n}\n", try writeToString(arena, &cfg));
}

test "writing the defaults says nothing at all" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const cfg = Config{};
    try testing.expectEqualStrings(".{\n}\n", try writeToString(arena_state.allocator(), &cfg));
}

test "writing names the settings that differ and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var cfg = Config{};
    cfg.audio.gain = 10.0;
    const text = try writeToString(arena_state.allocator(), &cfg);

    try testing.expect(std.mem.indexOf(u8, text, ".gain = 10") != null);
    // The section carrying it appears; the ones left alone do not.
    try testing.expect(std.mem.indexOf(u8, text, ".audio = .{") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".meeting") == null);
    try testing.expect(std.mem.indexOf(u8, text, ".tcp") == null);
    // Nor do that section's own untouched fields.
    try testing.expect(std.mem.indexOf(u8, text, ".detect_duration") == null);
}

test "each setting written carries its description" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var cfg = Config{};
    cfg.audio.target = "vocaster_hostmic";
    const text = try writeToString(arena_state.allocator(), &cfg);

    // The section's description and the setting's, both as comments.
    try testing.expect(std.mem.indexOf(u8, text, "// ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Capture device node name") != null);
    // Wrapped, so no line runs away.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try testing.expect(line.len <= wrap_columns);
}

test "a comment never breaks a word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try writeComment("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu", "", &buf.writer);

    var lines = std.mem.splitScalar(u8, buf.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(std.mem.startsWith(u8, line, "// "));
        // Every word survives whole: no line starts or ends mid-word, which
        // shows up as a fragment that is not in the original.
        try testing.expect(std.mem.indexOf(u8, "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu", line[3..]) != null);
    }
}

test "flags written out and read back give the same settings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A spread of kinds: enum, float, optional string, bool, integer, and a
    // setting nested two deep.
    var cfg = Config{};
    var cli = config.Cli{};
    const argv: []const [:0]const u8 = &.{
        "capsper",        "--trigger",    "capslock",
        "--audio-target", "vocaster",     "--audio-channel",
        "FR",             "--audio-gain", "10.0",
        "--port",         "43007",        "--no-auto-gain",
        "--record-keep",  "3",
    };
    try testing.expect(config.parseArgs(&cfg, &cli, argv) == null);
    cfg.meeting.enabled = true;
    cfg.meeting.vad.onset = 0.45;

    const text = try writeToString(arena, &cfg);
    const source = try arena.dupeZ(u8, text);
    const reparsed = try config.parse(arena, source, null);

    // Compared as text rather than with `expectEqual`, which compares the
    // string fields by pointer and so fails on two equal strings that were
    // allocated separately. Writing the reparsed config is also the property
    // that matters: the file a migration produces has to survive being read
    // back and written again unchanged.
    try testing.expectEqualStrings(text, try writeToString(arena, &reparsed));

    // And it is not vacuously stable: the values really did make the journey.
    try testing.expectEqual(config.TriggerKey.capslock, reparsed.trigger.key.?);
    try testing.expectEqualStrings("vocaster", reparsed.audio.target.?);
    try testing.expectEqual(config.Channel.FR, reparsed.audio.channel);
    try testing.expectEqual(@as(f32, 10.0), reparsed.audio.gain);
    try testing.expect(!reparsed.audio.auto_gain);
    try testing.expectEqual(@as(u16, 43007), reparsed.tcp.port.?);
    try testing.expectEqual(@as(usize, 3), reparsed.debug_recording.keep);
    try testing.expect(reparsed.meeting.enabled);
    try testing.expectEqual(@as(f32, 0.45), reparsed.meeting.vad.onset);
}

test "writing keeps a tilde, because expandPaths has not run yet" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const cfg = Config{ .model = "~/models/nemotron" };
    const text = try writeToString(arena_state.allocator(), &cfg);
    try testing.expect(std.mem.indexOf(u8, text, "~/models/nemotron") != null);
}

test "the usage names every flag, with its setting and its older spellings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try writeUsage(&buf.writer);
    const text = buf.written();

    inline for (config.flags) |f| {
        try testing.expect(std.mem.indexOf(u8, text, f.name) != null);
        if (f.root == .config) try testing.expect(std.mem.indexOf(u8, text, f.path) != null);
        inline for (f.aliases) |a| try testing.expect(std.mem.indexOf(u8, text, a) != null);
    }
}

test "the usage quotes the defaults off the settings type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try writeUsage(&buf.writer);
    const text = buf.written();

    try testing.expect(std.mem.indexOf(u8, text, "audio.channel, default FL") != null);
    try testing.expect(std.mem.indexOf(u8, text, "trigger.type_delay_us, default 12000") != null);
    // A setting that is off unless asked for says so rather than naming a
    // value it does not have.
    try testing.expect(std.mem.indexOf(u8, text, "tcp.port, default unset") != null);
    // A switch says what it sets, because its default is the state it exists
    // to leave.
    try testing.expect(std.mem.indexOf(u8, text, "audio.auto_gain = false") != null);
}

test "a negated flag says what it does, not what it undoes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try writeUsage(&buf.writer);
    const text = buf.written();

    // `--no-auto-gain` turns auto-gain off, so it must not be described by the
    // prose beside `Audio.auto_gain`, which argues for having it on.
    try testing.expect(std.mem.indexOf(u8, text, "Leave the gain where") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Track the speaking level") == null);

    // The setting keeps that prose where it belongs: above the field in a
    // written config file.
    var cfg_buf: std.Io.Writer.Allocating = .init(arena_state.allocator());
    var cfg = config.Config{};
    cfg.audio.auto_gain = false;
    try write(&cfg, &cfg_buf.writer);
    try testing.expect(std.mem.indexOf(u8, cfg_buf.written(), "Track the speaking level") != null);
}

test "the usage describes each flag with the prose beside its setting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try writeUsage(&buf.writer);
    const text = buf.written();

    // The first sentence of the doc comment on `Audio.gain`, wrapped.
    try testing.expect(std.mem.indexOf(u8, text, "Multiplier applied to the incoming samples") != null);
    // The group headings are the doc comments on the groups themselves.
    try testing.expect(std.mem.indexOf(u8, text, "audio -- Where the audio comes from") != null);
    // Nothing runs off an eighty column terminal.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try testing.expect(line.len <= wrap_columns);
}
