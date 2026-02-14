---
description: Build system, RPATH, dist packaging, and CI conventions
globs:
  - build.zig
  - run.ts
  - dist/*
  - .github/*
---

# Build & Dist

## RPATH

- Binary RPATH is `$ORIGIN/../lib` so `dist/bin/capsper` finds `dist/lib/*.so` at runtime.
- **Shared lib RPATH must be `$ORIGIN`** — configured via `CMAKE_INSTALL_RPATH=$ORIGIN` + `CMAKE_BUILD_WITH_INSTALL_RPATH=ON` in `build.zig`. The `.so` files depend on each other (e.g. `libwhisper.so` needs `libggml.so`), so they need `$ORIGIN` to find siblings in the same directory.
- **Never use `patchelf`** — fix RPATH at CMake configure time.
- The `dist()` target in `run.ts` validates RPATH with `readelf` and fails if any lib has a hardcoded absolute RUNPATH.

## Shared Libraries

Pre-built whisper.cpp shared libraries are committed in `dist/lib/` via Git LFS (~43 MB). The Zig build links against these directly — no CMake step needed for normal builds. Use `zig build rebuild-libs --prefix dist` only after bumping the whisper.cpp submodule.

Static linking is intentionally avoided — Zig's bundled libc++ conflicts with whisper.cpp's libstdc++ dependency.

## CPU Target

- **Dist builds target `x86_64_v3`** (AVX2+FMA+BMI) — matches our GPU support floor (GTX 1650+). Both `build()` and `ci()` pass `-Dcpu=x86_64_v3` to zig build.
- **`GGML_NATIVE=OFF`** in `build.zig` CMake configure — ensures whisper.cpp shared libs use explicit feature flags (SSE4.2, AVX, AVX2, FMA, F16C, BMI2) instead of `-march=native`.
- The `dist()` target validates no AVX-512 instructions are present in the binary.

## CI

- **Local and CI builds must be identical.** Same flags, same CPU target, same optimizations. No "dev mode" divergence — unknown differences between local and CI builds cause bugs that only appear in production.
- **CI workflows must only call `run.ts` targets** — no build/packaging logic in `.github/workflows/`. Everything must be testable locally via `./run.ts <target>`. CI-only behaviour (e.g. `gh release create`) is gated on env vars like `GH_TOKEN` inside `run.ts`, not split into separate workflow steps.
