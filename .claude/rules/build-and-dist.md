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

## CI

**CI workflows must only call `run.ts` targets** — no build/packaging logic in `.github/workflows/`. Everything must be testable locally via `./run.ts <target>`. CI-only behaviour (e.g. `gh release create`) is gated on env vars like `GH_TOKEN` inside `run.ts`, not split into separate workflow steps.
