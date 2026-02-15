#include <pipewire/pipewire.h>
#include <pipewire/stream.h>
#include <pipewire/core.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

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
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS
            | PW_STREAM_FLAG_INACTIVE,
        &pod, 1);
}

/* Connect a PipeWire capture stream for multi-channel recording.
   Like pw_connect_capture but requests all channels (for channel detection). */
int
pw_connect_capture_multi(struct pw_stream *stream,
                         uint32_t rate, uint32_t channels)
{
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(
        .format = SPA_AUDIO_FORMAT_S16_LE,
        .rate = rate,
        .channels = channels
    );
    const struct spa_pod *pod = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);
    if (!pod) return -1;

    return pw_stream_connect(stream,
        PW_DIRECTION_INPUT,
        PW_ID_ANY,
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
        &pod, 1);
}

/* ─── PipeWire source enumeration ────────────────────────────────────────── */

#define PW_SOURCE_NAME_MAX 256

struct pw_source_info {
    uint32_t id;
    char name[PW_SOURCE_NAME_MAX];
    char description[PW_SOURCE_NAME_MAX];
    uint32_t channels;
};

struct node_binding {
    struct spa_hook listener;
    struct pw_source_info *info;
};

struct enum_data {
    struct pw_source_info *results;
    uint32_t max_results;
    uint32_t count;
    uint32_t total_globals;
    struct pw_main_loop *loop;
    int pending_sync;
    struct pw_registry *registry;
    struct node_binding bindings[64];
    struct pw_proxy *proxies[64];
    uint32_t n_bindings;
};

static void
on_node_info(void *data, const struct pw_node_info *info)
{
    struct node_binding *nb = data;
    if (!info || !info->props) return;

    const char *ch_str = spa_dict_lookup(info->props, "audio.channels");
    if (ch_str && nb->info->channels == 0)
        nb->info->channels = (uint32_t)atoi(ch_str);
}

static const struct pw_node_events node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = on_node_info,
};

static void
on_registry_global(void *data, uint32_t id, uint32_t permissions,
                   const char *type, uint32_t version,
                   const struct spa_dict *props)
{
    struct enum_data *d = data;
    (void)permissions;

    d->total_globals++;

    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0 || !props)
        return;

    const char *media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    if (!media_class)
        return;
    /* Accept Audio/Source and Audio/Source/Virtual (loopback, etc.) */
    if (strncmp(media_class, "Audio/Source", 11) != 0)
        return;

    if (d->count >= d->max_results)
        return;

    struct pw_source_info *info = &d->results[d->count];
    info->id = id;

    const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    const char *desc = spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION);
    const char *ch_str = spa_dict_lookup(props, "audio.channels");

    snprintf(info->name, PW_SOURCE_NAME_MAX, "%s", name ? name : "");
    snprintf(info->description, PW_SOURCE_NAME_MAX, "%s", desc ? desc : "");
    info->channels = ch_str ? (uint32_t)atoi(ch_str) : 0;

    /* Bind node proxy to get detailed info (audio.channels from pw_node_info) */
    if (d->n_bindings < 64) {
        struct pw_proxy *proxy = pw_registry_bind(d->registry, id, type, version, 0);
        if (proxy) {
            struct node_binding *nb = &d->bindings[d->n_bindings];
            spa_zero(nb->listener);
            nb->info = info;
            pw_node_add_listener((struct pw_node *)proxy, &nb->listener, &node_events, nb);
            d->proxies[d->n_bindings] = proxy;
            d->n_bindings++;
        }
    }

    d->count++;
}

static void
on_core_done(void *data, uint32_t id, int seq)
{
    struct enum_data *d = data;
    if (id == PW_ID_CORE && seq == d->pending_sync)
        pw_main_loop_quit(d->loop);
}

/* Enumerate PipeWire Audio/Source nodes synchronously.
   Returns the number of sources found (up to max_results).
   Caller provides the results array. Returns -1 on error. */
int
pw_enumerate_sources(struct pw_source_info *results, uint32_t max_results)
{
    pw_init(NULL, NULL);

    struct pw_main_loop *loop = pw_main_loop_new(NULL);
    if (!loop) { pw_deinit(); return -1; }

    struct pw_context *context = pw_context_new(pw_main_loop_get_loop(loop), NULL, 0);
    if (!context) { pw_main_loop_destroy(loop); pw_deinit(); return -1; }

    struct pw_core *core = pw_context_connect(context, NULL, 0);
    if (!core) { pw_context_destroy(context); pw_main_loop_destroy(loop); pw_deinit(); return -1; }

    struct pw_registry *registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
    if (!registry) { pw_core_disconnect(core); pw_context_destroy(context); pw_main_loop_destroy(loop); pw_deinit(); return -1; }

    struct enum_data data = {
        .results = results,
        .max_results = max_results,
        .count = 0,
        .total_globals = 0,
        .loop = loop,
        .pending_sync = 0,
        .registry = registry,
        .n_bindings = 0,
    };

    /* Registry listener */
    static const struct pw_registry_events reg_events = {
        PW_VERSION_REGISTRY_EVENTS,
        .global = on_registry_global,
    };
    struct spa_hook reg_listener;
    spa_zero(reg_listener);
    pw_registry_add_listener(registry, &reg_listener, &reg_events, &data);

    /* Core listener for sync/roundtrip */
    static const struct pw_core_events core_events = {
        PW_VERSION_CORE_EVENTS,
        .done = on_core_done,
    };
    struct spa_hook core_listener;
    spa_zero(core_listener);
    pw_core_add_listener(core, &core_listener, &core_events, &data);

    /* First roundtrip: enumerate globals and bind node proxies */
    data.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);
    pw_main_loop_run(loop);

    /* Second roundtrip: let node info callbacks deliver audio.channels */
    data.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);
    pw_main_loop_run(loop);

    /* Cleanup */
    for (uint32_t i = 0; i < data.n_bindings; i++) {
        spa_hook_remove(&data.bindings[i].listener);
        pw_proxy_destroy(data.proxies[i]);
    }
    spa_hook_remove(&reg_listener);
    spa_hook_remove(&core_listener);
    pw_proxy_destroy((struct pw_proxy *)registry);
    pw_core_disconnect(core);
    pw_context_destroy(context);
    pw_main_loop_destroy(loop);
    pw_deinit();

    if (data.count == 0)
        fprintf(stderr, "No audio sources found "
                "(saw %u PipeWire objects).\n", data.total_globals);

    return (int)data.count;
}
