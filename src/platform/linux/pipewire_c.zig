const pw = @cImport({
    @cInclude("pipewire/pipewire.h");
    @cInclude("pipewire/stream.h");
    @cInclude("spa/param/audio/raw.h");
});

// PipeWire core
pub const pw_init = pw.pw_init;
pub const pw_deinit = pw.pw_deinit;

// Thread loop
pub const pw_thread_loop = pw.pw_thread_loop;
pub const pw_thread_loop_new = pw.pw_thread_loop_new;
pub const pw_thread_loop_destroy = pw.pw_thread_loop_destroy;
pub const pw_thread_loop_start = pw.pw_thread_loop_start;
pub const pw_thread_loop_stop = pw.pw_thread_loop_stop;
pub const pw_thread_loop_get_loop = pw.pw_thread_loop_get_loop;

// Stream
pub const pw_stream = pw.pw_stream;
pub const pw_stream_events = pw.pw_stream_events;
pub const pw_stream_new_simple = pw.pw_stream_new_simple;
pub const pw_stream_destroy = pw.pw_stream_destroy;
pub const pw_stream_connect = pw.pw_stream_connect;
pub const pw_stream_dequeue_buffer = pw.pw_stream_dequeue_buffer;
pub const pw_stream_queue_buffer = pw.pw_stream_queue_buffer;
pub const pw_buffer = pw.pw_buffer;

// Properties
pub const pw_properties_new = pw.pw_properties_new;

// Directions and flags
pub const PW_DIRECTION_INPUT = pw.PW_DIRECTION_INPUT;
pub const PW_ID_ANY = pw.PW_ID_ANY;

// Stream flags (c_uint, not an enum — combine with |)
pub const PW_STREAM_FLAG_AUTOCONNECT: c_uint = pw.PW_STREAM_FLAG_AUTOCONNECT;
pub const PW_STREAM_FLAG_MAP_BUFFERS: c_uint = pw.PW_STREAM_FLAG_MAP_BUFFERS;
pub const PW_STREAM_FLAG_RT_PROCESS: c_uint = pw.PW_STREAM_FLAG_RT_PROCESS;

// Stream state
pub const pw_stream_state = pw.enum_pw_stream_state;
pub const PW_STREAM_STATE_ERROR = pw.PW_STREAM_STATE_ERROR;
pub const PW_STREAM_STATE_STREAMING = pw.PW_STREAM_STATE_STREAMING;

// Stream control
pub const pw_stream_disconnect = pw.pw_stream_disconnect;
pub const pw_thread_loop_lock = pw.pw_thread_loop_lock;
pub const pw_thread_loop_unlock = pw.pw_thread_loop_unlock;

// C helper for building SPA audio format pod (avoids variadic macro issues in Zig).
// Takes a raw buffer to write into; returns a pointer into that buffer.
pub extern fn pw_build_audio_format(
    buf: [*]u8,
    buf_size: u32,
    rate: u32,
    channel_position: u32,
) ?*anyopaque;

// C helper to connect a capture stream with proper SPA format negotiation.
// Passing spa_pod** through Zig FFI breaks format negotiation (ports get generic
// names like input_1, auto-connect fails). Doing it in C works correctly.
pub extern fn pw_connect_capture(
    stream: *pw_stream,
    rate: u32,
    channel_position: u32,
) c_int;

// SPA audio channel positions
pub const SPA_AUDIO_CHANNEL_MONO: u32 = pw.SPA_AUDIO_CHANNEL_MONO;
pub const SPA_AUDIO_CHANNEL_FL: u32 = pw.SPA_AUDIO_CHANNEL_FL;
pub const SPA_AUDIO_CHANNEL_FR: u32 = pw.SPA_AUDIO_CHANNEL_FR;
// AUX channels are sequential: AUX0 = 0x1000, AUX1 = 0x1001, ..., AUX63 = 0x103F
pub const SPA_AUDIO_CHANNEL_START_AUX: u32 = pw.SPA_AUDIO_CHANNEL_START_Aux; // 0x1000

pub fn spaAudioChannelAux(n: u32) u32 {
    return SPA_AUDIO_CHANNEL_START_AUX + n;
}

// C helper to set software gain on a PipeWire capture stream via SPA_PROP_channelVolumes.
pub extern fn pw_set_stream_gain(
    stream: *pw_stream,
    gain: f32,
    n_channels: u32,
) c_int;

// C helper to set a source node's own volume, by node name. Linear, so 1.0
// is unity. This is the level every application sees and WirePlumber saves it,
// unlike the per-stream gain above which is private to one capture.
pub extern fn pw_set_source_volume(
    node_name: [*:0]const u8,
    volume: f32,
) c_int;

// C helper to connect a capture stream for multi-channel recording (channel detection).
pub extern fn pw_connect_capture_multi(
    stream: *pw_stream,
    rate: u32,
    channels: u32,
) c_int;

// Source enumeration result (matches struct pw_source_info in pw_helpers.c)
pub const PW_SOURCE_NAME_MAX = 256;
pub const pw_source_info = extern struct {
    id: u32,
    name: [PW_SOURCE_NAME_MAX]u8,
    description: [PW_SOURCE_NAME_MAX]u8,
    channels: u32,
};

// Synchronous enumeration of Audio/Source nodes. Returns count or -1 on error.
pub extern fn pw_enumerate_sources(
    results: [*]pw_source_info,
    max_results: u32,
) c_int;

// Device monitor (hotplug detection)
pub const pw_device_monitor = opaque {};
pub extern fn pw_device_monitor_create(target: [*:0]const u8) ?*pw_device_monitor;
pub extern fn pw_device_monitor_destroy(m: *pw_device_monitor) void;
pub extern fn pw_device_monitor_target_available(m: *pw_device_monitor) c_int;
pub extern fn pw_device_monitor_set_exit_on_lost(m: *pw_device_monitor, pipe_write_fd: c_int) void;
pub extern fn pw_device_monitor_set_on_appeared(m: *pw_device_monitor, cb: ?*const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) void;

// PipeWire property keys
pub const PW_KEY_MEDIA_TYPE = pw.PW_KEY_MEDIA_TYPE;
pub const PW_KEY_MEDIA_CATEGORY = pw.PW_KEY_MEDIA_CATEGORY;
pub const PW_KEY_MEDIA_ROLE = pw.PW_KEY_MEDIA_ROLE;
pub const PW_KEY_TARGET_OBJECT = pw.PW_KEY_TARGET_OBJECT;
pub const PW_KEY_NODE_NAME = pw.PW_KEY_NODE_NAME;

// Virtual sink (the far end of a call, captured from its monitor)
pub const pw_virtual_sink = opaque {};
pub extern fn pw_virtual_sink_create(
    node_name: [*:0]const u8,
    description: [*:0]const u8,
    output_target: ?[*:0]const u8,
) ?*pw_virtual_sink;
pub extern fn pw_virtual_sink_destroy(s: *pw_virtual_sink) void;

// Echo canceller: the near end with the sink's own audio subtracted out.
// Separate from the sink because it lives only while a session is open.
pub const pw_echo_canceller = opaque {};
pub extern fn pw_echo_canceller_create(
    sink_name: [*:0]const u8,
    description: [*:0]const u8,
    mic_target: ?[*:0]const u8,
) ?*pw_echo_canceller;
pub extern fn pw_echo_canceller_destroy(e: *pw_echo_canceller) void;
pub extern fn pw_echo_canceller_ready(e: *pw_echo_canceller) c_int;
pub extern fn pw_echo_canceller_mic_name(e: *pw_echo_canceller) ?[*:0]const u8;

// Sink usage watch (gate 1: is anything playing into our sink?)
pub const pw_sink_watch = opaque {};
pub extern fn pw_sink_watch_create(sink_name: [*:0]const u8) ?*pw_sink_watch;
pub extern fn pw_sink_watch_destroy(w: *pw_sink_watch) void;
pub extern fn pw_sink_watch_active_streams(w: *pw_sink_watch) u32;

// Capture stream properties (variadic pw_properties_new lives in C)
pub extern fn pw_build_capture_props(target: ?[*:0]const u8, capture_sink: c_int) ?*pw.struct_pw_properties;
