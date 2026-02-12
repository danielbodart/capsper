const std = @import("std");
const c = @import("whisper_c.zig");
const Vad = @import("vad.zig").Vad;
const Pipeline = @import("pipeline.zig").Pipeline;

const posix = std.posix;
const net = std.net;

pub const Server = struct {
    allocator: std.mem.Allocator,
    ctx: *c.whisper_context,
    vad: Vad,
    port: u16,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *c.whisper_context,
        vad: Vad,
        port: u16,
    ) Server {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .vad = vad,
            .port = port,
        };
    }

    pub fn run(self: *Server) !void {
        const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port);
        const listener = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 1);

        std.debug.print("Listening on port {d}\n", .{self.port});

        while (true) {
            const conn = try posix.accept(listener, null, null, posix.SOCK.CLOEXEC);
            defer posix.close(conn);

            std.debug.print("Client connected\n", .{});
            self.handleConnection(conn) catch |err| {
                std.debug.print("Connection error: {}\n", .{err});
            };
            std.debug.print("Client disconnected\n", .{});
        }
    }

    fn handleConnection(self: *Server, conn: posix.socket_t) !void {
        var pipeline = try Pipeline.init(self.allocator, self.ctx, .{}, 4);
        defer pipeline.deinit();

        // Audio accumulation buffer (raw PCM S16_LE bytes)
        var pcm_buf = std.ArrayListUnmanaged(u8){};
        defer pcm_buf.deinit(self.allocator);

        var recv_buf: [32768]u8 = undefined;

        // Track what we've already sent to only emit new text
        var sent_len: usize = 0;

        // How much audio we've already processed (in bytes)
        var processed_bytes: usize = 0;

        // Minimum new audio before re-transcribing (1.2 seconds)
        const min_new_bytes: usize = 38400; // 16000 Hz * 2 bytes * 1.2s

        while (true) {
            const n = posix.read(conn, &recv_buf) catch |err| switch (err) {
                error.ConnectionResetByPeer => return,
                else => return err,
            };

            if (n > 0) {
                try pcm_buf.appendSlice(self.allocator, recv_buf[0..n]);
            }

            const client_closed = (n == 0);
            const new_bytes = pcm_buf.items.len - processed_bytes;

            // Transcribe when we have enough new audio, or client closed with remaining data
            if (new_bytes >= min_new_bytes or (client_closed and pcm_buf.items.len > 0)) {
                const samples = try pcmToFloat(self.allocator, pcm_buf.items);
                defer self.allocator.free(samples);

                if (self.vad.hasSpeech(samples)) {
                    const is_last = client_closed;
                    if (try pipeline.transcribe(samples, is_last)) |result| {
                        defer self.allocator.free(result.text);

                        const text = std.mem.trim(u8, result.text, " ");
                        if (text.len > sent_len) {
                            // Only send the new portion
                            const new_text = std.mem.trimLeft(u8, text[sent_len..], " ");
                            if (new_text.len > 0) {
                                _ = posix.write(conn, new_text) catch return;
                                _ = posix.write(conn, "\n") catch return;
                                std.debug.print("  >> {s}\n", .{new_text});
                            }
                            sent_len = text.len;
                        }
                    }
                }
                processed_bytes = pcm_buf.items.len;
            }

            if (client_closed) return;
        }
    }
};

fn pcmToFloat(allocator: std.mem.Allocator, pcm_bytes: []const u8) ![]f32 {
    const n_samples = pcm_bytes.len / 2;
    const result = try allocator.alloc(f32, n_samples);
    errdefer allocator.free(result);

    for (result, 0..) |*sample, i| {
        const offset = i * 2;
        if (offset + 2 > pcm_bytes.len) break;
        const raw = std.mem.readInt(i16, pcm_bytes[offset..][0..2], .little);
        sample.* = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    return result;
}
