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

// SPA audio channel positions (u32 constants)
pub const SPA_AUDIO_CHANNEL_AUX0: u32 = pw.SPA_AUDIO_CHANNEL_AUX0;
pub const SPA_AUDIO_CHANNEL_AUX1: u32 = pw.SPA_AUDIO_CHANNEL_AUX1;
pub const SPA_AUDIO_CHANNEL_AUX2: u32 = pw.SPA_AUDIO_CHANNEL_AUX2;
pub const SPA_AUDIO_CHANNEL_AUX3: u32 = pw.SPA_AUDIO_CHANNEL_AUX3;
pub const SPA_AUDIO_CHANNEL_AUX4: u32 = pw.SPA_AUDIO_CHANNEL_AUX4;
pub const SPA_AUDIO_CHANNEL_AUX5: u32 = pw.SPA_AUDIO_CHANNEL_AUX5;
pub const SPA_AUDIO_CHANNEL_AUX6: u32 = pw.SPA_AUDIO_CHANNEL_AUX6;
pub const SPA_AUDIO_CHANNEL_AUX7: u32 = pw.SPA_AUDIO_CHANNEL_AUX7;
pub const SPA_AUDIO_CHANNEL_MONO: u32 = pw.SPA_AUDIO_CHANNEL_MONO;
pub const SPA_AUDIO_CHANNEL_FL: u32 = pw.SPA_AUDIO_CHANNEL_FL;

// PipeWire property keys
pub const PW_KEY_MEDIA_TYPE = pw.PW_KEY_MEDIA_TYPE;
pub const PW_KEY_MEDIA_CATEGORY = pw.PW_KEY_MEDIA_CATEGORY;
pub const PW_KEY_MEDIA_ROLE = pw.PW_KEY_MEDIA_ROLE;
pub const PW_KEY_TARGET_OBJECT = pw.PW_KEY_TARGET_OBJECT;
pub const PW_KEY_NODE_NAME = pw.PW_KEY_NODE_NAME;
