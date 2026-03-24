---
description: Build system, RPATH, dist packaging, and CI conventions
globs:
  - build.zig
  - run.ts
  - dist/*
  - .github/*
---

# Build & Dist

## RPATH (Linux)

- Binary RPATH is `$ORIGIN/../lib` so `dist/bin/capsper` finds `dist/lib/*.so` at runtime.
- **Never use `patchelf`** — fix RPATH at build time.
- macOS uses `@loader_path/../lib` (set by Zig build) and links system CoreML/CoreAudio frameworks.

## Shared Libraries

Pre-built onnxruntime shared libraries are committed in `dist/lib/` via Git LFS (Linux only). The Zig build links against these directly. macOS uses the system CoreML framework — no bundled shared libs.

## CPU Target

- **Linux dist builds target `x86_64_v3`** (AVX2+FMA+BMI) — matches our GPU support floor (GTX 1650+). Both `build()` and `ci()` pass `-Dcpu=x86_64_v3` to zig build.
- The `dist()` target validates no AVX-512 instructions are present in the binary.
- **macOS builds target Apple Silicon (arm64)** — no `-Dcpu` flag needed, Zig defaults to the native target.

## CI

- **Local and CI builds must be identical.** Same flags, same CPU target, same optimizations. No "dev mode" divergence — unknown differences between local and CI builds cause bugs that only appear in production.
- **CI workflows must only call `run.ts` targets** — no build/packaging logic in `.github/workflows/`. Everything must be testable locally via `./run.ts <target>`. CI-only behaviour (e.g. `gh release create`) is gated on env vars like `GH_TOKEN` inside `run.ts`, not split into separate workflow steps.
