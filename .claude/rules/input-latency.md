# Input Latency

**Nothing on the thread that carries keystrokes may wait.** No opening or
closing a device node, no sleeping, no lock held across either.

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
- **A sleep is a sleep.** A 200ms settle for udev is a real requirement, but
  it belongs in a deadline the loop checks, not in `Thread.sleep`.
- **`uinput_mutex` is shared with text injection.** Held across the delay
  between injected characters, it blocks every real keystroke for the length
  of the transcript. Hold it for one character, never across a sleep.

Anything periodic or slow — scanning devices, retrying a failed grab, waiting
on udev — either becomes event-driven (inotify already watches `/dev/input`),
or gets queued with a deadline and picked up on a later pass of the loop.

Before adding work to these threads, measure it: `strace -f -p <pid> -T -tt`
against the running service, and look at the duration of every call the loop
makes. A pass that does not show up as a stall in that trace is one that
cannot be felt while typing.
