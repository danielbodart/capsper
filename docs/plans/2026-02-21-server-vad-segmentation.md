# Pipeline Rewrite: Minimal AlignAtt from Scratch

**Goal:** Strip pipeline.zig to bare minimum, fix server layering, then systematically bring back only the features that are actually needed — validated against SimulStreaming's reference implementation.

**Architecture:** Four separated layers:
1. **I/O** — `AlignedReader`: reads from fd, ensures S16_LE sample alignment
2. **PTT gate** — accepts/discards based on `is_live` atomic
3. **VAD segmentation** — VadFilter edge detection drives `idle`/`speaking` state
4. **Pipeline processing** — transcribe cadence, token accumulation, trim

**Critical constraint:** All decisions byte-count driven (32000 bytes/sec), never wall-clock time. The engine is data-driven — back-pressure, not time-based. It doesn't matter how fast audio is pushed in.

**Design principle:** `speech_buf` only ever contains speech audio. Silence is never buffered. The pipeline should never see silence at the start of its buffer.

---

## Completed

### Phase 1: Strip pipeline.zig to minimal AlignAtt ✅

Deleted everything from pipeline.zig except what's needed to transcribe a single buffer using AlignAtt. No guards, no multi-tier prompt system.

**Kept:**
- `accumulated_tokens` + `commitTokens()` — forced prefix for decoder consistency
- `accumulated_frames` + `handleTrim()` — frame-aware buffer trimming
- `mel_buffer` — incremental mel cache across cycles
- `resetSegment()` — clears all state on segment boundary
- `truncateLastWord()` — word boundary truncation (skipped when forced prefix present)
- AlignAtt stopping via `checkStopping()` (no rewind detection — null `last_attend_frame`)

**Deleted:**
| Feature | Description | Status |
|---|---|---|
| `context_tokens` | Tokens from trimmed audio, fed as conditioning before `[sot]` | Removed |
| `last_attend_frame` | Cross-cycle rewind detection | Removed |
| `segment_max_raw_peak` | Adaptive confidence threshold baseline | Removed |
| Repetition guard | N-gram detection (1-64 tokens, 3 reps) | Removed |
| Confidence guard | Low raw softmax attention → discard as hallucination | Removed |
| Frame regression guard | Tokens attending behind frontier → discard | Removed |
| Rewind detection | Attention jump backwards > 200 frames → discard | Removed |
| Two-tier prompt | Budget allocation across domain/context/forced tokens | Simplified to domain + forced only |

### Phase 2: Fix server layering ✅

- **`speech_buf` (was `pcm_buf`)** — only contains speech audio, never silence. Audio only appended during speaking state or on the onset chunk.
- **`AlignedReader`** — S16_LE byte alignment at the I/O layer. TCP reads can return odd byte counts; the carry byte logic is encapsulated in the reader. Everything downstream sees only complete S16 samples.
- **Auto-gain gated on PipeWire** — only runs when `capture_ptr` is non-null. No-op in TCP mode (no capture device to adjust).

### Phase 3: Fix S16 byte alignment bug ✅

**Root cause:** TCP `posix.read` can return odd byte counts. After VadFilter offset flushes a segment, idle reads consumed bytes from the stream. If an idle read returned an odd count, the next read started at an odd stream offset. When onset fired, the chunk copied to `speech_buf` had misaligned S16 samples — every pair of bytes spanned two real samples, producing garbage values (e.g. -24064 instead of -291).

**Fix:** `AlignedReader` struct carries the trailing odd byte between reads and prepends it to the next read. Single responsibility, single alignment boundary.

### Current test scores

| Test | Coverage | WER | Status |
|---|---|---|---|
| jfk | 100% (22/22) | 0% | Pass |
| fully-committed | 100% (4/4) | 0% | Pass |
| working-test | 94.7% (18/19) | 5.3% | Pass |
| queued-fix | 100% (35/35) | 0% | Pass |
| long-pause | ~90% (66-68/74) | ~12% | Pass |
| repetition-loop | 87.2% (82/94) | 13.8% | Pass |

Short tests locked to 100%/0% WER thresholds. Medium tests set to minCoverage=85.

---

## Next Steps

### Task A: Audit SimulStreaming's decode features

Review the SimulStreaming reference implementation to determine the **minimal** set of decode features it uses. These are the candidates to bring back — anything SimulStreaming doesn't use, we probably don't need either.

**Key questions:**
- Does SimulStreaming use rewind detection? (check `last_attend_frame` usage)
- Does it have a repetition guard?
- Does it have a confidence/hallucination guard?
- Does it use context_tokens (conditioning before `[sot]`)?
- Does it have a frame regression guard?
- How does it handle buffer trimming — does it demote tokens?

The hypothesis is that many of the removed guards were compensating for silence leaking into the pipeline buffer. Now that `speech_buf` only contains speech and VadFilter handles segmentation properly, several guards may be unnecessary.

### Task B: Run long regression tests

Run `./run.ts long-test` to see how the simplified pipeline handles longer recordings. Key files:
- `dictation` (previous: 97%)
- `long-recording` (previous: 33.2% — pre-existing weakness)
- `repetition-loop-long` (previous: 99.6%)
- `silence-hallucination` (previous: 95.1%)

These will tell us which removed features are actually needed for longer audio.

### Task C: Bring back features incrementally

Based on Tasks A and B, bring back features one at a time, testing after each:

1. **Repetition guard** — if repetition-loop-long or long tests show repetition
2. **Confidence guard** — if hallucination appears on segments with weak speech
3. **context_tokens** — if long recordings lose coherence after trims
4. **Rewind detection** — if cross-cycle attention jumps cause garbage
5. **Frame regression guard** — if the decoder re-attends already-transcribed audio

Each addition should be independently testable. If a feature doesn't improve scores, don't keep it.

### Task D: Edge case review — PTT + VAD interaction

Manually verify PTT edge cases (can't be tested via TCP):
- PTT release during speech → flush + reset
- PTT press → clean start, VadFilter reset
- Timeout while speaking → flush
