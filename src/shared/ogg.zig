// src/shared/ogg.zig — the container an `.opus` file is actually made of.
//
// libopus produces packets; it does not produce files. An `.opus` file is
// those packets wrapped in Ogg pages, and that wrapping is the whole of this
// module: lacing packets into segments, batching segments into pages, and
// stamping each page with Ogg's own CRC.
//
// Written out rather than pulled in, because libogg is a second dependency for
// something the spec describes in two pages, and this way it is testable
// without an encoder anywhere near it.

const std = @import("std");

/// Ogg's CRC is its own variant: polynomial 0x04c11db7, no input or output
/// reflection, zero initial value and no final xor. It is not the CRC-32 in
/// zip or PNG, and using that one produces a file every player rejects.
const crc_table = blk: {
    @setEvalBranchQuota(20_000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var r: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| {
            r = if (r & 0x8000_0000 != 0) (r << 1) ^ 0x04c1_1db7 else r << 1;
        }
        table[i] = r;
    }
    break :blk table;
};

pub fn crc32(bytes: []const u8) u32 {
    var r: u32 = 0;
    for (bytes) |b| {
        r = (r << 8) ^ crc_table[@as(u8, @truncate(r >> 24)) ^ b];
    }
    return r;
}

/// The largest number of segments one page can carry, so the segment table
/// fits in the single byte that counts it.
pub const max_segments: usize = 255;

pub const Flags = struct {
    /// First page of the stream.
    first: bool = false,
    /// Last page of the stream. A file without it is truncated, and players
    /// say so.
    last: bool = false,
    /// This page starts with the continuation of a packet from the last one.
    continued: bool = false,
};

/// Writes Ogg pages for one logical stream.
///
/// Packets are buffered until a page is asked for, because the caller is the
/// only one who knows where a page boundary should fall -- the granule
/// position on a page describes the audio decoded by the end of it, so a page
/// has to be closed at a point where that number is known.
pub const Stream = struct {
    gpa: std.mem.Allocator,
    serial: u32,
    sequence: u32 = 0,

    /// Lacing values for the packets buffered so far.
    segments: std.ArrayListUnmanaged(u8) = .{},
    /// The packet bytes those lacing values describe.
    body: std.ArrayListUnmanaged(u8) = .{},

    pub fn init(gpa: std.mem.Allocator, serial: u32) Stream {
        return .{ .gpa = gpa, .serial = serial };
    }

    pub fn deinit(self: *Stream) void {
        self.segments.deinit(self.gpa);
        self.body.deinit(self.gpa);
    }

    /// Room for another packet of this size without overflowing a page.
    pub fn fits(self: *const Stream, packet_len: usize) bool {
        return self.segments.items.len + segmentsFor(packet_len) <= max_segments;
    }

    pub fn isEmpty(self: *const Stream) bool {
        return self.segments.items.len == 0;
    }

    /// Add a packet. Lacing is how Ogg encodes a packet's length: a run of
    /// 255s and then a final value under 255. A packet whose length is an
    /// exact multiple of 255 therefore needs a trailing zero, or the next
    /// packet would be read as part of it.
    pub fn addPacket(self: *Stream, packet: []const u8) !void {
        var remaining = packet.len;
        while (remaining >= 255) {
            try self.segments.append(self.gpa, 255);
            remaining -= 255;
        }
        try self.segments.append(self.gpa, @intCast(remaining));
        try self.body.appendSlice(self.gpa, packet);
    }

    /// Emit everything buffered as one page, and forget it.
    ///
    /// `granule` is the position of the audio decoded by the end of this page,
    /// counted in 48 kHz samples whatever the encoder's own rate. -1 means a
    /// page that completes no packet.
    pub fn writePage(self: *Stream, out: *std.ArrayListUnmanaged(u8), granule: i64, flags: Flags) !void {
        var header: [27]u8 = undefined;
        @memcpy(header[0..4], "OggS");
        header[4] = 0; // stream structure version
        header[5] = (if (flags.continued) @as(u8, 0x01) else 0) |
            (if (flags.first) @as(u8, 0x02) else 0) |
            (if (flags.last) @as(u8, 0x04) else 0);
        std.mem.writeInt(i64, header[6..14], granule, .little);
        std.mem.writeInt(u32, header[14..18], self.serial, .little);
        std.mem.writeInt(u32, header[18..22], self.sequence, .little);
        // The checksum is computed with this field zeroed, then written into
        // it, so the page as written checksums to the value it carries.
        std.mem.writeInt(u32, header[22..26], 0, .little);
        header[26] = @intCast(self.segments.items.len);

        const start = out.items.len;
        try out.appendSlice(self.gpa, &header);
        try out.appendSlice(self.gpa, self.segments.items);
        try out.appendSlice(self.gpa, self.body.items);

        const page = out.items[start..];
        std.mem.writeInt(u32, page[22..26], crc32(page), .little);

        self.sequence += 1;
        self.segments.clearRetainingCapacity();
        self.body.clearRetainingCapacity();
    }
};

fn segmentsFor(packet_len: usize) usize {
    return packet_len / 255 + 1;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The fields of a page, read back out of the bytes.
const Page = struct {
    granule: i64,
    serial: u32,
    sequence: u32,
    flags: u8,
    segments: []const u8,
    body: []const u8,
    bytes: []const u8,

    fn parse(bytes: []const u8) !Page {
        if (bytes.len < 27) return error.TooShort;
        if (!std.mem.eql(u8, bytes[0..4], "OggS")) return error.NotAPage;

        const n_segments = bytes[26];
        const segments = bytes[27 .. 27 + n_segments];

        var body_len: usize = 0;
        for (segments) |s| body_len += s;

        const body_start = 27 + @as(usize, n_segments);
        return .{
            .granule = std.mem.readInt(i64, bytes[6..14], .little),
            .serial = std.mem.readInt(u32, bytes[14..18], .little),
            .sequence = std.mem.readInt(u32, bytes[18..22], .little),
            .flags = bytes[5],
            .segments = segments,
            .body = bytes[body_start .. body_start + body_len],
            .bytes = bytes[0 .. body_start + body_len],
        };
    }

    /// Recompute the checksum the way a player would, and compare.
    fn checksumHolds(self: Page) bool {
        const stated = std.mem.readInt(u32, self.bytes[22..26], .little);

        var copy = std.ArrayListUnmanaged(u8){};
        defer copy.deinit(testing.allocator);
        copy.appendSlice(testing.allocator, self.bytes) catch return false;
        std.mem.writeInt(u32, copy.items[22..26], 0, .little);

        return crc32(copy.items) == stated;
    }
};

fn render(build: anytype) ![]u8 {
    var stream = Stream.init(testing.allocator, 0xDEADBEEF);
    defer stream.deinit();
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(testing.allocator);
    try build(&stream, &out);
    return out.toOwnedSlice(testing.allocator);
}

test "a page carries its own header fields" {
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            try s.addPacket("hello");
            try s.writePage(out, 960, .{ .first = true });
        }
    }.f);
    defer testing.allocator.free(bytes);

    const page = try Page.parse(bytes);
    try testing.expectEqual(@as(i64, 960), page.granule);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), page.serial);
    try testing.expectEqual(@as(u32, 0), page.sequence);
    try testing.expectEqual(@as(u8, 0x02), page.flags); // beginning of stream
    try testing.expectEqualStrings("hello", page.body);
}

test "the checksum is over the page with its own field zeroed" {
    // Getting this wrong produces a file every player rejects, and the only
    // symptom is the rejection.
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            try s.addPacket("some audio packet");
            try s.writePage(out, 1920, .{});
        }
    }.f);
    defer testing.allocator.free(bytes);

    try testing.expect((try Page.parse(bytes)).checksumHolds());
}

test "Ogg's CRC is not the one in zip" {
    // 0x04c11db7 unreflected. The familiar CRC-32 over "123456789" is
    // 0xCBF43926; this variant is not that.
    try testing.expect(crc32("123456789") != 0xCBF43926);
    try testing.expectEqual(@as(u32, 0x89A1897F), crc32("123456789"));
}

test "page sequence numbers increase" {
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            for (0..3) |i| {
                try s.addPacket("x");
                try s.writePage(out, @intCast(i * 960), .{});
            }
        }
    }.f);
    defer testing.allocator.free(bytes);

    var offset: usize = 0;
    for (0..3) |i| {
        const page = try Page.parse(bytes[offset..]);
        try testing.expectEqual(@as(u32, @intCast(i)), page.sequence);
        offset += page.bytes.len;
    }
    try testing.expectEqual(bytes.len, offset);
}

test "a packet under 255 bytes is one segment" {
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            try s.addPacket(&[_]u8{0} ** 100);
            try s.writePage(out, 0, .{});
        }
    }.f);
    defer testing.allocator.free(bytes);

    const page = try Page.parse(bytes);
    try testing.expectEqualSlices(u8, &.{100}, page.segments);
}

test "a long packet is laced into 255-byte segments" {
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            try s.addPacket(&[_]u8{0} ** 600);
            try s.writePage(out, 0, .{});
        }
    }.f);
    defer testing.allocator.free(bytes);

    const page = try Page.parse(bytes);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 90 }, page.segments);
    try testing.expectEqual(@as(usize, 600), page.body.len);
}

test "a packet that is a multiple of 255 ends with a zero segment" {
    // Without it, the next packet would be read as a continuation of this one.
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            try s.addPacket(&[_]u8{0} ** 255);
            try s.writePage(out, 0, .{});
        }
    }.f);
    defer testing.allocator.free(bytes);

    const page = try Page.parse(bytes);
    try testing.expectEqualSlices(u8, &.{ 255, 0 }, page.segments);
}

test "several packets share a page and stay separable" {
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            try s.addPacket("one");
            try s.addPacket("two");
            try s.addPacket("three");
            try s.writePage(out, 2880, .{});
        }
    }.f);
    defer testing.allocator.free(bytes);

    const page = try Page.parse(bytes);
    try testing.expectEqualSlices(u8, &.{ 3, 3, 5 }, page.segments);
    try testing.expectEqualStrings("onetwothree", page.body);
}

test "a page knows when it is full" {
    var stream = Stream.init(testing.allocator, 1);
    defer stream.deinit();

    // 254 one-segment packets still leave room for one more.
    for (0..254) |_| try stream.addPacket("x");
    try testing.expect(stream.fits(1));

    try stream.addPacket("x");
    try testing.expect(!stream.fits(1));
    try testing.expect(!stream.fits(1000));
}

test "flags mark the beginning and end of the stream" {
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            try s.addPacket("head");
            try s.writePage(out, 0, .{ .first = true });
            try s.addPacket("tail");
            try s.writePage(out, 960, .{ .last = true });
        }
    }.f);
    defer testing.allocator.free(bytes);

    const first = try Page.parse(bytes);
    try testing.expectEqual(@as(u8, 0x02), first.flags);

    const second = try Page.parse(bytes[first.bytes.len..]);
    try testing.expectEqual(@as(u8, 0x04), second.flags);
}

test "an empty page is legal and carries no segments" {
    // What a stream with nothing left to say still has to write to be closed.
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            try s.writePage(out, 4800, .{ .last = true });
        }
    }.f);
    defer testing.allocator.free(bytes);

    const page = try Page.parse(bytes);
    try testing.expectEqual(@as(usize, 0), page.segments.len);
    try testing.expectEqual(@as(usize, 0), page.body.len);
    try testing.expect(page.checksumHolds());
}

test "a granule of minus one marks a page completing no packet" {
    const bytes = try render(struct {
        fn f(s: *Stream, out: *std.ArrayListUnmanaged(u8)) !void {
            try s.addPacket("partial");
            try s.writePage(out, -1, .{});
        }
    }.f);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(i64, -1), (try Page.parse(bytes)).granule);
}

test "writing a page clears the buffer for the next one" {
    var stream = Stream.init(testing.allocator, 7);
    defer stream.deinit();
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(testing.allocator);

    try stream.addPacket("first");
    try testing.expect(!stream.isEmpty());
    try stream.writePage(&out, 0, .{});
    try testing.expect(stream.isEmpty());

    try stream.addPacket("second");
    try stream.writePage(&out, 960, .{});

    const one = try Page.parse(out.items);
    try testing.expectEqualStrings("first", one.body);
    const two = try Page.parse(out.items[one.bytes.len..]);
    try testing.expectEqualStrings("second", two.body);
}
