#include <pipewire/pipewire.h>
#include <pipewire/stream.h>
#include <pipewire/core.h>
#include <pipewire/impl-module.h>
#include <pipewire/extensions/metadata.h>
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

   `state.restore-props = false` on both ends, and it is load-bearing. The
   session manager otherwise saves whatever volume it last saw and hands it
   back to the next node with the same `media.name` -- which is derived from
   the description, so every capsper pass-through shares one. Muting a sink
   once, in a test, saved a zero against that shared name, and every meeting
   sink afterwards came up silent: linked correctly to the speakers, carrying
   the call, at volume zero. Capsper owns its own levels; the session manager
   must not remember them for it.

   The playback end is `node.passive`, so the whole thing sits in `suspended`
   when no application is holding the sink. That is what lets the graph answer
   "is a call happening?" rather than being permanently busy, and it is why the
   echo canceller below is a separate module with a separate lifetime rather
   than part of this one. Folding the two together works and costs exactly that
   property: the canceller schedules the sink alongside its own streams, so the
   sink never goes idle and the machine processes audio around the clock for
   the sake of calls that are not happening. */

struct pw_virtual_sink {
    struct pw_thread_loop *thread_loop;
    struct pw_context     *context;
    struct pw_core        *core;
    struct pw_impl_module *module;
};

struct pw_virtual_sink *
pw_virtual_sink_create(const char *node_name, const char *description,
                       const char *output_target)
{
    if (!node_name || !node_name[0])
        return NULL;

    /* Refcounted, and the sink can be the first thing in the process to touch
       PipeWire -- it goes up before the model loads. */
    pw_init(NULL, NULL);

    struct pw_virtual_sink *s = calloc(1, sizeof(*s));
    if (!s) return NULL;

    const char *desc = description ? description : node_name;

    /* Null follows the default output, which is the ordinary case. Naming one
       is what lets a test send the call somewhere it owns instead of at
       whoever is in the room. */
    char out[320] = "";
    if (output_target && output_target[0])
        snprintf(out, sizeof(out), "target.object = \"%s\" ", output_target);

    /* Stereo on both ends: the sink has to look like ordinary speakers to the
       meeting app, and the monitor's two channels are what the far end is
       eventually mixed down from.

       `node.nick` carries the same text as `node.description` because the two
       are read inconsistently: pavucontrol and GNOME show the description,
       while patchbay-style tools prefer the nick. Setting one and not the
       other means the sink is labelled properly in some pickers and shows its
       bare node name in the rest. */
    char args[1024];
    snprintf(args, sizeof(args),
             "{ "
             "capture.props = { "
                 "media.class = Audio/Sink "
                 "node.name = \"%s\" "
                 "node.description = \"%s\" "
                 "node.nick = \"%s\" "
                 "state.restore-props = false "
                 "audio.position = [ FL FR ] "
             "} "
             "playback.props = { "
                 "node.name = \"%s.passthrough\" "
                 "node.description = \"%s (pass-through)\" "
                 "node.passive = true "
                 "state.restore-props = false "
                 "%s"
                 "audio.position = [ FL FR ] "
             "} "
             "}",
             node_name, desc, desc,
             node_name, desc, out);

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

/* ─── Echo canceller ────────────────────────────────────────────────────────

   Speakers and an open microphone in one room means the call comes back in a
   few tens of milliseconds later, so the near track carries a quieter copy of
   everything the far end said and the far end lands in the transcript twice:
   once as itself, once putting words in the near end's mouth.

   `libpipewire-module-echo-cancel` in `monitor.mode`, which makes no sink of
   its own. Instead it captures a reference, captures the microphone, and
   exposes one Source carrying the microphone with the reference subtracted
   out. Two properties on that reference stream are what point it at capsper's
   sink rather than at the desktop's default output: `target.object` names the
   sink, and `stream.capture.sink` is what turns naming a sink into capturing
   its monitor. Without the second one it silently takes the default microphone
   instead, which is the same trap the far-end capture has to avoid.

   Taking the reference from capsper's own sink rather than from the default
   output is what makes this the call being removed rather than everything the
   speakers are playing, and it means the cancellation does not depend on which
   output happens to be the default -- something capsper does not control.

   It lives and dies with a session, not with the process. Idle, it would
   otherwise hold the whole graph running to cancel echo from calls that are
   not happening, which costs a core on a laptop for nothing. The price is that
   the filter reconverges each time a session opens; calls tend to start with
   the far end talking, which is the signal it needs.

   `priority.session = 0` keeps WirePlumber from making the cleaned microphone
   the desktop's default input. It has to be the only thing doing that job.
   Declaring the class Audio/Source/Virtual instead, or as well, is the obvious
   way to hide a synthetic node and it does hide it -- from capsper too. The
   near track's own capture is matched by the same session manager, so a class
   that says "not a real microphone" leaves that stream with nothing to link to
   and the near track records digital silence.

   And there is deliberately no `audio.position` on the microphone, however
   obvious one looks next to a mono mic. Pinning the capture to a single
   channel while the reference stays stereo makes WebRTC reject every frame as
   kBadNumberChannelsError, and it reports that nowhere capsper can see: the
   module loads, announces its plugin, builds all its nodes, links them
   correctly, and cancels nothing. Measured 1733 failed frames in eighteen
   seconds with a position set, and none without one. */

struct pw_echo_canceller {
    struct pw_thread_loop *thread_loop;
    struct pw_context     *context;
    struct pw_core        *core;
    struct pw_impl_module *module;
    struct pw_registry    *registry;
    struct spa_hook        registry_listener;

    char     mic_name[256];
    /* Read from the main thread; written only on the thread loop. */
    _Atomic uint32_t mic_id;
};

static void
on_aec_global(void *data, uint32_t id, uint32_t permissions,
              const char *type, uint32_t version,
              const struct spa_dict *props)
{
    struct pw_echo_canceller *e = data;
    (void)permissions;
    (void)version;

    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0 || !props)
        return;

    const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    if (name && strcmp(name, e->mic_name) == 0)
        atomic_store(&e->mic_id, id);
}

static void
on_aec_global_remove(void *data, uint32_t id)
{
    struct pw_echo_canceller *e = data;
    if (atomic_load(&e->mic_id) == id)
        atomic_store(&e->mic_id, 0);
}

static const struct pw_registry_events aec_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = on_aec_global,
    .global_remove = on_aec_global_remove,
};

/* `sink_name` is the sink whose monitor is the reference. `mic_target` names
   the microphone to clean, null meaning follow the desktop's default input.
   The cleaned microphone is named `<sink_name>.mic`, derived rather than
   configured for the same reason the pass-through end's name is. */
struct pw_echo_canceller *
pw_echo_canceller_create(const char *sink_name, const char *description,
                         const char *mic_target)
{
    if (!sink_name || !sink_name[0])
        return NULL;

    pw_init(NULL, NULL);

    struct pw_echo_canceller *e = calloc(1, sizeof(*e));
    if (!e) return NULL;
    snprintf(e->mic_name, sizeof(e->mic_name), "%s.mic", sink_name);

    char mic_desc[320];
    snprintf(mic_desc, sizeof(mic_desc), "%s (microphone)",
             description ? description : sink_name);

    char target[320] = "";
    if (mic_target && mic_target[0])
        snprintf(target, sizeof(target), "target.object = \"%s\" ", mic_target);

    char args[1536];
    snprintf(args, sizeof(args),
             "{ "
             "monitor.mode = true "
             "library.name = aec/libspa-aec-webrtc "
             /* Off rather than left at their defaults: the plugin can also
                apply gain control, noise suppression and a high-pass filter,
                and all three would move the near track's levels, which the cue
                logic reads to decide when a speaker has stopped. Removing the
                echo is the change being made here. */
             "aec.args = { "
                 "webrtc.gain_control = false "
                 "webrtc.noise_suppression = false "
                 "webrtc.high_pass_filter = false "
             "} "
             "sink.props = { "
                 "target.object = \"%s\" "
                 "stream.capture.sink = true "
             "} "
             "capture.props = { "
                 "%s"
             "} "
             "source.props = { "
                 "node.name = \"%s\" "
                 "node.description = \"%s\" "
                 "node.nick = \"%s\" "
                 "priority.session = 0 "
                 /* Same reason as the sink: a remembered zero here would be a
                    near track of digital silence. */
                 "state.restore-props = false "
             "} "
             "}",
             sink_name, target, e->mic_name, mic_desc, mic_desc);

    e->thread_loop = pw_thread_loop_new("capsper-aec", NULL);
    if (!e->thread_loop) { free(e); return NULL; }

    e->context = pw_context_new(pw_thread_loop_get_loop(e->thread_loop), NULL, 0);
    if (!e->context) {
        pw_thread_loop_destroy(e->thread_loop);
        free(e); return NULL;
    }

    pw_thread_loop_lock(e->thread_loop);

    if (pw_thread_loop_start(e->thread_loop) < 0) {
        pw_thread_loop_unlock(e->thread_loop);
        pw_context_destroy(e->context);
        pw_thread_loop_destroy(e->thread_loop);
        free(e); return NULL;
    }

    e->core = pw_context_connect(e->context, NULL, 0);
    if (!e->core) {
        pw_thread_loop_unlock(e->thread_loop);
        pw_thread_loop_stop(e->thread_loop);
        pw_context_destroy(e->context);
        pw_thread_loop_destroy(e->thread_loop);
        free(e); return NULL;
    }

    /* Watching before loading, so the cleaned microphone cannot appear in the
       window between the two and go unnoticed. */
    e->registry = pw_core_get_registry(e->core, PW_VERSION_REGISTRY, 0);
    if (e->registry)
        pw_registry_add_listener(e->registry, &e->registry_listener, &aec_events, e);

    /* A null here means the module itself is missing. The cancellation engine
       behind it loads separately and later, so this succeeding does not mean
       cancellation works, which is why the caller waits for the cleaned
       microphone rather than trusting this. */
    e->module = pw_context_load_module(e->context,
                                       "libpipewire-module-echo-cancel", args, NULL);
    if (!e->module) {
        fprintf(stderr, "[aec] Failed to load libpipewire-module-echo-cancel\n");
        if (e->registry) {
            spa_hook_remove(&e->registry_listener);
            pw_proxy_destroy((struct pw_proxy *)e->registry);
        }
        pw_core_disconnect(e->core);
        pw_thread_loop_unlock(e->thread_loop);
        pw_thread_loop_stop(e->thread_loop);
        pw_context_destroy(e->context);
        pw_thread_loop_destroy(e->thread_loop);
        free(e); return NULL;
    }

    pw_thread_loop_unlock(e->thread_loop);
    return e;
}

void
pw_echo_canceller_destroy(struct pw_echo_canceller *e)
{
    if (!e) return;

    pw_thread_loop_lock(e->thread_loop);
    if (e->registry) {
        spa_hook_remove(&e->registry_listener);
        pw_proxy_destroy((struct pw_proxy *)e->registry);
    }
    if (e->core)
        pw_core_disconnect(e->core);
    pw_thread_loop_unlock(e->thread_loop);

    pw_thread_loop_stop(e->thread_loop);
    pw_context_destroy(e->context);
    pw_thread_loop_destroy(e->thread_loop);
    free(e);
}

/* Has the cleaned microphone appeared in the graph? Safe from any thread. */
int
pw_echo_canceller_ready(struct pw_echo_canceller *e)
{
    return (e && atomic_load(&e->mic_id) != 0) ? 1 : 0;
}

/* The cleaned microphone's node name. Owned by the canceller. */
const char *
pw_echo_canceller_mic_name(struct pw_echo_canceller *e)
{
    return e ? e->mic_name : NULL;
}

/* ─── Sink usage watch (gate 1) ─────────────────────────────────────────────

   Answers one question: how many applications are currently playing into
   capsper's sink? That is the arm/disarm signal for a meeting, and it comes
   free with the dedicated sink -- an application holding the sink creates a
   Stream/Output/Audio node linked to it, and the node's state distinguishes
   playing from paused.

   Matching is on links whose *input* is the sink. capsper's own far-end
   capture attaches to the sink's monitor, which puts it on the output side of
   its link, so it is ignored without needing to be named. The loopback's
   pass-through end is likewise invisible here: its link goes into the real
   default output, not into the sink.

   Counting only `running` streams is what makes a paused call disarm: a
   paused client keeps its node but drops to `idle`. The debounce that stops a
   brief mute from splitting a meeting in two lives in Zig, not here -- this
   reports the instantaneous graph and nothing more. */

#define SINK_WATCH_MAX 32

struct pw_sink_watch;

/* One property as the graph reported it, copied so it outlives the event. */
struct prop_pair {
    char *key;
    char *value;
};

struct watched_stream {
    struct pw_sink_watch *watch;
    struct spa_hook        listener;
    struct pw_proxy       *proxy;
    uint32_t               node_id;
    enum pw_node_state     state;
    int                    used;
    /* Only output streams can link into the sink, so only they arm the gate.
       Input streams are tracked anyway, because the microphone stream an app
       opens alongside its playback is what tells a call from a video, and it
       is worth recording as metadata even though it never counts. */
    int                    is_input;
    /* The node's properties as last reported. Deep-copied, because the dict
       the event hands over belongs to the loop and does not outlive the
       callback. */
    struct prop_pair      *props;
    uint32_t               n_props;
};

static void
watched_stream_free_props(struct watched_stream *s)
{
    for (uint32_t i = 0; i < s->n_props; i++) {
        free(s->props[i].key);
        free(s->props[i].value);
    }
    free(s->props);
    s->props = NULL;
    s->n_props = 0;
}

static void copy_props(struct prop_pair **dst, uint32_t *dst_n, const struct spa_dict *d);

/* An info event carries only what changed, and `props` is NULL on the ones
   that changed something else.

   Every stream sends several: the first arrives with the properties and the
   node still idle, and the later ones say it is running and carry nothing.
   Copying unconditionally therefore threw the properties away moments after
   receiving them, and did it just before the gate opened -- so the metadata
   was reliably empty by the time anything came to read it, while the gate,
   the recording and the transcript all carried on working perfectly. */
static void
watched_stream_copy_props(struct watched_stream *s, const struct pw_node_info *info)
{
    if (!(info->change_mask & PW_NODE_CHANGE_MASK_PROPS) || !info->props)
        return;
    watched_stream_free_props(s);
    copy_props(&s->props, &s->n_props, info->props);
}

static const char *
props_lookup(const struct prop_pair *props, uint32_t n, const char *key)
{
    for (uint32_t i = 0; i < n; i++)
        if (strcmp(props[i].key, key) == 0)
            return props[i].value;
    return NULL;
}

static const char *
watched_stream_prop(const struct watched_stream *s, const char *key)
{
    return props_lookup(s->props, s->n_props, key);
}

/* The client behind a stream, tracked separately because the node does not
   carry everything its client declared -- and because the one identifier in
   the whole set that a client cannot lie about lives here.

   `application.process.id` on the node is whatever the application said about
   itself through the PulseAudio compatibility layer. A native PipeWire client
   such as `pw-play` does not set it at all. `pipewire.sec.pid` on the client
   is the peer credential of the socket, which the kernel supplies and no
   client can choose. For an application connecting through pipewire-pulse it
   names the pulse server rather than the application, so it is a fallback
   rather than a replacement -- but it is the only one there is when an
   application says nothing about itself. */
struct watched_client {
    struct pw_sink_watch *watch;
    struct spa_hook        listener;
    struct pw_proxy       *proxy;
    uint32_t               client_id;
    struct prop_pair      *props;
    uint32_t               n_props;
    int                    used;
};

static void
watched_client_free_props(struct watched_client *c)
{
    for (uint32_t i = 0; i < c->n_props; i++) {
        free(c->props[i].key);
        free(c->props[i].value);
    }
    free(c->props);
    c->props = NULL;
    c->n_props = 0;
}

/* Same copy as a stream's, against a different owner. */
static void
copy_props(struct prop_pair **dst, uint32_t *dst_n, const struct spa_dict *d)
{
    if (!d || d->n_items == 0)
        return;
    struct prop_pair *copy = calloc(d->n_items, sizeof(*copy));
    if (!copy)
        return;

    uint32_t n = 0;
    const struct spa_dict_item *item;
    spa_dict_for_each(item, d) {
        if (!item->key || !item->value)
            continue;
        char *k = strdup(item->key);
        char *v = strdup(item->value);
        if (!k || !v) { free(k); free(v); continue; }
        copy[n].key = k;
        copy[n].value = v;
        n++;
    }
    *dst = copy;
    *dst_n = n;
}

struct watched_link {
    uint32_t link_id;
    uint32_t out_node_id;
    int      used;
};

struct pw_sink_watch {
    struct pw_thread_loop *thread_loop;
    struct pw_context     *context;
    struct pw_core        *core;
    struct pw_registry    *registry;
    struct spa_hook        registry_listener;

    char     sink_name[256];
    uint32_t sink_id;   /* 0 until the sink shows up in the registry */

    struct watched_stream streams[SINK_WATCH_MAX];
    /* The sources and sinks themselves, as against the streams using them.
       Tracked so a recording can say which microphone it came off, which is
       the question its own properties cannot answer: a stream names the
       application, never the hardware. */
    struct watched_stream devices[SINK_WATCH_MAX];
    struct watched_client clients[SINK_WATCH_MAX];
    struct watched_link   links[SINK_WATCH_MAX];

    /* Read from the main thread; written only on the thread loop. */
    _Atomic uint32_t running_count;
};

static struct watched_stream *
sink_watch_find_stream(struct pw_sink_watch *w, uint32_t node_id)
{
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++)
        if (w->streams[i].used && w->streams[i].node_id == node_id)
            return &w->streams[i];
    return NULL;
}


/* Recount from scratch rather than tracking deltas: the inputs are two small
   fixed arrays, and a count that can drift out of step with the graph is the
   one bug that would be invisible until a meeting failed to record. */
static void
sink_watch_recount(struct pw_sink_watch *w)
{
    uint32_t running = 0;
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        if (!w->links[i].used)
            continue;
        struct watched_stream *s = sink_watch_find_stream(w, w->links[i].out_node_id);
        if (s && s->state == PW_NODE_STATE_RUNNING)
            running++;
    }
    atomic_store(&w->running_count, running);
}

static void
on_watched_stream_info(void *data, const struct pw_node_info *info)
{
    struct watched_stream *s = data;
    if (!info) return;
    s->state = info->state;
    watched_stream_copy_props(s, info);
    sink_watch_recount(s->watch);
}

static const struct pw_node_events watched_stream_events = {
    PW_VERSION_NODE_EVENTS,
    .info = on_watched_stream_info,
};

/* Bind a node into one of the fixed arrays. Devices and streams differ only
   in which array they land in and what the snapshot then does with them. */
static void
sink_watch_bind_node(struct pw_sink_watch *w, struct watched_stream *slots,
                     uint32_t id, uint32_t version, int is_input)
{
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++)
        if (slots[i].used && slots[i].node_id == id)
            return;

    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        struct watched_stream *s = &slots[i];
        if (s->used)
            continue;
        struct pw_proxy *proxy = pw_registry_bind(w->registry, id,
                                                  PW_TYPE_INTERFACE_Node, version, 0);
        if (!proxy)
            return;
        s->used = 1;
        s->node_id = id;
        s->proxy = proxy;
        s->watch = w;
        s->is_input = is_input;
        s->state = PW_NODE_STATE_CREATING;
        spa_zero(s->listener);
        pw_node_add_listener((struct pw_node *)proxy, &s->listener,
                             &watched_stream_events, s);
        return;
    }
}

static void
sink_watch_add_stream(struct pw_sink_watch *w, uint32_t id, uint32_t version,
                      int is_input)
{
    sink_watch_bind_node(w, w->streams, id, version, is_input);
}

static void
on_watched_client_info(void *data, const struct pw_client_info *info)
{
    struct watched_client *c = data;
    if (!info) return;
    // Same partial-update rule as a node's.
    if (!(info->change_mask & PW_CLIENT_CHANGE_MASK_PROPS) || !info->props)
        return;
    watched_client_free_props(c);
    copy_props(&c->props, &c->n_props, info->props);
}

static const struct pw_client_events watched_client_events = {
    PW_VERSION_CLIENT_EVENTS,
    .info = on_watched_client_info,
};

static void
sink_watch_add_client(struct pw_sink_watch *w, uint32_t id, uint32_t version)
{
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++)
        if (w->clients[i].used && w->clients[i].client_id == id)
            return;

    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        struct watched_client *c = &w->clients[i];
        if (c->used)
            continue;
        struct pw_proxy *proxy = pw_registry_bind(w->registry, id,
                                                  PW_TYPE_INTERFACE_Client, version, 0);
        if (!proxy)
            return;
        c->used = 1;
        c->client_id = id;
        c->proxy = proxy;
        c->watch = w;
        spa_zero(c->listener);
        pw_client_add_listener((struct pw_client *)proxy, &c->listener,
                               &watched_client_events, c);
        return;
    }
}

static struct watched_client *
sink_watch_find_client(struct pw_sink_watch *w, const char *id)
{
    if (!id)
        return NULL;
    uint32_t want = (uint32_t)atoi(id);
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++)
        if (w->clients[i].used && w->clients[i].client_id == want)
            return &w->clients[i];
    return NULL;
}

static void
sink_watch_add_link(struct pw_sink_watch *w, uint32_t link_id, uint32_t out_node_id)
{
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        if (w->links[i].used && w->links[i].link_id == link_id)
            return;
    }
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        if (w->links[i].used)
            continue;
        w->links[i].used = 1;
        w->links[i].link_id = link_id;
        w->links[i].out_node_id = out_node_id;
        sink_watch_recount(w);
        return;
    }
}

static void
on_sink_watch_global(void *data, uint32_t id, uint32_t permissions,
                     const char *type, uint32_t version,
                     const struct spa_dict *props)
{
    struct pw_sink_watch *w = data;
    (void)permissions;

    if (!props)
        return;

    if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
        const char *media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
        const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);

        if (!media_class)
            return;

        if (name && strcmp(media_class, "Audio/Sink") == 0 &&
            strcmp(name, w->sink_name) == 0)
            w->sink_id = id;

        if (strcmp(media_class, "Stream/Output/Audio") == 0)
            sink_watch_add_stream(w, id, version, 0);
        else if (strcmp(media_class, "Stream/Input/Audio") == 0)
            sink_watch_add_stream(w, id, version, 1);
        else if (strcmp(media_class, "Audio/Source") == 0)
            sink_watch_bind_node(w, w->devices, id, version, 1);
        else if (strcmp(media_class, "Audio/Sink") == 0)
            sink_watch_bind_node(w, w->devices, id, version, 0);
        return;
    }

    if (strcmp(type, PW_TYPE_INTERFACE_Client) == 0) {
        sink_watch_add_client(w, id, version);
        return;
    }

    if (strcmp(type, PW_TYPE_INTERFACE_Link) == 0) {
        const char *in_node = spa_dict_lookup(props, PW_KEY_LINK_INPUT_NODE);
        const char *out_node = spa_dict_lookup(props, PW_KEY_LINK_OUTPUT_NODE);
        if (!in_node || !out_node || w->sink_id == 0)
            return;
        if ((uint32_t)atoi(in_node) != w->sink_id)
            return;
        sink_watch_add_link(w, id, (uint32_t)atoi(out_node));
    }
}

static void
on_sink_watch_global_remove(void *data, uint32_t id)
{
    struct pw_sink_watch *w = data;
    int changed = 0;

    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        if (w->links[i].used && w->links[i].link_id == id) {
            w->links[i].used = 0;
            changed = 1;
        }
    }
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        struct watched_stream *s = &w->streams[i];
        if (s->used && s->node_id == id) {
            spa_hook_remove(&s->listener);
            pw_proxy_destroy(s->proxy);
            watched_stream_free_props(s);
            s->used = 0;
            s->proxy = NULL;
            changed = 1;
        }
        struct watched_stream *d = &w->devices[i];
        if (d->used && d->node_id == id) {
            spa_hook_remove(&d->listener);
            pw_proxy_destroy(d->proxy);
            watched_stream_free_props(d);
            d->used = 0;
            d->proxy = NULL;
        }
    }
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        struct watched_client *c = &w->clients[i];
        if (c->used && c->client_id == id) {
            spa_hook_remove(&c->listener);
            pw_proxy_destroy(c->proxy);
            watched_client_free_props(c);
            c->used = 0;
            c->proxy = NULL;
        }
    }
    if (w->sink_id == id)
        w->sink_id = 0;

    if (changed)
        sink_watch_recount(w);
}

struct pw_sink_watch *
pw_sink_watch_create(const char *sink_name)
{
    if (!sink_name || !sink_name[0])
        return NULL;

    pw_init(NULL, NULL);

    struct pw_sink_watch *w = calloc(1, sizeof(*w));
    if (!w) return NULL;
    snprintf(w->sink_name, sizeof(w->sink_name), "%s", sink_name);

    w->thread_loop = pw_thread_loop_new("capsper-sinkwatch", NULL);
    if (!w->thread_loop) { free(w); return NULL; }

    w->context = pw_context_new(pw_thread_loop_get_loop(w->thread_loop), NULL, 0);
    if (!w->context) {
        pw_thread_loop_destroy(w->thread_loop);
        free(w); return NULL;
    }

    pw_thread_loop_lock(w->thread_loop);

    if (pw_thread_loop_start(w->thread_loop) < 0) {
        pw_thread_loop_unlock(w->thread_loop);
        pw_context_destroy(w->context);
        pw_thread_loop_destroy(w->thread_loop);
        free(w); return NULL;
    }

    w->core = pw_context_connect(w->context, NULL, 0);
    if (!w->core) {
        pw_thread_loop_unlock(w->thread_loop);
        pw_thread_loop_stop(w->thread_loop);
        pw_context_destroy(w->context);
        pw_thread_loop_destroy(w->thread_loop);
        free(w); return NULL;
    }

    w->registry = pw_core_get_registry(w->core, PW_VERSION_REGISTRY, 0);
    if (!w->registry) {
        pw_core_disconnect(w->core);
        pw_thread_loop_unlock(w->thread_loop);
        pw_thread_loop_stop(w->thread_loop);
        pw_context_destroy(w->context);
        pw_thread_loop_destroy(w->thread_loop);
        free(w); return NULL;
    }

    static const struct pw_registry_events reg_events = {
        PW_VERSION_REGISTRY_EVENTS,
        .global = on_sink_watch_global,
        .global_remove = on_sink_watch_global_remove,
    };
    spa_zero(w->registry_listener);
    pw_registry_add_listener(w->registry, &w->registry_listener, &reg_events, w);

    pw_thread_loop_unlock(w->thread_loop);
    return w;
}

void
pw_sink_watch_destroy(struct pw_sink_watch *w)
{
    if (!w) return;

    pw_thread_loop_lock(w->thread_loop);
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        if (w->streams[i].used) {
            spa_hook_remove(&w->streams[i].listener);
            pw_proxy_destroy(w->streams[i].proxy);
            watched_stream_free_props(&w->streams[i]);
            w->streams[i].used = 0;
        }
        if (w->devices[i].used) {
            spa_hook_remove(&w->devices[i].listener);
            pw_proxy_destroy(w->devices[i].proxy);
            watched_stream_free_props(&w->devices[i]);
            w->devices[i].used = 0;
        }
        if (w->clients[i].used) {
            spa_hook_remove(&w->clients[i].listener);
            pw_proxy_destroy(w->clients[i].proxy);
            watched_client_free_props(&w->clients[i]);
            w->clients[i].used = 0;
        }
    }
    pw_core_disconnect(w->core);
    pw_thread_loop_unlock(w->thread_loop);

    pw_thread_loop_stop(w->thread_loop);
    pw_context_destroy(w->context);
    pw_thread_loop_destroy(w->thread_loop);
    free(w);
}

/* Applications currently playing into the sink. Safe to call from any thread. */
uint32_t
pw_sink_watch_active_streams(struct pw_sink_watch *w)
{
    return w ? atomic_load(&w->running_count) : 0;
}

/* Who is playing into the sink, and what the graph knows about them.

   The gate says a call is happening; this says whose. Both readings come from
   the same registry, so the metadata recorded against a session is the state
   that opened it rather than a second look taken later, by which time a
   browser may have torn the stream down and built another.

   Two kinds of stream are included. The ones linked into the sink are the
   call's audio and the reason the session exists. Alongside them go any
   streams sharing a process with those, which in practice means the
   microphone an app captures while it is on a call: a property of the same
   application, reported by the same client, and the clearest evidence in the
   graph that this is a conversation rather than a video playing.

   Everything is copied under the loop lock into memory the caller owns, so
   the snapshot stays readable after the graph has moved on. Nothing is
   parsed or interpreted here; the values are what the client said about
   itself, verbatim, for something later to make sense of. */

/* 0 playing into the sink, 1 another stream of the same process, 2 a device. */
struct snap_stream {
    int kind;
    uint32_t n_props;
    struct prop_pair *props;
    /* What the client behind the stream declared, kept apart from the node's
       own properties rather than merged: the two disagree on purpose, and
       which one said a thing is part of what it is worth. */
    uint32_t n_client_props;
    struct prop_pair *client_props;
};

struct pw_stream_snapshot {
    uint32_t n;
    struct snap_stream *streams;
};

static int
dup_props(struct prop_pair **dst, uint32_t *dst_n,
          const struct prop_pair *src, uint32_t n)
{
    *dst_n = 0;
    *dst = calloc(n ? n : 1, sizeof(**dst));
    if (!*dst)
        return -1;
    for (uint32_t i = 0; i < n; i++) {
        char *k = strdup(src[i].key);
        char *v = strdup(src[i].value);
        if (!k || !v) { free(k); free(v); continue; }
        (*dst)[*dst_n].key = k;
        (*dst)[*dst_n].value = v;
        (*dst_n)++;
    }
    return 0;
}

static int
snap_copy(struct snap_stream *dst, struct pw_sink_watch *w,
          const struct watched_stream *src)
{
    if (dup_props(&dst->props, &dst->n_props, src->props, src->n_props) != 0)
        return -1;

    struct watched_client *client =
        sink_watch_find_client(w, watched_stream_prop(src, PW_KEY_CLIENT_ID));
    if (client)
        dup_props(&dst->client_props, &dst->n_client_props,
                  client->props, client->n_props);
    return 0;
}

struct pw_stream_snapshot *
pw_sink_watch_snapshot(struct pw_sink_watch *w)
{
    if (!w) return NULL;

    struct pw_stream_snapshot *snap = calloc(1, sizeof(*snap));
    if (!snap) return NULL;
    snap->streams = calloc(SINK_WATCH_MAX * 2, sizeof(*snap->streams));
    if (!snap->streams) { free(snap); return NULL; }

    pw_thread_loop_lock(w->thread_loop);

    /* Pass one: the streams actually feeding the sink. */
    int linked_slot[SINK_WATCH_MAX] = {0};
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        if (!w->links[i].used)
            continue;
        struct watched_stream *s = sink_watch_find_stream(w, w->links[i].out_node_id);
        if (!s || !s->used)
            continue;
        for (uint32_t j = 0; j < SINK_WATCH_MAX; j++) {
            if (&w->streams[j] != s)
                continue;
            if (linked_slot[j])
                break;          /* two links from one stream is one stream */
            linked_slot[j] = 1;
            struct snap_stream *dst = &snap->streams[snap->n];
            dst->kind = 0;
            if (snap_copy(dst, w, s) == 0)
                snap->n++;
            break;
        }
    }

    /* Pass two: everything else the same processes are doing with audio. */
    for (uint32_t i = 0; i < SINK_WATCH_MAX; i++) {
        struct watched_stream *s = &w->streams[i];
        if (!s->used || linked_slot[i] || snap->n >= SINK_WATCH_MAX)
            continue;
        const char *pid = watched_stream_prop(s, PW_KEY_APP_PROCESS_ID);
        if (!pid)
            continue;

        int related = 0;
        for (uint32_t j = 0; j < SINK_WATCH_MAX && !related; j++) {
            if (!linked_slot[j])
                continue;
            const char *other = watched_stream_prop(&w->streams[j], PW_KEY_APP_PROCESS_ID);
            related = other && strcmp(other, pid) == 0;
        }
        if (!related)
            continue;

        struct snap_stream *dst = &snap->streams[snap->n];
        dst->kind = 1;
        if (snap_copy(dst, w, s) == 0)
            snap->n++;
    }

    /* Pass three: the hardware. Every source and sink goes in and the caller
       picks out the ones it asked to record through, because only the caller
       knows what it asked for. */
    for (uint32_t i = 0; i < SINK_WATCH_MAX && snap->n < SINK_WATCH_MAX * 2; i++) {
        struct watched_stream *d = &w->devices[i];
        if (!d->used || d->n_props == 0)
            continue;
        struct snap_stream *dst = &snap->streams[snap->n];
        dst->kind = 2;
        if (snap_copy(dst, w, d) == 0)
            snap->n++;
    }

    pw_thread_loop_unlock(w->thread_loop);
    return snap;
}

void
pw_stream_snapshot_destroy(struct pw_stream_snapshot *snap)
{
    if (!snap) return;
    for (uint32_t i = 0; i < snap->n; i++) {
        struct snap_stream *s = &snap->streams[i];
        for (uint32_t j = 0; j < s->n_props; j++) {
            free(s->props[j].key);
            free(s->props[j].value);
        }
        free(s->props);
        for (uint32_t j = 0; j < s->n_client_props; j++) {
            free(s->client_props[j].key);
            free(s->client_props[j].value);
        }
        free(s->client_props);
    }
    free(snap->streams);
    free(snap);
}

uint32_t
pw_stream_snapshot_count(const struct pw_stream_snapshot *snap)
{
    return snap ? snap->n : 0;
}

int
pw_stream_snapshot_kind(const struct pw_stream_snapshot *snap, uint32_t i)
{
    return (snap && i < snap->n) ? snap->streams[i].kind : 0;
}

uint32_t
pw_stream_snapshot_prop_count(const struct pw_stream_snapshot *snap, uint32_t i)
{
    return (snap && i < snap->n) ? snap->streams[i].n_props : 0;
}

const char *
pw_stream_snapshot_key(const struct pw_stream_snapshot *snap, uint32_t i, uint32_t j)
{
    if (!snap || i >= snap->n || j >= snap->streams[i].n_props) return NULL;
    return snap->streams[i].props[j].key;
}

const char *
pw_stream_snapshot_value(const struct pw_stream_snapshot *snap, uint32_t i, uint32_t j)
{
    if (!snap || i >= snap->n || j >= snap->streams[i].n_props) return NULL;
    return snap->streams[i].props[j].value;
}

uint32_t
pw_stream_snapshot_client_prop_count(const struct pw_stream_snapshot *snap, uint32_t i)
{
    return (snap && i < snap->n) ? snap->streams[i].n_client_props : 0;
}

const char *
pw_stream_snapshot_client_key(const struct pw_stream_snapshot *snap, uint32_t i, uint32_t j)
{
    if (!snap || i >= snap->n || j >= snap->streams[i].n_client_props) return NULL;
    return snap->streams[i].client_props[j].key;
}

const char *
pw_stream_snapshot_client_value(const struct pw_stream_snapshot *snap, uint32_t i, uint32_t j)
{
    if (!snap || i >= snap->n || j >= snap->streams[i].n_client_props) return NULL;
    return snap->streams[i].client_props[j].value;
}

/* Build the properties for a capture stream.

   In C because `pw_properties_new` is variadic and the set of pairs varies:
   a target may or may not be given, and capturing a *sink* needs one more
   property than capturing a source.

   `stream.capture.sink` is the one that is easy to get wrong. Without it, a
   stream targeting a sink by name does not fail -- it falls back to the
   default source and records the microphone, so the far-end track quietly
   becomes a second copy of the near end. */
struct pw_properties *
pw_build_capture_props(const char *target, int capture_sink)
{
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE,     "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE,     "Communication",
        /* Capsper owns its own gain, and the session manager must not save it
           or hand it back.

           Without this, WirePlumber stores whatever volume it last saw on one
           of these streams and restores it onto the next, keyed on the role
           above -- which every capture here shares. Three things went wrong
           because of it, and none of them looked like a volume problem.

           Auto-gain climbs and never attenuates below unity, which is safe
           only because it starts at unity. Restored, it starts wherever it
           last finished and can still only climb, so the gain ratchets upward
           across restarts.

           The far-end track inherits it too. That track is the sink's monitor,
           a digital signal that has never needed gain, and it arrived clipped
           at full scale.

           And it lifts whatever the echo canceller just removed back up, which
           is how 19 dB of measured cancellation became a near track louder
           than the microphone it came from. */
        "state.restore-props",  "false",
        NULL);
    if (!props)
        return NULL;

    if (target && target[0])
        pw_properties_set(props, PW_KEY_TARGET_OBJECT, target);
    if (capture_sink)
        pw_properties_set(props, PW_KEY_STREAM_CAPTURE_SINK, "true");

    return props;
}

/* ─── Source node volume ──────────────────────────────────────────────────────

   Setting the level on the microphone itself rather than on our own capture
   stream, which is the difference between levelling the signal and levelling
   our view of it.

   Two reasons it belongs here. It lands before the echo canceller, which reads
   the source node, so the canceller sees a properly levelled microphone rather
   than having its own output adjusted after the fact. And it is one mechanism
   for every path: dictation has no canceller, and this works the same for it.

   The consequences are worth naming. This is the volume every other
   application sees, and WirePlumber saves it, so it outlives capsper. That is
   the same control a desktop's input slider drives, which is the argument for
   it as much as against.

   Like the stream volume, PipeWire clamps this to 10x (+20 dB). Measured on a
   real microphone: asking for 400%, which the cubic scale pactl prints calls
   +36 dB, produced 19.9 dB. */

struct set_volume_data {
    const char *node_name;
    float volume;

    struct pw_main_loop *loop;
    struct pw_registry *registry;
    struct pw_core *core;
    int pending_sync;

    struct pw_proxy *node;
    struct spa_hook node_listener;
    /* How many volumes the array needs. SPA_PROP_channelVolumes is per
       channel, and a node rejects an array that is not its own width. */
    uint32_t channels;
    int applied;
};

static void
on_volume_node_info(void *data, const struct pw_node_info *info)
{
    struct set_volume_data *d = data;
    if (!info || !info->props) return;

    const char *ch = spa_dict_lookup(info->props, "audio.channels");
    if (ch) {
        int n = atoi(ch);
        if (n > 0 && n <= SPA_AUDIO_MAX_CHANNELS) d->channels = (uint32_t)n;
    }
}

static const struct pw_node_events volume_node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = on_volume_node_info,
};

static void
on_volume_registry_global(void *data, uint32_t id, uint32_t permissions,
                          const char *type, uint32_t version,
                          const struct spa_dict *props)
{
    struct set_volume_data *d = data;
    (void)permissions;
    (void)version;

    if (d->node) return; /* already found it */
    if (!props || !type || strcmp(type, PW_TYPE_INTERFACE_Node) != 0) return;

    const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    if (!name || strcmp(name, d->node_name) != 0) return;

    struct pw_proxy *proxy = pw_registry_bind(d->registry, id, type,
                                              PW_VERSION_NODE, 0);
    if (!proxy) return;

    d->node = proxy;
    pw_node_add_listener((struct pw_node *)proxy, &d->node_listener,
                         &volume_node_events, d);
}

static void
on_volume_core_done(void *data, uint32_t id, int seq)
{
    struct set_volume_data *d = data;
    if (id == PW_ID_CORE && seq == d->pending_sync)
        pw_main_loop_quit(d->loop);
}

/* Set a source node's volume by node name. `volume` is linear, so 1.0 is
   unity and 4.0 is +12 dB, matching pw_set_stream_gain rather than the cubic
   percentage pactl prints.

   Returns 0 on success, -1 if the node was not found or the volume was not
   accepted. Synchronous: it connects, finds the node, sets the parameter and
   waits for the server to acknowledge it before returning. */
int
pw_set_source_volume(const char *node_name, float volume)
{
    if (!node_name) return -1;

    pw_init(NULL, NULL);

    int rc = -1;
    struct pw_main_loop *loop = NULL;
    struct pw_context *context = NULL;
    struct pw_core *core = NULL;
    struct pw_registry *registry = NULL;

    loop = pw_main_loop_new(NULL);
    if (!loop) goto out;

    context = pw_context_new(pw_main_loop_get_loop(loop), NULL, 0);
    if (!context) goto out;

    core = pw_context_connect(context, NULL, 0);
    if (!core) goto out;

    registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
    if (!registry) goto out;

    struct set_volume_data data = {
        .node_name = node_name,
        .volume = volume,
        .loop = loop,
        .registry = registry,
        .core = core,
        .channels = 1,
    };

    static const struct pw_registry_events reg_events = {
        PW_VERSION_REGISTRY_EVENTS,
        .global = on_volume_registry_global,
    };
    struct spa_hook reg_listener;
    spa_zero(reg_listener);
    pw_registry_add_listener(registry, &reg_listener, &reg_events, &data);

    static const struct pw_core_events core_events = {
        PW_VERSION_CORE_EVENTS,
        .done = on_volume_core_done,
    };
    struct spa_hook core_listener;
    spa_zero(core_listener);
    pw_core_add_listener(core, &core_listener, &core_events, &data);

    /* First roundtrip finds the node and binds it. */
    data.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);
    pw_main_loop_run(loop);

    if (data.node) {
        /* Second roundtrip lets the node's info arrive, which is where the
           channel count comes from. */
        data.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);
        pw_main_loop_run(loop);

        float vols[SPA_AUDIO_MAX_CHANNELS];
        for (uint32_t i = 0; i < data.channels; i++) vols[i] = volume;

        uint8_t buf[1024];
        struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
        struct spa_pod *props_pod = spa_pod_builder_add_object(
            &b,
            SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
            SPA_PROP_channelVolumes,
            SPA_POD_Array(sizeof(float), SPA_TYPE_Float, data.channels, vols));

        if (props_pod) {
            pw_node_set_param((struct pw_node *)data.node, SPA_PARAM_Props, 0,
                              props_pod);
            /* Wait for the server to have processed it, so a caller that
               returns and immediately measures is not racing the graph. */
            data.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);
            pw_main_loop_run(loop);
            rc = 0;
        }

        spa_hook_remove(&data.node_listener);
        pw_proxy_destroy(data.node);
    }

    spa_hook_remove(&reg_listener);
    spa_hook_remove(&core_listener);

out:
    if (registry) pw_proxy_destroy((struct pw_proxy *)registry);
    if (core) pw_core_disconnect(core);
    if (context) pw_context_destroy(context);
    if (loop) pw_main_loop_destroy(loop);
    pw_deinit();
    return rc;
}

/* ─── The desktop's default microphone ────────────────────────────────────────

   Which source is "the default" is not a property of any node. It is an entry
   in PipeWire's `default` metadata object, written by the session manager and
   changed when the user picks a different input or unplugs the one they were
   using. So it is read from there rather than looked for in the registry.

   The value is JSON, `{"name":"vocaster_hostmic"}`, and only the name is
   wanted. */

struct default_source_data {
    struct pw_main_loop *loop;
    struct pw_registry *registry;
    int pending_sync;

    struct pw_proxy *metadata;
    struct spa_hook metadata_listener;

    char *out;
    size_t out_len;
    int found;
};

/* Pull the name out of `{"name":"..."}`.

   A hand parse rather than spa_json, because the shape is fixed by the
   session manager and one field is wanted from it. Returns 0 on success. */
static int
parse_default_name(const char *value, char *out, size_t out_len)
{
    if (!value) return -1;

    const char *key = strstr(value, "\"name\"");
    if (!key) return -1;

    const char *colon = strchr(key + 6, ':');
    if (!colon) return -1;

    const char *open = strchr(colon, '"');
    if (!open) return -1;
    open++;

    const char *close = strchr(open, '"');
    if (!close || (size_t)(close - open) >= out_len) return -1;

    memcpy(out, open, (size_t)(close - open));
    out[close - open] = '\0';
    return 0;
}

static int
on_default_metadata_property(void *data, uint32_t subject, const char *key,
                             const char *type, const char *value)
{
    struct default_source_data *d = data;
    (void)subject;
    (void)type;

    if (!key || strcmp(key, "default.audio.source") != 0) return 0;
    if (parse_default_name(value, d->out, d->out_len) == 0) d->found = 1;
    return 0;
}

static const struct pw_metadata_events default_metadata_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = on_default_metadata_property,
};

static void
on_default_registry_global(void *data, uint32_t id, uint32_t permissions,
                           const char *type, uint32_t version,
                           const struct spa_dict *props)
{
    struct default_source_data *d = data;
    (void)permissions;
    (void)version;

    if (d->metadata) return;
    if (!props || !type || strcmp(type, PW_TYPE_INTERFACE_Metadata) != 0) return;

    /* Several metadata objects exist -- settings, route-settings, and so on.
       The defaults live in the one called `default`. */
    const char *name = spa_dict_lookup(props, PW_KEY_METADATA_NAME);
    if (!name || strcmp(name, "default") != 0) return;

    struct pw_proxy *proxy = pw_registry_bind(d->registry, id, type,
                                              PW_VERSION_METADATA, 0);
    if (!proxy) return;

    d->metadata = proxy;
    pw_metadata_add_listener((struct pw_metadata *)proxy, &d->metadata_listener,
                             &default_metadata_events, d);
}

static void
on_default_core_done(void *data, uint32_t id, int seq)
{
    struct default_source_data *d = data;
    if (id == PW_ID_CORE && seq == d->pending_sync)
        pw_main_loop_quit(d->loop);
}

/* The node name of the desktop's default audio source, written into `out`.
   Returns 0 on success, -1 if there is no default or it could not be read. */
int
pw_get_default_source(char *out, uint32_t out_len)
{
    if (!out || out_len == 0) return -1;
    out[0] = '\0';

    pw_init(NULL, NULL);

    int rc = -1;
    struct pw_main_loop *loop = NULL;
    struct pw_context *context = NULL;
    struct pw_core *core = NULL;
    struct pw_registry *registry = NULL;

    loop = pw_main_loop_new(NULL);
    if (!loop) goto out;

    context = pw_context_new(pw_main_loop_get_loop(loop), NULL, 0);
    if (!context) goto out;

    core = pw_context_connect(context, NULL, 0);
    if (!core) goto out;

    registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
    if (!registry) goto out;

    struct default_source_data data = {
        .loop = loop,
        .registry = registry,
        .out = out,
        .out_len = out_len,
        .found = 0,
    };

    static const struct pw_registry_events reg_events = {
        PW_VERSION_REGISTRY_EVENTS,
        .global = on_default_registry_global,
    };
    struct spa_hook reg_listener;
    spa_zero(reg_listener);
    pw_registry_add_listener(registry, &reg_listener, &reg_events, &data);

    static const struct pw_core_events core_events = {
        PW_VERSION_CORE_EVENTS,
        .done = on_default_core_done,
    };
    struct spa_hook core_listener;
    spa_zero(core_listener);
    pw_core_add_listener(core, &core_listener, &core_events, &data);

    /* First roundtrip binds the metadata object. */
    data.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);
    pw_main_loop_run(loop);

    if (data.metadata) {
        /* Second lets it replay its properties, which is how the current
           value arrives -- metadata announces what it holds on binding. */
        data.pending_sync = pw_core_sync(core, PW_ID_CORE, 0);
        pw_main_loop_run(loop);

        spa_hook_remove(&data.metadata_listener);
        pw_proxy_destroy(data.metadata);
    }

    spa_hook_remove(&reg_listener);
    spa_hook_remove(&core_listener);
    rc = data.found ? 0 : -1;

out:
    if (registry) pw_proxy_destroy((struct pw_proxy *)registry);
    if (core) pw_core_disconnect(core);
    if (context) pw_context_destroy(context);
    if (loop) pw_main_loop_destroy(loop);
    pw_deinit();
    return rc;
}

/* ─── The microphone's level, held open ───────────────────────────────────────

   One object that knows which node is the microphone and can set its level
   cheaply, because the level controller adjusts it while audio is flowing and
   a connection per adjustment would mean building a PipeWire context inside
   the capture loop.

   It also answers the question the controller cannot ask for itself: has the
   microphone changed? The desktop's default source lives in metadata, and
   metadata emits an event when it is rewritten, so switching from an
   interface to a headset arrives as a change rather than as something that
   has to be noticed by looking. Nothing here polls.

   A named target pins the node and the metadata is ignored. Without one, the
   microphone is whatever the desktop currently calls the default, which is the
   same choice the user already made for every other application. */

struct pw_mic_level {
    struct pw_thread_loop *thread_loop;
    struct pw_context     *context;
    struct pw_core        *core;
    struct pw_registry    *registry;
    struct spa_hook        registry_listener;

    /* Set when a target was named, in which case the default is irrelevant. */
    int  pinned;
    char node_name[256];

    /* The node being levelled, once it has been seen in the registry. */
    uint32_t     node_id;
    struct pw_proxy *node;
    struct spa_hook  node_listener;
    uint32_t     channels;

    struct pw_proxy *metadata;
    struct spa_hook  metadata_listener;

    /* Raised on the thread loop when the default moves, read and cleared by
       whoever is levelling. */
    _Atomic int changed;

    /* Raised when a node is bound. */
    _Atomic int bound;

    /* The level asked for, applied as soon as there is something to apply it
       to. The registry delivers its globals on the thread loop, so a caller
       setting a level the moment it created this would be setting it on
       nothing -- and following the default takes two steps, the metadata and
       then the node it names. Remembering it here is what makes that a matter
       of ordering rather than of waiting, which matters because the caller is
       opening a session and a second spent here is a second of the call it
       never captured.

       Negative means nothing has been asked for yet. */
    float pending_volume;
};

static void mic_level_bind_node(struct pw_mic_level *m, uint32_t id);
static int mic_level_apply(struct pw_mic_level *m, float volume);

static void
on_mic_node_info(void *data, const struct pw_node_info *info)
{
    struct pw_mic_level *m = data;
    if (!info || !info->props) return;
    const char *ch = spa_dict_lookup(info->props, "audio.channels");
    if (ch) {
        int n = atoi(ch);
        if (n > 0 && n <= SPA_AUDIO_MAX_CHANNELS) m->channels = (uint32_t)n;
    }
}

static const struct pw_node_events mic_node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = on_mic_node_info,
};

/* Drop whatever node we were levelling, so a new name can be bound. */
static void
mic_level_release_node(struct pw_mic_level *m)
{
    if (!m->node) return;
    spa_hook_remove(&m->node_listener);
    pw_proxy_destroy(m->node);
    m->node = NULL;
    m->node_id = 0;
    m->channels = 1;
    atomic_store(&m->bound, 0);
}

static int
on_mic_metadata_property(void *data, uint32_t subject, const char *key,
                         const char *type, const char *value)
{
    struct pw_mic_level *m = data;
    (void)subject;
    (void)type;

    if (m->pinned) return 0;
    if (!key || strcmp(key, "default.audio.source") != 0) return 0;

    char name[sizeof(m->node_name)];
    if (parse_default_name(value, name, sizeof(name)) != 0) return 0;
    if (strcmp(name, m->node_name) == 0) return 0;

    snprintf(m->node_name, sizeof(m->node_name), "%s", name);
    mic_level_release_node(m);
    atomic_store(&m->changed, 1);

    /* The node for the new name may already be in the registry, in which case
       no further global event is coming and it has to be looked for now. */
    return 0;
}

static const struct pw_metadata_events mic_metadata_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = on_mic_metadata_property,
};

static void
on_mic_registry_global(void *data, uint32_t id, uint32_t permissions,
                       const char *type, uint32_t version,
                       const struct spa_dict *props)
{
    struct pw_mic_level *m = data;
    (void)permissions;
    (void)version;

    if (!props || !type) return;

    if (strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0 && !m->metadata && !m->pinned) {
        const char *name = spa_dict_lookup(props, PW_KEY_METADATA_NAME);
        if (name && strcmp(name, "default") == 0) {
            struct pw_proxy *proxy = pw_registry_bind(m->registry, id, type,
                                                      PW_VERSION_METADATA, 0);
            if (proxy) {
                m->metadata = proxy;
                pw_metadata_add_listener((struct pw_metadata *)proxy,
                                         &m->metadata_listener,
                                         &mic_metadata_events, m);
            }
        }
        return;
    }

    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0) return;
    if (m->node) return;
    if (!m->node_name[0]) return;

    const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    if (!name || strcmp(name, m->node_name) != 0) return;

    mic_level_bind_node(m, id);
}

static void
on_mic_registry_global_remove(void *data, uint32_t id)
{
    struct pw_mic_level *m = data;
    /* The microphone went away. Let go of it so the next name can bind, and
       say so, because a controller carrying a level across a device change is
       levelling for hardware that is no longer there. */
    if (m->node && m->node_id == id) {
        mic_level_release_node(m);
        atomic_store(&m->changed, 1);
    }
}

static void
mic_level_bind_node(struct pw_mic_level *m, uint32_t id)
{
    struct pw_proxy *proxy = pw_registry_bind(m->registry, id,
                                              PW_TYPE_INTERFACE_Node,
                                              PW_VERSION_NODE, 0);
    if (!proxy) return;
    m->node = proxy;
    m->node_id = id;
    pw_node_add_listener((struct pw_node *)proxy, &m->node_listener,
                         &mic_node_events, m);
    atomic_store(&m->bound, 1);

    /* Whatever was asked for before there was anything to ask. */
    if (m->pending_volume >= 0.0f) mic_level_apply(m, m->pending_volume);
}

/* `target` names the node to level, or is NULL to follow the desktop's
   default input and keep following it. */
struct pw_mic_level *
pw_mic_level_create(const char *target)
{
    pw_init(NULL, NULL);

    struct pw_mic_level *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    m->channels = 1;
    m->pending_volume = -1.0f;
    if (target && target[0]) {
        m->pinned = 1;
        snprintf(m->node_name, sizeof(m->node_name), "%s", target);
    }

    m->thread_loop = pw_thread_loop_new("capsper-miclevel", NULL);
    if (!m->thread_loop) { free(m); return NULL; }

    m->context = pw_context_new(pw_thread_loop_get_loop(m->thread_loop), NULL, 0);
    if (!m->context) {
        pw_thread_loop_destroy(m->thread_loop);
        free(m); return NULL;
    }

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
        .global = on_mic_registry_global,
        .global_remove = on_mic_registry_global_remove,
    };
    spa_zero(m->registry_listener);
    pw_registry_add_listener(m->registry, &m->registry_listener, &reg_events, m);

    pw_thread_loop_unlock(m->thread_loop);

    return m;
}

void
pw_mic_level_destroy(struct pw_mic_level *m)
{
    if (!m) return;

    pw_thread_loop_lock(m->thread_loop);
    mic_level_release_node(m);
    if (m->metadata) {
        spa_hook_remove(&m->metadata_listener);
        pw_proxy_destroy(m->metadata);
    }
    spa_hook_remove(&m->registry_listener);
    pw_proxy_destroy((struct pw_proxy *)m->registry);
    pw_core_disconnect(m->core);
    pw_thread_loop_unlock(m->thread_loop);

    pw_thread_loop_stop(m->thread_loop);
    pw_context_destroy(m->context);
    pw_thread_loop_destroy(m->thread_loop);
    free(m);
}

/* Set the level on the bound node. Caller holds the thread loop. */
static int
mic_level_apply(struct pw_mic_level *m, float volume)
{
    if (!m->node) return -1;

    float vols[SPA_AUDIO_MAX_CHANNELS];
    for (uint32_t i = 0; i < m->channels; i++) vols[i] = volume;

    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
    struct spa_pod *props_pod = spa_pod_builder_add_object(
        &b,
        SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
        SPA_PROP_channelVolumes,
        SPA_POD_Array(sizeof(float), SPA_TYPE_Float, m->channels, vols));
    if (!props_pod) return -1;

    pw_node_set_param((struct pw_node *)m->node, SPA_PARAM_Props, 0, props_pod);
    return 0;
}

/* Set the microphone-s level. Linear, so 1.0 is unity; PipeWire clamps at 10x.

   Returns 0 when it reached a node. A -1 is not a failure to remember: the
   value is kept and applied the moment one binds, which is what covers a
   microphone that has not reached the registry yet and a default that moved
   while nothing was bound. */
int
pw_mic_level_set(struct pw_mic_level *m, float volume)
{
    if (!m) return -1;

    pw_thread_loop_lock(m->thread_loop);
    m->pending_volume = volume;
    int rc = mic_level_apply(m, volume);
    pw_thread_loop_unlock(m->thread_loop);
    return rc;
}

/* Whether the microphone has changed since this was last asked, and clears
   the flag. A controller seeing 1 should start again from its configured
   level rather than carrying the old device's across. */
int
pw_mic_level_take_changed(struct pw_mic_level *m)
{
    if (!m) return 0;
    return atomic_exchange(&m->changed, 0);
}

/* The node currently being levelled, or an empty string if none is bound.
   For logging: a meeting that switched microphones should say so. */
const char *
pw_mic_level_node_name(struct pw_mic_level *m)
{
    return m ? m->node_name : "";
}
