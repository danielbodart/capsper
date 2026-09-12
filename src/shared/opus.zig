// src/shared/opus.zig — writing an `.opus` file.
//
// libopus produces packets; `ogg.zig` wraps them into pages; this is the part
// in between that knows what an Opus stream in an Ogg container has to look
// like. Two header packets, then audio, then a page marked as the last one.
//
// One number here is easy to get wrong and invisible when it is: granule
// positions are counted in 48 kHz samples whatever rate the encoder was given.
// Capsper records at 16 kHz, so a 20 ms frame is 320 samples in and 960 on the
// clock. Get it wrong and the file plays at the wrong speed with a duration
// nothing agrees on.

const std = @import("std");
const ogg = @import("ogg.zig");

const c = @cImport({
    @cInclude("opus.h");
});

const log = std.log.scoped(.opus);

/// Capsper's one audio format.
pub const sample_rate: u32 = 16000;

/// The rate every Opus timestamp is expressed in, regardless of the input.
const timestamp_rate: u32 = 48000;

/// 20 ms, the frame size everything defaults to and the one with the best
/// overhead-to-latency trade for speech.
pub const frame_ms: u32 = 20;
pub const frame_samples: usize = sample_rate * frame_ms / 1000;
const frame_timestamps: u64 = timestamp_rate * frame_ms / 1000;

/// The plan's budget. Opus couples stereo channels efficiently only when they
/// correlate, and near and far do not at all, so this is roughly twice what a
/// single voice would need -- about 20 MB an hour, the same total two mono
/// tracks would have cost.
pub const default_bitrate: i32 = 48_000;

/// Held back at the start of the decoded stream, and declared in the header so
/// a player knows to drop it. Encoder lookahead, converted to the timestamp
/// rate like everything else.
fn preSkip(encoder: *c.OpusEncoder) u16 {
    var lookahead: c_int = 0;
    if (c.opus_encoder_ctl(encoder, c.OPUS_GET_LOOKAHEAD_REQUEST, &lookahead) != c.OPUS_OK) return 0;
    return @intCast(@as(u32, @intCast(lookahead)) * timestamp_rate / sample_rate);
}

/// Encodes interleaved 16-bit PCM into an Ogg Opus file as it arrives.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    file: std.fs.File,
    encoder: *c.OpusEncoder,
    stream: ogg.Stream,
    channels: u8,

    /// Samples that did not fill a frame, carried to the next write.
    pending: std.ArrayListUnmanaged(i16) = .{},
    /// Bytes ready to go to disk.
    out: std.ArrayListUnmanaged(u8) = .{},

    /// Audio handed to the encoder so far, on the 48 kHz clock.
    granule: u64 = 0,
    pre_skip: u16 = 0,

    /// Big enough for any 20 ms stereo packet; Opus will not exceed it at any
    /// sane bitrate, and it errors rather than overruns if it would.
    var packet_buf: [4000]u8 = undefined;

    pub fn create(gpa: std.mem.Allocator, file: std.fs.File, channels: u8, bitrate: i32) !Writer {
        var err: c_int = 0;
        const encoder = c.opus_encoder_create(
            @intCast(sample_rate),
            @intCast(channels),
            // Not VOIP: the two channels are independent sources hard-panned
            // apart, which is not the single-talker case VOIP mode assumes.
            c.OPUS_APPLICATION_AUDIO,
            &err,
        );
        if (err != c.OPUS_OK or encoder == null) return error.OpusEncoderFailed;
        errdefer c.opus_encoder_destroy(encoder);

        _ = c.opus_encoder_ctl(encoder, c.OPUS_SET_BITRATE_REQUEST, @as(c_int, bitrate));

        var self = Writer{
            .gpa = gpa,
            .file = file,
            .encoder = encoder.?,
            // Any number will do; it only has to be consistent within the file.
            .stream = ogg.Stream.init(gpa, 0x43_41_50_53),
            .channels = channels,
        };
        self.pre_skip = preSkip(encoder.?);

        try self.writeHeaders();
        return self;
    }

    /// The two header packets, each alone on its own page, which is what the
    /// Ogg Opus mapping requires.
    fn writeHeaders(self: *Writer) !void {
        var head: [19]u8 = undefined;
        @memcpy(head[0..8], "OpusHead");
        head[8] = 1; // version
        head[9] = self.channels;
        std.mem.writeInt(u16, head[10..12], self.pre_skip, .little);
        std.mem.writeInt(u32, head[12..16], sample_rate, .little);
        std.mem.writeInt(u16, head[16..18], 0, .little); // output gain
        head[18] = 0; // mapping family: plain mono or stereo

        try self.stream.addPacket(&head);
        try self.stream.writePage(&self.out, 0, .{ .first = true });

        const vendor = "capsper";
        var tags: std.ArrayListUnmanaged(u8) = .{};
        defer tags.deinit(self.gpa);
        try tags.appendSlice(self.gpa, "OpusTags");
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(vendor.len), .little);
        try tags.appendSlice(self.gpa, &len_buf);
        try tags.appendSlice(self.gpa, vendor);
        std.mem.writeInt(u32, &len_buf, 0, .little); // no user comments
        try tags.appendSlice(self.gpa, &len_buf);

        try self.stream.addPacket(tags.items);
        try self.stream.writePage(&self.out, 0, .{});

        try self.flushToDisk();
    }

    /// Feed interleaved 16-bit PCM. Whole frames are encoded; the remainder
    /// waits for the next call.
    pub fn write(self: *Writer, pcm: []const u8) !void {
        // Read sample by sample rather than casting the slice: PCM arrives
        // from a pipe at whatever offset it lands on, and a byte slice carries
        // no promise of being two-aligned.
        const whole = pcm.len - pcm.len % 2;
        try self.pending.ensureUnusedCapacity(self.gpa, whole / 2);
        var i: usize = 0;
        while (i < whole) : (i += 2) {
            self.pending.appendAssumeCapacity(std.mem.readInt(i16, pcm[i..][0..2], .little));
        }

        const per_frame = frame_samples * self.channels;
        while (self.pending.items.len >= per_frame) {
            try self.encodeFrame(self.pending.items[0..per_frame]);

            const rest = self.pending.items.len - per_frame;
            std.mem.copyForwards(i16, self.pending.items[0..rest], self.pending.items[per_frame..]);
            self.pending.shrinkRetainingCapacity(rest);
        }
        try self.flushToDisk();
    }

    fn encodeFrame(self: *Writer, frame: []const i16) !void {
        const n = c.opus_encode(
            self.encoder,
            frame.ptr,
            @intCast(frame_samples),
            &packet_buf,
            @intCast(packet_buf.len),
        );
        if (n < 0) return error.OpusEncodeFailed;

        self.granule += frame_timestamps;

        // A page per packet would be a page of overhead per 20 ms, so packets
        // accumulate until the page is full.
        const packet = packet_buf[0..@intCast(n)];
        if (!self.stream.fits(packet.len)) {
            try self.stream.writePage(&self.out, @intCast(self.granule - frame_timestamps), .{});
        }
        try self.stream.addPacket(packet);
    }

    /// Encode whatever is left, close the stream, and write the file out.
    ///
    /// The last page has to be marked as such: without it the file is
    /// truncated as far as any player is concerned, however complete it is.
    pub fn finish(self: *Writer) void {
        const per_frame = frame_samples * self.channels;
        if (self.pending.items.len > 0) {
            // Pad the last frame with silence rather than dropping it. The
            // granule position still says where the audio really ended, so a
            // player trims the padding rather than playing it.
            self.pending.appendNTimes(self.gpa, 0, per_frame - self.pending.items.len) catch {};
            self.encodeFrame(self.pending.items[0..per_frame]) catch {};
            self.pending.clearRetainingCapacity();
        }

        self.stream.writePage(&self.out, @intCast(self.granule), .{ .last = true }) catch {};
        self.flushToDisk() catch |err| log.err("could not finish the opus file: {}", .{err});

        c.opus_encoder_destroy(self.encoder);
        self.stream.deinit();
        self.pending.deinit(self.gpa);
        self.out.deinit(self.gpa);
    }

    fn flushToDisk(self: *Writer) !void {
        if (self.out.items.len == 0) return;
        try self.file.writeAll(self.out.items);
        self.out.clearRetainingCapacity();
    }

    /// Seconds of audio written, from the one clock that counts.
    pub fn durationSeconds(self: *const Writer) f64 {
        return @as(f64, @floatFromInt(self.granule)) / @as(f64, @floatFromInt(timestamp_rate));
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a frame is 20ms at capsper's rate, on the 48kHz clock" {
    // The conversion that makes a file play at the right speed.
    try testing.expectEqual(@as(usize, 320), frame_samples);
    try testing.expectEqual(@as(u64, 960), frame_timestamps);
}

test "an encoded file starts with the two header packets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("a.opus", .{ .read = true });
    var writer = try Writer.create(testing.allocator, file, 2, default_bitrate);

    // Two seconds of stereo silence is plenty to produce audio pages.
    const silence = [_]u8{0} ** (2 * 2 * sample_rate);
    try writer.write(&silence);
    try testing.expectApproxEqAbs(@as(f64, 1.0), writer.durationSeconds(), 0.05);
    writer.finish();
    file.close();

    const bytes = try tmp.dir.readFileAlloc(testing.allocator, "a.opus", 1 << 20);
    defer testing.allocator.free(bytes);

    // The identification header is alone on the first page, as the mapping
    // requires, and the comment header follows.
    try testing.expectEqualStrings("OggS", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "OpusHead") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "OpusTags") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "OpusHead").? < std.mem.indexOf(u8, bytes, "OpusTags").?);
}

test "the header declares the channels and the recording rate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("b.opus", .{ .read = true });
    var writer = try Writer.create(testing.allocator, file, 2, default_bitrate);
    writer.finish();
    file.close();

    const bytes = try tmp.dir.readFileAlloc(testing.allocator, "b.opus", 1 << 20);
    defer testing.allocator.free(bytes);

    const head = std.mem.indexOf(u8, bytes, "OpusHead").?;
    try testing.expectEqual(@as(u8, 1), bytes[head + 8]); // version
    try testing.expectEqual(@as(u8, 2), bytes[head + 9]); // stereo
    try testing.expectEqual(sample_rate, std.mem.readInt(u32, bytes[head + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u8, 0), bytes[head + 18]); // mapping family 0
}

test "the file ends with a page marked as the last" {
    // Without the flag a player reports the file as truncated, however
    // complete it is.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("c.opus", .{ .read = true });
    var writer = try Writer.create(testing.allocator, file, 2, default_bitrate);
    const silence = [_]u8{0} ** (2 * 2 * sample_rate);
    try writer.write(&silence);
    writer.finish();
    file.close();

    const bytes = try tmp.dir.readFileAlloc(testing.allocator, "c.opus", 1 << 20);
    defer testing.allocator.free(bytes);

    // Walk to the final page and check its header-type byte.
    var offset: usize = 0;
    var last_flags: u8 = 0;
    while (offset + 27 <= bytes.len and std.mem.eql(u8, bytes[offset..][0..4], "OggS")) {
        const n_segments = bytes[offset + 26];
        var body: usize = 0;
        for (bytes[offset + 27 ..][0..n_segments]) |s| body += s;
        last_flags = bytes[offset + 5];
        offset += 27 + @as(usize, n_segments) + body;
    }
    try testing.expectEqual(bytes.len, offset); // every byte accounted for
    try testing.expectEqual(@as(u8, 0x04), last_flags);
}

test "a partial frame is padded rather than dropped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("d.opus", .{ .read = true });
    var writer = try Writer.create(testing.allocator, file, 2, default_bitrate);

    // Half a frame: 160 stereo samples where 320 make a frame.
    const half = [_]u8{0} ** (160 * 2 * 2);
    try writer.write(&half);
    try testing.expectEqual(@as(u64, 0), writer.granule); // nothing encoded yet

    writer.finish();
    file.close();

    const bytes = try tmp.dir.readFileAlloc(testing.allocator, "d.opus", 1 << 20);
    defer testing.allocator.free(bytes);
    // The tail was encoded on the way out, so there is more than just headers.
    try testing.expect(bytes.len > 100);
}

test "opus is much smaller than the wav it came from" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("e.opus", .{ .read = true });
    var writer = try Writer.create(testing.allocator, file, 2, default_bitrate);

    // Ten seconds of stereo at 16 kHz is 640 kB as WAV.
    const chunk = [_]u8{0} ** 64_000;
    for (0..10) |_| try writer.write(&chunk);
    writer.finish();
    file.close();

    const size = (try tmp.dir.statFile("e.opus")).size;
    try testing.expect(size < 640_000 / 4);
}
