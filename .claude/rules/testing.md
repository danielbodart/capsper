---
description: Testing conventions — unit tests, property tests, integration tests
globs:
  - src/**/*.zig
  - test/*
---

# Testing Conventions

## Unit Tests

Add unit tests for any pure functions (functions that don't depend on whisper.cpp C types). Keep testable logic in modules that don't import `whisper_c.zig` so tests run fast without requiring the GPU or model. Unit tests live inline in their source files (see `src/utils.zig`, `src/alignatt.zig`).

## Property Tests

For functions with tricky invariants (word matching, offset calculations, stability/delta logic), add property-based tests in `src/prop_tests.zig` using [minish](https://github.com/CogitatorTech/minish). Good candidates: functions that are idempotent, symmetric, have roundtrip relationships, or where edge cases around spaces/punctuation/empty strings matter. Property tests catch bugs that hand-written examples miss.

## Integration Tests

Integration tests are self-contained: each starts its own server with `--port 0` (OS-assigned port), parses the port from the "Listening on port" log line, and cleans up on exit. Run via `./run.ts slow-test`.
