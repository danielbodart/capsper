// src/shared/settings_form.zig — the settings, as a form and back again.
//
// `config.zig` holds the settings type and `config_docs.zig` can read the
// prose beside each field. Between them there is enough to build the whole
// form without naming a single setting here: walk the real type, ask what each
// field holds, and write the control that fits it. Add a field to `Config` and
// it appears, documented, with no edit to this file. That is the entire reason
// it is a walk rather than a page of HTML.
//
// The form is written by the server rather than assembled in the browser. It
// has no behaviour -- no live values, nothing that changes until it is
// submitted -- so a renderer in JavaScript would exist only to turn values
// this module already holds into markup it already knows how to write.
//
// Coming back, a posted form is turned into ZON text and handed to
// `std.zon.parse`: the same parser, with the same diagnostics, that validates
// a hand-written config file. There is then exactly one place that decides
// what a setting means. Values are re-emitted from what was parsed rather than
// pasted in as they arrived, so a string field cannot carry ZON of its own
// into the document.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const config_docs = @import("config_docs.zig");
const utils = @import("utils.zig");

const Config = config.Config;

/// What a field holds, as far as a form control is concerned.
const Shape = enum { boolean, text, integer, number, choice };

fn shapeOf(comptime T: type) Shape {
    const Leaf = LeafType(T);
    return switch (@typeInfo(Leaf)) {
        .bool => .boolean,
        .int => .integer,
        .float => .number,
        .@"enum" => .choice,
        .pointer => |p| if (p.size == .slice and p.child == u8)
            .text
        else
            @compileError("settings form: no control for " ++ @typeName(Leaf)),
        else => @compileError("settings form: no control for " ++ @typeName(Leaf)),
    };
}

fn LeafType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

// ─── Writing the form ────────────────────────────────────────────────────────

/// The settings as a form, with every field's description beside it.
///
/// `devices` names the capture devices the platform could find, offered as
/// suggestions on the fields that take one. Empty is fine and means the field
/// is a plain text box -- which is what macOS gets until its device
/// enumeration exists, and what any machine gets if the query fails.
pub fn writeForm(cfg: *const Config, devices: []const []const u8, w: *std.Io.Writer) !void {
    try w.writeAll("<datalist id=\"devices\">");
    for (devices) |d| {
        try w.writeAll("<option value=\"");
        try utils.writeHtml(w, d);
        try w.writeAll("\">");
    }
    try w.writeAll("</datalist>\n");

    try writeFields(Config, cfg.*, "", w);
}

/// Whether a field names an audio device, and so should offer the list.
///
/// By path, which is a small piece of knowledge about `Config` in a file that
/// otherwise has none. The alternative is a marker on the field itself, and a
/// type that carries presentation for one consumer is a worse trade than three
/// paths named here.
fn takesDevice(comptime path: []const u8) bool {
    for ([_][]const u8{ "audio.target", "meeting.near", "meeting.output" }) |p| {
        if (std.mem.eql(u8, path, p)) return true;
    }
    return false;
}

fn writeFields(comptime T: type, value: T, comptime prefix: []const u8, w: *std.Io.Writer) !void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const path = if (prefix.len == 0) f.name else prefix ++ "." ++ f.name;
        const doc = config_docs.docFor(T, f.name, path);
        const v = @field(value, f.name);

        if (config_docs.sectionType(f.type)) |S| {
            try w.writeAll("<fieldset><legend>");
            try utils.writeHtml(w, f.name);
            try w.writeAll("</legend><p class=\"doc\">");
            try utils.writeHtml(w, doc);
            try w.writeAll("</p>\n");
            try writeFields(S, v, path, w);
            try w.writeAll("</fieldset>\n");
        } else {
            try writeField(f.type, path, doc, v, w);
        }
    }
}

fn writeField(
    comptime T: type,
    comptime path: []const u8,
    doc: []const u8,
    value: T,
    w: *std.Io.Writer,
) !void {
    const shape = comptime shapeOf(T);
    const optional = @typeInfo(T) == .optional;

    try w.writeAll("<div class=\"field\"><label for=\"");
    try w.writeAll(path);
    try w.writeAll("\">");
    try w.writeAll(path);
    try w.writeAll("</label>");

    switch (shape) {
        .boolean => {
            // A cleared checkbox posts nothing at all, which is
            // indistinguishable from a field that was never on the form. The
            // hidden partner posts the false, and the checkbox overwrites it
            // when it is ticked -- so the value is always stated.
            try w.print("<input type=\"hidden\" name=\"{s}\" value=\"false\">", .{path});
            try w.print(
                "<input type=\"checkbox\" id=\"{s}\" name=\"{s}\" value=\"true\"{s}>",
                .{ path, path, if (unwrap(T, value) orelse false) " checked" else "" },
            );
        },
        .choice => {
            const Leaf = LeafType(T);
            try w.print("<select id=\"{s}\" name=\"{s}\">", .{ path, path });
            // An optional enum can be unset, and that is a real choice rather
            // than a missing one -- `trigger.key` of null is "no push to talk".
            if (optional) {
                try w.print("<option value=\"\"{s}>(unset)</option>", .{
                    if (unwrap(T, value) == null) " selected" else "",
                });
            }
            inline for (@typeInfo(Leaf).@"enum".fields) |e| {
                const chosen = if (unwrap(T, value)) |got| got == @field(Leaf, e.name) else false;
                try w.print("<option value=\"{s}\"{s}>{s}</option>", .{
                    e.name, if (chosen) " selected" else "", e.name,
                });
            }
            try w.writeAll("</select>");
        },
        .integer, .number => {
            try w.print(
                "<input type=\"number\" id=\"{s}\" name=\"{s}\"{s} value=\"",
                .{ path, path, if (shape == .number) " step=\"any\"" else "" },
            );
            if (unwrap(T, value)) |got| {
                if (shape == .number) try w.print("{d}", .{got}) else try w.print("{d}", .{got});
            }
            try w.writeAll("\">");
        },
        .text => {
            try w.print("<input type=\"text\" id=\"{s}\" name=\"{s}\"", .{ path, path });
            if (comptime takesDevice(path)) try w.writeAll(" list=\"devices\"");
            try w.writeAll(" value=\"");
            if (unwrap(T, value)) |got| try utils.writeHtml(w, got);
            try w.writeAll("\">");
        },
    }

    try w.writeAll("<p class=\"doc\">");
    try utils.writeHtml(w, doc);
    try w.writeAll("</p></div>\n");
}

/// The value inside an optional, or the value itself when there is no optional
/// to look through.
///
/// The identity function, and it earns its name rather than its body: an
/// already-optional value passes through, and a concrete one coerces into the
/// optional return type. What it buys is that the callers above can ask "is
/// there a value here" the same way whether or not the field can be null.
fn unwrap(comptime T: type, value: T) ?LeafType(T) {
    return value;
}

// ─── Reading it back ─────────────────────────────────────────────────────────

pub const Values = std.StringHashMapUnmanaged([]const u8);

/// Decode an `application/x-www-form-urlencoded` body into path/value pairs.
///
/// A later pair wins, which is what makes the hidden partner of a checkbox
/// work: the false is posted first and the tick overwrites it.
pub fn parseBody(arena: Allocator, body: []const u8) !Values {
    var out: Values = .{};
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = try decode(arena, pair[0..eq]);
        const value = try decode(arena, pair[eq + 1 ..]);
        try out.put(arena, key, value);
    }
    return out;
}

/// Percent decoding, plus the one rule that is form encoding's own: `+` is a
/// space. `std.Uri` does not know that, because in a URI it is not true.
fn decode(arena: Allocator, text: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        if (text[i] == '+') {
            buf[n] = ' ';
            i += 1;
        } else if (text[i] == '%' and i + 2 < text.len) {
            buf[n] = std.fmt.parseInt(u8, text[i + 1 ..][0..2], 16) catch {
                buf[n] = text[i];
                i += 1;
                continue;
            };
            i += 3;
        } else {
            buf[n] = text[i];
            i += 1;
        }
    }
    return buf[0..n];
}

pub const Problem = struct {
    path: []const u8,
    message: []const u8,
};

/// Turn posted values into a ZON document naming every setting the form
/// carried, or report the first field that could not be read.
///
/// Nothing arrives in the document as it was posted. A number is parsed and
/// printed again, an enum is matched against the real tags and written as the
/// tag that matched, and a string goes through `std.zon.stringify`. A field
/// the form did not carry is left out, and `std.zon.parse` then fills it from
/// the default compiled into `Config` -- which is what makes a form that has
/// gained a field since the page was loaded behave sensibly rather than
/// clearing it.
pub fn writeZon(values: *const Values, w: *std.Io.Writer) !?Problem {
    try w.writeAll(".{\n");
    const problem = try writeZonFields(Config, values, "", 1, w);
    try w.writeAll("}\n");
    return problem;
}

/// Whether the form carried any setting inside `T`, however deep.
fn carries(comptime T: type, values: *const Values, comptime prefix: []const u8) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const path = if (prefix.len == 0) f.name else prefix ++ "." ++ f.name;
        if (config_docs.sectionType(f.type)) |S| {
            if (carries(S, values, path)) return true;
        } else if (values.get(path) != null) {
            return true;
        }
    }
    return false;
}

fn writeZonFields(
    comptime T: type,
    values: *const Values,
    comptime prefix: []const u8,
    comptime depth: usize,
    w: *std.Io.Writer,
) !?Problem {
    const pad = "    " ** depth;

    inline for (@typeInfo(T).@"struct".fields) |f| {
        const path = if (prefix.len == 0) f.name else prefix ++ "." ++ f.name;

        if (config_docs.sectionType(f.type)) |S| {
            // Asked before it is opened, so a section none of whose settings
            // the form carried costs no lines -- the same shape a hand-written
            // file has, and no buffer to hold the answer in.
            if (carries(S, values, path)) {
                try w.print("{s}.{s} = .{{\n", .{ pad, f.name });
                if (try writeZonFields(S, values, path, depth + 1, w)) |p| return p;
                try w.print("{s}}},\n", .{pad});
            }
        } else {
            // An `if` rather than `continue`: this is an `inline for`, so a
            // runtime `continue` would be control flow leaving a comptime
            // loop body and the compiler refuses it.
            if (values.get(path)) |raw| {
                try w.print("{s}.{s} = ", .{ pad, f.name });
                if (try writeZonValue(f.type, path, raw, w)) |p| return p;
                try w.writeAll(",\n");
            }
        }
    }
    return null;
}

fn writeZonValue(
    comptime T: type,
    comptime path: []const u8,
    raw: []const u8,
    w: *std.Io.Writer,
) !?Problem {
    const optional = @typeInfo(T) == .optional;
    const Leaf = LeafType(T);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");

    // An empty box on an optional field means "unset", which is a value. On a
    // field that has no null it means the box was cleared, and the honest
    // answer is the default rather than an empty string -- so it is written as
    // nothing and `writeZonFields` has already skipped it.
    if (trimmed.len == 0) {
        if (optional) {
            try w.writeAll("null");
            return null;
        }
        return .{ .path = path, .message = "cannot be empty" };
    }

    switch (comptime shapeOf(T)) {
        .boolean => {
            if (std.mem.eql(u8, trimmed, "true")) try w.writeAll("true")
            else if (std.mem.eql(u8, trimmed, "false")) try w.writeAll("false")
            else return .{ .path = path, .message = "must be true or false" };
        },
        .choice => {
            // Matched against the real tags, so an unknown one is refused
            // rather than written out. This is also what stops a request that
            // never went near the select from putting anything it likes here.
            const tag = std.meta.stringToEnum(Leaf, trimmed) orelse
                return .{ .path = path, .message = "is not one of the choices" };
            try w.print(".{s}", .{@tagName(tag)});
        },
        .integer => {
            const n = std.fmt.parseInt(Leaf, trimmed, 10) catch
                return .{ .path = path, .message = "must be a whole number in range" };
            try w.print("{d}", .{n});
        },
        .number => {
            const n = std.fmt.parseFloat(Leaf, trimmed) catch
                return .{ .path = path, .message = "must be a number" };
            // `inf` and `nan` parse, print, and parse back as ZON, so the
            // round trip would accept them all the way to the file -- where a
            // gain of infinity or a voice-activity threshold of nan is not a
            // setting anyone can have meant. A number input in a browser
            // refuses to type them; nothing else was refusing them.
            if (!std.math.isFinite(n)) return .{ .path = path, .message = "must be a finite number" };
            try w.print("{d}", .{n});
        },
        // The one value that is written from what arrived, and the one that is
        // escaped on the way.
        .text => try std.zon.stringify.serialize(trimmed, .{}, w),
    }
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn formToZon(arena: Allocator, pairs: []const [2][]const u8) !struct { text: []const u8, problem: ?Problem } {
    var values: Values = .{};
    for (pairs) |p| try values.put(arena, p[0], p[1]);

    var buf: std.Io.Writer.Allocating = .init(arena);
    const problem = try writeZon(&values, &buf.writer);
    return .{ .text = buf.written(), .problem = problem };
}

fn formHtml(arena: Allocator, cfg: *const Config, devices: []const []const u8) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(arena);
    try writeForm(cfg, devices, &buf.writer);
    return buf.written();
}

test "a posted form becomes settings, through the same parser a file uses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try formToZon(arena, &.{
        .{ "audio.gain", "2.5" },
        .{ "audio.channel", "FR" },
        .{ "trigger.key", "capslock" },
        .{ "http.port", "43008" },
        .{ "meeting.enabled", "true" },
        .{ "meeting.sink_name", "my_sink" },
    });
    try testing.expectEqual(@as(?Problem, null), out.problem);

    const source = try arena.dupeZ(u8, out.text);
    var diag: std.zon.parse.Diagnostics = .{};
    const cfg = try config.parse(arena, source, &diag);

    try testing.expectEqual(@as(f32, 2.5), cfg.audio.gain);
    try testing.expectEqual(config.Channel.FR, cfg.audio.channel);
    try testing.expectEqual(config.TriggerKey.capslock, cfg.trigger.key.?);
    try testing.expectEqual(@as(u16, 43008), cfg.http.port.?);
    try testing.expect(cfg.meeting.enabled);
    try testing.expectEqualStrings("my_sink", cfg.meeting.sink_name);
}

test "a section the form did not carry costs no lines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try formToZon(arena, &.{.{ "audio.gain", "3" }});
    try testing.expectEqual(@as(?Problem, null), out.problem);
    try testing.expect(std.mem.indexOf(u8, out.text, ".audio = .{") != null);
    try testing.expect(std.mem.indexOf(u8, out.text, ".meeting") == null);
    try testing.expect(std.mem.indexOf(u8, out.text, ".tcp_server") == null);
}

test "an empty box on an optional setting means unset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try formToZon(arena, &.{
        .{ "audio.target", "" },
        .{ "trigger.key", "" },
    });
    try testing.expectEqual(@as(?Problem, null), out.problem);

    const source = try arena.dupeZ(u8, out.text);
    var diag: std.zon.parse.Diagnostics = .{};
    const cfg = try config.parse(arena, source, &diag);
    try testing.expectEqual(@as(?[:0]const u8, null), cfg.audio.target);
    try testing.expectEqual(@as(?config.TriggerKey, null), cfg.trigger.key);
}

test "a string cannot carry settings of its own into the document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A device name that closes the value and starts a field of its own. It
    // has to come back as one string and change nothing else.
    const attack = "mic\", .verbose = true, .x = \"";
    const out = try formToZon(arena, &.{.{ "audio.target", attack }});
    try testing.expectEqual(@as(?Problem, null), out.problem);

    const source = try arena.dupeZ(u8, out.text);
    var diag: std.zon.parse.Diagnostics = .{};
    const cfg = try config.parse(arena, source, &diag);
    try testing.expectEqualStrings(attack, cfg.audio.target.?);
    try testing.expect(!cfg.verbose);
}

test "a value that is not of its field's type is named rather than written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad_enum = try formToZon(arena, &.{.{ "audio.channel", "SIDEWAYS" }});
    try testing.expectEqualStrings("audio.channel", bad_enum.problem.?.path);

    const bad_number = try formToZon(arena, &.{.{ "audio.gain", "loud" }});
    try testing.expectEqualStrings("audio.gain", bad_number.problem.?.path);

    // Out of range for its own integer type, not merely for an int.
    const out_of_range = try formToZon(arena, &.{.{ "http.port", "70000" }});
    try testing.expectEqualStrings("http.port", out_of_range.problem.?.path);

    // A setting with no null cannot be blanked.
    const blanked = try formToZon(arena, &.{.{ "meeting.sink_name", "" }});
    try testing.expectEqualStrings("meeting.sink_name", blanked.problem.?.path);
}

test "a posted body decodes the way a browser encodes one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var values = try parseBody(arena, "meeting.sink_description=Capsper%3A+Transcribe&audio.gain=2.5");
    try testing.expectEqualStrings("Capsper: Transcribe", values.get("meeting.sink_description").?);
    try testing.expectEqualStrings("2.5", values.get("audio.gain").?);
}

test "a checkbox's hidden partner is overwritten by the tick" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What a browser posts for a ticked box: the hidden false first, then the
    // checkbox's own true. The last one has to win.
    var ticked = try parseBody(arena, "meeting.enabled=false&meeting.enabled=true");
    try testing.expectEqualStrings("true", ticked.get("meeting.enabled").?);

    // And for a cleared one, only the hidden field is posted.
    var cleared = try parseBody(arena, "meeting.enabled=false");
    try testing.expectEqualStrings("false", cleared.get("meeting.enabled").?);
}

test "the form names every setting, with its description beside it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = Config{};
    const html = try formHtml(arena, &cfg, &.{"vocaster_hostmic"});

    // A control per shape, each named by its dotted path.
    try testing.expect(std.mem.indexOf(u8, html, "name=\"audio.gain\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "name=\"meeting.enabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<select id=\"audio.channel\"") != null);
    // Enum choices come from the type, so all 67 channels are offered.
    try testing.expect(std.mem.indexOf(u8, html, "<option value=\"AUX63\"") != null);
    // The prose beside the field in config.zig reaches the page.
    try testing.expect(std.mem.indexOf(u8, html, "Capture device node name") != null);
    // The device query's answers are offered on the fields that take one.
    try testing.expect(std.mem.indexOf(u8, html, "vocaster_hostmic") != null);
    try testing.expect(std.mem.indexOf(u8, html, "list=\"devices\"") != null);
}

test "the form shows what is running, not what the defaults are" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = Config{};
    cfg.audio.gain = 7.5;
    cfg.meeting.enabled = true;
    cfg.audio.channel = .FR;

    const html = try formHtml(arena, &cfg, &.{});

    try testing.expect(std.mem.indexOf(u8, html, "name=\"audio.gain\" step=\"any\" value=\"7.5\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "name=\"meeting.enabled\" value=\"true\" checked") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<option value=\"FR\" selected>") != null);
}
