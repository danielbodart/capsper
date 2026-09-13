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
// The one consumer today is `--write-config`, which writes the settings out as
// ZON with each one's description above it as a comment. The table is shaped
// for the others that want the same three things -- path, type and description
// -- with usage text the obvious next one.

const std = @import("std");
const config = @import("config.zig");
const generated = @import("config_field_docs");

const Config = config.Config;

/// One setting, addressed the way the config file and a dotted flag would.
pub const Entry = struct {
    /// Dotted path from the root of the settings: "meeting.vad.onset".
    path: []const u8,
    /// What the field holds. A section is a struct; everything else is a leaf.
    type_name: []const u8,
    doc: []const u8,
    /// Sections are the structs that group the settings. They take no value
    /// themselves, and their description heads the group.
    is_section: bool,
};

/// Every setting, depth first, in declaration order. A section comes
/// immediately before the settings it contains.
pub const entries = buildEntries();

// ─── Building the table ──────────────────────────────────────────────────────

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

fn countEntries(comptime T: type, comptime prefix: []const u8) usize {
    comptime var n: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        n += 1;
        const path = if (prefix.len == 0) f.name else prefix ++ "." ++ f.name;
        if (sectionType(f.type)) |S| n += countEntries(S, path);
    }
    return n;
}

fn fillEntries(
    comptime T: type,
    comptime prefix: []const u8,
    comptime out: []Entry,
    comptime at: usize,
) usize {
    comptime var i = at;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const path = if (prefix.len == 0) f.name else prefix ++ "." ++ f.name;
        const section = sectionType(f.type);
        out[i] = .{
            .path = path,
            .type_name = @typeName(f.type),
            .doc = docFor(T, f.name, path),
            .is_section = section != null,
        };
        i += 1;
        if (section) |S| i = fillEntries(S, path, out, i);
    }
    return i;
}

fn buildEntries() [countEntries(Config, "")]Entry {
    @setEvalBranchQuota(100_000);
    comptime var out: [countEntries(Config, "")]Entry = undefined;
    _ = comptime fillEntries(Config, "", &out, 0);
    const frozen = out;
    return frozen;
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
///
/// Breaks only between words, and lets a word longer than the line stand off
/// the right margin rather than splitting it: the long ones here are node
/// names and paths, and a broken path is worse than a ragged edge.
fn writeComment(doc: []const u8, comptime pad: []const u8, writer: *std.Io.Writer) !void {
    const width = wrap_columns - pad.len - 3;

    var rest = std.mem.trim(u8, doc, " ");
    while (rest.len > 0) {
        var take = rest.len;
        if (take > width) {
            take = if (std.mem.lastIndexOfScalar(u8, rest[0 .. width + 1], ' ')) |space|
                space
            else
                std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        }
        try writer.print("{s}// {s}\n", .{ pad, std.mem.trimRight(u8, rest[0..take], " ") });
        rest = std.mem.trimLeft(u8, rest[take..], " ");
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn writeToString(arena: std.mem.Allocator, cfg: *const Config) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(arena);
    try write(cfg, &buf.writer);
    return buf.written();
}

test "every setting has a description" {
    // The table cannot be built at all if one is missing, so reaching here is
    // the assertion. This names it so a failure reads as what it is.
    try testing.expect(entries.len > 0);
}

test "the table holds sections and the settings inside them" {
    var saw_section = false;
    var saw_nested_leaf = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.path, "meeting")) {
            saw_section = true;
            try testing.expect(e.is_section);
        }
        if (std.mem.eql(u8, e.path, "meeting.vad.onset")) {
            saw_nested_leaf = true;
            try testing.expect(!e.is_section);
        }
        try testing.expect(e.doc.len > 0);
    }
    try testing.expect(saw_section);
    try testing.expect(saw_nested_leaf);
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
    try testing.expect(std.mem.indexOf(u8, text, ".tcp_server") == null);
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
    try testing.expectEqual(@as(u16, 43007), reparsed.tcp_server.port.?);
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
