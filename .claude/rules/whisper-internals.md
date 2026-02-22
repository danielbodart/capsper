---
description: Whisper.cpp streaming internals — padding, decode, AlignAtt, delta tracking, sliding window
globs:
  - src/pipeline.zig
  - src/server.zig
  - src/alignatt.zig
  - src/vad.zig
---

# Whisper Streaming Internals

- **30-second padding**: whisper.cpp's mel computation requires 480000 samples (30s). Short audio must be zero-padded or the decoder emits immediate EOT.
- **Split prompt decode**: `whisper_get_logits_from_state()` reads from offset 0, but batch decode only populates logits for the last token. Prompt tokens are decoded in two calls: batch first N-1, then the last token alone.
- **Prompt structure**: `[startofprev][domain_terms][context_tokens][sot][lang][transcribe][notimestamps][accumulated_tokens]`. The `<|startofprev|>` prefix is included when domain terms OR context tokens are present. Domain terms and context tokens go before `[sot]` for conditioning. Accumulated tokens go AFTER `[notimestamps]` as forced decoder output — the model processes them as its own previous output, building KV cache state. Domain terms are tokenized once at startup via `whisper_tokenize()` and stored as a token slice.
- **Token accumulation**: Pipeline maintains `accumulated_tokens` across decode cycles within a VAD segment. After emitting words, confirmed tokens are committed as forced prefix for the next cycle. Reset on segment boundary or flush.
- **Two-tier token demotion**: When the sliding window trims audio, tokens whose audio was trimmed are demoted from forced (after `[notimestamps]`) to conditioning (before `[sot]`) as `context_tokens`. The split point is determined by per-token cross-attention frame positions (more precise than SimulStreaming's segment-at-a-time approach). At least 1 token is always demoted. Context tokens are trimmed from the front (oldest first) when they exceed budget.
- **Incremental mel**: `MelBuffer` in `mel.zig` caches raw (pre-normalization) mel frames. Each cycle only computes FFT for new audio frames. `exportForWhisper` normalizes and zero-pads to 3000 frames for the encoder. Mel frame count is clamped to 3000 as a safety bound. Reset on segment boundary or buffer trim.
- **Sliding window**: Audio buffer capped at 30s (`max_buffer_bytes=960000`). On trim, mel cache is reset, `last_attend_frame` is adjusted, and front tokens are demoted to context.
- **Rewind detection**: `last_attend_frame` persists across decode cycles. If attention jumps backwards by > 200 frames (rewind_threshold), all generated tokens are discarded. Reset to null on segment boundary; adjusted by trim_frame on buffer trim.
