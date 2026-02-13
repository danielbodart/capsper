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
