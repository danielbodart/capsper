---
description: PipeWire FFI constraints — why SPA pod calls must go through C helpers
globs:
  - src/pw_helpers.c
  - src/audio_capture.zig
  - src/pw_detect.zig
  - src/pipewire_c.zig
---

# PipeWire FFI

**All PipeWire calls involving SPA pods or variadic macros must be in `src/pw_helpers.c`, not called directly from Zig.**

Passing `spa_pod**` params through Zig FFI breaks SPA format negotiation — ports get generic names like `input_1`, auto-connect fails, and resampling doesn't happen. Variadic C macros (SPA pod builders) cannot be called from Zig at all.

If you need new PipeWire functionality, add a C wrapper in `pw_helpers.c` and call it from Zig.
