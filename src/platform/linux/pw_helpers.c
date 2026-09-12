#include <pipewire/pipewire.h>
#include <pipewire/stream.h>
#include <pipewire/core.h>
#include <pipewire/impl-module.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/props.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <stdatomic.h>

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

/* Set software gain on a PipeWire capture stream via SPA_PROP_channelVolumes.
   Must be in C because pw_stream_set_control uses varargs. */
int
pw_set_stream_gain(struct pw_stream *stream, float gain, uint32_t n_channels)
{
    float vol[64]; /* SPA_AUDIO_MAX_CHANNELS */
    if (n_channels > 64) n_channels = 64;
    for (uint32_t i = 0; i < n_channels; i++)
        vol[i] = gain;
    return pw_stream_set_control(stream, SPA_PROP_channelVolumes, n_channels, vol, 0);
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

/* ─── PipeWire device monitor (hotplug) ──────────────────────────────────── */

struct pw_device_monitor {
    struct pw_thread_loop *thread_loop;
    struct pw_context     *context;
    struct pw_core        *core;
    struct pw_registry    *registry;
    struct spa_hook        registry_listener;
    struct spa_hook        core_listener;
    char       target[256];
    _Atomic uint32_t target_node_id;  /* PW id when present, 0 = absent */
    int        initial_enum_done;     /* set after first pw_core_sync */
    int        pending_sync;
    _Atomic int exit_on_lost;         /* if set, close pipe_write_fd on target removal */
    _Atomic int pipe_write_fd;        /* fd to close on target removal (-1 = none) */
    /* Called when the target (re)appears after the initial enumeration — e.g.
       the user powers on the mic after login. Lets the capture stream re-route
       to the target without a PTT press (needed in low-latency always-active
       mode, where nothing else triggers a reconnect). */
    void (*on_appeared)(void *);
    void  *on_appeared_data;
};

static void
on_monitor_global(void *data, uint32_t id, uint32_t permissions,
                  const char *type, uint32_t version,
                  const struct spa_dict *props)
{
    struct pw_device_monitor *m = data;
    (void)permissions; (void)version;

    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0 || !props)
        return;

    const char *media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    if (!media_class)
        return;
    if (strncmp(media_class, "Audio/Source", 11) != 0)
        return;

    const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    if (!name || strcmp(name, m->target) != 0)
        return;

    atomic_store(&m->target_node_id, id);
    if (m->initial_enum_done) {
        fprintf(stderr, "[hotplug] Target device appeared: %s\n", name);
        if (m->on_appeared)
            m->on_appeared(m->on_appeared_data);
    }
}

static void
on_monitor_global_remove(void *data, uint32_t id)
{
    struct pw_device_monitor *m = data;
    if (atomic_load(&m->target_node_id) == id) {
        atomic_store(&m->target_node_id, 0);
        fprintf(stderr, "[hotplug] Target device removed\n");
        if (atomic_load(&m->exit_on_lost)) {
            int fd = atomic_exchange(&m->pipe_write_fd, -1);
            if (fd >= 0) {
                fprintf(stderr, "[hotplug] Closing audio pipe (--on-device-lost exit)\n");
                close(fd);
            }
        }
    }
}

static void
on_monitor_core_done(void *data, uint32_t id, int seq)
{
    struct pw_device_monitor *m = data;
    if (id == PW_ID_CORE && seq == m->pending_sync)
        m->initial_enum_done = 1;
}

struct pw_device_monitor *
pw_device_monitor_create(const char *target)
{
    struct pw_device_monitor *m = calloc(1, sizeof(*m));
    if (!m) return NULL;

    snprintf(m->target, sizeof(m->target), "%s", target);
    atomic_store(&m->pipe_write_fd, -1);
    atomic_store(&m->exit_on_lost, 0);

    m->thread_loop = pw_thread_loop_new("capsper-hotplug", NULL);
    if (!m->thread_loop) { free(m); return NULL; }

    m->context = pw_context_new(
        pw_thread_loop_get_loop(m->thread_loop), NULL, 0);
    if (!m->context) {
        pw_thread_loop_destroy(m->thread_loop);
        free(m); return NULL;
    }

    /* Lock before connect so registry events don't fire before listeners are set */
    pw_thread_loop_lock(m->thread_loop);

    if (pw_thread_loop_start(m->thread_loop) < 0) {
        pw_thread_loop_unlock(m->thread_loop);
        pw_context_destroy(m->context);
        pw_thread_loop_destroy(m->thread_loop);
        free(m); return NULL;
    }

    m->core = pw_context_connect(m->context, NULL, 0);
    if (!m->core) {
        pw_thread_loop_unlock(m->thread_loop);
        pw_thread_loop_stop(m->thread_loop);
        pw_context_destroy(m->context);
        pw_thread_loop_destroy(m->thread_loop);
        free(m); return NULL;
    }

    m->registry = pw_core_get_registry(m->core, PW_VERSION_REGISTRY, 0);
    if (!m->registry) {
        pw_core_disconnect(m->core);
        pw_thread_loop_unlock(m->thread_loop);
        pw_thread_loop_stop(m->thread_loop);
        pw_context_destroy(m->context);
        pw_thread_loop_destroy(m->thread_loop);
        free(m); return NULL;
    }

    static const struct pw_registry_events reg_events = {
        PW_VERSION_REGISTRY_EVENTS,
        .global = on_monitor_global,
        .global_remove = on_monitor_global_remove,
    };
    spa_zero(m->registry_listener);
    pw_registry_add_listener(m->registry, &m->registry_listener,
                             &reg_events, m);

    static const struct pw_core_events core_events = {
        PW_VERSION_CORE_EVENTS,
        .done = on_monitor_core_done,
    };
    spa_zero(m->core_listener);
    pw_core_add_listener(m->core, &m->core_listener, &core_events, m);

    /* Sync roundtrip — initial_enum_done is set in the callback */
    m->pending_sync = pw_core_sync(m->core, PW_ID_CORE, 0);

    pw_thread_loop_unlock(m->thread_loop);

    return m;
}

void
pw_device_monitor_destroy(struct pw_device_monitor *m)
{
    if (!m) return;

    pw_thread_loop_lock(m->thread_loop);
    spa_hook_remove(&m->registry_listener);
    spa_hook_remove(&m->core_listener);
    pw_proxy_destroy((struct pw_proxy *)m->registry);
    pw_core_disconnect(m->core);
    pw_thread_loop_unlock(m->thread_loop);

    pw_thread_loop_stop(m->thread_loop);
    pw_context_destroy(m->context);
    pw_thread_loop_destroy(m->thread_loop);
    free(m);
}

int
pw_device_monitor_target_available(struct pw_device_monitor *m)
{
    return atomic_load(&m->target_node_id) != 0;
}

void
pw_device_monitor_set_exit_on_lost(struct pw_device_monitor *m, int pipe_write_fd)
{
    if (!m) return;
    atomic_store(&m->pipe_write_fd, pipe_write_fd);
    atomic_store(&m->exit_on_lost, 1);
}

/* Register a callback invoked (on the monitor's thread loop) when the target
   device (re)appears after startup. The callback must do its own locking of any
   other PipeWire loop it touches (e.g. the capture stream's thread loop). */
void
pw_device_monitor_set_on_appeared(struct pw_device_monitor *m,
                                  void (*cb)(void *), void *data)
{
    if (!m) return;
    m->on_appeared = cb;
    m->on_appeared_data = data;
}

/* ─── Virtual sink ──────────────────────────────────────────────────────────

   A sink capsper owns, so the far end of a call can be captured from
   somewhere that contains only the call. The user selects it in the meeting
   app, and that selection is the declaration of intent -- unlike the default
   output's monitor, which would also catch music and notifications.

   It is `libpipewire-module-loopback` loaded into our own context, which is
   exactly what the `pw-loopback` tool does. One module gives all three things
   the graph needs: the sink itself (the loopback's capture end, declared
   Audio/Sink), a monitor on it to capture from, and a playback end that
   carries the audio on to the real default output so the call is still
   audible.

   The playback end is `node.passive`, so the whole thing sits in `suspended`
   when no application is holding the sink. That is what lets the graph answer
   "is a call happening?" rather than being permanently busy. */

struct pw_virtual_sink {
    struct pw_thread_loop *thread_loop;
    struct pw_context     *context;
    struct pw_core        *core;
    struct pw_impl_module *module;
};

struct pw_virtual_sink *
pw_virtual_sink_create(const char *node_name, const char *description)
{
    if (!node_name || !node_name[0])
        return NULL;

    /* Refcounted, and the sink can be the first thing in the process to touch
       PipeWire -- it goes up before the model loads. */
    pw_init(NULL, NULL);

    struct pw_virtual_sink *s = calloc(1, sizeof(*s));
    if (!s) return NULL;

    /* Stereo on both ends: the sink has to look like ordinary speakers to the
       meeting app, and the monitor's two channels are what the far end is
       eventually mixed down from. */
    char args[1024];
    snprintf(args, sizeof(args),
             "{ "
             "capture.props = { "
                 "media.class = Audio/Sink "
                 "node.name = \"%s\" "
                 "node.description = \"%s\" "
                 "audio.position = [ FL FR ] "
             "} "
             "playback.props = { "
                 "node.name = \"%s.passthrough\" "
                 "node.description = \"%s (pass-through)\" "
                 "node.passive = true "
                 "audio.position = [ FL FR ] "
             "} "
             "}",
             node_name, description ? description : node_name,
             node_name, description ? description : node_name);

    s->thread_loop = pw_thread_loop_new("capsper-sink", NULL);
    if (!s->thread_loop) { free(s); return NULL; }

    s->context = pw_context_new(pw_thread_loop_get_loop(s->thread_loop), NULL, 0);
    if (!s->context) {
        pw_thread_loop_destroy(s->thread_loop);
        free(s); return NULL;
    }

    pw_thread_loop_lock(s->thread_loop);

    if (pw_thread_loop_start(s->thread_loop) < 0) {
        pw_thread_loop_unlock(s->thread_loop);
        pw_context_destroy(s->context);
        pw_thread_loop_destroy(s->thread_loop);
        free(s); return NULL;
    }

    s->core = pw_context_connect(s->context, NULL, 0);
    if (!s->core) {
        pw_thread_loop_unlock(s->thread_loop);
        pw_thread_loop_stop(s->thread_loop);
        pw_context_destroy(s->context);
        pw_thread_loop_destroy(s->thread_loop);
        free(s); return NULL;
    }

    /* The module creates its nodes on this loop, which is why the load
       happens under the lock rather than before the loop is running. */
    s->module = pw_context_load_module(s->context,
                                       "libpipewire-module-loopback", args, NULL);
    if (!s->module) {
        fprintf(stderr, "[sink] Failed to load libpipewire-module-loopback\n");
        pw_core_disconnect(s->core);
        pw_thread_loop_unlock(s->thread_loop);
        pw_thread_loop_stop(s->thread_loop);
        pw_context_destroy(s->context);
        pw_thread_loop_destroy(s->thread_loop);
        free(s); return NULL;
    }

    pw_thread_loop_unlock(s->thread_loop);

    fprintf(stderr, "[sink] Virtual sink '%s' ready\n", node_name);
    return s;
}

void
pw_virtual_sink_destroy(struct pw_virtual_sink *s)
{
    if (!s) return;

    pw_thread_loop_lock(s->thread_loop);
    /* Destroying the context unloads the module with it, which is what
       removes the sink from the graph. */
    if (s->core)
        pw_core_disconnect(s->core);
    pw_thread_loop_unlock(s->thread_loop);

    pw_thread_loop_stop(s->thread_loop);
    pw_context_destroy(s->context);
    pw_thread_loop_destroy(s->thread_loop);
    free(s);
}
