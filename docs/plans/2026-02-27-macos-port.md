# macOS / Apple Silicon Port

**Goal:** Port capsper to macOS on Apple Silicon, replacing Linux-specific subsystems (evdev/uinput, PipeWire, CUDA) with macOS equivalents (CGEventTap, Core Audio, Metal). Maintain the same UX: CapsLock push-to-talk, transcription injected as keystrokes into any focused application.

**Target:** macOS 15+ (Sequoia) on Apple Silicon (M1+). Fine to require latest OS version and cutting-edge hardware. No need for Intel Mac support.

**Distribution:** Local builds + friend distribution via ad-hoc code signing. No Mac App Store, no notarization, no Developer ID cert required initially.

---

## Platform Mapping

| Linux (current) | macOS equivalent | Complexity vs Linux |
|---|---|---|
| evdev exclusive grab | `hidutil` CapsLock remap | Simpler |
| uinput virtual keyboard | CGEventPost + CGEventKeyboardSetUnicodeString | Simpler |
| inotify keyboard hotplug | Not needed (hidutil is device-agnostic) | Eliminated |
| EVIOCGKEY polling safety net | Not needed (CGEventTap is reliable) | Eliminated |
| PipeWire `pw_stream` | Core Audio AUHAL (`kAudioUnitSubType_HALOutput`) | Comparable |
| PipeWire channel map (`--pw-channel`) | `kAudioOutputUnitProperty_ChannelMap` | Identical concept |
| PipeWire device hotplug | `AudioObjectAddPropertyListener` | Simpler |
| PipeWire software gain (`pw_set_stream_gain`) | AUHAL gain or AudioUnit mixer | Comparable |
| `pw_helpers.c` (SPA pod wrappers) | `ca_helpers.c` (AudioBufferList wrappers) | Same pattern |
| CUDA (whisper.cpp) | Metal (whisper.cpp) | Same C API, different backend flag |
| systemd user service | LaunchAgent plist | Simpler |
| evdev group permissions | TCC permissions (Accessibility + Microphone) | Different but manageable |
| No code signing needed | Ad-hoc code signing + entitlements | New requirement |

---

## Subsystem 1: Keyboard Interception & Text Injection

### Current Linux Architecture (`input.zig`, ~1500 lines)

- Opens all `/dev/input/event*` keyboard devices via evdev
- `EVIOCGRAB` exclusive grab — physical keys only go through our virtual device
- Creates uinput virtual keyboard, forwards all keys through it
- Intercepts trigger key (CapsLock), converts to PTT signal
- Injects transcribed text as keystrokes via uinput `EV_KEY` events
- Hotplug via inotify on `/dev/input/`
- Safety: panic sequence (Enter+Backspace+Escape = ungrab), EVIOCGKEY polling every 200ms

### macOS Approach: `hidutil` + CGEventTap + CGEventPost

#### CapsLock Interception

**Problem:** macOS processes CapsLock at the HID driver level before any user-space code sees it. A CGEventTap receives `kCGEventFlagsChanged` (not keyDown/keyUp), and by the time the callback fires, the OS has already toggled CapsLock state and the LED.

**Solution: `hidutil` remap.** `hidutil property --set` remaps keys inside `IOHIDKeyboardFilter`, which runs before the CapsLock toggle logic in the HID stack.

```bash
# Remap CapsLock (0x39) → F19 (0x6E) at the HID driver level
hidutil property --set '{"UserKeyMapping":[{
  "HIDKeyboardModifierMappingSrc": 0x700000039,
  "HIDKeyboardModifierMappingDst": 0x70000006E
}]}'
```

This prevents the OS from ever seeing CapsLock:
- No LED toggle
- No CapsLock state change
- No `flagsChanged` event
- Instead, a clean `keyDown`/`keyUp` pair for F19 enters the event stream

The remap is session-scoped (lost on reboot). Persistent via LaunchAgent or applied at app startup.

On macOS 15+, the terminal/app calling `hidutil` needs Input Monitoring permission. Since we already need Accessibility permission (which is a superset), this is covered.

**Reference:** [Apple Technical Note TN2450: Remapping Keys in macOS Sierra](https://developer.apple.com/library/archive/technotes/tn2450/_index.html) — official Apple documentation on `hidutil` key remapping.

#### Keyboard Event Interception

**CGEventTap** intercepts the remapped F19 key:

```c
// Create an active tap at the HID level (earliest interception point)
CGEventMask mask = (1 << kCGEventKeyDown) | (1 << kCGEventKeyUp);
CFMachPortRef tap = CGEventTapCreate(
    kCGHIDEventTap,              // tap location: HID level (earliest)
    kCGHeadInsertEventTap,       // placement: first callback at this level
    kCGEventTapOptionDefault,    // active: can modify/suppress events
    mask,
    tapCallback,
    context
);

// Callback
CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type,
                        CGEventRef event, void *ctx) {
    if (type == kCGEventTapDisabledByTimeout) {
        // Watchdog killed the tap — re-enable immediately
        CGEventTapEnable(tap, true);
        return event;
    }

    int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (keycode == 0x61) {  // F19 virtual keycode
        // Signal PTT state change
        if (type == kCGEventKeyDown) ptt_pressed(ctx);
        else ptt_released(ctx);
        return NULL;  // swallow the event — apps never see F19
    }

    return event;  // pass through all other keys unmodified
}
```

**Tap locations explained:**
- `kCGHIDEventTap` — where HID device events enter the window server. Earliest interception point. This is the equivalent of our evdev grab position.
- `kCGSessionEventTap` — where events enter the login session. Downstream of HID tap. Less useful.
- `kCGAnnotatedSessionEventTap` — after accessibility annotations. Observation only.

**Watchdog behavior:** macOS has an undocumented watchdog that auto-disables active taps if the callback takes too long. The tap object remains valid but stops receiving events. Must handle `kCGEventTapDisabledByTimeout` and call `CGEventTapEnable(tap, true)`. Also check `CGEventTapIsEnabled()` periodically as a safety net (similar to our EVIOCGKEY polling on Linux).

**Code signing can silently kill taps:** If the binary is re-signed or the code signature changes while running, the tap may stop receiving events without any error. Runtime health checks via `CGEventTapIsEnabled()` every few seconds are required.

**Permissions:** Requires **Accessibility** permission (System Settings → Privacy & Security → Accessibility). Single permission covers both interception (CGEventTap) and injection (CGEventPost). Prompted on first launch via `AXIsProcessTrusted()` check.

**Reference:** [CGEventTapCreate documentation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))

#### Text Injection

**CGEventPost** injects transcribed text as synthetic keyboard events. Two approaches:

**Character-by-character (simple, universal):**
```c
void inject_text(const char *utf8_text) {
    // Convert UTF-8 to UTF-16 (UniChar)
    CFStringRef str = CFStringCreateWithCString(NULL, utf8_text, kCFStringEncodingUTF8);
    CFIndex len = CFStringGetLength(str);

    for (CFIndex i = 0; i < len; i++) {
        UniChar ch = CFStringGetCharacterAtIndex(str, i);
        CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventRef keyUp   = CGEventCreateKeyboardEvent(NULL, 0, false);
        CGEventKeyboardSetUnicodeString(keyDown, 1, &ch);
        CGEventKeyboardSetUnicodeString(keyUp, 1, &ch);
        CGEventPost(kCGSessionEventTap, keyDown);
        CGEventPost(kCGSessionEventTap, keyUp);
        CFRelease(keyDown);
        CFRelease(keyUp);
    }
    CFRelease(str);
}
```

**Batched (faster, up to 20 chars per event):**
```c
void inject_text_batched(const UniChar *chars, size_t len) {
    for (size_t i = 0; i < len; i += 20) {
        size_t batch = (len - i > 20) ? 20 : len - i;
        CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventRef keyUp   = CGEventCreateKeyboardEvent(NULL, 0, false);
        CGEventKeyboardSetUnicodeString(keyDown, batch, &chars[i]);
        CGEventKeyboardSetUnicodeString(keyUp, batch, &chars[i]);
        CGEventPost(kCGSessionEventTap, keyDown);
        CGEventPost(kCGSessionEventTap, keyUp);
        CFRelease(keyDown);
        CFRelease(keyUp);
    }
}
```

`CGEventKeyboardSetUnicodeString` attaches up to 20 Unicode characters to a single key event. The virtual keycode (first param, 0 above) is ignored when Unicode string is set — the receiving app gets the Unicode content directly. This handles emoji, CJK, accented characters, everything — no keycode mapping needed (much simpler than our Linux uinput path which must deal with XKB layouts).

**Where it works:**
- All native macOS apps (AppKit, SwiftUI)
- All Electron apps (VS Code, Discord, Slack, Notion)
- All browsers (Chrome, Firefox, Safari)
- Terminal emulators (iTerm2, Terminal.app, Alacritty)
- Java/Swing apps

**Where it doesn't work:**
- Secure Keyboard Entry (password fields) — by design. Not a problem for dictation.
- Pre-login window — irrelevant for our use case.

**Typing cancel:** Same approach as Linux — on PTT release, stop injecting. Since CGEventPost is synchronous (returns after posting), we can check an atomic flag between batches.

#### What We Don't Need on macOS

- **No hotplug.** `hidutil` remap is device-agnostic — it applies to all keyboards, current and future. No inotify equivalent needed.
- **No panic sequence.** We're not grabbing the keyboard exclusively. If capsper crashes, all keys still work normally. The only effect is F19 keypresses leaking through (harmless).
- **No EVIOCGKEY polling.** CGEventTap doesn't have the "lost key release" problem that evdev has. We still want the `CGEventTapIsEnabled()` health check, but for a different reason (watchdog auto-disable).
- **No virtual keyboard device.** CGEventPost injects directly into the event stream. No uinput equivalent needed.

#### Comparison to Karabiner-Elements

Karabiner takes the heavy approach: root-privileged daemon, IOHIDManager exclusive grab (`kIOHIDOptionsTypeSeizeDevice`), DriverKit virtual HID device. This is necessary because Karabiner remaps arbitrary keys to arbitrary other keys with complex rules.

We don't need any of that. Our requirements are much simpler:
1. Intercept one specific key (CapsLock) → `hidutil` remap handles this
2. Suppress it from reaching apps → CGEventTap returning NULL handles this
3. Inject text → CGEventPost handles this

No root, no DriverKit, no Apple entitlement approval.

**Known Karabiner issue for reference:** There's a DriverKit bug (present through Sonoma 14+) where `kIOHIDOptionsTypeSeizeDevice` doesn't fully hide the physical keyboard from `IOHIDManager` enumeration — other apps see double input. This affects Karabiner's Discord PTT users. We completely sidestep this by not using IOHIDManager at all.

---

## Subsystem 2: Audio Capture

### Current Linux Architecture (`audio_capture.zig` + `pw_helpers.c`, ~600 lines)

- PipeWire `pw_stream` with `process` callback delivers raw S16_LE PCM
- Channel selection via stream params (e.g., `--pw-channel FL`)
- Software gain via `pw_set_stream_gain()` C helper
- Device hotplug via PipeWire registry listener
- Auto-switch to target mic on PTT press
- `pw_detect.zig` interactive setup wizard for device/channel/gain calibration

### macOS Approach: Core Audio AUHAL

#### Basic Capture Setup

Core Audio's AUHAL (Audio Unit HAL Output) is the direct equivalent of `pw_stream`. It's callback-driven with configurable buffer sizes and direct hardware access.

```c
// 1. Create AUHAL instance
AudioComponentDescription desc = {
    .componentType         = kAudioUnitType_Output,
    .componentSubType      = kAudioUnitSubType_HALOutput,
    .componentManufacturer = kAudioUnitManufacturer_Apple,
};
AudioComponent comp = AudioComponentFindNext(NULL, &desc);
AudioComponentInstance auHAL;
AudioComponentInstanceNew(comp, &auHAL);

// 2. Enable input on element 1, disable output on element 0
UInt32 one = 1, zero = 0;
AudioUnitSetProperty(auHAL, kAudioOutputUnitProperty_EnableIO,
    kAudioUnitScope_Input, 1, &one, sizeof(one));
AudioUnitSetProperty(auHAL, kAudioOutputUnitProperty_EnableIO,
    kAudioUnitScope_Output, 0, &zero, sizeof(zero));

// 3. Set desired format: 16kHz mono S16_LE
AudioStreamBasicDescription fmt = {
    .mSampleRate       = 16000.0,
    .mFormatID         = kAudioFormatLinearPCM,
    .mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    .mBytesPerPacket   = 2,
    .mFramesPerPacket  = 1,
    .mBytesPerFrame    = 2,
    .mChannelsPerFrame = 1,
    .mBitsPerChannel   = 16,
};
AudioUnitSetProperty(auHAL, kAudioUnitProperty_StreamFormat,
    kAudioUnitScope_Output, 1, &fmt, sizeof(fmt));

// 4. Register input callback
AURenderCallbackStruct cb = { .inputProc = captureCallback, .inputProcRefCon = ctx };
AudioUnitSetProperty(auHAL, kAudioOutputUnitProperty_SetInputCallback,
    kAudioUnitScope_Global, 0, &cb, sizeof(cb));

// 5. Initialize and start
AudioUnitInitialize(auHAL);
AudioOutputUnitStart(auHAL);
```

**Critical gotcha:** The `ioData` parameter in the input callback is NULL. You must pre-allocate an `AudioBufferList` and call `AudioUnitRender()` to pull data into it:

```c
OSStatus captureCallback(void *ctx,
                          AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *ts,
                          UInt32 busNumber,
                          UInt32 numFrames,
                          AudioBufferList *ioData)  // NULL for input!
{
    AudioBufferList bufList;
    bufList.mNumberBuffers = 1;
    bufList.mBuffers[0].mNumberChannels = 1;
    bufList.mBuffers[0].mDataByteSize = numFrames * 2;  // S16 = 2 bytes
    bufList.mBuffers[0].mData = preallocated_buffer;

    AudioUnitRender(auHAL, flags, ts, busNumber, numFrames, &bufList);

    // bufList.mBuffers[0].mData now contains S16_LE PCM
    // Feed to server.zig the same way PipeWire callback does
    return noErr;
}
```

**Sample rate conversion:** AUHAL does NOT auto-resample. If the hardware mic runs at 48kHz and we want 16kHz, we need an `AudioConverter` in the chain. The AUHAL's built-in converter handles channel layout changes but not sample rate. Options:
1. Set up a separate `AudioConverterRef` for 48k→16k SRC
2. Use `AVAudioConverter` (higher-level, easier API)
3. Do SRC ourselves (we already have the math for PCM conversion in `utils.zig`)

PipeWire does this automatically via its built-in resampler. This is the one area where Core Audio is more work.

**Reference:** [TN2091: Device Input using the HAL Output Audio Unit](https://developer.apple.com/library/archive/technotes/tn2091/_index.html) — Apple's canonical AUHAL reference.

#### Channel Selection

Direct equivalent of `--pw-channel FL`. Uses `kAudioOutputUnitProperty_ChannelMap`:

```c
// Capture only channel 2 (0-indexed) from a 4-channel device as mono:
SInt32 channelMap[1];
channelMap[0] = 2;  // device channel 2 → our mono output channel 0

AudioUnitSetProperty(auHAL,
    kAudioOutputUnitProperty_ChannelMap,
    kAudioUnitScope_Output, 1,
    channelMap, sizeof(channelMap));
```

Set `mChannelsPerFrame = 1` in the desired format and a 1-element map pointing to the device channel index. Set unused slots to `-1`. Built into the AUHAL's internal converter — no extra library needed.

#### Device Enumeration

```c
// Get list of all audio devices
AudioObjectPropertyAddress prop = {
    .mSelector = kAudioHardwarePropertyDevices,
    .mScope    = kAudioObjectPropertyScopeGlobal,
    .mElement  = kAudioObjectPropertyElementMain,
};

UInt32 size;
AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &prop, 0, NULL, &size);
int count = size / sizeof(AudioDeviceID);
AudioDeviceID *devices = malloc(size);
AudioObjectGetPropertyData(kAudioObjectSystemObject, &prop, 0, NULL, &size, devices);

// For each device, get name and check if it has input channels
for (int i = 0; i < count; i++) {
    // Get device name
    CFStringRef name;
    AudioObjectPropertyAddress nameProp = {
        .mSelector = kAudioObjectPropertyName,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 nameSize = sizeof(name);
    AudioObjectGetPropertyData(devices[i], &nameProp, 0, NULL, &nameSize, &name);

    // Check input channel count
    AudioObjectPropertyAddress inputProp = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope = kAudioObjectPropertyScopeInput,  // input side
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 bufSize;
    AudioObjectGetPropertyDataSize(devices[i], &inputProp, 0, NULL, &bufSize);
    AudioBufferList *bufList = malloc(bufSize);
    AudioObjectGetPropertyData(devices[i], &inputProp, 0, NULL, &bufSize, bufList);
    // bufList->mBuffers[n].mNumberChannels tells you channel count per stream
}
```

#### Device Hotplug

```c
// Fires when any audio device is added or removed
AudioObjectPropertyAddress devicesAddr = {
    .mSelector = kAudioHardwarePropertyDevices,
    .mScope    = kAudioObjectPropertyScopeGlobal,
    .mElement  = kAudioObjectPropertyElementMain,
};
AudioObjectAddPropertyListener(
    kAudioObjectSystemObject, &devicesAddr, devicesChangedCallback, ctx);

// Fires when default input device changes
AudioObjectPropertyAddress defaultInputAddr = {
    .mSelector = kAudioHardwarePropertyDefaultInputDevice,
    .mScope    = kAudioObjectPropertyScopeGlobal,
    .mElement  = kAudioObjectPropertyElementMain,
};
AudioObjectAddPropertyListener(
    kAudioObjectSystemObject, &defaultInputAddr, defaultInputChangedCallback, ctx);
```

The callback doesn't tell you which device changed — just that the list changed. Re-enumerate and diff against cached list. Simpler than PipeWire's registry listener but same concept.

The `kAudioHardwarePropertyDefaultInputDevice` listener is the direct equivalent of our PTT-press auto-switch. When the user changes their default mic in System Settings, we get notified and can switch the AUHAL to the new device.

#### Software Gain

Two options:

1. **AUHAL volume property:**
```c
Float32 gain = 2.0;  // 2x gain
AudioUnitSetProperty(auHAL, kHALAudioDevicePropertySubVolumeScalar,
    kAudioUnitScope_Output, 1, &gain, sizeof(gain));
```

2. **Manual gain in callback** (simpler, more portable):
```c
// In captureCallback, after AudioUnitRender:
int16_t *samples = (int16_t *)bufList.mBuffers[0].mData;
for (int i = 0; i < numFrames; i++) {
    int32_t amplified = (int32_t)samples[i] * gain_factor;
    samples[i] = (int16_t)clamp(amplified, -32768, 32767);
}
```

Option 2 is what we'd probably do since our `auto_gain.zig` already works in the sample domain. Same math, just applied in the Core Audio callback instead of via `pw_set_stream_gain`.

#### Avoid AVAudioEngine

**Do not use AVAudioEngine** for this project. Documented problems:

1. Accessing `engine.outputNode` with AirPods connected forces them into 16kHz "headset mode" system-wide. Degrades audio quality for all other apps until your process exits. No workaround.
2. The `bufferSize` parameter in `installTap()` is a hint only — macOS typically delivers 4800-frame buffers regardless.
3. `inputNode.presentationLatency` can return 0.0, making timestamp compensation impossible.

AUHAL is more code but actually works correctly.

**Reference:** [It's Over Between Us, AVAudioEngine](https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/) — detailed bug documentation.

#### C Wrapper Pattern

Same pattern as `pw_helpers.c` — wrap Core Audio calls in C, call from Zig:

```
src/
├── ca_helpers.c        # Core Audio C wrappers (AudioBufferList, AUHAL setup)
├── ca_helpers.h        # Header for Zig @cImport
├── audio_capture.zig   # Platform-agnostic interface, calls ca_helpers on macOS
```

The `AudioBufferList` struct, `AudioStreamBasicDescription`, and `AudioComponentDescription` have the same kind of packed-struct and alignment issues as PipeWire's SPA pods. Keep them in C.

#### pw_detect Equivalent

The `--pw-detect` interactive setup wizard can be ported straightforwardly:
1. Enumerate devices → `kAudioHardwarePropertyDevices` (shown above)
2. Let user pick → same TUI
3. Record silence/speech → AUHAL capture (shown above)
4. Detect best channel → `kAudioOutputUnitProperty_ChannelMap` per-channel RMS analysis
5. Calibrate auto-gain → same math as `auto_gain.zig`

The flow is identical; only the underlying API calls change.

---

## Subsystem 3: Transcription (whisper.cpp)

### Current Linux Architecture

- whisper.cpp with CUDA backend (NVIDIA GPU)
- Model: `ggml-large-v3-turbo-q5_0.bin` (573 MB, q5_0 quantization)
- Pre-built shared libraries in `dist/lib/` (libwhisper.so, libggml-cuda.so, etc.)
- Our pipeline code (`pipeline.zig`, `alignatt.zig`, `mel.zig`) calls whisper.cpp's C API directly — manually drives mel spectrogram, encode, decode loop

### macOS Approach: Metal Backend

**The pipeline layer is fully portable.** `pipeline.zig`, `alignatt.zig`, `mel.zig`, `vad.zig` — none of these know about CUDA or Metal. They call whisper.cpp's C API (`whisper_encode()`, `whisper_decode()`, `whisper_get_logits()`, etc.), which is backend-agnostic. The Metal backend is selected at whisper.cpp build time, not at our API call level.

#### Build Changes

Replace CUDA flags with Metal:

```bash
# Linux (current)
cmake -DGGML_CUDA=ON -DGGML_NATIVE=OFF ...

# macOS
cmake -DGGML_METAL=ON -DGGML_NATIVE=OFF \
      -DGGML_METAL_EMBED_LIBRARY=ON ...
```

`GGML_METAL_EMBED_LIBRARY=ON` embeds the Metal shader source into the library binary. Without this, whisper.cpp looks for `.metal` files at runtime (fragile for distribution).

The Metal shader compilation requires `xcrun metal` — only available on macOS. This is why cross-compilation from Linux is not possible.

#### Performance on Apple Silicon

Published benchmarks for large-v3-turbo (Metal, Flash Attention ON):

| Chip | Encode | Decode/step | Notes |
|---|---|---|---|
| M2 Ultra (76-core GPU) | 147 ms | 1.31 ms | Fastest published |
| M4 Max (40-core GPU) | 250 ms | 1.65 ms | Current high-end laptop |
| M2/M3/M4 Pro (est.) | 300-500 ms | 2-4 ms | Mid-range laptop |
| NVIDIA V100 (CUDA) | 172 ms | 15.76 ms | Datacenter reference |

**Decoder step time is what matters most for our streaming pipeline.** We run many incremental decode cycles per PTT event, each producing a few tokens. At 1.3-4 ms per token step on Apple Silicon vs 15.8 ms on V100, the decode path is significantly faster on Metal.

**Encoder latency** (one call per decode cycle) of 300-500 ms on mid-range Apple Silicon is acceptable for PTT. Our current CUDA path on a GTX 1650 is in a similar range.

#### Unified Memory Advantage

Apple Silicon's unified memory architecture eliminates the PCIe bottleneck:

- **No CPU↔GPU memory copies.** Model weights, KV cache, mel buffer, speech buffer all live in shared memory accessible to both CPU and GPU.
- **GGML uses `MTLResourceStorageModeShared`** + `newBufferWithBytesNoCopy` for zero-copy Metal buffer creation from CPU-allocated memory.
- **Die-level fabric bandwidth:** ~200 GB/s on M1 Pro, ~800 GB/s on M2 Ultra (vs PCIe 4.0 x16 at ~32 GB/s bidirectional on discrete GPUs).

For our use case (short PTT bursts, incremental decode cycles with growing KV cache), no data movement between cycles is the key benefit.

#### Quantization

Our existing `q5_0` quantization works on Metal:
- For large models (large-v3-turbo), quantized weights reduce memory bandwidth demand, which can make them faster than FP16 on the encoder.
- Official whisper.cpp v1.7.5 release notes: "quantized models (q5_0, q8_0) showed comparable performance to unquantized versions on Metal" for large models.
- K-quant formats (q4_K_M, q5_K_M) are not available in whisper.cpp — only the older Q4/Q5/Q8 scheme. q5_0 is the right choice.

#### GGML Low-Level Dispatch on Apple Silicon

GGML uses a tiered strategy:

1. **ARM NEON SIMD** — small matrix ops (decoder steps, which are GEMV not GEMM). This is our hot path.
2. **Accelerate framework (vecLib/CBLAS)** — large matrix ops. Internally dispatches to the **AMX coprocessor** (undocumented 32x32 FMA grid, ~1855 GFLOPS on M1 Pro).
3. **Metal GPU shaders** — full GPU compute for encoder and decoder. Custom kernels handle dequantization + matmul in a single pass for quantized models.

`-DGGML_USE_ACCELERATE` is on by default on macOS.

#### Optional: Core ML + Neural Engine

Adding `-DWHISPER_COREML=1` enables a **Core ML encoder** that runs on the Apple Neural Engine (ANE):

- Encoder runs on ANE: ~3x faster than CPU-only, lower power draw (0.3W vs 1.5W per forward pass)
- Decoder still runs on CPU (ANE can't handle autoregressive KV-cache growth efficiently)
- Requires shipping a `.mlmodelc` bundle alongside the GGML model
- **First-run JIT compilation:** ANE compiles the Core ML model to device-specific binary on first use. This takes **up to 6 minutes** on M2. Subsequent runs use cache. Could trigger this during install (like our model download).

This is optional and can be added later. Metal-only is the baseline.

#### Shared Library Layout

macOS equivalent of our `dist/lib/` layout:

```
dist/
├── bin/capsper                    (built by zig)
├── lib/
│   ├── libwhisper.dylib           (Metal backend)
│   ├── libggml.dylib
│   ├── libggml-base.dylib
│   ├── libggml-cpu.dylib
│   └── libggml-metal.dylib        (replaces libggml-cuda.so)
├── models/
│   ├── ten-vad-ggml.bin
│   ├── ggml-silero-v5.1.2.bin
│   └── ggml-large-v3-turbo-q5_0.bin
└── install.sh
```

RPATH: `@executable_path/../lib` (macOS equivalent of `$ORIGIN/../lib`). Shared lib inter-dependencies use `@loader_path` (equivalent of `$ORIGIN`). Use `install_name_tool` to fix paths if CMake doesn't set them correctly, or configure via `CMAKE_INSTALL_RPATH` at build time (preferred, same as Linux).

#### VAD Backends

- **TEN-VAD GGML** (`--vad ten`) — fully portable. Pure Zig + GGML, no platform dependencies. FFT via submodule C code. Works as-is on macOS.
- **TEN-VAD Native** (`--vad ten-native`) — prebuilt `libten_vad.so` is Linux-specific. Would need a macOS `.dylib` build of the TEN-VAD submodule. Low priority since the GGML port exists.
- **Silero** (`--vad silero`) — via whisper.cpp, platform-agnostic. Works as-is.

---

## Subsystem 4: Permissions & Code Signing

### Permissions Required

| Permission | What Needs It | How to Grant |
|---|---|---|
| **Accessibility** | CGEventTap (keyboard interception) + CGEventPost (text injection) | System Settings → Privacy & Security → Accessibility → add capsper |
| **Microphone** | Core Audio AUHAL capture | TCC dialog on first `AVCaptureDevice.requestAccess(for: .audio)` call |
| **Input Monitoring** | `hidutil` key remap (macOS 15+) | Covered by Accessibility permission (superset) |

Two permissions total from the user's perspective: Accessibility and Microphone.

### Code Signing for Development

Ad-hoc signing is sufficient for local dev and friend distribution:

```bash
# Create entitlements file
cat > capsper.entitlements << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign with microphone entitlement and hardened runtime
codesign --force --sign - \
    --options runtime \
    --entitlements capsper.entitlements \
    dist/bin/capsper
```

`--sign -` = ad-hoc (no Apple Developer cert). `--options runtime` = hardened runtime (required for TCC to show the microphone permission dialog).

### First-Launch Flow

1. User runs `capsper` for the first time
2. macOS shows "capsper wants to access the microphone" → user clicks Allow
3. User must manually add capsper to Accessibility in System Settings (no programmatic prompt for this — `AXIsProcessTrusted()` returns false, we print instructions)
4. User restarts capsper → fully functional

On subsequent launches, permissions are cached in the TCC database. No re-prompting.

### Gatekeeper for Friend Distribution

Friends receiving a pre-built binary will see "capsper can't be opened because it is from an unidentified developer." Solutions:

1. **Right-click → Open** — bypasses Gatekeeper for that binary (one-time)
2. **`xattr -cr /path/to/capsper`** — removes the quarantine flag
3. **System Settings → Privacy & Security → "Allow Anyway"** — appears after a blocked launch attempt

All are one-time operations. Power users won't have trouble.

---

## Subsystem 5: Service Management

### Current Linux Architecture

- systemd user service (`capsper.service`)
- `ExecStartPre` runs `apply-update.sh` (symlink swap for updates)
- `capsper-update.sh` downloads from GitHub Releases, verifies SHA256

### macOS Approach: LaunchAgent

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.capsper.dictation</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/USERNAME/.local/share/capsper/bin/capsper</string>
        <string>--trigger</string>
        <string>capslock</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/USERNAME/.local/share/capsper/capsper.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/USERNAME/.local/share/capsper/capsper.log</string>
</dict>
</plist>
```

Installed to `~/Library/LaunchAgents/com.capsper.dictation.plist`.

```bash
# Load and start
launchctl load ~/Library/LaunchAgents/com.capsper.dictation.plist

# Stop and unload
launchctl unload ~/Library/LaunchAgents/com.capsper.dictation.plist

# View status
launchctl list | grep capsper
```

**`hidutil` remap persistence:** Add a second LaunchAgent or make capsper apply the `hidutil` remap on startup before setting up the CGEventTap. Prefer the latter — keeps everything self-contained.

---

## Build System

### Zig Cross-Compilation: Not Possible

Two blockers prevent building macOS capsper on Linux:

1. **Metal shaders** — `xcrun metal` compiler only exists on macOS
2. **Apple frameworks** — linking against CoreAudio, CoreGraphics, ApplicationServices requires the macOS SDK (Xcode-only distribution)

Must build on macOS.

### CI

GitHub Actions provides macOS runners including Apple Silicon:

```yaml
# .github/workflows/ci.yml
jobs:
  linux:
    runs-on: ubuntu-latest
    steps:
      - run: ./run.ts ci

  macos:
    runs-on: macos-15      # Apple Silicon (M-series)
    steps:
      - run: ./run.ts ci   # Same task runner, platform-detected build flags
```

### Platform Detection in `run.ts`

`run.ts` detects platform and sets build flags accordingly:

```typescript
const isMacOS = process.platform === 'darwin';
const zigBuildFlags = isMacOS
    ? ['-Dbackend=metal']
    : ['-Dbackend=cuda', `-Dcpu=x86_64_v3`];
```

### build.zig Changes

The Zig build script needs platform-conditional linking:

```zig
if (target.result.os.tag == .macos) {
    // Link Apple frameworks
    exe.linkFramework("CoreAudio");
    exe.linkFramework("CoreGraphics");
    exe.linkFramework("ApplicationServices");
    exe.linkFramework("CoreFoundation");

    // Link Metal-backend whisper.cpp
    exe.addLibraryPath(.{ .cwd_relative = "dist/lib" });
    exe.linkSystemLibrary("whisper");
    exe.linkSystemLibrary("ggml");
    exe.linkSystemLibrary("ggml-metal");

    // Compile macOS-specific C helpers
    exe.addCSourceFile(.{ .file = .{ .cwd_relative = "src/ca_helpers.c" } });
    exe.addCSourceFile(.{ .file = .{ .cwd_relative = "src/cg_helpers.c" } });
} else {
    // Linux: existing PipeWire + CUDA path
    exe.addCSourceFile(.{ .file = .{ .cwd_relative = "src/pw_helpers.c" } });
    // ... existing Linux linking
}
```

### Source File Organization

Platform-specific code isolated in separate files:

```
src/
├── main.zig              # Entry point (platform-conditional wiring)
├── server.zig            # Platform-agnostic 2-state machine
├── pipeline.zig          # Platform-agnostic whisper pipeline
├── alignatt.zig          # Platform-agnostic attention analysis
├── mel.zig               # Platform-agnostic mel buffer (if extracted)
├── vad.zig               # Platform-agnostic VAD
├── auto_gain.zig         # Platform-agnostic gain math
├── utils.zig             # Platform-agnostic utilities
│
├── input.zig             # CURRENT: evdev/uinput (Linux)
├── input_macos.zig       # NEW: CGEventTap/CGEventPost (macOS)
│
├── audio_capture.zig     # CURRENT: PipeWire (Linux)
├── audio_capture_macos.zig  # NEW: Core Audio AUHAL (macOS)
│
├── pw_helpers.c          # CURRENT: PipeWire C wrappers (Linux)
├── pw_detect.zig         # CURRENT: PipeWire setup wizard (Linux)
│
├── ca_helpers.c          # NEW: Core Audio C wrappers (macOS)
├── ca_helpers.h          # NEW: Header for Zig @cImport
├── cg_helpers.c          # NEW: CoreGraphics C wrappers (macOS)
├── cg_helpers.h          # NEW: Header for Zig @cImport
├── ca_detect.zig         # NEW: Core Audio setup wizard (macOS)
│
├── whisper_c.zig         # Unchanged: whisper.cpp C bridge
├── pipewire_c.zig        # CURRENT: PipeWire C bridge (Linux-only)
├── coreaudio_c.zig       # NEW: Core Audio C bridge (macOS-only)
├── coregraphics_c.zig    # NEW: CoreGraphics C bridge (macOS-only)
```

The server, pipeline, VAD, and utility layers don't change at all. The platform boundary is at the input and audio capture layers — same as how it's currently structured, just with macOS alternatives.

---

## Apple's Built-in Dictation vs Capsper

For context on why this port is worth doing — Apple's built-in dictation is not a competitor:

| | Apple Dictation | Capsper |
|---|---|---|
| **Model** | Small on-device model (opt-in) or server-side (default) | Whisper large-v3-turbo (573 MB, fully local) |
| **Accuracy** | Good for conversational speech. Struggles with technical terms, code, mixed languages, proper nouns | Significantly better across all domains. Domain term prompting via `<|startofprev|>` |
| **Privacy** | Default sends audio to Apple servers | Fully local, never leaves the machine |
| **UX** | Takes over input focus, shows dictation UI, dedicated dictation mode | Push-to-talk into any focused field, no UI takeover, seamless |
| **Customization** | None | Trigger key, domain terms, VAD thresholds, gain calibration |
| **Integration** | System feature, not extensible | Keystroke injection works in every app identically |

The fundamental UX difference: Apple's dictation is a modal input method. Capsper is transparent keystroke injection — the receiving app doesn't know the text came from speech.

---

## Implementation Phases

### Phase 1: Keyboard + Text Injection (macOS `input_macos.zig`)

Start here because it's the simplest subsystem and the most novel (no Linux code to reuse).

1. `hidutil` CapsLock→F19 remap on startup
2. CGEventTap intercepts F19, signals PTT state
3. CGEventPost + CGEventKeyboardSetUnicodeString injects text (batched, 20 chars/event)
4. Watchdog health check (`CGEventTapIsEnabled()` polling)
5. Undo `hidutil` remap on clean exit

**Test:** Manual — run binary, press CapsLock, verify no LED toggle and no F19 reaches apps. Type text programmatically, verify it appears in TextEdit/Terminal/VS Code.

### Phase 2: Audio Capture (macOS `audio_capture_macos.zig` + `ca_helpers.c`)

1. AUHAL setup for 16kHz mono S16_LE capture
2. Channel selection via `kAudioOutputUnitProperty_ChannelMap`
3. Device enumeration and selection
4. Callback feeds PCM to server.zig (same interface as PipeWire callback)
5. Sample rate conversion if hardware doesn't support 16kHz natively

**Test:** Capture audio, write to WAV, verify with existing regression test infrastructure (can feed WAV to server via TCP socket).

### Phase 3: Whisper.cpp Metal Build

1. CMake configure with `-DGGML_METAL=ON`
2. Build shared `.dylib` libraries
3. Verify RPATH (`@executable_path/../lib`, `@loader_path`)
4. Run existing pipeline unit tests (platform-agnostic)
5. Benchmark encode/decode latency on target hardware

**Test:** Feed known audio via TCP, compare transcription output to Linux CUDA output. Should be identical (same model, same pipeline code, different backend).

### Phase 4: Integration + Service

1. Wire all subsystems together in `main.zig` (platform-conditional)
2. End-to-end PTT flow: CapsLock → audio capture → transcription → keystroke injection
3. LaunchAgent plist for service management
4. `install.sh` macOS path (detect platform, install LaunchAgent instead of systemd service)
5. `ca_detect.zig` setup wizard (device/channel/gain calibration)

### Phase 5: Polish

1. Permission prompting UX (detect missing permissions, print clear instructions)
2. Auto-gain runtime adjustment (same math, Core Audio gain API)
3. Device hotplug listener
4. Typing cancel on PTT release
5. `run.ts` platform-conditional build/test/CI targets

---

## Open Questions

1. **Sample rate conversion strategy:** Build an `AudioConverter` chain, use AVAudioConverter, or do SRC in Zig? The AUHAL doesn't auto-resample. Need to check what sample rates the built-in Mac mic actually supports — if it supports 16kHz natively, this is moot.

2. **Metal shader embedding vs external files:** `GGML_METAL_EMBED_LIBRARY=ON` embeds shaders in the dylib (simpler distribution). Verify this works with our RPATH layout.

3. **TEN-VAD FFT on macOS:** The GGML VAD backend calls `ten-vad/src/fftw.c` via `@cImport`. Need to verify this compiles on macOS (it's plain C, should be fine, but check for any POSIX assumptions).

4. **CPU target for macOS:** Linux targets `x86_64_v3`. macOS targets `aarch64` (Apple Silicon). Do we need any specific ARM feature flags, or is the default `aarch64-macos` target sufficient?

5. **Test infrastructure:** Regression tests use TCP socket to feed audio. This is platform-agnostic and should work as-is. Unit tests and property tests are also platform-agnostic. May need macOS-specific integration tests for CGEventTap and Core Audio.

---

## References

### Keyboard / Input
- [Apple TN2450: Remapping Keys (hidutil)](https://developer.apple.com/library/archive/technotes/tn2450/_index.html)
- [Apple QA1519: Detecting the Caps Lock Key](https://developer.apple.com/library/archive/qa/qa1519/_index.html)
- [CGEventTapCreate documentation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate)
- [Karabiner-Elements source (reference architecture)](https://github.com/pqrs-org/Karabiner-Elements)
- [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)

### Audio
- [Apple TN2091: Device Input using AUHAL](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)
- [Core Audio Overview](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/WhatisCoreAudio/WhatisCoreAudio.html)
- [Audio APIs Part 1: Core Audio (practitioner comparison)](https://bastibe.de/2017-06-17-audio-apis-coreaudio.html)
- [It's Over, AVAudioEngine (bug documentation)](https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/)

### Transcription
- [whisper.cpp repository](https://github.com/ggml-org/whisper.cpp)
- [whisper.cpp release benchmarks (Metal)](https://github.com/ggml-org/whisper.cpp/releases)
- [Core ML encoder PR #566](https://github.com/ggml-org/whisper.cpp/pull/566)
- [ANE architecture discussion #548](https://github.com/ggml-org/whisper.cpp/discussions/548)
- [WhisperKit paper (streaming on ANE)](https://arxiv.org/html/2507.10860v1)
- [mac-whisper-speedtest (M4 benchmarks)](https://github.com/anvanvan/mac-whisper-speedtest)

### Permissions & Distribution
- [Hardened Runtime documentation](https://developer.apple.com/documentation/security/hardened-runtime)
- [HIDDriverKit documentation](https://developer.apple.com/documentation/hiddriverkit)
