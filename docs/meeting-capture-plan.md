# Meeting Capture Plan

Add a second capture mode to capsper: continuous, unattended, two audio sources,
one WebVTT transcript. Push-to-talk dictation stays exactly as it is; this is a
third mode beside local PTT and the TCP server, built from the same primitives.

## Goal

Turn on a service option, get a virtual output device. Point a meeting app at it.
Capsper transcribes both sides of the conversation and writes a single timed
transcript with the speakers separated, plus the audio it heard.

## Scope

In scope:

- A virtual PipeWire sink, created and owned by capsper, that appears in the
  desktop's output picker.
- Pass-through of that sink to the current default output, so the call is still
  audible.
- Two capture tracks: the monitor of that sink (the far end), and the default
  input (the host).
- Two gates per track: node connection, then VAD.
- Both tracks through the existing pipeline, one connection each.
- One WebVTT file per session, both tracks interleaved, speakers as voice spans.
- Per-track audio, compressed.
- Dated session directories.

Explicitly out of scope, and not to be added later without a separate decision:
calendar integration, meeting detection heuristics, uploading anywhere,
summarisation, speaker identification beyond the two tracks, any network access
at all. Capsper's whole proposition is that nothing leaves the machine.

## Why a sink and not a microphone

The far end has to be captured from somewhere. The alternatives are worse:

- **Monitor of the default output** -- catches Spotify, notifications, everything.
- **Hardware loopback** (e.g. the Vocaster's Loopback 1/2) -- only works while the
  call is routed through that interface, so it breaks the moment the user switches
  to a USB headset.
- **A dedicated sink** -- the user selects it in the meeting app. That selection
  *is* the declaration of intent. Nothing else is in it.

The dedicated sink also gives us the arm/disarm signal for free, which is the
subject of gate 1.

## Gate 1: node connection

An application playing into the sink creates a `Stream/Output/Audio` node linked
to it. That node exists only while the application holds the sink, and its state
distinguishes playing from paused.

Measured on dan-desktop (`pw-dump`, idle machine, Spotify paused, a Chrome tab
playing):

| node | class | state |
| --- | --- | --- |
| `vocaster_videocall_out` | Audio/Sink | suspended |
| `vocaster_hostmic` | Audio/Source | suspended |
| `alsa_output.pci-0000_00_1f.3.iec958-stereo` | Audio/Sink | running |
| `spotify` | Stream/Output/Audio | idle |
| `Google Chrome` | Stream/Output/Audio | running |

Two things to take from that. First, virtual nodes built from
`libpipewire-module-loopback` with `node.passive` on the device end sit in
`suspended` when nothing is using them -- they are not permanently active, so the
graph is a real signal and not a constant. Second, the discriminator we need is
already visible: a paused client keeps its stream node but drops to `idle`, while
a playing one is `running`.

So:

- **Arm** when a `Stream/Output/Audio` is linked to the capsper sink in state
  `running`.
- **Disarm** when the last such stream leaves, or stays `idle`, for a debounce
  window. Something in the region of 30 seconds, so a screen-share renegotiation
  or a brief mute does not split a meeting into two sessions.

This is the same class of signal the Notion desktop app uses on macOS (it watches
for a process holding the microphone), except PipeWire gives it to us per node
rather than per process, so we can ignore our own capture streams.

**To verify before building:** whether Chrome tears its output stream down
promptly when a call ends, or leaves an `idle` stream parked on the sink
indefinitely. The debounce handles the second case; the measurement decides its
length.

## Gate 2: VAD

Capsper dropped Silero/TEN-VAD when Nemotron replaced whisper.cpp, because
push-to-talk became the sole gate. Unattended capture removes that gate, so it
comes back -- but for a different reason than last time, and it is worth writing
down which reason, because it changes what "good enough" means.

**Not for hallucination.** Measured: 60s of digital silence and 60s of pink room
tone at roughly -50 dBFS, both through `--transcribe`, both produced zero
characters. Nemotron does not hallucinate into silence the way whisper did. The
`silence-hallucination` fixture is a whisper-era artefact; its reference text is
simply what was being said while recording a file with long gaps in it.

**For cost.** Measured on dan-desktop (i9-12900K, CPU build):

| input | audio | CPU | CPU per audio-second |
| --- | --- | --- | --- |
| digital silence | 60 s | 68.4 s | 1.14 |
| pink room tone | 60 s | 68.4 s | 1.14 |
| speech (`long-recording.wav`) | 102 s | 108.7 s | 1.07 |

Silence costs the same as speech, fractionally more. The encoder runs on every
chunk regardless and the decoder emits blank. The far-end track is quiet for most
of an hour whenever the host is the one talking, so that is close to a full core
spent producing nothing.

On the desktop that is two cores out of twenty-four, which is tolerable but
pointless. On dan-blade it is a CPU-only build holding two cores continuously on
battery for the length of a meeting, which is not.

Concurrency is already linear, so the cost is per-track and additive. Measured,
same machine, `long-recording.wav` fast-forwarded over TCP:

| clients | wall | CPU | cores per real-time stream |
| --- | --- | --- | --- |
| 1 | 32.1 s | 96.0 s | 0.94 |
| 2 | 33.3 s | 201.1 s | 0.99 |

### The timestamp trap

`formatAudioTime` derives position from total audio bytes received at 32000
bytes/sec. That is correct *only* because everything received is currently fed
through. Once VAD elides silence before the encoder, bytes-received and
bytes-encoded diverge, and every cue after the first pause drifts by the total
silence skipped.

Position must be counted **on arrival, ahead of the gate**, and carried alongside
the audio into the pipeline. This is easy to get wrong and nearly impossible to
notice until a transcript is an hour long and the end is minutes out.

### Model choice

ONNX Runtime is already loaded on Linux, so a Silero-class VAD is close to free
there. macOS runs the CoreML backend, so it means either pulling ORT in beside
CoreML or converting the VAD as well -- `coreml-conversion-plan.md` is the map for
the second option. This is the real cost of the decision, not the model size.

## Cue boundaries need no model

Separate from gate 2, and worth not conflating with it. Since Nemotron emits
nothing during silence (measured above), a run of consecutive non-emitting chunks
*is* a pause, and that closes a cue. No VAD required for this, even if VAD is
present for cost reasons.

The one ambiguity is that a chunk can also emit nothing while the decoder holds
tokens mid-word. `ort/pipeline.zig` already distinguishes those: it tracks an EMA
of the level over emitting chunks and judges each new chunk relative to it, with
`SPEECH_RMS_FRACTION = 0.5` calibrated against the regression corpus, and the
comment notes the relative measure makes it gain- and mic-independent. Quiet and
non-emitting closes a cue; loud and non-emitting is the existing stall case.

Both signals sit next to `emitted_before` in `processChunk` today. Cue closing is
bookkeeping on values we already compute.

## Transcript format: WebVTT

SRT was the first instinct and it is the right instinct -- use prior art -- but SRT
has no speaker field, so every tool that needs one invents a text prefix
convention. That is inventing a format while pretending not to.

WebVTT has voice spans in the spec:

```
WEBVTT

1
00:00:04.120 --> 00:00:07.880
<v Host>so the thing I wanted to raise was the routing

2
00:00:08.020 --> 00:00:11.400
<v Far>yeah, I looked at that yesterday
```

Which buys:

- **Speaker attribution as ground truth, not inference.** Two tracks means host
  versus far end is known, not guessed. Better than what the commercial tools
  produce by diarisation.
- **One file, not two.** Cues from both tracks merge by audio position, which both
  connections share because they start together. The merge is a sort.
- **Overlap is legal.** The spec permits overlapping cues, requiring only that
  start times are non-decreasing. Crosstalk is representable rather than something
  we have to resolve.
- **It plays.** Any player will show the transcript against the audio, which makes
  checking a transcript against what was actually said a drag-and-drop rather than
  a tooling problem.
- Converting to SRT is a timestamp separator substitution, if anything downstream
  only eats SRT.

Payload constraints to respect when writing: a cue payload may not contain the
substring `-->`, and a blank line terminates a cue. Cue identifiers must be unique
and carry the same `-->` restriction.

## Replacing the debug recorder

`recorder.zig` currently writes `NNN.wav` plus `NNN.log` per utterance, with the
log holding a header, the emitted text, and a cycle log. Every line in it is
already stamped with an audio position by the same `formatAudioTime`. So the two
outputs are the same artefact at different verbosity, and they should collapse.

Mapping:

| today | becomes |
| --- | --- |
| `=== Capsper Recording NNN (vX) ===` header | `NOTE` block after the `WEBVTT` line |
| `Duration: N.Ns (N bytes)` | same header NOTE |
| `--- Emitted Text ---` | the cues themselves |
| `[t] cycle=N state buf=Nms words=N \| "..."` | `NOTE` block before the cue it produced |
| `  -> emit: "..."` | the cue payload |
| `NNN.wav` | per-track compressed audio beside the `.vtt` |

**On JSON.** Metadata cues carrying JSON are an established convention for
`kind="metadata"` tracks, and the payload rules allow it -- one line, no `-->`.
But a file used as captions renders its cue payloads, so JSON as *cue* payloads
would show up as subtitles in any player, which throws away the "it just plays"
property above.

`NOTE` blocks are the way to have both. They are free text, invisible to every
renderer, and carry the same `-->` and blank-line restrictions, so single-line
JSON sits in them happily:

```
NOTE {"cycle":42,"state":"streaming","buf_ms":1680,"words":7,"rms_ema":0.031}

3
00:00:11.600 --> 00:00:14.050
<v Host>right, that makes sense
```

So the difference between a normal transcript and a debug one is exactly one
thing: whether the `NOTE` blocks are written. Same writer, same file layout, one
flag.

**Open question.** The debug recorder is a ring buffer keyed on `seq % keep`,
which is right for "keep the last ten utterances while I chase a bug" and wrong
for meeting sessions, which should never be silently overwritten. Proposal: keep
the ring for the PTT debug path, use dated directories for meeting sessions, and
let the detail flag be orthogonal to both.

## Audio files

Two tracks, kept separately -- they are the thing that makes the speaker
attribution verifiable, and merging them at the audio level would destroy it. The
transcript is where the two sides come together, not the audio.

WAV at 32000 bytes/sec is 115 MB per hour per track, so 230 MB for a meeting.
Opus at 24 kbps mono is roughly 11 MB per track per hour, which is the difference
between thinking about disk and not. Opus is also the right codec for the content
by design, and libopus is a small C dependency of the kind the tree already
carries.

Decision needed: Opus for everything, or keep WAV for the PTT debug path where the
files are seconds long, lossless matters for regression comparisons, and the ring
buffer bounds the size anyway. Leaning towards the second.

## Directory layout

Sessions are user data, so `$XDG_DATA_HOME/capsper/sessions/` by default, with
`--meeting-dir` to override.

```
sessions/2026/09/11/143000-a1b2/
  transcript.vtt
  host.opus
  far.opus
```

Date-nested directories rather than a flat directory of ISO-named files: a year of
meetings is a lot of entries, and `YYYY/MM/DD` is the layout every photo and log
tool converged on. The time-plus-short-id leaf keeps two meetings starting in the
same minute apart without needing a lock.

## Flags

Sketch, to be settled during phase 1:

```
--meeting-dir DIR       Enable meeting capture, write sessions under DIR
--meeting-sink NAME     Name of the virtual sink (default: capsper_call)
--transcript-detail     minimal | debug  (debug adds NOTE blocks)
```

The host track uses the existing source selection. Note that
`platform/linux/audio.zig` already omits `PW_KEY_TARGET_OBJECT` when no target is
given and logs "PipeWire capture ready (default source)", and `want_local` is
satisfied by `--trigger` alone -- so following the desktop's default input picker
already works today, it has simply never been used.

The catch is that `--audio-channel` and `--audio-gain` are per-device
measurements. Following the default onto a different mic would apply the previous
device's gain to it. `AutoGain` is the way out: it starts at unity, climbs, and
never attenuates below unity, so it is safe in the direction that matters.
Following the default means dropping the static gain, not just the target.

## Phases

**Phase 1 -- the sink and the graph.** Create the virtual sink, pass it through to
the default output, expose its monitor as a capture source. No transcription.
Success: select it in Google Meet, still hear the call, see the monitor carrying
audio in `pw-dump`. Settle the flag names here.

**Phase 2 -- gate 1 and two-track capture.** Arm and disarm on stream link and
state with the debounce. Write two audio files per session into the dated layout.
Measure how Chrome actually behaves on call end and set the debounce from that.
Still no transcription.

**Phase 3 -- transcription and WebVTT.** Two connections into the existing
pipeline, cue closing from the emit and RMS signals, merge by audio position,
voice spans, one file. Move `recorder.zig` onto the same writer and reduce the
debug log to `NOTE` blocks.

**Phase 4 -- VAD.** Gate ahead of the encoder. Do the arrival-side position
counting *first*, with a test that feeds a file with long silences and asserts the
final cue timestamp matches the file duration. Then measure the saving against the
table above and decide whether macOS gets it.

**Phase 5 -- Opus.** Compress the session tracks. Decide the PTT debug path
separately.

Phases 1 through 3 are a complete, useful tool on their own. Phase 4 is an
optimisation with a sharp edge, and phase 5 is convenience.
