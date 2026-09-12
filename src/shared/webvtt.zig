// src/shared/webvtt.zig — the transcript format, and the only thing that writes it.
//
// SRT was the first instinct and the right one -- use prior art -- but SRT has
// no speaker field, so every tool that needs one invents a text prefix
// convention, which is inventing a format while pretending not to. WebVTT has
// voice spans in the spec:
//
//     WEBVTT
//
//     1
//     00:00:04.120 --> 00:00:07.880
//     <v Near>so the thing I wanted to raise was the routing
//
// Which buys speaker attribution as ground truth rather than inference -- two
// tracks means near versus far is known, not diarised -- one file instead of
// two, legal overlap so crosstalk is representable, and a file that drops into
// any player and shows the transcript against the audio.
//
// It is also what the debug recorder writes. A debug recording and a meeting
// transcript are the same artefact at different verbosity, so they are the
// same writer: the only difference is whether the NOTE blocks are emitted.
//
// NOTE blocks are how the diagnostic detail rides along without becoming
// subtitles. Every renderer discards them, so a debug file still just plays,
// and single-line JSON sits in one happily.

const std = @import("std");
const utils = @import("utils.zig");

/// Which side of the conversation a cue came from. The names are terse for a
/// human reading the transcript against the audio, and that is accepted rather
/// than solved: we genuinely do not know who the far end is, and substituting
/// real names is a later concern the format does not need to answer.
pub const Voice = enum {
    near,
    far,

    /// Capitalised in the file because it is a label a person reads.
    pub fn label(self: Voice) []const u8 {
        return switch (self) {
            .near => "Near",
            .far => "Far",
        };
    }
};

pub const Detail = enum {
    /// Cues only.
    minimal,
    /// Cues plus a NOTE block for each diagnostic line.
    debug,
};

/// A cue payload may not contain `-->`, and a blank line terminates a cue. Both
/// restrictions apply to NOTE blocks and cue identifiers too.
///
/// Rather than reject text that breaks them -- which would mean losing
/// transcript -- the sequence is defanged. An arrow in speech is
/// extraordinarily unlikely; silently truncating a cue because of one would be
/// much worse than rewriting it.
const arrow = "-->";
const arrow_replacement = "->";

pub const Writer = struct {
    out: std.ArrayListUnmanaged(u8) = .{},
    gpa: std.mem.Allocator,
    detail: Detail,
    /// Cue identifiers must be unique. A counter is the simplest thing that is.
    next_cue: u32 = 1,
    started: bool = false,

    pub fn init(gpa: std.mem.Allocator, detail: Detail) Writer {
        return .{ .gpa = gpa, .detail = detail };
    }

    pub fn deinit(self: *Writer) void {
        self.out.deinit(self.gpa);
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.out.items;
    }

    /// The `WEBVTT` line, plus an optional header NOTE. Must come first: a file
    /// that does not start with WEBVTT is not a WebVTT file.
    pub fn begin(self: *Writer, header: ?[]const u8) !void {
        std.debug.assert(!self.started);
        self.started = true;

        try self.out.appendSlice(self.gpa, "WEBVTT\n");
        if (header) |text| {
            try self.out.append(self.gpa, '\n');
            try self.writeNoteBlock(text);
        }
    }

    /// A free-text comment, invisible to every renderer. Written only when the
    /// detail setting asks for it, which is the entire difference between a
    /// normal transcript and a debug one.
    pub fn note(self: *Writer, text: []const u8) !void {
        if (self.detail != .debug) return;
        try self.out.append(self.gpa, '\n');
        try self.writeNoteBlock(text);
    }

    /// A note that is always written whatever the detail setting, for the
    /// things a recording found in two years has to say for itself -- which
    /// side is which, what wrote it.
    pub fn headerNote(self: *Writer, text: []const u8) !void {
        try self.out.append(self.gpa, '\n');
        try self.writeNoteBlock(text);
    }

    /// One cue: an identifier, a timing line, and the payload behind a voice
    /// span. Times are in milliseconds from the start of the session, which is
    /// the same clock both tracks share.
    pub fn cue(self: *Writer, voice: Voice, start_ms: u64, end_ms: u64, text: []const u8) !void {
        std.debug.assert(self.started);

        // The spec requires non-decreasing start times, not non-overlapping
        // cues, so crosstalk is representable. It does require an end at or
        // after the start.
        const end = @max(end_ms, start_ms);

        const w = self.out.writer(self.gpa);
        try w.print("\n{d}\n", .{self.next_cue});
        self.next_cue += 1;

        try writeTimestamp(w, start_ms);
        try w.writeAll(" --> ");
        try writeTimestamp(w, end);
        try w.print("\n<v {s}>", .{voice.label()});
        try self.writeSanitised(text);
        try self.out.append(self.gpa, '\n');
    }

    fn writeNoteBlock(self: *Writer, text: []const u8) !void {
        try self.out.appendSlice(self.gpa, "NOTE ");
        try self.writeSanitised(text);
        try self.out.append(self.gpa, '\n');
    }

    /// Write text that cannot break out of its block: no `-->`, and no blank
    /// line. Newlines are kept, because a cue payload is allowed to span
    /// lines; it is only an *empty* line that ends the block.
    fn writeSanitised(self: *Writer, text: []const u8) !void {
        var rest = text;
        while (rest.len > 0) {
            const cut = std.mem.indexOf(u8, rest, arrow) orelse {
                try self.appendCollapsingBlankLines(rest);
                return;
            };
            try self.appendCollapsingBlankLines(rest[0..cut]);
            try self.out.appendSlice(self.gpa, arrow_replacement);
            rest = rest[cut + arrow.len ..];
        }
    }

    fn appendCollapsingBlankLines(self: *Writer, text: []const u8) !void {
        for (text) |c| {
            // A second newline in a row would end the block early, so the run
            // collapses to one.
            if (c == '\n' and self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == '\n') continue;
            // A lone carriage return has the same effect through a CRLF
            // reader, and carries no meaning worth keeping.
            if (c == '\r') continue;
            try self.out.append(self.gpa, c);
        }
    }
};

/// `HH:MM:SS.mmm`. WebVTT allows the hours field to be dropped, and this does
/// not: a fixed width sorts, aligns, and diffs, and a meeting can run past an
/// hour.
pub fn writeTimestamp(w: anytype, total_ms: u64) !void {
    const ms = total_ms % 1000;
    const total_s = total_ms / 1000;
    try w.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        total_s / 3600,
        (total_s / 60) % 60,
        total_s % 60,
        ms,
    });
}

/// Milliseconds of audio from a byte count, at the one format capsper works
/// in: 16 kHz, 16-bit, mono. 32000 bytes a second.
///
/// This is the position that has to be counted *on arrival*, ahead of any gate
/// that might elide silence before the encoder. Bytes-received and
/// bytes-encoded are the same number today only because everything received is
/// fed through; the moment that stops being true, a position derived from the
/// encoder drifts by the total silence skipped, and every cue after the first
/// pause is wrong.
pub fn msFromBytes(byte_count: u64) u64 {
    return byte_count * 1000 / 32000;
}

// ─── Deciding where a cue ends ───────────────────────────────────────────────

pub const Cue = struct {
    voice: Voice,
    start_ms: u64,
    end_ms: u64,
    text: []const u8,
};

/// Turns a stream of per-chunk observations into cues, for one track.
///
/// No model is needed for this, which is worth separating from the VAD
/// question rather than conflating with it. Nemotron emits nothing during
/// silence -- measured: a minute of digital silence and a minute of room tone
/// both produce zero characters -- so a run of non-emitting chunks *is* a
/// pause, and a pause closes a cue.
///
/// The one ambiguity is that a chunk can also emit nothing while the decoder
/// is holding tokens mid-word. The level tells those apart: an EMA is kept
/// over chunks that did emit, and a new chunk is judged relative to it. Quiet
/// and non-emitting is a pause; loud and non-emitting is the decoder still
/// working, and must not end the cue. Being a *relative* measure, it needs no
/// calibration against a particular microphone or gain setting.
///
/// The EMA is kept here rather than read out of the pipeline deliberately.
/// Only the ORT backend tracks one, for its own stall detection, and lifting
/// that private state into the shared interface would tie cue boundaries to a
/// backend. This is a few lines of arithmetic over audio the caller already
/// has in hand.
///
/// On timing, honestly: a cue's start is the audio position at which its first
/// text arrived, not the position at which the words were spoken. An RNNT
/// decoder emits behind the audio, so cues sit slightly late. That is the same
/// approximation the debug log has always made, it is good enough to read a
/// transcript against its audio, and per-word timing is a separate problem the
/// pipeline does not currently answer.
pub const CueBuilder = struct {
    voice: Voice,
    gpa: std.mem.Allocator,

    /// How many consecutive quiet, non-emitting chunks end a cue. At 560 ms a
    /// chunk this is a little over a second of silence -- long enough not to
    /// break a sentence at a breath, short enough to keep cues readable.
    close_after_quiet_chunks: u32 = 2,

    /// Level below which a non-emitting chunk counts as silence, as a fraction
    /// of recent speech. The same fraction the ORT backend uses to tell a
    /// stall from a pause, for the same reason.
    quiet_fraction: f64 = 0.5,

    speech_rms_ema: f64 = 0,
    quiet_chunks: u32 = 0,

    text: std.ArrayListUnmanaged(u8) = .{},
    start_ms: u64 = 0,
    end_ms: u64 = 0,
    open: bool = false,

    const ema_alpha: f64 = 0.1;

    pub fn init(gpa: std.mem.Allocator, voice: Voice) CueBuilder {
        return .{ .gpa = gpa, .voice = voice };
    }

    pub fn deinit(self: *CueBuilder) void {
        self.text.deinit(self.gpa);
    }

    /// Feed one chunk: the span of audio it covers, how loud it was, and
    /// whatever text it produced (empty if none).
    ///
    /// The chunk's span rather than a single position, so that a cue built
    /// from one chunk still has a duration. A zero-length cue is legal WebVTT
    /// and useless in a player.
    ///
    /// Returns a cue when this chunk closed one. The returned text is owned by
    /// the builder and is only valid until the next call.
    pub fn push(
        self: *CueBuilder,
        chunk_start_ms: u64,
        chunk_end_ms: u64,
        chunk_rms: f64,
        new_text: []const u8,
    ) !?Cue {
        if (new_text.len > 0) {
            self.quiet_chunks = 0;
            self.speech_rms_ema = if (self.speech_rms_ema == 0)
                chunk_rms
            else
                ema_alpha * chunk_rms + (1 - ema_alpha) * self.speech_rms_ema;

            if (!self.open) {
                self.open = true;
                self.start_ms = chunk_start_ms;
                self.text.clearRetainingCapacity();
            }
            try self.text.appendSlice(self.gpa, new_text);
            self.end_ms = chunk_end_ms;
            return null;
        }

        if (!self.open) return null;

        // Loud but silent is the decoder still working, so the cue stays open.
        if (self.speech_rms_ema > 0 and chunk_rms >= self.quiet_fraction * self.speech_rms_ema) {
            self.quiet_chunks = 0;
            return null;
        }

        self.quiet_chunks += 1;
        if (self.quiet_chunks < self.close_after_quiet_chunks) return null;
        return self.take();
    }

    /// Close whatever is open, for the end of a session.
    pub fn flush(self: *CueBuilder) ?Cue {
        if (!self.open) return null;
        return self.take();
    }

    fn take(self: *CueBuilder) ?Cue {
        self.open = false;
        self.quiet_chunks = 0;

        const trimmed = std.mem.trim(u8, self.text.items, " \t\r\n");
        // A cue of nothing but punctuation is what a flush produces when the
        // model finishes a sentence it had already emitted. It is a subtitle
        // reading "." against silence, so it is dropped.
        if (utils.isBlankOrPunct(trimmed)) return null;

        return .{
            .voice = self.voice,
            .start_ms = self.start_ms,
            .end_ms = self.end_ms,
            .text = trimmed,
        };
    }
};

// ─── Merging the two tracks ──────────────────────────────────────────────────

/// Collects cues from both tracks and writes them as one transcript.
///
/// One file, not two, because both tracks share an audio position -- they
/// start together -- so merging them is a sort and nothing more. It has to be
/// a sort, though: cues complete when their own track goes quiet, so they
/// arrive out of order, and WebVTT requires start times that do not decrease.
/// Writing them as they complete produces a file that is subtly invalid.
///
/// Stable, so two cues that start in the same millisecond keep the order they
/// were added in rather than swapping between runs.
pub const Transcript = struct {
    gpa: std.mem.Allocator,
    detail: Detail,
    header: ?[]const u8 = null,
    cues: std.ArrayListUnmanaged(Owned) = .{},
    notes: std.ArrayListUnmanaged([]const u8) = .{},

    const Owned = struct {
        voice: Voice,
        start_ms: u64,
        end_ms: u64,
        text: []const u8,
    };

    pub fn init(gpa: std.mem.Allocator, detail: Detail) Transcript {
        return .{ .gpa = gpa, .detail = detail };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.cues.items) |c| self.gpa.free(c.text);
        self.cues.deinit(self.gpa);
        for (self.notes.items) |n| self.gpa.free(n);
        self.notes.deinit(self.gpa);
    }

    /// Take a copy, because a `Cue` borrows its builder's buffer only until
    /// the next chunk.
    pub fn add(self: *Transcript, cue: Cue) !void {
        try self.cues.append(self.gpa, .{
            .voice = cue.voice,
            .start_ms = cue.start_ms,
            .end_ms = cue.end_ms,
            .text = try self.gpa.dupe(u8, cue.text),
        });
    }

    /// A NOTE written after the header, before the cues. Kept only when the
    /// detail setting is `.debug`, so nothing is copied for a transcript that
    /// would discard it.
    pub fn note(self: *Transcript, text: []const u8) !void {
        if (self.detail != .debug) return;
        try self.notes.append(self.gpa, try self.gpa.dupe(u8, text));
    }

    /// Render the whole transcript. The caller owns the returned bytes.
    pub fn render(self: *Transcript, header_notes: []const []const u8) ![]u8 {
        std.mem.sort(Owned, self.cues.items, {}, struct {
            fn lessThan(_: void, a: Owned, b: Owned) bool {
                return a.start_ms < b.start_ms;
            }
        }.lessThan);

        var w = Writer.init(self.gpa, self.detail);
        defer w.deinit();

        try w.begin(self.header);
        for (header_notes) |text| try w.headerNote(text);
        for (self.notes.items) |text| try w.note(text);
        for (self.cues.items) |c| try w.cue(c.voice, c.start_ms, c.end_ms, c.text);

        return self.gpa.dupe(u8, w.bytes());
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn render(detail: Detail, build: anytype) ![]u8 {
    var w = Writer.init(testing.allocator, detail);
    defer w.deinit();
    try build(&w);
    return testing.allocator.dupe(u8, w.bytes());
}

test "a file starts with the WEBVTT line" {
    const out = try render(.minimal, struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("WEBVTT\n", out);
}

test "cues carry an identifier, a timing line and a voice span" {
    const out = try render(.minimal, struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
            try w.cue(.near, 4120, 7880, "so the thing I wanted to raise was the routing");
            try w.cue(.far, 8020, 11400, "yeah, I looked at that yesterday");
        }
    }.f);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\WEBVTT
        \\
        \\1
        \\00:00:04.120 --> 00:00:07.880
        \\<v Near>so the thing I wanted to raise was the routing
        \\
        \\2
        \\00:00:08.020 --> 00:00:11.400
        \\<v Far>yeah, I looked at that yesterday
        \\
    , out);
}

test "cue identifiers are unique and increasing" {
    const out = try render(.minimal, struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
            for (0..3) |_| try w.cue(.near, 0, 1000, "x");
        }
    }.f);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\n1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\n2\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\n3\n") != null);
}

test "overlapping cues are written as they are, because crosstalk is legal" {
    const out = try render(.minimal, struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
            try w.cue(.near, 1000, 5000, "both talking");
            try w.cue(.far, 2000, 4000, "at once");
        }
    }.f);
    defer testing.allocator.free(out);

    // The spec asks only that start times do not decrease, which they do not.
    try testing.expect(std.mem.indexOf(u8, out, "00:00:01.000 --> 00:00:05.000") != null);
    try testing.expect(std.mem.indexOf(u8, out, "00:00:02.000 --> 00:00:04.000") != null);
}

test "an end before its start is clamped rather than written backwards" {
    const out = try render(.minimal, struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
            try w.cue(.near, 5000, 1000, "x");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "00:00:05.000 --> 00:00:05.000") != null);
}

test "NOTE blocks are written only when the detail setting asks" {
    const build = struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
            try w.note("{\"cycle\":42,\"state\":\"streaming\"}");
            try w.cue(.near, 0, 1000, "right, that makes sense");
        }
    }.f;

    const without = try render(.minimal, build);
    defer testing.allocator.free(without);
    try testing.expect(std.mem.indexOf(u8, without, "NOTE") == null);
    try testing.expect(std.mem.indexOf(u8, without, "right, that makes sense") != null);

    const with = try render(.debug, build);
    defer testing.allocator.free(with);
    try testing.expect(std.mem.indexOf(u8, with, "NOTE {\"cycle\":42") != null);
    try testing.expect(std.mem.indexOf(u8, with, "right, that makes sense") != null);
}

test "a header note is written whatever the detail setting" {
    const out = try render(.minimal, struct {
        fn f(w: *Writer) !void {
            try w.begin("channels: near=left far=right");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\WEBVTT
        \\
        \\NOTE channels: near=left far=right
        \\
    , out);
}

test "an arrow in speech is defanged rather than truncating the cue" {
    // A cue payload may not contain the substring, and losing transcript would
    // be much worse than rewriting it.
    const out = try render(.minimal, struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
            try w.cue(.near, 0, 1000, "the arrow --> points right");
        }
    }.f);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<v Near>the arrow -> points right") != null);
    // Exactly one timing line, so the payload did not start a second cue.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, " --> "));
}

test "a blank line inside a payload does not end the cue early" {
    const out = try render(.minimal, struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
            try w.cue(.near, 0, 1000, "first\n\n\nsecond");
        }
    }.f);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\WEBVTT
        \\
        \\1
        \\00:00:00.000 --> 00:00:01.000
        \\<v Near>first
        \\second
        \\
    , out);
}

test "carriage returns are dropped, so a CRLF reader sees no blank line" {
    const out = try render(.minimal, struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
            try w.cue(.near, 0, 1000, "one\r\ntwo");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\r") == null);
    try testing.expect(std.mem.indexOf(u8, out, "one\ntwo") != null);
}

test "a note carrying an arrow is defanged too" {
    const out = try render(.debug, struct {
        fn f(w: *Writer) !void {
            try w.begin(null);
            try w.note("emit --> \"hello\"");
        }
    }.f);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, arrow));
}

test "timestamps are fixed width and keep the hours field" {
    var buf: [32]u8 = undefined;

    var s = std.io.fixedBufferStream(&buf);
    try writeTimestamp(s.writer(), 0);
    try testing.expectEqualStrings("00:00:00.000", s.getWritten());

    s = std.io.fixedBufferStream(&buf);
    try writeTimestamp(s.writer(), 4120);
    try testing.expectEqualStrings("00:00:04.120", s.getWritten());

    // Meetings run past an hour, which is why the field is never dropped.
    s = std.io.fixedBufferStream(&buf);
    try writeTimestamp(s.writer(), 3_661_007);
    try testing.expectEqualStrings("01:01:01.007", s.getWritten());

    s = std.io.fixedBufferStream(&buf);
    try writeTimestamp(s.writer(), 36_000_000);
    try testing.expectEqualStrings("10:00:00.000", s.getWritten());
}

test "audio position comes from bytes at the one format capsper uses" {
    try testing.expectEqual(@as(u64, 0), msFromBytes(0));
    try testing.expectEqual(@as(u64, 1000), msFromBytes(32_000));
    try testing.expectEqual(@as(u64, 500), msFromBytes(16_000));
    // An hour, to show the arithmetic does not overflow or lose precision.
    try testing.expectEqual(@as(u64, 3_600_000), msFromBytes(115_200_000));
}

// ─── CueBuilder ──────────────────────────────────────────────────────────────

const loud: f64 = 0.1;
const quiet: f64 = 0.001;

test "text opens a cue and silence closes it" {
    var b = CueBuilder.init(testing.allocator, .near);
    defer b.deinit();

    try testing.expect(try b.push(0, 0 + 560, loud, "hello") == null);
    try testing.expect(try b.push(560, 560 + 560, loud, " there") == null);
    // First quiet chunk is not enough on its own.
    try testing.expect(try b.push(1120, 1120 + 560, quiet, "") == null);

    const cue = (try b.push(1680, 1680 + 560, quiet, "")).?;
    try testing.expectEqual(Voice.near, cue.voice);
    try testing.expectEqual(@as(u64, 0), cue.start_ms);
    try testing.expectEqual(@as(u64, 1120), cue.end_ms);
    try testing.expectEqualStrings("hello there", cue.text);
}

test "silence before any speech produces nothing" {
    var b = CueBuilder.init(testing.allocator, .near);
    defer b.deinit();

    for (0..10) |i| {
        try testing.expect(try b.push(i * 560, i * 560 + 560, quiet, "") == null);
    }
    try testing.expect(b.flush() == null);
}

test "a loud non-emitting chunk keeps the cue open" {
    // The decoder holding tokens mid-word, not a pause. Closing here would cut
    // a sentence in half.
    var b = CueBuilder.init(testing.allocator, .near);
    defer b.deinit();

    try testing.expect(try b.push(0, 0 + 560, loud, "the quick") == null);
    try testing.expect(try b.push(560, 560 + 560, loud, "") == null);
    try testing.expect(try b.push(1120, 1120 + 560, loud, "") == null);
    try testing.expect(try b.push(1680, 1680 + 560, loud, "") == null);
    // Still open, so the rest of the sentence joins the same cue.
    try testing.expect(try b.push(2240, 2240 + 560, loud, " brown fox") == null);

    const cue = b.flush().?;
    try testing.expectEqualStrings("the quick brown fox", cue.text);
    try testing.expectEqual(@as(u64, 2800), cue.end_ms);
}

test "a loud chunk resets the silence run rather than counting toward it" {
    var b = CueBuilder.init(testing.allocator, .near);
    defer b.deinit();

    try testing.expect(try b.push(0, 0 + 560, loud, "one") == null);
    try testing.expect(try b.push(560, 560 + 560, quiet, "") == null);
    try testing.expect(try b.push(1120, 1120 + 560, loud, "") == null);
    // One quiet chunk again, not two in a row, so the cue survives.
    try testing.expect(try b.push(1680, 1680 + 560, quiet, "") == null);
    try testing.expect(b.open);
}

test "a second cue starts where its own text arrived" {
    var b = CueBuilder.init(testing.allocator, .near);
    defer b.deinit();

    _ = try b.push(0, 0 + 560, loud, "first");
    _ = try b.push(560, 560 + 560, quiet, "");
    const first = (try b.push(1120, 1120 + 560, quiet, "")).?;
    try testing.expectEqualStrings("first", first.text);

    try testing.expect(try b.push(1680, 1680 + 560, loud, "second") == null);
    const second = b.flush().?;
    try testing.expectEqualStrings("second", second.text);
    try testing.expectEqual(@as(u64, 1680), second.start_ms);
}

test "the quiet threshold is relative, so gain and microphone do not matter" {
    // The same conversation ten times louder behaves identically.
    for ([_]f64{ 0.01, 0.1, 1.0 }) |scale| {
        var b = CueBuilder.init(testing.allocator, .far);
        defer b.deinit();

        _ = try b.push(0, 0 + 560, scale, "hello");
        try testing.expect(try b.push(560, 560 + 560, scale * 0.6, "") == null); // 60%: still speech
        _ = try b.push(1120, 1120 + 560, scale * 0.1, ""); // 10%: silence
        const cue = (try b.push(1680, 1680 + 560, scale * 0.1, "")).?;
        try testing.expectEqualStrings("hello", cue.text);
    }
}

test "flush closes an open cue and is a no-op afterwards" {
    var b = CueBuilder.init(testing.allocator, .far);
    defer b.deinit();

    _ = try b.push(0, 0 + 560, loud, "trailing words");
    const cue = b.flush().?;
    try testing.expectEqual(Voice.far, cue.voice);
    try testing.expectEqualStrings("trailing words", cue.text);
    try testing.expect(b.flush() == null);
}

test "a cue of nothing but whitespace is dropped" {
    var b = CueBuilder.init(testing.allocator, .near);
    defer b.deinit();

    _ = try b.push(0, 0 + 560, loud, "   ");
    try testing.expect(b.flush() == null);
}

test "surrounding whitespace is trimmed but inner spacing is kept" {
    var b = CueBuilder.init(testing.allocator, .near);
    defer b.deinit();

    _ = try b.push(0, 0 + 560, loud, "  hello ");
    _ = try b.push(560, 560 + 560, loud, " there  ");
    const cue = b.flush().?;
    try testing.expectEqualStrings("hello  there", cue.text);
}

test "a whole session of chunks yields the cues the pauses imply" {
    var b = CueBuilder.init(testing.allocator, .near);
    defer b.deinit();

    var vtt = Writer.init(testing.allocator, .minimal);
    defer vtt.deinit();
    try vtt.begin(null);

    // Two utterances with a pause between them.
    const script = [_]struct { rms: f64, text: []const u8 }{
        .{ .rms = loud, .text = "so the thing" },
        .{ .rms = loud, .text = " I wanted to raise" },
        .{ .rms = quiet, .text = "" },
        .{ .rms = quiet, .text = "" },
        .{ .rms = quiet, .text = "" },
        .{ .rms = loud, .text = "was the routing" },
    };
    for (script, 0..) |step, i| {
        if (try b.push(i * 560, i * 560 + 560, step.rms, step.text)) |cue| {
            try vtt.cue(cue.voice, cue.start_ms, cue.end_ms, cue.text);
        }
    }
    if (b.flush()) |cue| try vtt.cue(cue.voice, cue.start_ms, cue.end_ms, cue.text);

    try testing.expectEqualStrings(
        \\WEBVTT
        \\
        \\1
        \\00:00:00.000 --> 00:00:01.120
        \\<v Near>so the thing I wanted to raise
        \\
        \\2
        \\00:00:02.800 --> 00:00:03.360
        \\<v Near>was the routing
        \\
    , vtt.bytes());
}

// ─── Transcript (merging the two tracks) ─────────────────────────────────────

test "cues from both tracks are merged into one file in time order" {
    var t = Transcript.init(testing.allocator, .minimal);
    defer t.deinit();

    // Added in the order the tracks finished them, which is not time order:
    // a cue completes when its own track goes quiet.
    try t.add(.{ .voice = .near, .start_ms = 1680, .end_ms = 10640, .text = "ask not what your country" });
    try t.add(.{ .voice = .far, .start_ms = 1120, .end_ms = 9000, .text = "and so my fellow americans" });

    const out = try t.render(&.{});
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\WEBVTT
        \\
        \\1
        \\00:00:01.120 --> 00:00:09.000
        \\<v Far>and so my fellow americans
        \\
        \\2
        \\00:00:01.680 --> 00:00:10.640
        \\<v Near>ask not what your country
        \\
    , out);
}

test "start times never decrease, which is the one thing the spec requires" {
    var t = Transcript.init(testing.allocator, .minimal);
    defer t.deinit();

    const starts = [_]u64{ 9000, 100, 5000, 0, 12000, 700 };
    for (starts) |s| {
        try t.add(.{ .voice = .near, .start_ms = s, .end_ms = s + 100, .text = "x" });
    }

    const out = try t.render(&.{});
    defer testing.allocator.free(out);

    var last: u64 = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const sep = std.mem.indexOf(u8, line, " --> ") orelse continue;
        const ms = try parseTimestamp(line[0..sep]);
        try testing.expect(ms >= last);
        last = ms;
    }
    try testing.expectEqual(@as(u64, 12_000), last);
}

test "two cues starting together keep the order they were added in" {
    var t = Transcript.init(testing.allocator, .minimal);
    defer t.deinit();

    try t.add(.{ .voice = .near, .start_ms = 500, .end_ms = 900, .text = "first added" });
    try t.add(.{ .voice = .far, .start_ms = 500, .end_ms = 900, .text = "second added" });

    const out = try t.render(&.{});
    defer testing.allocator.free(out);
    try testing.expect(
        std.mem.indexOf(u8, out, "first added").? < std.mem.indexOf(u8, out, "second added").?,
    );
}

test "header notes come before every cue" {
    var t = Transcript.init(testing.allocator, .minimal);
    defer t.deinit();

    try t.add(.{ .voice = .near, .start_ms = 0, .end_ms = 100, .text = "hello" });

    const out = try t.render(&.{"audio.wav: near = left, far = right"});
    defer testing.allocator.free(out);

    try testing.expect(
        std.mem.indexOf(u8, out, "NOTE audio.wav").? < std.mem.indexOf(u8, out, "<v Near>").?,
    );
}

test "a transcript keeps its own copy of each cue's text" {
    // Cues borrow their builder's buffer, which is reused on the next chunk.
    var t = Transcript.init(testing.allocator, .minimal);
    defer t.deinit();

    var scratch: [16]u8 = "hello there     ".*;
    try t.add(.{ .voice = .near, .start_ms = 0, .end_ms = 100, .text = scratch[0..11] });
    @memset(&scratch, 'x');

    const out = try t.render(&.{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "hello there") != null);
}

test "notes are kept only for a debug transcript" {
    for ([_]Detail{ .minimal, .debug }) |detail| {
        var t = Transcript.init(testing.allocator, detail);
        defer t.deinit();

        try t.note("{\"cycle\":7}");
        try t.add(.{ .voice = .near, .start_ms = 0, .end_ms = 100, .text = "hello" });

        const out = try t.render(&.{});
        defer testing.allocator.free(out);

        try testing.expectEqual(detail == .debug, std.mem.indexOf(u8, out, "{\"cycle\":7}") != null);
        try testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    }
}

test "an empty transcript is still a valid file" {
    var t = Transcript.init(testing.allocator, .minimal);
    defer t.deinit();

    const out = try t.render(&.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("WEBVTT\n", out);
}

/// `HH:MM:SS.mmm` back to milliseconds, for asserting on rendered output.
fn parseTimestamp(text: []const u8) !u64 {
    var parts = std.mem.splitScalar(u8, text, ':');
    const h = try std.fmt.parseInt(u64, parts.next().?, 10);
    const m = try std.fmt.parseInt(u64, parts.next().?, 10);
    var secs = std.mem.splitScalar(u8, parts.next().?, '.');
    const s = try std.fmt.parseInt(u64, secs.next().?, 10);
    const ms = try std.fmt.parseInt(u64, secs.next().?, 10);
    return ((h * 60 + m) * 60 + s) * 1000 + ms;
}

test "a cue of nothing but punctuation is dropped" {
    // What a flush produces when the model finishes a sentence it has already
    // emitted: a subtitle reading "." against silence.
    var b = CueBuilder.init(testing.allocator, .near);
    defer b.deinit();

    _ = try b.push(0, 560, loud, ".");
    try testing.expect(b.flush() == null);
}
