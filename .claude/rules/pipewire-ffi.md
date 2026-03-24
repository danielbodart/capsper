---
description: PipeWire FFI constraints — why SPA pod calls must go through C helpers (Linux only)
globs:
  - src/platform/linux/pw_helpers.c
  - src/platform/linux/audio.zig
  - src/platform/linux/detect.zig
  - src/platform/linux/pipewire_c.zig
---

# PipeWire FFI (Linux)

**All PipeWire calls involving SPA pods or variadic macros must be in `src/platform/linux/pw_helpers.c`, not called directly from Zig.**

Passing `spa_pod**` params through Zig FFI breaks SPA format negotiation — ports get generic names like `input_1`, auto-connect fails, and resampling doesn't happen. Variadic C macros (SPA pod builders) cannot be called from Zig at all.

If you need new PipeWire functionality, add a C wrapper in `pw_helpers.c` and call it from Zig.

This rule applies only to the Linux platform code. macOS uses CoreAudio (no PipeWire).
