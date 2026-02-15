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
- **Prompt structure**: `[startofprev][domain_terms][context_tokens][sot][lang][transcribe][notimestamps]`. The `<|startofprev|>` prefix is only included when domain terms or context tokens are present. Domain terms are tokenized once at startup via `whisper_tokenize()` and stored as a token slice.
- **AlignAtt always `is_last=true`**: The frame_threshold=25 is too conservative for short streaming buffers. Server-side word stability checking handles hallucination filtering instead.
- **Word-level delta tracking**: Stability is checked at word granularity (not byte), using case-insensitive comparison with trailing punctuation stripped. This handles Whisper changing "so" to "so," between cycles.
- **Sliding window**: Audio buffer capped at 15s (`max_buffer_bytes=480000`). When trimmed, prev_text offset scanning (up to 6 words) realigns the emitted word count.
