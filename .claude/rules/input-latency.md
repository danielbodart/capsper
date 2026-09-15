# Input Latency

**Nothing on the thread that carries keystrokes may wait, except on a
transcript going in.** No opening or closing a device node, no sleeping, no
lock held across either. The one sanctioned wait is `uinput_mutex` during text
injection, and the reason is below.

The keyboard is not wired to the desktop — capsper is in the middle. A key
press is read from the real device, written to a virtual one, and only then
seen by whatever the user is typing into. On Linux that is the `eventLoop`
thread in `src/platform/linux/input.zig`; on macOS it is the CGEventTap
callback and its CFRunLoop thread in `src/platform/macos/input.zig`. Whatever
those threads wait for, the user's typing waits for. There is no queue that
catches up gracefully: keys pile in a kernel buffer and arrive late, in a
clump. On macOS it is worse than late — the OS disables a tap whose callback
overruns, and the keyboard stops passing through capsper at all.

The costs are not obvious from reading the code, which is why the rule is
blunt rather than "be careful":

- **Closing an evdev fd costs an RCU grace period** — 10–17ms each, measured.
  A device that sleeps on USB costs 50ms to open. Twenty-odd devices is a
  third of a second.
- **A sleep is a sleep** — on `eventLoop`. The 200ms settle for udev is a real
  requirement and is a plain `Thread.sleep`, because it happens on `deviceLoop`,
  where sleeping costs nobody anything.
- **`uinput_mutex` is shared with text injection, and injection holds it for
  the whole transcript.** That does block every real keystroke for as long as
  the transcript takes. It is the exception, because the alternative is worse:
  a key event means what the modifier state around it says it means, so a real
  keystroke let in between two injected ones is read in the transcript's
  context and the rest of the transcript in its — press a shortcut mid-inject
  and the remaining characters arrive as chords of it. Locking per character
  bought the latency back and paid in corrupted input. Injection happens in the
  moment just after speaking, when nobody is typing; a shortcut misfiring is
  felt, a pause there is not.
- **Opening and closing device nodes belongs to `deviceLoop`, not `eventLoop`.**
  That is what the second thread in `input.zig` is for. `eventLoop` polls,
  reads and forwards; it marks a dead device and moves on, and `deviceLoop`
  does the close. Adding an `open` or a `close` back into `eventLoop` — a
  hotplug grab, a rescan, a retry — puts ten to fifty milliseconds between a
  key and the screen.

Anything periodic or slow — scanning devices, retrying a failed grab, waiting
on udev — belongs on `deviceLoop`, which is free to block on any of it. The
question to ask of new work is not "how long does this take?" but "which thread
is it on?".

Before adding work to these threads, measure it: `strace -f -p <pid> -T -tt`
against the running service, and look at the duration of every call the loop
makes. A pass that does not show up as a stall in that trace is one that
cannot be felt while typing.
