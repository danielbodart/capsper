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
  input (the near end).
- Two gates per track: node connection, then VAD.
- Both tracks through the existing pipeline, one connection each.
- One WebVTT file per session, both tracks interleaved, speakers as voice spans.
- One stereo audio file per session, near left and far right, format selectable.
- A generated `index.html` that plays the two together.
- Dated session directories.
- A config file, since this is where the option count stops fitting on a command
  line. Existing flags keep working unchanged.

Explicitly out of scope, and not to be added later without a separate decision:
calendar integration, meeting detection heuristics, uploading anywhere,
summarisation, speaker identification beyond the two tracks, any network access
at all, and an HTTP server for the generated page. Capsper's whole proposition is
that nothing leaves the machine.

## Naming: near end and far end

The two sides are **near** and **far** throughout -- in the file names, in the
voice spans, in the prose. Not host/guest, not local/remote, and not a mixture,
which is what the first draft of this document was.

Near-end and far-end are the standard vocabulary of echo cancellation and VoIP,
which is exactly this signal topology: the near end is the microphone, the far end
is what arrives from the call and comes out of the speaker. For an audio tool that
is the right audience to be legible to.

The other two candidates are already spoken for:

- **local/remote** -- `local` means local audio capture as opposed to the TCP
  transport throughout `server.zig` and `main.zig`, in comments, log lines and the
  usage text. Reusing it for a speaker would give one word two meanings in one
  file.
- **host/guest** -- taken by the hardware. A Focusrite Vocaster exposes a Host
  Microphone and a Guest Microphone, meaning two people in the same room. If
  capsper ever captures that second mic, host/guest for the two ends of a call
  leaves you with a host, a guest, and a remote guest.

Near/far is also the only pair that survives that growth: near covers everyone in
the room and far covers everyone on the call, so a third track needs no rename.

One known weakness, accepted rather than solved: `<v Near>` and `<v Far>` are
terse as labels for a human reading the transcript against the audio. They are the
honest defaults, because we genuinely do not know who the far end is. Substituting
real names is a later concern and not something the format needs to solve.

The `remote host` in the directory layout section below is the networking sense
and stays as it is.

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
of an hour whenever the near end is the one talking, so that is close to a full core
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
<v Near>so the thing I wanted to raise was the routing

2
00:00:08.020 --> 00:00:11.400
<v Far>yeah, I looked at that yesterday
```

Which buys:

- **Speaker attribution as ground truth, not inference.** Two tracks means near
  end versus far end is known, not guessed. Better than what the commercial tools
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
<v Near>right, that makes sense
```

So the difference between a normal transcript and a debug one is exactly one
thing: whether the `NOTE` blocks are written. Same writer, same file layout, one
flag.

The ring buffer stays. `seq % keep` is right for "keep the last ten utterances
while I chase a bug", and it is wrong for meeting sessions, which must never be
silently overwritten. So the two paths differ in exactly two ways -- rotation
versus dated directories, and which audio format they default to -- and share
everything else: the same writer, the same cue logic, the same `NOTE` emission
controlled by the same detail setting. The rotation is a naming policy handed to
the writer, not a second implementation of it.

## Audio files

**One stereo file, near on the left, far on the right.** Not two mono files.

Channel separation is lossless separation, so nothing is given up: `ffmpeg` splits
it back into two mono tracks in one invocation if anything ever wants them that
way. What is gained is a single timeline. Two files have two, and if one capture
starts a few tens of milliseconds after the other, or takes a dropout, they
desync and neither file records that it happened. Interleaved samples cannot
drift apart from each other or from the transcript.

**The recording is never gated.** VAD gates the ASR encoder only, never the file.
If elided silence reached the audio, it would stop lining up with the cue
timestamps and the transcript would no longer be checkable against what was said,
which is the entire reason the audio is kept. Two different things are called "the
encoder" in this document; this is the line between them.

Hard-panned stereo is tiring to listen to directly, and that is accepted rather
than designed around -- the file is for checking a transcript, and the player in
the next section routes either channel to both ears anyway.

The channel assignment goes in a `NOTE` at the top of the transcript, so a
recording found in two years says which side is which without this document.

**This works because there are exactly two sides.** If the Vocaster guest
microphone ever becomes a third track, stereo cannot hold it. Opus handles more
channels through its mapping families and WAV handles it trivially, so the formats
generalise, but the "it just plays" property does not survive past two. That is
the boundary, stated rather than pretended away.

WAV at 32000 bytes/sec is 115 MB per hour per channel. Opus couples stereo
channels efficiently only when they correlate, and these two do not at all, so
budget around 48 kbps rather than 24 -- roughly 20 MB an hour, which is the same
total as two mono tracks would have been. No saving, no cost.

Two formats, `wav` and `opus`, selectable per path rather than globally. Defaults:

| path | default | why |
| --- | --- | --- |
| meeting sessions | `opus` | hours of audio, kept indefinitely |
| PTT debug recordings | `wav` | seconds long, ring-bounded, and regression comparisons want the raw samples |

Either can be set to either. The debug default is not a limitation to work around
later -- raw is the right thing there, and the setting exists so an unusual case
can say so, not because the default is in doubt.

Channel count follows the number of tracks, so the debug path stays mono: it
records one side of nothing.

## The player

An `index.html` written beside the transcript and the audio, referencing both as
siblings. A small embedded script, no build step, no dependencies.

What it does: an `<audio>` element for `audio.opus`, a `<track>` element for
`transcript.vtt`, and a transcript that scrolls in step with playback -- near end
on the left, far end on the right, like a chat log. Plus a Web Audio graph that
routes either channel to both ears, so the hard panning becomes a near / far /
both control rather than something to endure.

**It uses the browser's own WebVTT parser.** No hand-written parsing. Set the
track to `mode = "hidden"` and cue events fire without anything being rendered;
`cue.text` carries the payload as authored, so the voice span prefix comes off
with a regex and the rest is the line to display. This is the whole reason the
cues stay as readable text rather than JSON: the standard parser already handles
them, and the file still drops into mpv or any other player and works.

The `NOTE` blocks are invisible here, which is correct. The native parser discards
comments, so the debug detail costs the player nothing and needs no handling. It
is there for a human reading the file and for whatever reads it later.

**It assumes it is served over HTTP.** Capsper does not ship a server; point any
static file server at the sessions directory. This is a deliberate simplification
and it has one consequence worth knowing before anyone debugs it for an afternoon:
opening `index.html` straight off the filesystem will look like it works and the
channel control will be silent. Both Chrome and Firefox treat every `file://` URL
as its own opaque origin, so `createMediaElementSource` on an audio element
pointing at a sibling file outputs zeroes rather than failing. Chrome notes it in
the console and carries on.

**The page is a view, not the format.** The transcript and the audio are
canonical, `index.html` is regenerable from them, and nothing may end up recorded
only in the page. Otherwise the player quietly becomes a thing that has to stay
backwards compatible.

## Configuration

New surface goes in a config file. The CLI keeps working exactly as it does, and
keeps every flag it has, but the meeting options are config-only rather than
growing another dozen flags onto a command line that already has twenty.

**Format: ZON.** `std.zon.parse.fromSlice` is in the standard library as of the
pinned toolchain (verified in Zig 0.15.2, with a `Diagnostics` type that reports
errors with source locations). That matters more than it sounds:

- **No dependency.** JSON is also in the stdlib but has no comments, and comments
  are the whole point of a hand-edited config. JSON-with-comments means a
  third-party parser for a file we read once at startup.
- **Comments and multiline strings come free**, because ZON's grammar is a subset
  of Zig's.
- **The struct is the schema.** `fromSlice` parses into a Zig type, so the config
  type checks at compile time and unknown or mistyped fields are a parse error
  with a line number rather than a silent default.
- **The project already uses it.** `build.zig.zon` is ZON, with comments in it
  today. One format to know, not two.

Sketch:

```zig
.{
    .meeting = .{
        .enabled = true,
        // The name this appears under in the desktop's output picker.
        .sink_name = "capsper_call",
        .dir = "~/.local/share/capsper/sessions",
        .audio_format = .opus,
        // How long a sink can sit idle before the session is closed. Long
        // enough to survive a screen-share renegotiation or a brief mute.
        .idle_close_seconds = 30,
        .detail = .minimal, // or .debug, which adds NOTE blocks
    },
    .debug_recording = .{
        .dir = "~/.local/share/capsper/debug",
        .keep = 10,
        .audio_format = .wav,
        .detail = .debug,
    },
}
```

Resolution order: config file, then CLI flags, so a flag can always override a
setting for one run. Search `$XDG_CONFIG_HOME/capsper/config.zon`, then the path
given by a `--config` flag. A missing file is not an error; it means defaults.

## Directory layout

Sessions are user data, so `$XDG_DATA_HOME/capsper/sessions/` by default.

```
sessions/2026/09/11/T143000Z/
  index.html
  transcript.vtt
  audio.opus
```

Date-nested rather than a flat directory of long names: a year of meetings is a
lot of entries, and `YYYY/MM/DD` is the layout every photo and log tool converged
on. The leaf is the ISO 8601 basic-format time with its designators, `T` marking
a time and `Z` marking the zone, so the whole path reads as one ISO timestamp
split across directories and sorts correctly at every level.

**Basic format, not extended** -- `T143000Z` rather than `T14:30:00Z` -- and the
reason is portability, not legality. Linux accepts a colon in a filename happily;
only `/` and NUL are forbidden. But Windows reserves the colon outright, and
`windows-port-plan.md` sits in this same directory, so a layout with colons in it
is one that does not survive the port. macOS accepts it through the POSIX layer
but Finder still renders it as a slash, a leftover from HFS. And on Unix generally
the colon is the path-list separator, so colon-delimited `PATH`-style variables
misparse, and `scp` and `rsync` read `host:path` and take the leading component
for a remote host. ISO 8601 anticipated all of this: basic format is part of the
standard rather than a workaround for it, and nothing but punctuation is lost.

**Dates are UTC**, which is what makes `Z` honest. The tradeoff to be aware of:
a meeting at half past midnight BST files under the previous day. The alternative,
local time, puts it where you would look for it but introduces an hour that
happens twice a year. UTC is chosen for being unambiguous; it can be revisited if
it turns out to be annoying in practice.

Two sessions starting in the same second cannot happen given the idle-close
window, so there is no suffix. If the directory somehow exists, fail rather than
invent a name.

## Flags

The meeting options live in the config file. The only new flag is:

```
--config PATH           Config file location (default: $XDG_CONFIG_HOME/capsper/config.zon)
```

The near-end track uses the existing source selection. Note that
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

**Phase 0 -- the config file.** `std.zon.parse` into a config struct, XDG lookup,
`--config` to override, flags winning over file. Nothing reads it yet beyond the
settings that already exist as flags, which is the point: it lands and is proven
before anything depends on it. Settle the field names here, because they are the
part that is expensive to change later.

**Phase 1 -- the sink and the graph.** Create the virtual sink, pass it through to
the default output, expose its monitor as a capture source. No transcription.
Success: select it in Google Meet, still hear the call, see the monitor carrying
audio in `pw-dump`.

**Phase 2 -- gate 1 and two-track capture.** Arm and disarm on stream link and
state with the debounce. Write one interleaved stereo file per session into the
dated layout, near left and far right. Measure how Chrome actually behaves on call
end and set the debounce from that. Still no transcription.

**Phase 3 -- transcription and WebVTT.** Two connections into the existing
pipeline, cue closing from the emit and RMS signals, merge by audio position,
voice spans, one file. Move `recorder.zig` onto the same writer, keeping its
rotation, and reduce the debug log to `NOTE` blocks. The regression corpus is the
test: the debug path must produce the same text it does today, with the diagnostic
detail relocated rather than lost.

**Phase 4 -- VAD.** Gate ahead of the ASR encoder, never the recording. Do the
arrival-side position counting *first*, with a test that feeds a file with long
silences and asserts the final cue timestamp matches the file duration. Then
measure the saving against the table above and decide whether macOS gets it.

**Phase 5 -- Opus.** libopus behind the format setting, so both paths can select
either. Sessions default to it, debug recordings stay WAV.

**Phase 6 -- the player.** `index.html` written beside each session. Native track
parser, chat-style transcript synced to playback, Web Audio channel routing.
Served over HTTP, with no server shipped.

Phases 0 through 3 are a complete, useful tool on their own. Phase 4 is an
optimisation with a sharp edge, phase 5 is convenience, and phase 6 is the thing
that makes a session pleasant to revisit rather than merely archived.
