# Plan: Zig Rewrite of Whisper Dictation

## Goal

Replace the current Python (SimulStreaming) + Bash (whisper.sh) dictation system with a single
Zig binary. The binary handles audio capture, voice activity detection, streaming Whisper
inference with AlignAtt policy, and text input simulation — no Python runtime, no TCP server,
no shell scripts.

## Why

- **Startup time**: Current system takes up to 5 minutes for Python + PyTorch + model loading.
  A native binary with ggml (whisper.cpp) should load in seconds.
- **Memory**: PyTorch runtime overhead is substantial. whisper.cpp uses ~1.5 GB for
  large-v3-turbo vs ~3+ GB with PyTorch.
- **Complexity**: Current system spans 3 projects (whisper.sh, SimulStreaming, keyd config),
  2 languages (Bash, Python), a TCP protocol, and multiple background processes. A single
  binary eliminates all of that.
- **Deployment**: One binary + one model file. No mise, no pip, no venv.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Single Zig Binary                     │
│                                                          │
│  ┌────────────┐  ┌──────────┐  ┌───────────────────┐    │
│  │ Audio      │  │ Key      │  │ Text Output       │    │
│  │ Capture    │  │ Monitor  │  │ (ydotool/uinput)  │    │
│  │ (ALSA)     │  │ (evdev)  │  │                   │    │
│  └─────┬──────┘  └────┬─────┘  └────────▲──────────┘    │
│        │              │                  │               │
│        ▼              │                  │               │
│  ┌─────────────┐      │           ┌──────┴──────────┐   │
│  │ VAD         │      │           │ Text Cleanup    │   │
│  │ (whisper.cpp│      │           │ & Word Boundary │   │
│  │  built-in)  │      │           │ Truncation      │   │
│  └─────┬───────┘      │           └────────▲────────┘   │
│        │              │                    │             │
│        ▼              │                    │             │
│  ┌─────────────────────────────────────────┴──────┐     │
│  │              Streaming Pipeline                 │     │
│  │                                                 │     │
│  │  Audio Buffer → Mel → Encode → Decode Loop     │     │
│  │                                    │            │     │
│  │                              AlignAtt Policy    │     │
│  │                          (check cross-attention │     │
│  │                           after each token)     │     │
│  └─────────────────────────────────────────────────┘     │
│                         │                                │
│                    C API calls                           │
│                         │                                │
│  ┌──────────────────────▼──────────────────────────┐     │
│  │              whisper.cpp (libwhisper)            │     │
│  │  - Encoder / Decoder / KV Cache                 │     │
│  │  - Mel spectrogram                              │     │
│  │  - Tokenizer                                    │     │
│  │  - Cross-attention capture (DTW path)           │     │
│  │  - Built-in VAD (ggml-based)                    │     │
│  └─────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────┘
```

### Key Design Decision: In-Process, Not Client/Server

The current system uses a TCP server because Python is slow to start and we want the model
to stay loaded. With whisper.cpp the model loads in seconds, and everything runs in-process.
This eliminates the TCP protocol, connection management, and reconnection logic.

---

## Dependencies

| Dependency | Language | Linked via | Purpose |
|---|---|---|---|
| whisper.cpp | C/C++ | `@cImport` of `whisper.h` | Whisper inference, mel, tokenizer, VAD |
| libasound (ALSA) | C | `@cImport` of `alsa/asoundlib.h` | Audio capture |
| libevdev | C | `@cImport` of `libevdev/libevdev.h` | Push-to-talk key monitoring |

No ONNX Runtime needed — whisper.cpp v1.7.5+ has its own ggml-based VAD model.

---

## whisper.cpp Modifications Required

### 1. Expose cross-attention data from low-level API

**Problem**: `whisper_decode_with_state()` hardcodes `save_alignment_heads_QKs = false`
(line 3956 in `src/whisper.cpp`). The attention data is only captured when called from
`whisper_full()`.

**Solution**: Add a new public function that passes `true`:

```c
// In include/whisper.h:
WHISPER_API int whisper_decode_with_state_and_aheads(
        struct whisper_context * ctx,
          struct whisper_state * state,
           const whisper_token * tokens,
                           int   n_tokens,
                           int   n_past,
                           int   n_threads);
```

```c
// In src/whisper.cpp (alongside existing whisper_decode_with_state):
int whisper_decode_with_state_and_aheads(
        struct whisper_context * ctx,
          struct whisper_state * state,
           const whisper_token * tokens,
                           int   n_tokens,
                           int   n_past,
                           int   n_threads) {
    whisper_batch_prep_legacy(state->batch, tokens, n_tokens, n_past, 0);
    whisper_kv_cache_seq_rm(state->kv_self, 0, n_past, -1);
    // Note: save_alignment_heads_QKs = true (was false in whisper_decode_with_state)
    if (!whisper_decode_internal(*ctx, *state, state->batch, n_threads, true, nullptr, nullptr)) {
        return 1;
    }
    return 0;
}
```

### 2. Expose cross-attention tensor data

**Problem**: `state->aheads_cross_QKs` and `state->aheads_cross_QKs_data` are internal.

**Solution**: Add accessor functions:

```c
// In include/whisper.h:

// Get cross-attention data from alignment heads after a decode call.
// Returns pointer to float array of shape [n_tokens × n_audio_ctx × n_heads].
// Returns NULL if DTW is not enabled or no attention data is available.
// The pointer is valid until the next decode call.
WHISPER_API const float * whisper_state_get_aheads_cross_qks(
        struct whisper_state * state,
                         int * n_tokens,
                         int * n_audio_ctx,
                         int * n_heads);
```

### 3. Enable DTW context params with alignment head preset

Already supported — just set `cparams.dtw_token_timestamps = true` and
`cparams.dtw_aheads_preset = WHISPER_AHEADS_LARGE_V3_TURBO`.

### Summary of Changes

These are minimal, additive changes — 2 new functions (~30 lines of C total). No existing
API is modified. They could potentially be upstreamed.

---

## AlignAtt Algorithm (Pure Zig)

This is the core streaming logic, implemented entirely in Zig. No ML framework needed —
it's pure math on the attention tensor.

### Algorithm

After each token is decoded:

1. **Get attention tensor** `[n_tokens, n_audio_ctx, n_heads]` from whisper.cpp
2. **Extract last token's attention** — slice `attention[last_token, :, :]`
3. **Trim to content length** — remove padding frames beyond actual audio
4. **Normalize** — z-score per head: `(attn - mean) / std`
5. **Median filter** — window size 7, smooths noisy attention
6. **Average across heads** — collapse head dimension
7. **Argmax** — find most-attended audio frame for the last token
8. **Stopping rule** — if `content_frames - most_attended_frame <= frame_threshold` (25):
   STOP generating, we've caught up to the live audio
9. **Rewind detection** — if attention jumped backwards by > `rewind_threshold` (200 frames):
   discard this segment (likely hallucination)

### After stopping:

10. **Decode tokens to text**
11. **Word boundary truncation** — strip last incomplete word (unless VAD says utterance ended)
12. **Emit confirmed text** — send to input simulation

### Constants (from SimulStreaming defaults)

```
frame_threshold     = 25       // frames (~0.5s) — stop if attention this close to audio end
rewind_threshold    = 200      // frames (~4s) — discard if attention jumps back this far
audio_max_len       = 30.0     // seconds — rolling audio buffer max
median_filter_width = 7        // attention smoothing window
encoder_frame_rate  = 0.02     // seconds per encoder frame (after 2x downsampling)
```

---

## VAD Integration

### Option A: whisper.cpp Built-in VAD (Recommended)

whisper.cpp v1.7.5+ includes a ggml-based VAD with a clean C API:

```c
// Load VAD model
struct whisper_vad_context * vctx = whisper_vad_init_from_file_with_params(
    "ggml-silero-vad.bin", whisper_vad_default_context_params());

// Detect speech in audio chunk
bool has_speech = whisper_vad_detect_speech(vctx, samples, n_samples);

// Get speech segment boundaries
struct whisper_vad_segments * segs = whisper_vad_segments_from_samples(
    vctx, whisper_vad_default_params(), samples, n_samples);
```

Default VAD params:
```
threshold               = 0.5
min_speech_duration_ms  = 250
min_silence_duration_ms = 500   // matches current Silero setup
max_speech_duration_s   = FLT_MAX
speech_pad_ms           = 100   // matches current Silero setup
```

**Advantages**: No extra dependency. Same library, same build. Already tuned.

### Option B: Silero VAD via ONNX Runtime

If the built-in VAD proves insufficient, we can fall back to Silero:
- ONNX Runtime has a C API
- Silero VAD v5 model is ~2 MB ONNX file
- Would add one more C dependency

**Recommendation**: Start with Option A. The parameters match our current setup closely.
Only switch to Option B if quality regresses.

---

## Phases

### Phase 0: Project Setup

- Create Zig project with `zig init`
- Set up build.zig to compile and link whisper.cpp as a C library
- Verify we can call `whisper_init_from_file_with_params()` from Zig
- Verify we can load and run inference on a test audio file (e.g., jfk.wav)

**Validation**: Zig binary loads model, transcribes jfk.wav, prints text to stdout.

### Phase 1: whisper.cpp Modifications

- Add `whisper_decode_with_state_and_aheads()` function
- Add `whisper_state_get_aheads_cross_qks()` accessor
- Add to `whisper.h` header
- Test: call from Zig, verify attention tensor shape and values are sensible

**Validation**: After decoding a few tokens, we can read cross-attention weights from Zig.

### Phase 2: Audio Capture

- Integrate ALSA via `@cImport`
- Open default capture device: S16_LE, mono, 16000 Hz
- Stream audio into a ring buffer
- Chunk into configurable intervals (e.g., 40ms chunks matching current vac-chunk-size)

**Validation**: Record audio to a file, play it back, confirm it sounds correct.

### Phase 3: VAD

- Integrate whisper.cpp built-in VAD
- Implement state machine: `silence → voice_detected → speaking → silence_detected → silence`
- Buffer audio during silence, forward to pipeline during speech
- Detect utterance boundaries (500ms silence)

**Validation**: Print "speech start" / "speech end" events while speaking into mic.

### Phase 4: AlignAtt Streaming

- Implement the core decode loop using low-level API:
  1. `whisper_pcm_to_mel_with_state()`
  2. `whisper_encode_with_state()`
  3. Loop: `whisper_decode_with_state_and_aheads()` → check attention → continue or stop
- Implement attention analysis: z-score normalization, median filter, argmax
- Implement stopping rule and rewind detection
- Implement word boundary truncation
- Manage rolling 30s audio buffer with token context carry-over

**Validation**: Stream audio from file, compare transcription output against current Python
system. Text should appear incrementally with similar latency.

### Phase 5: Push-to-Talk

- Monitor keyboard via libevdev (read `/dev/input/eventN`)
- Detect KEY_F24 press/release (evdev code 194, matching current keyd config)
- Implement 1-second debounce on release (matching current behavior)
- Gate text output on key state

**Validation**: Press F24, speak, release — text only output during key hold.

### Phase 6: Text Input Simulation

- Implement ydotool socket protocol (write to `/tmp/.ydotool_socket`)
  OR use libevdev/uinput to create a virtual keyboard
- Apply text cleanup: collapse whitespace, remove spaces before punctuation
- Handle smart spacing (no space before punctuation, space between words)

**Validation**: Text appears in focused window when speaking with key held.

### Phase 7: Integration & Polish

- Wire all phases together into the main event loop
- Implement signal handling (SIGINT, SIGTERM) for clean shutdown
- Model warmup on startup (transcribe jfk.wav to warm caches)
- Error handling: device not found, model not found, permission errors
- Command-line args: model path, device, language, key code, thresholds

**Validation**: Full end-to-end: start binary, hold key, speak, see text typed. Compare
latency and accuracy against current Python system.

---

## Event Loop Design

The main loop has three concurrent activities:

1. **Audio capture** — continuous, fills ring buffer (dedicated thread or async)
2. **Key monitoring** — reads evdev events (dedicated thread)
3. **Processing** — runs when audio is available AND key is pressed:

```
loop {
    audio_chunk = audio_ring_buffer.read(chunk_size);

    vad_result = vad.process(audio_chunk);

    switch (vad_result) {
        .voice_start => {
            pipeline.init();
            pipeline.feed(audio_chunk);
        },
        .voice_continue => {
            pipeline.feed(audio_chunk);
            if (pipeline.has_enough_audio()) {
                text = pipeline.process();  // encode → decode loop with AlignAtt
                if (key_is_pressed and text.len > 0) {
                    type_text(text);
                }
            }
        },
        .voice_end => {
            text = pipeline.finish();  // force-emit remaining text
            if (key_is_pressed and text.len > 0) {
                type_text(text);
            }
            pipeline.reset();
        },
        .silence => {},
    }
}
```

### Threading Model

- **Thread 1 (main)**: Processing loop — VAD, encode, decode, AlignAtt, text output
- **Thread 2**: Audio capture — ALSA read loop, writes to lock-free ring buffer
- **Thread 3**: Key monitor — evdev read loop, writes atomic bool

Zig's `std.Thread` and `std.atomic` provide what we need. The ring buffer between audio
capture and processing is the only shared data structure.

---

## File Structure

```
whisper-dictate/
├── build.zig              # Build config: link whisper.cpp, ALSA, evdev
├── build.zig.zon          # Zig package manifest
├── src/
│   ├── main.zig           # Entry point, arg parsing, event loop
│   ├── audio.zig          # ALSA capture, ring buffer
│   ├── vad.zig            # VAD state machine wrapping whisper.cpp VAD
│   ├── pipeline.zig       # Streaming pipeline: mel → encode → decode
│   ├── alignatt.zig       # AlignAtt policy: attention analysis, stopping rule
│   ├── text.zig           # Text cleanup, word boundary truncation, spacing
│   ├── input.zig          # ydotool / uinput text typing
│   ├── keymon.zig         # evdev key monitoring, debounce
│   └── whisper_c.zig      # @cImport wrapper for whisper.h, helper types
└── whisper.cpp/            # git submodule or vendored (with our modifications)
    ├── include/whisper.h
    ├── src/whisper.cpp
    └── ...
```

---

## Model Files

- `ggml-large-v3-turbo.bin` — Whisper model in ggml format (~1.5 GB)
  - whisper.cpp uses ggml format, not PyTorch `.pt` files
  - Download: `whisper.cpp/models/download-ggml-model.sh large-v3-turbo`
- `ggml-silero-vad.bin` — VAD model (~2 MB)
  - Included with whisper.cpp or downloadable separately

---

## Risk Assessment

### Low Risk
- **ALSA integration**: Well-documented C API, Zig `@cImport` handles it
- **evdev integration**: Simple read loop, well-documented
- **VAD**: Using whisper.cpp built-in, no extra dependencies
- **Text cleanup**: Trivial string manipulation

### Medium Risk
- **whisper.cpp modifications**: Small and additive, but we're forking. Need to track
  upstream and rebase periodically. Consider upstreaming the changes.
- **AlignAtt fidelity**: The algorithm is well-understood from the Python code, but subtle
  differences in floating-point behavior between PyTorch and ggml could affect quality.
  Mitigation: compare attention matrices side-by-side during development.
- **Build complexity**: Linking whisper.cpp (C++) from Zig requires care. The `@cImport` only
  works on the C API header, but the library itself is C++. Zig can link C++ object files
  via its build system.

### Higher Risk
- **Low-level decode loop correctness**: Reimplementing what `whisper_full()` does internally
  (prompt token setup, KV cache management, token suppression, timestamp handling) is the
  most complex part. We need to get the token sequence right:
  `[sot_prev] [context_tokens] [sot] [lang] [transcribe] [notimestamps] [generated...]`

  Mitigation: start by using `whisper_full()` with callbacks for a working prototype,
  then migrate to the low-level API only if needed for AlignAtt integration.

---

## Alternative Approach: whisper_full() with Callbacks

If the low-level API proves too complex, there's a simpler path:

1. Use `whisper_full()` which handles all the token management internally
2. Use `logits_filter_callback` — called after each token, receives logits and all
   previous tokens. We can check the attention data here.
3. To stop generation: set the EOT token logit very high, forcing the decoder to emit EOT
4. This is "hacky" but avoids reimplementing the entire decode loop

**Recommendation**: Implement the callback approach first as a working prototype (Phase 4a),
then evaluate whether migrating to the low-level API is worth the complexity (Phase 4b).

---

## Success Criteria

1. **Parity**: Transcription quality and latency comparable to current Python system
2. **Startup**: Model loaded and ready in < 10 seconds (vs current ~60-300 seconds)
3. **Memory**: < 2 GB RSS (vs current ~4+ GB with PyTorch)
4. **Single binary**: `./whisper-dictate --model ggml-large-v3-turbo.bin` — that's it
5. **Maintainable**: Clear separation of concerns, each module testable independently
