# Windows Port Plan

Add Windows as a third platform for capsper. CapsLock push-to-talk, mic capture,
transcription via ORT+DirectML, and text injection into any focused app.

## Research Summary

### Keyboard Interception: `SetWindowsHookEx(WH_KEYBOARD_LL)`

Global low-level keyboard hook. Intercepts keystrokes system-wide regardless of
which window has focus. Capsper runs as a background process (no visible window
needed) and intercepts CapsLock in any app -- same model as Linux evdev grab and
macOS CGEventTap.

- Suppress CapsLock: return non-zero from hook callback (prevents toggle + eats keypress)
- Press/release: `KBDLLHOOKSTRUCT.flags & LLKHF_UP` distinguishes down/up
- Injected events: check `LLKHF_INJECTED` flag to pass through our own SendInput output
- No admin required for standard user windows
- No kernel driver needed

**Constraint:** requires a Win32 message pump (`GetMessage` loop) on the hook
thread. Callback must return within ~300ms or Windows auto-unhooks. Do no work in
the callback -- signal the server thread and return.

**UIPI limitation:** non-elevated capsper cannot intercept keys in elevated (admin)
windows. Acceptable for dictation -- matches how AutoHotkey/espanso handle this.
Document "run as admin" as optional for users who need it.

### Text Injection: `SendInput` + `KEYEVENTF_UNICODE`

Injects text as synthetic keyboard input into whatever window has focus.

- Set `dwFlags = KEYEVENTF_UNICODE`, put UTF-16 code unit in `wScan`, set `wVk = 0`
- Send keydown + keyup pair per character
- Handles arbitrary Unicode natively: accented chars, CJK, emoji (as surrogate pairs)
- Works regardless of physical keyboard layout
- Same UIPI limitation as hooks (can't inject into elevated windows from non-elevated process)

### Audio Capture: WASAPI

Windows Audio Session API -- the standard modern audio capture API.

- Microphone capture in shared or exclusive mode
- Supports 16kHz mono S16_LE PCM (our format) or resample from device native format
- Low latency (~10ms buffer periods available)
- Device enumeration via `IMMDeviceEnumerator`
- Equivalent to PipeWire on Linux and CoreAudio on macOS

### Inference: ORT + DirectML (~30-50 MB)

- DirectML ships with Windows 10 1903+ / Windows 11
- Works on AMD + NVIDIA + Intel GPUs -- single binary covers all vendors
- Same ONNX models, same ORT C API already in capsper
- Add `OrtSessionOptionsAppendExecutionProvider_DML()` alongside existing EP setup
- CPU fallback: ORT CPU EP (already implemented)

### Distribution

- Code-sign the binary (keyboard hooks trigger AV heuristics on unsigned binaries)
- No installer needed -- same tarball model as Linux/macOS
- Service: Task Scheduler with "Run only when user is logged on" (not a Windows Service,
  which runs in Session 0 with no desktop and no hook support)
- Or: startup shortcut / tray app

## Platform Comparison

| | Linux | macOS | Windows |
|---|---|---|---|
| Key intercept | evdev grab | CGEventTap | `WH_KEYBOARD_LL` |
| Key suppress | uinput passthrough | Return NULL from tap | Return non-zero from callback |
| Text inject | uinput events | CGEventPost | `SendInput` + `KEYEVENTF_UNICODE` |
| Unicode | Custom keymap | CGEventKeyboardSetUnicodeString | Native UTF-16 |
| Audio capture | PipeWire | CoreAudio AUHAL | WASAPI |
| Permissions | `input` group + udev | Accessibility + Mic TCC | None (standard user) |
| Service | systemd user unit | LaunchAgent | Task Scheduler |
| Inference | ORT CUDA/CPU | CoreML (ANE) | ORT DirectML |

## Implementation Plan

### Phase 1: Platform Plumbing

New files following the existing comptime switch pattern:

```
src/platform/windows/
  input.zig      -- WH_KEYBOARD_LL hook + SendInput text injection
  audio.zig      -- WASAPI mic capture
  detect.zig     -- WASAPI device enumeration
```

Update comptime switches in:
- `src/platform/input.zig`
- `src/platform/audio.zig`
- `src/platform/detect.zig`

**input.zig details:**
- Spawn dedicated thread with Win32 message loop
- Install `WH_KEYBOARD_LL` hook, filter `VK_CAPITAL` (0x14)
- On CapsLock down/up: signal server thread via existing trigger mechanism
- Check `LLKHF_INJECTED` to ignore our own SendInput output
- Text injection: `SendInput` with `KEYEVENTF_UNICODE`, UTF-16 encode, surrogate pairs for emoji

**audio.zig details:**
- `IMMDeviceEnumerator` → `IMMDevice` → `IAudioClient` → `IAudioCaptureClient`
- Request 16kHz mono S16_LE if supported, or capture at device native format and resample
- Feed PCM into existing server loop via same interface as PipeWire/CoreAudio

### Phase 2: Build System

- Add Windows target to `build.zig` (new backend option or auto-detect)
- Link Win32 libs: `user32`, `ole32`, `avrt` (WASAPI real-time), `kernel32`
- Add Windows build to `run.ts`
- ORT + DirectML: bundle `onnxruntime.dll` + `DirectML.dll` in `dist/lib/`

### Phase 3: Packaging & CI

- GitHub Actions Windows runner
- Code-signing (if we get a certificate)
- Task Scheduler XML template or startup shortcut for `install.sh` equivalent
- Release artifact: `capsper-windows-x86_64.zip`

