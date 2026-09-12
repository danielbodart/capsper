// src/platform/linux/sink.zig — the output device capsper owns, and the echo
// canceller that hangs off it.
//
// Turning on meeting capture puts a sink in the desktop's output picker. The
// user selects it in the meeting app, and that selection is what says "record
// this"; nothing else is ever in it. The audio carries on to the real default
// output, so the call is still audible.
//
// The two types here have deliberately different lifetimes. The sink is up for
// as long as capsper runs, because it has to be in the picker before anyone
// goes looking for it, and idle it sits `suspended` and costs nothing. The
// canceller is up only while a session is open, because it does not sit idle:
// it schedules the sink alongside its own streams, so leaving it running would
// hold the whole graph turning over to cancel echo from calls that are not
// happening. On a laptop that is a core spent on nothing.
//
// Everything here is a thin wrapper over `pw_helpers.c`. The module arguments
// are SPA-flavoured strings and the module API is C, so per the PipeWire FFI
// rule the work lives on that side.

const std = @import("std");
const pw = @import("pipewire_c.zig");
const source = @import("../../shared/source.zig");

pub const VirtualSink = struct {
    handle: *pw.pw_virtual_sink,
    /// The node name the sink appears under, which is also the node to capture
    /// the far end from: a sink's monitor is addressed by the sink's own name.
    ///
    /// Capturing it needs `stream.capture.sink = true` on the capture stream's
    /// properties, and that is not an optimisation. Targeting a sink by name
    /// *without* it does not fail -- the stream falls back to the default
    /// source and quietly records the microphone instead, which sounds like
    /// working code right up until the far-end track turns out to be a second
    /// copy of the near end. `test/pw-sink.test.ts` pins this down by
    /// asserting the monitor reads as digital silence when nothing is playing.
    name: [:0]const u8,

    /// `output_target` names where the call is passed on to, null following
    /// the desktop's default output.
    pub fn init(
        name: [:0]const u8,
        description: [:0]const u8,
        output_target: ?[:0]const u8,
    ) !VirtualSink {
        const handle = pw.pw_virtual_sink_create(
            name.ptr,
            description.ptr,
            if (output_target) |t| t.ptr else null,
        ) orelse return error.VirtualSinkFailed;
        return .{ .handle = handle, .name = name };
    }

    pub fn deinit(self: *VirtualSink) void {
        pw.pw_virtual_sink_destroy(self.handle);
    }
};

/// Loading the module and the module producing nodes are two events, and the
/// second happens on the module's own loop after the first returns. Worse,
/// they come apart: the module loads happily when the cancellation engine
/// behind it is missing, and then never makes the source at all. So the source
/// appearing in the registry is the only honest success signal, and waiting
/// for it has to be bounded -- a target that never arrives would be captured
/// as permanent silence, which is the failure that looks like working code.
const mic_poll_ms: u64 = 25;
const mic_timeout_ms: u64 = 3000;

/// The microphone with the call taken out of it.
///
/// Speakers and an open microphone in one room means the call comes back in a
/// few tens of milliseconds later, so the near track carries a quieter copy of
/// everything the far end said and the far end lands in the transcript twice:
/// once as itself, once putting words in the near end's mouth.
///
/// The cancellation is WebRTC's AEC3, running as a node in the graph rather
/// than as a stage inside capsper. That placement is what keeps the cleaning
/// off the paths that must not have it: push-to-talk dictation, its debug
/// recordings, and the TCP server go on reading the microphone directly,
/// because nothing points them at the cleaned source.
pub const EchoCanceller = struct {
    handle: *pw.pw_echo_canceller,
    /// The node the near track captures from instead of the microphone.
    mic: [:0]const u8,

    /// `sink_name` is the sink whose monitor is the reference, so what gets
    /// subtracted is the call rather than everything the speakers are playing.
    /// `mic_target` null follows the desktop's default input.
    pub fn init(
        sink_name: [:0]const u8,
        description: [:0]const u8,
        mic_target: ?[:0]const u8,
    ) !EchoCanceller {
        const handle = pw.pw_echo_canceller_create(
            sink_name.ptr,
            description.ptr,
            if (mic_target) |t| t.ptr else null,
        ) orelse return error.EchoCancelModuleUnavailable;
        errdefer pw.pw_echo_canceller_destroy(handle);

        var waited: u64 = 0;
        while (pw.pw_echo_canceller_ready(handle) == 0) {
            if (waited >= mic_timeout_ms) return error.EchoCancelUnavailable;
            std.Thread.sleep(mic_poll_ms * std.time.ns_per_ms);
            waited += mic_poll_ms;
        }

        const mic = pw.pw_echo_canceller_mic_name(handle) orelse
            return error.EchoCancelUnavailable;
        return .{ .handle = handle, .mic = std.mem.span(mic) };
    }

    pub fn deinit(self: *EchoCanceller) void {
        pw.pw_echo_canceller_destroy(self.handle);
    }
};

/// Watches how many applications are currently playing into the sink.
///
/// This is gate 1: the user selecting the sink in a meeting app is the signal
/// that a call is happening, and the graph reports it without capsper having
/// to guess from calendars or window titles. Only `running` streams count, so
/// a paused call reads as zero -- the debounce that stops a brief mute ending
/// a session lives in `shared/meeting.zig`.
pub const SinkWatch = struct {
    handle: *pw.pw_sink_watch,

    pub fn init(sink_name: [:0]const u8) !SinkWatch {
        const handle = pw.pw_sink_watch_create(sink_name.ptr) orelse
            return error.SinkWatchFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *SinkWatch) void {
        pw.pw_sink_watch_destroy(self.handle);
    }

    pub fn activeStreams(self: *const SinkWatch) u32 {
        return pw.pw_sink_watch_active_streams(self.handle);
    }

    /// Who is playing into the sink, and everything their clients declared
    /// about themselves. Read at the moment a session opens rather than
    /// later: a browser rebuilds its streams freely, and a second look would
    /// describe a graph that is no longer the one being recorded.
    ///
    /// The allocator should be an arena the caller discards once the metadata
    /// is written. Nothing here is needed for longer than that.
    pub fn snapshot(self: *const SinkWatch, arena: std.mem.Allocator) ![]const source.Stream {
        const snap = pw.pw_sink_watch_snapshot(self.handle) orelse return &.{};
        defer pw.pw_stream_snapshot_destroy(snap);

        const streams = try arena.alloc(source.Stream, pw.pw_stream_snapshot_count(snap));
        for (streams, 0..) |*stream, i| {
            const si: u32 = @intCast(i);
            const props = try arena.alloc(source.Prop, pw.pw_stream_snapshot_prop_count(snap, si));
            for (props, 0..) |*prop, j| {
                const pj: u32 = @intCast(j);
                prop.* = .{
                    .key = try arena.dupe(u8, cstr(pw.pw_stream_snapshot_key(snap, si, pj))),
                    .value = try arena.dupe(u8, cstr(pw.pw_stream_snapshot_value(snap, si, pj))),
                };
            }

            const client = try arena.alloc(source.Prop, pw.pw_stream_snapshot_client_prop_count(snap, si));
            for (client, 0..) |*prop, j| {
                const pj: u32 = @intCast(j);
                prop.* = .{
                    .key = try arena.dupe(u8, cstr(pw.pw_stream_snapshot_client_key(snap, si, pj))),
                    .value = try arena.dupe(u8, cstr(pw.pw_stream_snapshot_client_value(snap, si, pj))),
                };
            }

            stream.* = .{
                .kind = @enumFromInt(pw.pw_stream_snapshot_kind(snap, si)),
                .props = props,
                .client = client,
            };
        }
        return streams;
    }
};

fn cstr(ptr: ?[*:0]const u8) []const u8 {
    return if (ptr) |p| std.mem.span(p) else "";
}
