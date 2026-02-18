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
- **Prompt structure**: `[startofprev][domain_terms][sot][lang][transcribe][notimestamps][accumulated_tokens]`. The `<|startofprev|>` prefix is only included when domain terms are present. Domain terms go before `[sot]` for conditioning. Accumulated tokens go AFTER `[notimestamps]` as forced decoder output — the model processes them as its own previous output, building KV cache state. Domain terms are tokenized once at startup via `whisper_tokenize()` and stored as a token slice.
- **Token accumulation**: Pipeline maintains `accumulated_tokens` across decode cycles within a VAD segment. After emitting words, confirmed tokens are committed as forced prefix for the next cycle. Reset on segment boundary, flush, or 15s buffer trim.
- **Incremental mel**: `MelBuffer` in `mel.zig` caches raw (pre-normalization) mel frames. Each cycle only computes FFT for new audio frames. `exportForWhisper` normalizes and zero-pads to 3000 frames for the encoder. Mel frame count is clamped to 3000 as a safety bound. Reset on segment boundary or 15s buffer trim.
- **Sliding window**: Audio buffer capped at 15s (`max_buffer_bytes=480000`). On trim, mel cache is reset and front tokens are demoted from forced (after `[notimestamps]`) to conditioning (before `[sot]`) using ceiling division to ensure at least 1 token is demoted.
- **Repetition guard**: Decode loop breaks if the same token is sampled 3+ times consecutively, discarding the repeated tokens. Prevents catastrophic hallucination loops.
