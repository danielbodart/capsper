# macOS / Apple Silicon Port

**Goal:** Port capsper to macOS on Apple Silicon, replacing Linux-specific subsystems (evdev/uinput, PipeWire, CUDA) with macOS equivalents (CGEventTap, Core Audio, Metal). Maintain the same UX: CapsLock push-to-talk, transcription injected as keystrokes into any focused application. **This is a multi-platform project — Linux support is not being replaced.**

**Target:** macOS 15+ (Sequoia) on Apple Silicon (M1+). No Intel Mac support needed.

**Distribution:** Homebrew formula in a personal tap (`homebrew-capsper`). No Apple Developer fee, no code signing, no notarization required. For direct distribution: ad-hoc code signing is sufficient.

**Build requirement:** Full Xcode.app required (not just Command Line Tools) for Metal shader compilation (`xcrun metal`).

**Local Xcode installation:** First-time install must go through the App Store GUI or [developer.apple.com/xcode](https://developer.apple.com/xcode/) — `mas` (Mac App Store CLI) only works for apps you've previously "purchased". After the first install, subsequent updates can use `mas install 497799835`.
```bash
# After installing Xcode from App Store:
sudo xcodebuild -license accept
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain  # NO sudo — per-user install
xcrun metal --version  # verify Metal tools work
```

**Xcode 26+ Metal Toolchain gotcha:** The Metal compiler is a separate download since Xcode 26. Must be installed with `xcodebuild -downloadComponent MetalToolchain` **without sudo** — the toolchain is [only visible to the user who installed it](https://openradar.appspot.com/FB20389216). Running with sudo installs it as root and your user can't see it.
The bootstrap script detects whether `xcrun metal` already works and prints setup instructions if not. On GitHub CI runners, Xcode is preinstalled in the runner image — no manual install needed.

---

## Decisions Log

| Decision | Rationale |
|---|---|
| Separate files per platform (`input.zig` + `input_macos.zig`) | Files are already large; keeps platform code cleanly separated |
| Hybrid C/Zig approach | Zig where possible, C helpers for Apple API edge cases (same pattern as `pw_helpers.c`) |
| Auto-detect platform in `build.zig` / `run.ts` | No CUDA on macOS, no Metal on Linux — auto-detection is unambiguous |
| Build Metal dylibs on GitHub CI (free M1 runners) | Avoids committing macOS binaries to LFS; CI runners have Metal GPU support |
| Separate platform release downloads | Linux users shouldn't download macOS dylibs and vice versa |
| Homebrew formula (not cask) for distribution | CLI tool fits formula pattern; no signing/notarization needed via brew |
| Comptime platform shims (not build options) | `builtin.os.tag` is idiomatic Zig; avoids threading options through every target |
| `--stream-wav` for initial Metal validation | Faster and more deterministic than TCP socket; already exists |
| Full Xcode required for building | Metal shader embedding (`GGML_METAL_EMBED_LIBRARY=ON`) needs `xcrun metal` which is not in CLI tools |

---

## Platform Mapping

| Linux (current) | macOS equivalent | Complexity vs Linux |
|---|---|---|
| evdev exclusive grab | `hidutil` CapsLock remap + CGEventTap | Simpler |
| uinput virtual keyboard | CGEventPost + CGEventKeyboardSetUnicodeString | Simpler |
| inotify keyboard hotplug | Not needed (hidutil is device-agnostic) | Eliminated |
| EVIOCGKEY polling safety net | `CGEventTapIsEnabled()` health check | Simpler |
| PipeWire `pw_stream` | Core Audio AUHAL (`kAudioUnitSubType_HALOutput`) | Comparable |
| PipeWire channel map (`--pw-channel`) | `kAudioOutputUnitProperty_ChannelMap` | Identical concept |
| PipeWire device hotplug | `AudioObjectAddPropertyListener` | Simpler |
| PipeWire software gain (`pw_set_stream_gain`) | Manual gain in capture callback | Same pattern |
| `pw_helpers.c` (SPA pod wrappers) | `ca_helpers.c` (CoreAudio wrappers) | Same pattern |
| CUDA (whisper.cpp) | Metal (whisper.cpp) | Same C API, different backend flag |
| systemd user service | LaunchAgent plist | Simpler |
| systemd update timer | LaunchAgent update timer or `brew upgrade` | See Service Management |
| evdev group permissions | TCC (Accessibility + Microphone) | Different but manageable |
| No code signing needed | Ad-hoc code signing + entitlements | New requirement |
| `apt install` deps | `brew install` deps | Same pattern |

---

## Architecture: Platform Abstraction

### Approach: Comptime Platform Shims

Each platform-specific module gets a macOS sibling and a thin shim that selects at comptime:

```
src/audio_capture_platform.zig    →  re-exports audio_capture.zig (Linux) or audio_capture_macos.zig
src/input_platform.zig            →  re-exports input.zig (Linux) or input_macos.zig
src/audio_detect_platform.zig     →  re-exports pw_detect.zig (Linux) or audio_detect_macos.zig
```

Shim pattern (4 lines each):
```zig
const builtin = @import("builtin");
pub usingnamespace if (builtin.os.tag == .macos)
    @import("audio_capture_macos.zig")
else
    @import("audio_capture.zig");
```

This means:
- `server.zig` imports `audio_capture_platform.zig` — one line change, zero behavior change
- `main.zig` imports `input_platform.zig` and `audio_detect_platform.zig`
- No build options to thread through every target
- Both implementations export identical public surfaces (same struct names, same method signatures)

### Interface Contracts

**`AudioCapture`** — both `audio_capture.zig` and `audio_capture_macos.zig` must export:
```zig
pub const AudioCapture = struct {
    pub const default_channel: u32 = ...; // platform-specific default
    pub fn init(target: ?[:0]const u8, channel_position: u32) !AudioCapture
    pub fn deinit(self: *AudioCapture) void
    pub fn setActive(self: *AudioCapture, active: bool) void
    pub fn setCork(self: *AudioCapture, corked: bool) void
    pub fn setGain(self: *AudioCapture, gain: f32) void
    pub fn getFd(self: *const AudioCapture) posix.fd_t
    pub fn parseChannelName(name: []const u8) ?u32
};
```

**`InputHandler`** — both `input.zig` and `input_macos.zig` must export:
```zig
pub const InputHandler = struct {
    pub fn init(config: Config) !InputHandler
    pub fn deinit(self: *InputHandler) void
    pub fn start(self: *InputHandler) !void
    pub fn typeTextCallback(ctx: *anyopaque, text: []const u8) void
};
pub fn parseTriggerKey(name: []const u8) ?u16
```

### Data Flow: Audio Capture (macOS)

```
CoreAudio AUHAL callback thread (C, in ca_helpers.c)
    → AudioUnitRender() to pull PCM from hardware
    → applies software gain (integer multiply in-place on S16 samples)
    → posix.write(pipe_write_fd, pcm_chunk)

Main thread (server.zig:handleConnection — UNCHANGED)
    ChunkedReader.read(pipe_read_fd)
    → VadFilter.filterAudio()
    → speech_buf.appendSlice()
    → Pipeline.transcribe()
```

The pipe is the synchronization primitive, identical to the Linux path. `server.zig:handleConnection` does not change at all.

### Data Flow: Input Handling (macOS)

```
CGEventTap callback thread (CoreFoundation RunLoop, in input_helpers_macos.c)
    → receives CGEvent (keydown/keyup for remapped F19)
    → if trigger key: calls Zig function pointer (live_fn)
    → returns NULL to swallow event (or event to pass through)

Zig InputHandler.typeText() (called from server.zig TypeCallback)
    → for each char: calls input_macos_inject_text() C helper
    → CGEventCreateKeyboardEvent + CGEventKeyboardSetUnicodeString + CGEventPost
    → delay between batches (std.Thread.sleep), check cancel flag
```

---

## Source File Organization

### New Files

| File | Purpose |
|---|---|
| `src/audio_capture_platform.zig` | Comptime shim → `audio_capture.zig` or `audio_capture_macos.zig` |
| `src/input_platform.zig` | Comptime shim → `input.zig` or `input_macos.zig` |
| `src/audio_detect_platform.zig` | Comptime shim → `pw_detect.zig` or `audio_detect_macos.zig` |
| `src/audio_capture_macos.zig` | CoreAudio AUHAL capture (same interface as `audio_capture.zig`) |
| `src/input_macos.zig` | CGEventTap + CGEventPost input handler (same interface as `input.zig`) |
| `src/audio_detect_macos.zig` | CoreAudio device enumeration wizard |
| `src/ca_helpers.c` | C wrappers for CoreAudio (AUHAL setup, device enumeration, AudioBufferList) |
| `src/input_helpers_macos.c` | C wrappers for CGEventTap/CGEventPost/hidutil |
| `dist/install-macos.sh` | macOS installer (LaunchAgent, permissions, model download) |

### Files to Modify

| File | Changes |
|---|---|
| `src/server.zig` | Import `audio_capture_platform.zig`; rename `pw_target`/`pw_channel` → `audio_target`/`audio_channel` |
| `src/main.zig` | Import platform shims; comptime GPU check message; move `parseChannelName` to platform module |
| `build.zig` | Platform-conditional linking (frameworks vs PipeWire), RPATH, C source files, lib paths |
| `run.ts` | Platform detection, `brew` vs `apt`, macOS dep checks, `otool` vs `readelf` validation |
| `src/prop_tests.zig` | Import `input_platform.zig`; guard Linux-specific tests with comptime |
| `.github/workflows/ci.yml` | Add parallel macOS job on `macos-15` runner |

### Platform-Agnostic Files (NO Changes)

`pipeline.zig`, `alignatt.zig`, `mel.zig`, `vad.zig`, `utils.zig`, `auto_gain.zig`, `dsp.zig`, `conv.zig`, `whisper_c.zig`, `recorder.zig`, `server.zig` (except the import line and field renames)

---

## Subsystem 1: Keyboard Interception & Text Injection

### CapsLock Interception via `hidutil`

macOS processes CapsLock at the HID driver level before user-space code sees it. **Solution:** `hidutil property --set` remaps CapsLock to F19 inside `IOHIDKeyboardFilter`, before the CapsLock toggle logic.

```bash
hidutil property --set '{"UserKeyMapping":[{
  "HIDKeyboardModifierMappingSrc": 0x700000039,
  "HIDKeyboardModifierMappingDst": 0x70000006E
}]}'
```

Effects: no LED toggle, no CapsLock state change, clean keyDown/keyUp pair for F19. Session-scoped (lost on reboot) — capsper applies it on startup.

**Reference:** [Apple TN2450: Remapping Keys](https://developer.apple.com/library/archive/technotes/tn2450/_index.html)

### CGEventTap for Keyboard Interception

```c
CGEventMask mask = (1 << kCGEventKeyDown) | (1 << kCGEventKeyUp);
CFMachPortRef tap = CGEventTapCreate(
    kCGHIDEventTap,              // earliest interception point
    kCGHeadInsertEventTap,
    kCGEventTapOptionDefault,    // active: can suppress events
    mask, tapCallback, context
);
```

Callback returns `NULL` to swallow F19 (trigger key), returns `event` for all other keys.

**Watchdog:** macOS auto-disables taps if callback is slow. Handle `kCGEventTapDisabledByTimeout` and re-enable. Poll `CGEventTapIsEnabled()` periodically as safety net.

**Permissions:** Requires Accessibility permission. Check with `AXIsProcessTrustedWithOptions()` — print clear instructions if denied.

### CGEventPost for Text Injection

```c
// Batched: up to 20 Unicode chars per event
CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, 0, true);
CGEventKeyboardSetUnicodeString(keyDown, batch_len, chars);
CGEventPost(kCGSessionEventTap, keyDown);
```

`CGEventKeyboardSetUnicodeString` bypasses keycode mapping entirely — handles emoji, CJK, accented characters natively. Much simpler than Linux's uinput path.

**Limitations:** Secure Keyboard Entry (password fields) blocks injection — acceptable for dictation.

### What We Don't Need on macOS

- **No hotplug** — `hidutil` remap is device-agnostic
- **No panic sequence** — not grabbing keyboard exclusively; crash = all keys still work
- **No virtual keyboard device** — CGEventPost injects directly into event stream

---

## Subsystem 2: Audio Capture

### Core Audio AUHAL

Direct equivalent of PipeWire `pw_stream`. Callback-driven, configurable buffer sizes, direct hardware access.

**Key difference from PipeWire:** AUHAL does NOT auto-resample. If hardware mic is 48kHz and we want 16kHz, we need an `AudioConverterRef` for sample rate conversion. PipeWire handles this transparently.

**Pipe-based handoff:** Same architecture as Linux — AUHAL callback writes S16_LE PCM to a pipe, main thread reads via `ChunkedReader`. Preserves `server.zig:handleConnection` completely unchanged.

**Channel selection:** `kAudioOutputUnitProperty_ChannelMap` — zero-based channel index. "MONO"/"FL" → 0, "FR" → 1.

**Software gain:** Applied in capture callback via integer multiply (same math as `auto_gain.zig`, just in the callback instead of via `pw_set_stream_gain`).

**Do NOT use AVAudioEngine.** Documented bugs: forces AirPods into 16kHz headset mode, ignores buffer size hints, broken latency reporting. AUHAL is more code but works correctly. See [It's Over, AVAudioEngine](https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/).

### C Wrapper Pattern

Same as `pw_helpers.c` — `AudioBufferList`, `AudioStreamBasicDescription`, and `AudioComponentDescription` have packed-struct and alignment issues from Zig. Keep them in `ca_helpers.c`.

Functions:
- `ca_get_default_input_device(AudioDeviceID *out)`
- `ca_enumerate_input_devices(struct ca_device_info *results, int max)`
- `ca_device_uid_for_name(const char *name, char *uid_out, size_t uid_max)`
- `ca_create_auhal(AudioDeviceID device, int channel, int pipe_write_fd, float *gain_ptr)` → `AudioComponentInstance`
- `ca_start_auhal(AudioComponentInstance unit)` / `ca_stop_auhal()`

---

## Subsystem 3: Transcription (whisper.cpp Metal)

**The pipeline layer is fully portable.** `pipeline.zig`, `alignatt.zig`, `mel.zig`, `vad.zig` call whisper.cpp's backend-agnostic C API. Metal is selected at whisper.cpp build time, not at our API level.

### Build Changes

```bash
# Linux (current)
cmake -DGGML_CUDA=ON -DGGML_NATIVE=OFF ...

# macOS
cmake -DGGML_METAL=ON -DGGML_NATIVE=OFF -DGGML_METAL_EMBED_LIBRARY=ON ...
```

`GGML_METAL_EMBED_LIBRARY=ON` embeds Metal shader source into the dylib — no `.metal` files needed at runtime. Requires full Xcode (`xcrun metal` compiler).

### Shared Library Layout

```
dist/lib-macos/                    (built by CI, NOT committed to LFS)
├── libwhisper.dylib
├── libggml.dylib
├── libggml-base.dylib
├── libggml-cpu.dylib
└── libggml-metal.dylib            (replaces libggml-cuda.so)
```

RPATH: Binary uses `@loader_path/../lib`. Shared lib inter-dependencies use `@loader_path`. Configured via `CMAKE_INSTALL_RPATH=@loader_path` + `CMAKE_BUILD_WITH_INSTALL_RPATH=ON`.

### Performance on Apple Silicon

Published benchmarks for large-v3-turbo (Metal):

| Chip | Encode | Decode/step |
|---|---|---|
| M2 Ultra (76-core GPU) | 147 ms | 1.31 ms |
| M4 Max (40-core GPU) | 250 ms | 1.65 ms |
| M2/M3/M4 Pro (est.) | 300-500 ms | 2-4 ms |

Decoder step time matters most for streaming. Apple Silicon is significantly faster per step than CUDA on mid-range GPUs.

**Word error rate should be identical** — same model, same pipeline code, same mel spectrogram (computed in Zig), different GPU backend for encode/decode. The CI macOS runner can validate this by running regression tests.

### VAD Backends on macOS

- **TEN-VAD GGML** (`--vad ten`) — fully portable, works as-is
- **Silero** (`--vad silero`) — via whisper.cpp, works as-is
- **TEN-VAD Native** (`--vad ten-native`) — Linux-only (`libten_vad.so`). Error on macOS.

### Zig Code Changes for Metal

Minimal:
- `main.zig:requireGpu()` — change "CUDA" error message to "Metal" via comptime
- `main.zig:469` — warmup log mentions "CUDA kernel compilation", change to "Metal shader compilation" via comptime
- Everything else is backend-agnostic

---

## Subsystem 4: Permissions & Code Signing

### Permissions Required

| Permission | What Needs It | How to Grant |
|---|---|---|
| **Accessibility** | CGEventTap + CGEventPost | System Settings → Privacy & Security → Accessibility → add capsper |
| **Microphone** | Core Audio AUHAL | TCC dialog on first launch (requires hardened runtime + entitlement) |

Two permissions from the user's perspective.

### Ad-hoc Code Signing

```bash
codesign --force --sign - --options runtime --entitlements capsper.entitlements dist/bin/capsper
```

`--sign -` = ad-hoc (no cert). `--options runtime` = hardened runtime (needed for TCC mic prompt).

Entitlements file:
```xml
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
```

### Gatekeeper: Not an Issue via Homebrew

Homebrew downloads tarballs via `curl`, which does not set the quarantine xattr. Gatekeeper never triggers. No signing or notarization needed for Homebrew formula distribution.

For direct downloads (GitHub Releases), users need one of: right-click → Open, `xattr -cr`, or System Settings → Allow Anyway.

---

## Subsystem 5: Service Management & Auto-Update

### LaunchAgent (systemd equivalent)

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
        <string>INSTALL_DIR/bin/capsper</string>
        <string>--trigger</string>
        <string>capslock</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DYLD_LIBRARY_PATH</key>
        <string>INSTALL_DIR/lib</string>
    </dict>
    <key>StandardOutPath</key>
    <string>INSTALL_DIR/capsper.log</string>
    <key>StandardErrorPath</key>
    <string>INSTALL_DIR/capsper.log</string>
</dict>
</plist>
```

Installed to `~/Library/LaunchAgents/com.capsper.dictation.plist`.

```bash
launchctl load ~/Library/LaunchAgents/com.capsper.dictation.plist    # start
launchctl unload ~/Library/LaunchAgents/com.capsper.dictation.plist  # stop
launchctl list | grep capsper                                        # status
```

### Auto-Update Options

Three viable approaches, from simplest to most integrated:

**Option A: Homebrew-native updates (recommended for Homebrew installs)**
- User runs `brew upgrade capsper` manually, or enables `brew autoupdate`
- Formula points to GitHub Release URL with sha256 — update the formula when releasing
- Can automate formula updates in CI: after uploading release assets, commit new sha256 to the tap repo
- No custom update infrastructure needed

**Option B: Version check on startup**
- capsper checks GitHub Releases API on startup (or daily via cached timestamp)
- If newer version available, prints: `"capsper vX.Y.Z available — run 'brew upgrade capsper' to update"`
- Lightweight, non-intrusive, works for both Homebrew and direct installs

**Option C: LaunchAgent update timer (mirrors Linux pattern)**
- Second LaunchAgent (`com.capsper.update.plist`) with `StartCalendarInterval` (daily/weekly)
- Runs `capsper-update-macos.sh` — downloads from GitHub Releases, verifies SHA256, stages update
- Next capsper restart picks up new binary (same `apply-update.sh` pattern as Linux)
- More complex but works for non-Homebrew installs

**Recommendation:** Start with Option A (Homebrew-native) + Option B (startup version check). Add Option C later if needed for non-Homebrew users.

### `hidutil` Remap Persistence

The `hidutil` remap is session-scoped (lost on reboot). Two options:

1. **capsper applies it on startup** (preferred) — self-contained, no extra LaunchAgent
2. **Separate LaunchAgent** — runs `hidutil` at login before capsper starts

Option 1 is simpler. capsper's `init()` calls `hidutil` via `posix.execve` or the C helper before creating the CGEventTap.

---

## Build System

### `build.zig` Platform Branching

Implemented via helper functions to avoid duplication across exe, test, and tool targets:

```zig
const is_macos = target.result.os.tag == .macos;

// Helper functions: addWhisperIncludes, addTenVad, addPlatformDeps,
// addWhisperLibs, addLibPath — each takes *Compile (not *Module,
// because Module.linkSystemLibrary requires an options struct in Zig 0.15).

addWhisperIncludes(b, exe);
addTenVad(b, exe, ten_vad_flags);
addPlatformDeps(b, exe, is_macos);   // CoreAudio+frameworks or PipeWire
addWhisperLibs(b, exe, is_macos);    // ggml-metal+ggml-blas or ggml-cuda
```

### `rebuild-libs` Step

```zig
if (is_macos) {
    cmake_configure.addArg("-DGGML_METAL=ON");
    cmake_configure.addArg("-DGGML_METAL_EMBED_LIBRARY=ON");
    // output to dist/lib-macos/
} else {
    cmake_configure.addArg("-DGGML_CUDA=ON");
    cmake_configure.addArg("-DCMAKE_CUDA_ARCHITECTURES=75-virtual;86-virtual;89-virtual;120a-virtual");
    // output to dist/lib/
}
```

### `run.ts` Platform Detection

```typescript
const IS_MACOS = process.platform === "darwin";

async function ensureDeps(opts?: { gpu_libs?: boolean }) {
    if (IS_MACOS) {
        if (!await which("brew")) { console.error("Homebrew required"); process.exit(1); }
        // Verify Xcode for Metal shader compilation
        if (opts?.gpu_libs) {
            const { exitCode } = await $`xcrun metal --version`.quiet().nothrow();
            if (exitCode !== 0) {
                console.error("Full Xcode.app required for Metal shader compilation.");
                console.error("Install from: https://developer.apple.com/xcode/");
                process.exit(1);
            }
        }
    } else {
        // existing Linux dep checks (apt, pkg-config, nvcc, etc.)
    }
}
```

Build flags:
```typescript
const cpu_flag = IS_MACOS ? [] : ["-Dcpu=x86_64_v3"];  // macOS uses default aarch64
```

Dist validation:
```typescript
if (IS_MACOS) {
    // otool -L for dylib deps, otool -l for RPATH, file for Mach-O check
} else {
    // readelf for RPATH, objdump for AVX-512 check
}
```

### `dist/` Layout

```
dist/
├── bin/capsper                    (gitignored — built by zig)
├── lib/                           (Linux .so files — committed via LFS)
│   ├── libwhisper.so.1.8.3
│   ├── libggml-cuda.so.0.9.6
│   └── ...
├── lib-macos/                     (macOS .dylib files — built by CI, gitignored)
│   ├── libwhisper.dylib
│   ├── libggml-metal.dylib
│   └── ...
├── models/
│   ├── ten-vad-ggml.bin
│   ├── ggml-silero-v5.1.2.bin
│   └── ggml-large-v3-turbo-q5_0.bin  (gitignored)
├── install.sh                     (Linux installer)
└── install-macos.sh               (macOS installer)
```

Release tarballs:
- `capsper-linux-x86_64.tar.gz` — contains `bin/`, `lib/` (from `dist/lib/`), `models/`, `install.sh`
- `capsper-macos-arm64.tar.gz` — contains `bin/`, `lib/` (from `dist/lib-macos/`, renamed to `lib/`), `models/`, `install-macos.sh`

Both tarballs have the same internal layout (`bin/`, `lib/`, `models/`) so RPATH (`@loader_path/../lib` / `$ORIGIN/../lib`) works identically.

---

## CI

### GitHub Actions macOS Runners

**Free M1 runners (`macos-14`, `macos-15`) are available for public repos.** Specs: 3 vCPU, 7 GB RAM, Metal GPU support.

**Xcode is preinstalled** on the runner image (Xcode 16.4 on `macos-15`). No need to install via `mas` or download — `xcrun metal` works out of the box. This is NOT installed via the App Store; it's baked into the runner image by GitHub.

**Note:** Xcode 26+ dropped the Metal toolchain as a separate download. Runners currently have Xcode 16.x which includes Metal tools. If runner images upgrade to Xcode 26+, add `xcodebuild -downloadComponent MetalToolchain` (without sudo) to CI before the build step.

This is significant — we can:
1. Build Metal dylibs from source on CI (no LFS for macOS libs)
2. Run unit tests and property tests
3. Run regression tests (same WAV files, same model) to validate WER parity with Linux/CUDA
4. Create release assets automatically

### Workflow Structure

```yaml
jobs:
  linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive, lfs: true }
      - run: ./run.ts ci

  macos:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      # Xcode + xcrun metal preinstalled on runner — no setup needed
      - run: ./run.ts ci
```

`run.ts ci` auto-detects platform and runs the appropriate build + test + dist + release steps.

### macOS CI Build Steps

1. `ensureDeps()` — verify `xcrun metal` works (preinstalled), install cmake via brew if needed
2. `rebuild-libs` — CMake with `-DGGML_METAL=ON`, output to `dist/lib-macos/`
3. `build` — zig build linking against `dist/lib-macos/`
4. `test` — unit tests + property tests (no GPU needed)
5. `short-test` / `medium-test` — regression tests via `--stream-wav` (validates Metal transcription quality)
6. `dist` — create `capsper-macos-arm64.tar.gz`, validate with `otool`
7. Release upload (on tag)

---

## Homebrew Distribution

### Tap Repository

Create `github.com/OWNER/homebrew-capsper` with:

```
Formula/
└── capsper.rb
```

### Formula

```ruby
class Capsper < Formula
  desc "Push-to-talk voice dictation (Metal GPU, fully local)"
  homepage "https://github.com/OWNER/capsper"
  version "X.Y.Z"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/OWNER/capsper/releases/download/vX.Y.Z/capsper-macos-arm64.tar.gz"
      sha256 "..."
    end
  end

  def install
    libexec.install "bin/capsper"
    (libexec/"lib").install Dir["lib/*.dylib"]
    (libexec/"models").install Dir["models/*.bin"]

    # Wrapper script (DYLD_LIBRARY_PATH for dylib resolution)
    (bin/"capsper").write_env_script libexec/"bin/capsper",
      DYLD_LIBRARY_PATH: "#{libexec}/lib"
  end

  def caveats
    <<~EOS
      Capsper requires two permissions:

      1. Accessibility (for keyboard interception + text injection):
         System Settings → Privacy & Security → Accessibility → add capsper

      2. Microphone (prompted automatically on first run)

      To download the Whisper model (~574 MB), run:
         capsper --dry-run

      To set up as a background service:
         capsper --setup
    EOS
  end
end
```

### Installation Flow

```bash
brew tap OWNER/capsper
brew install capsper
capsper --dry-run          # downloads model, validates Metal GPU
capsper --trigger capslock  # run interactively
```

### Formula Update Automation

In `run.ts ci()`, after uploading release assets:
```typescript
if (process.env.GH_TOKEN && tag) {
    // Update homebrew-capsper formula with new version + sha256
    // Can use gh api or direct git commit to the tap repo
}
```

---

## macOS Installer (`install-macos.sh`)

For non-Homebrew installs (direct tarball download):

```bash
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/capsper"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_NAME="com.capsper.dictation.plist"

# Check brew is available (for future deps if needed)
command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh"; exit 1; }

# Copy files
mkdir -p "$INSTALL_DIR"/{bin,lib,models}
cp bin/capsper "$INSTALL_DIR/bin/"
cp lib/*.dylib "$INSTALL_DIR/lib/"
cp models/*.bin "$INSTALL_DIR/models/" 2>/dev/null || true

# Ad-hoc code sign with hardened runtime + mic entitlement
codesign --force --sign - --options runtime --entitlements capsper.entitlements "$INSTALL_DIR/bin/capsper"

# Download whisper model if not present
if [ ! -f "$INSTALL_DIR/models/ggml-large-v3-turbo-q5_0.bin" ]; then
    echo "Downloading Whisper model (~574 MB)..."
    curl -L -o "$INSTALL_DIR/models/ggml-large-v3-turbo-q5_0.bin" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
fi

# Install LaunchAgent
mkdir -p "$PLIST_DIR"
sed "s|INSTALL_DIR|$INSTALL_DIR|g" com.capsper.dictation.plist > "$PLIST_DIR/$PLIST_NAME"

# Accessibility permission check
echo ""
echo "=== Permissions Setup ==="
echo "Capsper needs Accessibility permission to intercept keyboard events."
echo "Go to: System Settings → Privacy & Security → Accessibility"
echo "Click '+' and add: $INSTALL_DIR/bin/capsper"
echo ""
echo "Microphone permission will be prompted on first run."
echo ""
echo "To start: launchctl load ~/Library/LaunchAgents/$PLIST_NAME"
echo "To stop:  launchctl unload ~/Library/LaunchAgents/$PLIST_NAME"
```

---

## Implementation Phases

### Phase 1: Validate Metal Transcription (Minimal — prove feasibility) ✅ COMPLETE

**Goal:** Prove whisper.cpp Metal backend produces correct transcriptions on M4.

Steps:
1. Install full Xcode on Mac
2. Update `bootstrap.sh` / mise to work on macOS (Zig + Bun)
3. Build whisper.cpp with Metal: `cmake -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DBUILD_SHARED_LIBS=ON`
4. Place dylibs in `dist/lib-macos/`
5. Create platform shim files (`audio_capture_platform.zig`, `input_platform.zig`, `audio_detect_platform.zig`)
6. Update `build.zig` for platform-conditional linking
7. Stub out macOS platform modules (enough to compile `--stream-wav` mode, which bypasses audio capture and input entirely)
8. Build capsper on macOS
9. Run `--stream-wav` with known test WAV files
10. Compare transcription output to Linux/CUDA baseline

**Success criteria:** `--stream-wav` produces identical (or near-identical) transcription to Linux. Unit tests pass.

**What this validates:** Metal GPU works, whisper.cpp C API is portable, pipeline/mel/alignatt/vad are truly platform-agnostic, build system works cross-platform.

**Results (2026-03-14):**
- Apple M4 detected: Metal GPU Family Apple9, unified memory, 11.4 GB
- JFK warmup: 1.7s (including first-run Metal shader compilation)
- `--stream-wav test/jfk.wav` streaming output matches Linux/CUDA: correct word-level deltas
- `build.zig` refactored with helper functions (`addWhisperIncludes`, `addTenVad`, `addPlatformDeps`, `addWhisperLibs`, `addLibPath`) — eliminates previous duplication across exe/test/vad targets
- Metal build also links `ggml-blas` (Accelerate/BLAS framework) — not present in Linux build
- RPATH: `@loader_path/../lib-macos` (dev), `@loader_path/../lib` (release tarball)
- Platform shims use `const impl = if (builtin.os.tag == .macos) ... else ...` pattern (not `usingnamespace` — that doesn't work with comptime `if` in Zig 0.15)

**Gotchas discovered:**
- Xcode 26+ requires separate `xcodebuild -downloadComponent MetalToolchain` — and it MUST run without sudo (per-user install, Apple bug)
- `mas install` (Mac App Store CLI) only works for apps previously installed via the App Store — first-time Xcode must go through the GUI
- Zig 0.15 `Module.linkSystemLibrary` takes an options struct; `Compile.linkSystemLibrary` takes just a string — helpers must take `*Compile`, not `*Module`

### Phase 2: Audio Capture (Medium — local mic works) ✅ COMPLETE (loopback), ⏳ Real mic pending

**Goal:** Capture audio from Mac microphone, feed to streaming pipeline.

Steps:
1. ~~Implement `ca_helpers.c` (AUHAL setup, device enumeration)~~ — Not needed, pure Zig `@cImport` works
2. ✅ Implement `audio_capture_macos.zig` (pipe-based handoff, same interface)
3. ⏳ Implement `audio_detect_macos.zig` (device wizard) — deferred
4. ✅ Update `server.zig` to use platform shim
5. ✅ Test: `--pw-target "BlackHole 2ch"` loopback transcription works
6. ⏳ Test: `--input local` with real mic — blocked on user interaction for mic permission

**Results (2026-03-14):**
- AUHAL captures at device native rate (48kHz), mono S16 — channel mixing + float→int works
- AUHAL CANNOT do sample rate conversion — silently returns zeros if you request a different rate
- AudioConverterFillComplexBuffer handles 48kHz→16kHz SRC with max quality anti-aliasing
- AudioConverterConvertBuffer does NOT support SRC (documented limitation)
- BlackHole loopback: 19 words, 3 VAD segments from JFK — matches Linux quality
- Automated test (`ca-stream.test.ts`) uses LaunchAgent for GUI session TCC context
- Device lookup by name (device IDs change on reboot)
- `test/macos-audio-helpers.c` provides CLI for device enumeration + output switching

**Gotchas discovered:**
- macOS TCC blocks microphone from SSH sessions — there is NO workaround via database manipulation (tried: system TCC with csreq blobs, all process identities, Full Disk Access grants, auth_reason variants, tccd restart). TCC validates by audit session, not just process identity.
- LaunchAgent (launchctl load) is the ONLY way to get GUI session TCC context from SSH
- Each new binary that accesses the mic needs its own TCC grant (user must click Allow on desktop)
- AVFoundation returns "undetermined" even when CoreAudio HAL delivers zeros — they use different check paths but both enforce TCC
- BlackHole device needs default output set before afplay to route audio through loopback

**Success criteria:** ✅ BlackHole loopback transcription passes automated test. ⏳ Real mic transcription needs user to grant permission interactively.

### Phase 3: Keyboard & Text Injection (Medium — full PTT flow) ✅ CODE COMPLETE, ⏳ needs Accessibility TCC grant

**Goal:** CapsLock push-to-talk with text injection into focused app.

Steps:
1. ✅ Implement `input_helpers_macos.c` (CGEventTap, CGEventPost, hidutil)
2. ✅ Implement `input_macos.zig` (InputHandler, parseTriggerKey)
3. ⏳ Test: `--trigger capslock` end-to-end PTT flow — needs Accessibility permission granted via System Settings

**Results (2026-03-15):**
- `hidutil` CapsLock → F19 remap works (verified — prevents LED toggle)
- CGEventTap creation works but requires Accessibility TCC permission
- CGEventPost text injection via `CGEventKeyboardSetUnicodeString` — handles all Unicode, batches 20 chars/event
- Dedicated thread runs CFRunLoop for the event tap
- Clean shutdown: restores CapsLock remap, stops tap, joins thread
- Error messages are platform-specific ("Accessibility permission" on macOS vs "input group" on Linux)

**What's needed to complete:**
- User grants Accessibility permission: System Settings → Privacy & Security → Accessibility → add capsper
- Or use `test/grant-tcc-mic.sh dist/bin/capsper kTCCServiceAccessibility` (requires SIP disabled)
- End-to-end PTT test: CapsLock → speak → release → text appears in focused app

### Phase 4: Build & CI (Full — automated) ✅ MOSTLY COMPLETE, ⏳ CI workflow pending

**Goal:** Fully automated build, test, and release pipeline.

Steps:
1. ✅ Update `run.ts` for macOS (deps, build, dist validation, platform-specific tarballs)
2. ✅ Update `bootstrap.sh` for macOS (brew deps, Xcode detection)
3. ⏳ Add `ci-macos` job to `.github/workflows/ci.yml`
4. ⏳ Run regression tests on macOS CI (validate WER parity)
5. ⏳ Create dual-platform release assets

**Results (2026-03-15):**
- `run.ts` fully platform-aware: auto-detects macOS, uses brew, builds without `-Dcpu=x86_64_v3`, runs `ca-stream.test.ts` instead of `pw-stream.test.ts`, `dist()` validates with `otool` and creates `capsper-macos-arm64.tar.gz`
- `./run.ts build` works end-to-end on macOS
- `./run.ts test` passes (unit + property tests, Linux input tests guarded with comptime check)
- `ensureMacOSLibs()` auto-builds Metal dylibs if `dist/lib-macos/` is empty
- `dist()` creates macOS tarball with `lib-macos/` renamed to `lib/` for consistent RPATH

**What's needed to complete:**
- Add `ci-macos` job to GitHub Actions workflow (use `macos-15` runner)
- CI needs: BlackHole install + `launchctl kickstart` coreaudiod (no reboot on CI)
- Cache the whisper model on CI (574 MB, fits in GitHub Actions 10 GB cache)
- Run regression tests via `--stream-wav` (doesn't need audio devices)
- Run `ca-stream.test.ts` BlackHole loopback test on CI

### Phase 5: Installation & Distribution (Full — user-facing) ⏳ NOT STARTED

**Goal:** Users can install via Homebrew or direct download.

Steps:
1. ⏳ Create `install-macos.sh` (LaunchAgent, permissions guidance, model download)
2. ⏳ Create Homebrew tap with formula
3. ⏳ LaunchAgent plist for background service
4. ⏳ Permission setup guidance (Accessibility + Microphone)
5. ⏳ Auto-update mechanism (formula update + version check)

**Success criteria:** `brew install OWNER/capsper/capsper` works end-to-end.

---

## Deferred Items

Items explicitly deferred during implementation, to be addressed later:

1. **Device detection wizard (`audio_detect_macos.zig`)** — the interactive `--pw-detect` equivalent for macOS. Needs CoreAudio device enumeration, multi-channel RMS analysis, gain calibration. Deferred because default mic + auto-gain is sufficient for initial use.

2. **Channel selection** — `--audio-channel` / `--pw-channel` on macOS. Currently hardcoded to mono channel 0. Deferred because most Mac mics are mono.

3. **Real microphone testing** — EarPods mic was very quiet in testing (2-3 blips in system settings). Needs investigation: may be a channel issue (2-channel device, mic might be on channel 1), or just a quiet mic that needs auto-gain to ramp up. Blocked on user granting mic permission interactively from desktop.

4. **Device hotplug** — `AudioObjectAddPropertyListener` for detecting mic connect/disconnect. Not needed for initial use.

5. **TEN-VAD native backend** — `--vad ten-native` uses Linux-only `libten_vad.so`. Not available on macOS. Should print error if selected. (Currently handled in `main.zig` via comptime check possibility, but not yet implemented.)

---

## Resolved Questions

1. **Sample rate conversion:** ✅ RESOLVED — AUHAL cannot do SRC. Confirmed with controlled test: format set + init succeed but AudioUnitRender returns errors (379/379 callbacks failed). `AudioConverterFillComplexBuffer` with max quality is the correct solution. `AudioConverterConvertBuffer` also cannot do SRC (documented limitation).

2. **TEN-VAD FFT on macOS:** ✅ RESOLVED — `ten-vad/src/fftw.c` compiles and works on macOS. All 46 property tests pass including TEN-VAD related tests.

3. **TCC permissions from SSH:** ✅ RESOLVED — macOS TCC validates by audit session, not process identity. Database manipulation alone does not work. Solution: LaunchAgent for GUI session context + `test/grant-tcc-mic.sh` for programmatic TCC grants with cdhash-based csreq. Requires SIP disabled for the grant script.

## Open Questions

1. **macOS CI regression test model:** The 574 MB whisper model would need to be cached on CI. GitHub Actions cache has a 10 GB limit — check if this is practical, or if we need a smaller model for CI-only regression tests.

2. **Homebrew formula auto-update:** Best mechanism for automatically updating the tap formula when a new release is tagged. Options: GitHub Action in the tap repo triggered by release webhook, or `run.ts ci` pushes directly.

3. **CI BlackHole installation:** BlackHole normally requires reboot, but `sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod` should suffice on CI. Needs testing on a macOS runner.

4. **CI TCC grants:** GitHub Actions macOS runners may have different TCC restrictions. Need to verify if `test/grant-tcc-mic.sh` works on CI, or if runners already have mic/accessibility permissions.

---

## References

### Keyboard / Input
- [Apple TN2450: Remapping Keys (hidutil)](https://developer.apple.com/library/archive/technotes/tn2450/_index.html)
- [Apple QA1519: Detecting the Caps Lock Key](https://developer.apple.com/library/archive/qa/qa1519/_index.html)
- [CGEventTapCreate documentation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate)
- [Karabiner-Elements source (reference architecture)](https://github.com/pqrs-org/Karabiner-Elements)

### Audio
- [Apple TN2091: Device Input using AUHAL](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)
- [Core Audio Overview](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/WhatisCoreAudio/WhatisCoreAudio.html)
- [It's Over, AVAudioEngine (bug documentation)](https://supermegaultragroovy.com/2021/01/26/it-s-over-avaudioengine/)

### Transcription
- [whisper.cpp repository](https://github.com/ggml-org/whisper.cpp)
- [whisper.cpp release benchmarks (Metal)](https://github.com/ggml-org/whisper.cpp/releases)

### Distribution
- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Creating a Homebrew Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Hardened Runtime documentation](https://developer.apple.com/documentation/security/hardened-runtime)
