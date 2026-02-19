# Streaming Architecture: Capsper vs SimulStreaming

Capsper's streaming decode is inspired by [SimulStreaming](https://github.com/backspacetg/SimulStreaming) (AlignAtt-based incremental Whisper). This document maps the design differences between the two systems — where we diverge, why, and what we adopted.

## Frame Threshold (25/4 split)

Capsper uses 25 frames (500ms) during streaming, dropping to 4 frames (80ms) on final flush. SimulStreaming's dataclass default is 4, but its CLI default is also 25 — the 4 is a competition tuning, not the standard setting.

The 500ms trailing gap is transient: each decode cycle leaves the last 500ms undecoded, but the next cycle covers it once new audio arrives. By the time a buffer trim happens (>15s), audio from the trailing gap has been decoded in subsequent cycles. The flush path (threshold=4) handles the final case where there's no next cycle.

Reducing to 4 for streaming would lower latency by ~420ms per cycle but at the cost of noisier edge tokens. The 25/4 split is the right tradeoff: conservative during streaming, aggressive on final flush.

## Mel Padding

Initial comparison suggested Capsper's mel-level zero-padding creates a sharp discontinuity vs SimulStreaming's audio-level zero-padding (`F.pad(audio, (0, N_SAMPLES))` -> STFT -> trim to 3000). Deep trace shows they produce identical output:

1. `computeFrame` (`mel.zig`) handles the boundary correctly — when the FFT window extends past the audio, positions beyond `samples.len` return 0. The Hann window tapers naturally, so the last computed frame is a proper transition frame.
2. Frames past the boundary are pure silence: `log10(max(0, 1e-10)) = -10.0` for all mel bands, which after normalization matches the `silence_norm` that `exportForWhisper` hard-fills.
3. Normalization is equivalent — both find `max` over content frames only, clamp to `max - 8.0`, normalize to ~[0,1].
4. Capsper computes 1 more transition frame than whisper.cpp's formula: `(N+200)/160+1` vs `1+N/160`.

No functional difference.

## Cross-Attention Frame Persistence

SimulStreaming persists `last_attend_frame` as an instance variable across decode cycles and adjusts it on trim: `self.last_attend_frame -= int(50 * removed_seconds)` (`simul_whisper.py:279`). It initializes to `-rewind_threshold` so the first token never triggers a false rewind.

Capsper does the same (`pipeline.zig`):
- `last_attend_frame: ?usize` persists on the `Pipeline` struct across `transcribe()` calls
- Adjusted in `handleTrim()`: subtract `trim_frame`, or set to `null` if the attended frame was in trimmed audio (unsigned `usize` uses `null` as the negative sentinel equivalent)
- Reset to `null` in `resetSegment()` on utterance boundary
- `checkStopping` skips rewind detection when `null`, matching SimulStreaming's negative-sentinel behavior

The flush path calls `resetSegment()` internally, making the "flush always resets" invariant structural.

## Token Demotion Granularity

SimulStreaming removes whole segments' tokens at once on buffer trim (`simul_whisper.py:269-284`). Capsper uses per-token cross-attention frames to decide the exact split point (`pipeline.zig`), which is more precise. The frame data is reliable because the 25-frame threshold means tokens are well within the decoded region by the time a trim happens.

## Token Format After Demotion

SimulStreaming round-trips through text when demoting tokens (decode -> text -> re-tokenize), which can shift subword boundaries. Capsper preserves raw token IDs, maintaining exact decoder state without tokenization drift.

## CIF Word Boundary Detection

SimulStreaming uses a trained CIF linear layer for word boundary detection, primarily valuable for non-English languages (Chinese, Japanese) where boundaries are ambiguous. Capsper is English-only — tokens naturally encode word boundaries via leading spaces. Not implemented.

## Rewind Recovery

SimulStreaming explicitly rolls back to pre-decode tokens and resets `last_attend_frame` on rewind detection (`simul_whisper.py:512-523`). Capsper does the same:
- Clears `generated` and `token_frames` with `clearRetainingCapacity()` so no partial tokens survive
- Resets `last_attend_frame = null`

The caller (`transcribeAndEmit`) skips commit/emit on rewind, but the cleanup happens at the source in the decode loop.

## API Design (Capsper-specific)

Structural choices that don't map to SimulStreaming but prevent bugs:

- **`handleTrim()`** encapsulates all trim side effects: mel cache reset, token demotion, frame list adjustment, `last_attend_frame` update.
- **Flush reset** is structural — `transcribe(samples, flush=true)` calls `resetSegment()` internally. No caller discipline required.
- **Null attention data** — when `whisper_state_get_aheads_cross_qks` returns null, the unverified token is popped and decode breaks with `stop_reason = "no_attn"` instead of continuing with a placeholder.
