---
description: Zwanzig static analyzer — known limitations and suppression syntax
globs:
  - src/**/*.zig
  - build.zig
---

# Static Analysis (zwanzig)

`zig build analyze` runs zwanzig on `src/` with three safety engines: `store-violations-engine`, `stack-escape-engine`, `unreachable-code-engine`. It's part of `dev` and `ci` and fails the build on any finding.

## Known False Positives

Zwanzig does not understand `errdefer` control flow. It treats `errdefer` cleanup as always-executed, so any `errdefer allocator.free(x)` or `errdefer posix.close(fd)` gets flagged as a double-free/double-close. These are false positives — `errdefer` only runs on the error path.

Similarly, `stack-escape-engine` flags returning fixed-size arrays by value (e.g. `fn foo() [44]u8 { var x: [44]u8 = ...; return x; }`), which is a safe copy in Zig, not a dangling reference.

## Suppression Syntax

When you encounter a false positive, suppress it inline:

```zig
// Single line:
// zwanzig-disable-next-line: store-violations-engine
errdefer allocator.free(buf);

// Multi-line block (e.g. errdefer with braces):
// zwanzig-disable: store-violations-engine
errdefer {
    posix.close(pipe_fds[0]);
    posix.close(pipe_fds[1]);
}
// zwanzig-enable: store-violations-engine
```

Only suppress with a clear reason (idiomatic Zig pattern that zwanzig misunderstands). Never suppress to hide real bugs.
