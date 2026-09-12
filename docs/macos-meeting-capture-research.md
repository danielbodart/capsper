# macOS Meeting Capture: Far-End Audio Research

Research companion to `meeting-capture-plan.md`. That plan is written entirely for
Linux/PipeWire: a virtual sink built from `libpipewire-module-loopback`, armed by
watching node-connection state in `pw-dump`, passed through to the default output,
and captured from its monitor. **None of that machinery exists on macOS.** This
document works out the macOS equivalent of the one piece the plan calls the
"clincher": getting the far end -- what the other people on the call are saying --
into a capture stream, while the call stays audible through the speakers.

The near end is not in question. Capsper already captures the microphone on macOS
via AUHAL (`src/platform/macos/audio.zig`); that code is the near-end track
unchanged. Everything below is about the far end only.

## The ask, and the short answer

The request was: *can we create a virtual audio output device on macOS, set it as
the meeting app's speaker, capture the far side from it, and route that through to
the real default output -- private APIs acceptable if reverse-engineered and used
by other open-source tools.*

The answer has two layers:

1. **Yes, a virtual output device is possible, and it needs no private API.**
   Apple's `AudioServerPlugIn` is a public, documented API for exactly this, and
   BlackHole (MIT, signed and notarised, years in production) is the open-source
   reference implementation. So the private-API question doesn't even arise for
   this route.

2. **But you probably shouldn't use a virtual device at all.** Since macOS 14.2,
   Core Audio has a public **process-tap** API that captures a chosen
   application's output directly, with the audio still playing through the
   speakers, and **no driver to install**. It gets us the same far-end stream with
   less moving machinery, and the pass-through the request asks for ("route through
   to the default output") comes for free because the audio was never diverted in
   the first place.

The rest of this document is why, and what each route costs.

## Why the Linux design doesn't port

The Linux plan leans on three PipeWire properties that macOS has no equivalent of:

- **A user-creatable virtual sink** (`module-loopback`) that shows up in the output
  picker and that capsper owns from inside its own process. On macOS you cannot
  conjure an output device from inside your own process. A virtual device is a
  *system* component -- an `AudioServerPlugIn` bundle installed in
  `/Library/Audio/Plug-Ins/HAL/`, loaded into the `coreaudiod` daemon, needing
  admin rights to install. It is not something a running capsper spins up on
  demand.

- **The monitor of a sink** as a first-class capture source. PipeWire gives every
  sink a monitor for free. CoreAudio has no monitor concept; a virtual device
  loops its output back to its own input only because its plug-in code is written
  to, which is exactly what BlackHole does.

- **Gate 1: node-connection state** (`Stream/Output/Audio` linked and `running`)
  read from `pw-dump` as the arm/disarm signal. There is no `pw-dump` on macOS and
  no per-node graph to inspect the same way. The macOS arm/disarm signal has to
  come from somewhere else (see "Arm/disarm on macOS" below).

Everything else in the plan -- WebVTT, near/far naming, the stereo file, the
player, the config, the phasing -- is platform-agnostic and stands. It is only the
audio-plumbing layer, Phase 1 and the Gate 1 half of Phase 2, that needs a
separate macOS design.

## Option A -- Core Audio process tap (recommended)

The modern path, introduced in **macOS 14.2** (the aggregate-device reader shape
that every sample uses settled in **14.4**, so treat 14.4 as the practical floor).
It captures the output of a specific process without routing that audio anywhere
different -- the call keeps coming out of the speakers, and capsper reads a copy.

**It is a public C API** in `<CoreAudio/AudioHardware.h>` and
`<CoreAudio/CATapDescription.h>`, callable straight from Objective-C or C. That
matters here: capsper's macOS platform layer is C/Objective-C bridged to Zig
(`audio.zig` + `mic_permission.m` + `input_helpers.c`), with no Swift anywhere.
The tap API fits that model directly -- it would live in a new helper next to
`audio.zig`, the same way AUHAL capture does today.

The shape of it (from Apple's headers and the `insidegui/AudioCap` sample):

1. Resolve the target process to an `AudioObjectID`:
   `kAudioHardwarePropertyTranslatePIDToProcessObject`.
2. Build a `CATapDescription` naming that process (or a set of them), with a
   mixdown choice (mono or stereo) and a mute behaviour.
3. `AudioHardwareCreateProcessTap(desc, &tapID)`.
4. `AudioHardwareCreateAggregateDevice(...)` with the tap's UUID embedded in the
   aggregate's `TapList`, which makes the tapped audio appear as an ordinary input
   stream.
5. Read it with a standard I/O callback -- the same pattern `onCapture` in
   `audio.zig` already implements for AUHAL, feeding the same S16/16kHz converter
   and the same pipe.

**The call stays audible.** `CATapDescription`'s mute behaviour defaults to
unmuted -- the process's audio plays normally and the tap gets a copy. (The other
modes, muted and muted-only-when-tapped, exist but are not what we want.) So the
request's "route through to the default output" requirement is satisfied by doing
nothing: the audio was never diverted, so there is nothing to route back.

**Permissions.** TCC-gated behind a system prompt. Needs
`NSAudioCaptureUsageDescription` in the bundle's `Info.plist` (note: this is a
*different* key from the microphone's `NSMicrophoneUsageDescription`, and it does
not appear in Xcode's dropdown -- it has to be added by hand). The binary must be
signed for the prompt to fire; capsper is already signed via `fulcio-codesign`
with an entitlements plist and a TCC-grant flow (`scripts/grant-tcc.sh`,
`run.ts`), so this slots into an existing mechanism rather than inventing one.

### Costs and gotchas

- **Browser meetings are the hard case.** Chrome and friends play call audio from
  a *renderer/helper* process, not the main browser process, so tapping "Google
  Chrome" by its obvious PID can tap the wrong process and get silence. Options:
  tap the helper (needs identifying it), or tap the whole system mix and accept
  what the Linux plan explicitly rejected -- Spotify, notifications, everything.
  Native meeting apps (Zoom, Teams, Slack huddles) play from their own process and
  are clean. **This is the single biggest thing to verify before committing to the
  tap route.**
- **Signature strength for TCC.** The tap prompt requires a signed binary; whether
  the current `fulcio-codesign` ad-hoc-style signature is enough to make the
  *audio-capture* TCC prompt fire (as opposed to the AVFoundation mic prompt,
  which is known to work under it) needs a live check on a 14.4+ machine.
- **Three documented semantic traps** (per the DGR Labs 2026 write-up): the
  exclusive-flag direction on the tap, the exact aggregate-device shape, and the
  fact that the tap's aggregate device does not play nicely with `AVAudioEngine`.
  Capsper reads raw CoreAudio I/O callbacks, not `AVAudioEngine`, so the third
  trap doesn't apply to us -- but the first two do.
- **Far-end only.** A process tap captures application *output*, never the
  microphone. That is correct for us -- the mic is the near end and AUHAL already
  has it -- but it means the two tracks come from two different CoreAudio
  mechanisms, not one.

## Option B -- virtual audio device (`AudioServerPlugIn` / BlackHole)

This is the literal thing the request described, and the closest analogue to the
Linux design: a device the user selects as the meeting app's speaker, where the
selection *is* the declaration of intent (exactly the plan's argument for a
dedicated sink over a system-output monitor).

- **Public API, no reverse engineering.** `AudioServerPlugIn` is documented; Apple
  ships sample drivers. BlackHole (MIT) is a complete, production open-source
  implementation we could learn from or, licence permitting, adapt. Soundflower is
  the dead predecessor -- it used a kernel extension, which is why it broke;
  BlackHole uses the userspace plug-in API and does not.
- **It is a system install, not a runtime feature.** A `.driver` bundle goes in
  `/Library/Audio/Plug-Ins/HAL/` and is loaded by `coreaudiod`. That means an
  installer step with admin rights, a component that persists on the system
  outside capsper's own lifecycle, and a device that lingers in the user's output
  menu whether or not capsper is running. This is a substantially bigger footprint
  than "a service option" and cuts against capsper's self-contained-binary
  proposition.
- **Pass-through is extra work.** A loopback device swallows the audio -- select it
  as the speaker and the call goes silent unless you also send it onward. On macOS
  that means the user builds a Multi-Output Device (BlackHole + real speakers) in
  Audio MIDI Setup, or capsper creates an aggregate/multi-output programmatically
  and manages it. Either way the "route through to the default output" half is a
  second mechanism to build and maintain, whereas Option A gets it for free.
- **The upside it has over Option A:** device-selection as intent is
  unambiguous and browser-process-agnostic -- it does not care whether Chrome
  plays from a helper process, because the user pointed the *app* at the device.
  If the browser-helper problem in Option A turns out to be intractable, this is
  the fallback that dodges it.

## Option C -- ScreenCaptureKit

`SCStream` with `capturesAudio` can pull the system audio mix (audio support since
macOS 13.0). Rejected for this use:

- **Wrong shape.** It is screen-recording infrastructure: it wants the Screen
  Recording permission and lights up the menu-bar recording indicator, for an
  audio-only feature. That is a confusing permission story and a persistent UI
  artefact for something that never touches the screen.
- **System mix, not intent-scoped.** Per-application filtering exists via
  `SCContentFilter`, but the natural mode is the whole system mix -- the same
  "catches everything" problem the Linux plan rejected for the default-output
  monitor.
- **Swift-oriented.** The API is Objective-C-callable but is designed and
  documented around Swift, against a codebase that is deliberately Swift-free.

Worth knowing exists; not the tool for this.

## Arm/disarm on macOS (the Gate 1 equivalent)

The Linux plan's Gate 1 reads node-connection state from the graph. macOS has no
equivalent single signal, and the answer differs by option:

- **Option B (virtual device):** closest to Linux. A client playing into the
  device produces a running I/O on it; capsper can watch the device's own
  running/idle state as the arm/disarm signal, debounced the same way the plan
  describes (~30 s, to survive a mute or a screen-share renegotiation).
- **Option A (process tap):** the signal is per-process. A process
  `AudioObjectID` exposes whether it is currently running output
  (`kAudioProcessPropertyIsRunning` / `...IsRunningOutput`), which is the arm
  signal -- the tapped app started playing. The same debounce applies.

Either way, Gate 2 (VAD) and "cue boundaries need no model" from the plan are
unchanged -- they operate on the PCM after capture and don't care how it was
captured.

## Recommendation

**Build Option A (process tap) as the macOS Phase 1, and keep Option B
(AudioServerPlugIn/BlackHole-style device) in reserve as the fallback for the
browser-helper case.**

Reasoning, in order of weight:

1. **No install, no persistent system component.** A process tap is a runtime
   capability of the signed capsper binary. It keeps the self-contained-binary
   story that a HAL driver bundle would break.
2. **Pass-through is free.** The call stays on the speakers by default; the
   request's routing requirement needs no code.
3. **It's a C API against a C/Objective-C layer.** It fits `audio.zig`'s existing
   AUHAL/converter/pipe pattern with no new language in the build.
4. **No private API and no admin step**, which is a strictly smaller ask than the
   request was prepared to accept.

The one real risk is the browser-helper-process problem. That is why B stays on
the shelf: if far-end capture from browser-based Meet/Teams-in-a-tab can't be made
reliable through a process tap, the user-selected virtual device sidesteps it
entirely, at the cost of an installer and a manual pass-through.

## Verify before building

1. **Browser far-end capture via a process tap.** On a 14.4+ machine, tap a Google
   Meet call in Chrome and confirm the far end is captured -- and work out which
   process (main vs. renderer/helper) actually carries it. This decides A vs. B.
2. **TCC prompt under the current signature.** Confirm the audio-capture prompt
   (`NSAudioCaptureUsageDescription`) actually fires for a `fulcio-codesign`-signed
   capsper, not only the AVFoundation mic prompt.
3. **macOS floor.** Confirm 14.4 as the minimum for the tap route and decide
   whether that floor is acceptable, or whether B is needed to reach older systems.
4. **Two-track timing.** The near end (AUHAL) and far end (tap) come from two
   independent CoreAudio clocks. Confirm they stay aligned well enough for the
   single interleaved stereo file the plan specifies, or that the arrival-side
   position counting the plan already mandates absorbs the skew.

## Sources

- [BlackHole (ExistentialAudio) -- open-source AudioServerPlugIn virtual device](https://github.com/ExistentialAudio/BlackHole)
- [insidegui/AudioCap -- sample: recording system/process audio on macOS 14.4+](https://github.com/insidegui/AudioCap)
- [Recall.ai -- Core Audio Taps deep dive](https://www.recall.ai/blog/core-audio-taps)
- [DGR Labs -- Capturing System Audio on macOS in 2026](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)
- [Ask Canary -- CoreAudio tap: capturing system audio without a virtual device](https://askcanary.com/glossary/coreaudio-tap/)
