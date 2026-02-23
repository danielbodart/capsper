# Session-Level Recording & TCP Unification — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move WAV recording from VAD utterance boundaries to session boundaries (PTT press/release or TCP connect/disconnect), and unify TCP to use the same PTT gating as local mode.

**Architecture:** Recorder API becomes session-scoped (`startRecording`/`endRecording`). TCP `runTcp` sets `is_live` on accept/disconnect so `handleConnection` uses the same PTT gating logic for both modes. `EndReason` enum is removed.

**Tech Stack:** Zig 0.15, whisper.cpp, PipeWire

---

### Task 1: Simplify Recorder API

**Files:**
- Modify: `src/recorder.zig`

**Step 1: Remove `EndReason` enum**

Delete lines 6-18 (the `EndReason` enum). It's no longer needed — sessions just end.

**Step 2: Rename `startUtterance` → `startRecording`**

Replace the method (lines 58-65) with:

```zig
/// Called when a session begins (PTT press or TCP connect).
/// Clears buffers and starts accumulating audio.
pub fn startRecording(self: *Recorder) void {
    self.rec_buf.clearRetainingCapacity();
    self.diag_buf.clearRetainingCapacity();
    self.emit_buf.clearRetainingCapacity();
    self.active = true;
    self.utterance_start_ns = std.time.nanoTimestamp();
}
```

No `initial_pcm` parameter — we record everything from session start, silence included.

**Step 3: Rename `endUtterance` → `endRecording`**

Replace the method (lines 110-154). Remove the `EndReason` parameter. Remove the "End reason" line from the log output:

```zig
/// Called when a session ends (PTT release or TCP disconnect).
/// Writes NNN.wav + NNN.log, advances seq.
pub fn endRecording(self: *Recorder) !void {
    if (!self.active) return;
    self.active = false;

    const idx = self.seq % self.keep;
    self.seq += 1;

    // Write WAV
    var wav_name_buf: [16]u8 = undefined;
    const wav_name = std.fmt.bufPrint(&wav_name_buf, "{d:0>3}.wav", .{idx}) catch return;
    {
        var wav_buf = std.ArrayListUnmanaged(u8){};
        defer wav_buf.deinit(self.allocator);
        try utils.writeWav(wav_buf.writer(self.allocator), self.rec_buf.items);
        var file = try self.dir.createFile(wav_name, .{});
        defer file.close();
        try file.writeAll(wav_buf.items);
    }

    // Write log
    var log_name_buf: [16]u8 = undefined;
    const log_name = std.fmt.bufPrint(&log_name_buf, "{d:0>3}.log", .{idx}) catch return;
    {
        var log_buf = std.ArrayListUnmanaged(u8){};
        defer log_buf.deinit(self.allocator);
        const w = log_buf.writer(self.allocator);
        const duration_ms = self.utteranceDurationMs();
        std.fmt.format(w, "=== Capsper Recording {d:0>3} (v{s}) ===\n", .{ self.seq - 1, self.version }) catch {};
        std.fmt.format(w, "Duration: {d}.{d}s ({d} bytes)\n", .{
            duration_ms / 1000, (duration_ms % 1000) / 100, self.rec_buf.items.len,
        }) catch {};
        w.writeAll("\n--- Emitted Text ---\n") catch {};
        w.writeAll(self.emit_buf.items) catch {};
        w.writeAll("\n\n--- Cycle Log ---\n") catch {};
        w.writeAll(self.diag_buf.items) catch {};
        var file = try self.dir.createFile(log_name, .{});
        defer file.close();
        try file.writeAll(log_buf.items);
    }

    std.debug.print("[rec] wrote {s} + {s} ({d} bytes audio)\n", .{
        wav_name, log_name, self.rec_buf.items.len,
    });
}
```

**Step 4: Build to verify**

Run: `./run.ts build`
Expected: Compile errors in `server.zig` (references to old names). That's expected — we fix those in Task 2.

**Step 5: Commit recorder changes**

```
git add src/recorder.zig
git commit -m "refactor: rename recorder API to session-scoped (startRecording/endRecording)"
```

---

### Task 2: Rewire server.zig recording calls

**Files:**
- Modify: `src/server.zig`

**Step 1: Remove EndReason import**

Delete line 12: `const EndReason = recorder_mod.EndReason;`

**Step 2: Move `startRecording` to PTT press edge**

In `handleConnection` at the PTT press edge (line 413), replace:
```zig
if (self.recorder) |rec| rec.logEvent(start_ns, "PTT pressed");
```
with:
```zig
if (self.recorder) |rec| {
    rec.startRecording();
    rec.logEvent(start_ns, "PTT pressed");
}
```

**Step 3: Move `endRecording` to PTT release edge**

In the PTT release edge (line 356), replace:
```zig
if (self.recorder) |rec| rec.logEvent(start_ns, "PTT released");
```
with:
```zig
if (self.recorder) |rec| {
    rec.logEvent(start_ns, "PTT released");
    rec.endRecording() catch |err| {
        std.debug.print("[rec] write error: {}\n", .{err});
    };
}
```

**Step 4: Remove `startUtterance` from VAD onset**

At lines 305-308, remove the recorder calls from the idle→speaking transition. Replace:
```zig
if (self.recorder) |rec| {
    rec.startUtterance(speech_buf.items);
    rec.logEvent(start_ns, "idle → speaking");
}
```
with:
```zig
if (self.recorder) |rec| rec.logEvent(start_ns, "idle → speaking");
```

**Step 5: Remove `endUtterance` from `resetUtterance`**

In `resetUtterance` (lines 536-551), remove the recorder call. The `EndReason` parameter is also no longer needed. Replace the entire function:

```zig
fn resetUtterance(
    self: *Server,
    pipeline: *Pipeline,
    speech_buf: *std.ArrayListUnmanaged(u8),
    speech_trim_total: *usize,
    vad_filter: *VadFilter,
) void {
    pipeline.resetSegment();
    vad_filter.reset();
    speech_trim_total.* += speech_buf.items.len;
    speech_buf.clearRetainingCapacity();
}
```

**Step 6: Update all `resetUtterance` call sites**

There are 3 calls — remove the `EndReason` argument from each:

- Line 339: `.flush` → remove
- Line 368: `.released` → remove
- Line 426: `if (!live) .released else .timeout` → remove

**Step 7: Handle `endRecording` on client disconnect**

In the final flush section (lines 416-436), add `endRecording` before returning on `client_closed`. After the existing flush logic, before `if (client_closed) return;`, add:

```zig
if (client_closed) {
    if (self.recorder) |rec| rec.endRecording() catch |err| {
        std.debug.print("[rec] write error: {}\n", .{err});
    };
    return;
}
```

And remove the bare `if (client_closed) return;` that was there before.

**Step 8: Build and run tests**

Run: `./run.ts`
Expected: Build succeeds, unit tests pass, short regressions pass. Recording behavior changes are not exercised by regression tests (they don't use `--record-dir`), so this should be green.

**Step 9: Commit**

```
git add src/server.zig
git commit -m "refactor: move recording start/stop from VAD transitions to session boundaries"
```

---

### Task 3: TCP unification — connection = session

**Files:**
- Modify: `src/server.zig`

**Step 1: Set `is_live` in `runTcp` around each connection**

In `runTcp` (lines 183-192), wrap the connection with `setLive` calls:

```zig
while (true) {
    const conn = try posix.accept(listener, null, null, posix.SOCK.CLOEXEC);
    defer posix.close(conn);

    std.debug.print("Client connected\n", .{});
    setLive(true);
    if (self.recorder) |rec| rec.startRecording();
    self.handleConnection(conn, conn, self.type_callback) catch |err| {
        std.debug.print("Connection error: {}\n", .{err});
    };
    if (self.recorder) |rec| rec.endRecording() catch |err| {
        std.debug.print("[rec] write error: {}\n", .{err});
    };
    setLive(false);
    std.debug.print("Client disconnected\n", .{});
}
```

**Step 2: Change `is_live` default to `false`**

Line 20: Change `is_live` init from `true` to `false`:
```zig
pub var is_live = std.atomic.Value(bool).init(false);
```

**Step 3: Set `is_live` true in `runLocal` when no trigger key**

In `runLocal`, after PipeWire setup (around line 226), the existing code already handles `is_live` for the no-trigger case via `capture.setActive(true)`. But now that the default is `false`, we need to explicitly go live. Add after the existing `capture.setActive(true)` on line 225:

The existing code at lines 223-226:
```zig
} else if (is_live.load(.monotonic)) {
    // Normal mode: connect now (no --trigger, always live).
    capture.setActive(true);
}
```

Needs to change to unconditionally go live when there's no trigger key. But we can't tell from here whether there's a trigger key — `is_live` was the proxy. The simplest fix: in `main.zig`, only set `is_live` to false when a trigger key is present (which it already does at line 353). With the new default of `false`, we need `main.zig` to set it to `true` when there's NO trigger key.

In `src/main.zig` around line 351-354, change:
```zig
// Start not-live when using trigger key (trigger press goes live)
if (trigger_key != null) {
    server_mod.setLive(false);
}
```
to:
```zig
// With trigger key: start not-live (trigger press goes live)
// Without trigger key: start live (always on)
if (trigger_key != null) {
    server_mod.setLive(false);
} else if (input_mode == .local) {
    server_mod.setLive(true);
}
```

TCP mode doesn't need this — `runTcp` calls `setLive(true)` on accept.

**Step 4: Build and run tests**

Run: `./run.ts`
Expected: All tests pass. The regression tests use TCP mode — they connect (which now calls `setLive(true)`) and disconnect (which calls `setLive(false)`). The `handleConnection` loop sees `is_live` true on entry and processes audio normally.

**Step 5: Commit**

```
git add src/server.zig src/main.zig
git commit -m "refactor: unify TCP and local mode — connection = session with PTT gating"
```

---

### Task 4: Verify with full test suite

**Step 1: Run full test suite**

Run: `./run.ts`
Expected: Build + unit tests + short regressions all pass.

**Step 2: Run slow tests**

Run: `./run.ts slow-test`
Expected: Medium and long regressions pass within existing thresholds. This change doesn't affect transcription quality — only recording boundaries moved.

**Step 3: Squash fixup commits if any**

If any fixes were needed, squash them into the relevant commits.
