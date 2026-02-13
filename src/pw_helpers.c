#include <pipewire/pipewire.h>
#include <pipewire/stream.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>

/* Build a SPA pod for S16_LE mono capture at the given channel position.
   Called from Zig because spa_format_audio_raw_build uses complex C macros
   (SPA_POD_Array, etc.) that expand into variadic function calls Zig can't handle.

   The caller provides a raw buffer; we build the pod into it and return a pointer
   into that buffer. The buffer must stay alive until pw_stream_connect() returns. */
struct spa_pod *
pw_build_audio_format(uint8_t *buf, uint32_t buf_size,
                      uint32_t rate, uint32_t channel_position)
{
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, buf_size);
    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(
        .format = SPA_AUDIO_FORMAT_S16_LE,
        .rate = rate,
        .channels = 1,
        .position = { channel_position }
    );
    return spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);
}

/* Connect a PipeWire capture stream with the given audio format.
   Done in C because passing the spa_pod** params array through Zig FFI
   causes format negotiation to fail (ports get generic names like input_1
   instead of input_MONO, and auto-connect doesn't work). */
int
pw_connect_capture(struct pw_stream *stream,
                   uint32_t rate, uint32_t channel_position)
{
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(
        .format = SPA_AUDIO_FORMAT_S16_LE,
        .rate = rate,
        .channels = 1,
        .position = { channel_position }
    );
    const struct spa_pod *pod = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);
    if (!pod) return -1;

    return pw_stream_connect(stream,
        PW_DIRECTION_INPUT,
        PW_ID_ANY,
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
        &pod, 1);
}
