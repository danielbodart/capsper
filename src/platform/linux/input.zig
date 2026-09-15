// src/input.zig — evdev/uinput input handling
//
// Grabs physical keyboards via evdev, forwards all keys through a virtual
// uinput keyboard, intercepts a configurable trigger key for push-to-talk,
// and injects transcribed text as keystrokes.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.input);

// Linux input event codes from kernel headers
const ev = @cImport({
    @cInclude("linux/input-event-codes.h");
});

// ──── Structs (defined manually to avoid @cImport .type keyword issue) ────

pub const InputEvent = extern struct {
    tv_sec: isize,
    tv_usec: isize,
    type: u16,
    code: u16,
    value: i32,

    comptime {
        std.debug.assert(@sizeOf(InputEvent) == 24);
    }

    fn syn() InputEvent {
        return .{ .tv_sec = 0, .tv_usec = 0, .type = EV_SYN, .code = 0, .value = 0 };
    }

    fn key(code: u16, value: i32) InputEvent {
        return .{ .tv_sec = 0, .tv_usec = 0, .type = EV_KEY, .code = code, .value = value };
    }
};

const InputId = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

const UINPUT_MAX_NAME_SIZE = 80;

const UinputSetup = extern struct {
    id: InputId,
    name: [UINPUT_MAX_NAME_SIZE]u8,
    ff_effects_max: u32,
};

// ──── Event type / key constants ────

const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const EV_REP: u16 = 0x14;
const EV_LED: u16 = 0x11;

const BUS_VIRTUAL: u16 = 0x06;
const VIRTUAL_VENDOR: u16 = 0x0FAC;

const KEY_MAX: u32 = 0x2ff;

// ──── ioctl numbers (computed at comptime) ────

fn _ioc(dir: u32, typ: u8, nr: u32, size: u32) u32 {
    return (dir << 30) | (@as(u32, typ) << 8) | nr | (size << 16);
}

const IOC_NONE: u32 = 0;
const IOC_WRITE: u32 = 1;
const IOC_READ: u32 = 2;

const EVIOCGRAB = _ioc(IOC_WRITE, 'E', 0x90, @sizeOf(c_int));
const EVIOCGID = _ioc(IOC_READ, 'E', 0x02, @sizeOf(InputId));
fn EVIOCGBIT(evt: u32, len: u32) u32 {
    return _ioc(IOC_READ, 'E', 0x20 + evt, len);
}
fn EVIOCGKEY(len: u32) u32 {
    return _ioc(IOC_READ, 'E', 0x18, len);
}
fn EVIOCGNAME(len: u32) u32 {
    return _ioc(IOC_READ, 'E', 0x06, len);
}

const UI_SET_EVBIT = _ioc(IOC_WRITE, 'U', 100, @sizeOf(c_int));
const UI_SET_KEYBIT = _ioc(IOC_WRITE, 'U', 101, @sizeOf(c_int));
const UI_SET_LEDBIT = _ioc(IOC_WRITE, 'U', 104, @sizeOf(c_int));
const UI_DEV_SETUP = _ioc(IOC_WRITE, 'U', 3, @sizeOf(UinputSetup));
const UI_DEV_CREATE = _ioc(IOC_NONE, 'U', 1, 0);
const InotifyEvent = extern struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    len: u32,
};

const UI_DEV_DESTROY = _ioc(IOC_NONE, 'U', 2, 0);
fn UI_GET_SYSNAME(len: u32) u32 {
    return _ioc(IOC_READ, 'U', 44, len);
}

// inotify constants
const IN_ATTRIB: u32 = 0x004;
const IN_CREATE: u32 = 0x100;
const IN_NONBLOCK: c_int = 0x800;
const IN_CLOEXEC: c_int = 0x80000;

// ──── ioctl wrapper ────

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn inotify_init1(flags: c_int) c_int;
extern "c" fn inotify_add_watch(fd: c_int, pathname: [*:0]const u8, mask: u32) c_int;

fn doIoctl(fd: posix.fd_t, request: u32, arg: usize) !void {
    if (ioctl(@intCast(fd), @as(c_ulong, request), arg) < 0) {
        return error.IoctlFailed;
    }
}

// ──── ASCII → keycode map (ported from ydotool tool_type.c) ────

const KeyMapping = struct {
    code: u16,
    shift: bool,
};

fn km(code: u16) KeyMapping {
    return .{ .code = code, .shift = false };
}

fn kms(code: u16) KeyMapping {
    return .{ .code = code, .shift = true };
}

const ascii_map: [128]?KeyMapping = blk: {
    var map: [128]?KeyMapping = .{null} ** 128;
    // Control characters
    map['\t'] = km(ev.KEY_TAB);
    map['\n'] = km(ev.KEY_ENTER);
    // 0x20-0x2f: space ! " # $ % & ' ( ) * + , - . /
    map[' '] = km(ev.KEY_SPACE);
    map['!'] = kms(ev.KEY_1);
    map['"'] = kms(ev.KEY_APOSTROPHE);
    map['#'] = kms(ev.KEY_3);
    map['$'] = kms(ev.KEY_4);
    map['%'] = kms(ev.KEY_5);
    map['&'] = kms(ev.KEY_7);
    map['\''] = km(ev.KEY_APOSTROPHE);
    map['('] = kms(ev.KEY_9);
    map[')'] = kms(ev.KEY_0);
    map['*'] = kms(ev.KEY_8);
    map['+'] = kms(ev.KEY_EQUAL);
    map[','] = km(ev.KEY_COMMA);
    map['-'] = km(ev.KEY_MINUS);
    map['.'] = km(ev.KEY_DOT);
    map['/'] = km(ev.KEY_SLASH);
    // 0x30-0x39: digits
    map['0'] = km(ev.KEY_0);
    map['1'] = km(ev.KEY_1);
    map['2'] = km(ev.KEY_2);
    map['3'] = km(ev.KEY_3);
    map['4'] = km(ev.KEY_4);
    map['5'] = km(ev.KEY_5);
    map['6'] = km(ev.KEY_6);
    map['7'] = km(ev.KEY_7);
    map['8'] = km(ev.KEY_8);
    map['9'] = km(ev.KEY_9);
    // 0x3a-0x40: : ; < = > ? @
    map[':'] = kms(ev.KEY_SEMICOLON);
    map[';'] = km(ev.KEY_SEMICOLON);
    map['<'] = kms(ev.KEY_COMMA);
    map['='] = km(ev.KEY_EQUAL);
    map['>'] = kms(ev.KEY_DOT);
    map['?'] = kms(ev.KEY_SLASH);
    map['@'] = kms(ev.KEY_2);
    // 0x41-0x5a: A-Z (uppercase)
    map['A'] = kms(ev.KEY_A);
    map['B'] = kms(ev.KEY_B);
    map['C'] = kms(ev.KEY_C);
    map['D'] = kms(ev.KEY_D);
    map['E'] = kms(ev.KEY_E);
    map['F'] = kms(ev.KEY_F);
    map['G'] = kms(ev.KEY_G);
    map['H'] = kms(ev.KEY_H);
    map['I'] = kms(ev.KEY_I);
    map['J'] = kms(ev.KEY_J);
    map['K'] = kms(ev.KEY_K);
    map['L'] = kms(ev.KEY_L);
    map['M'] = kms(ev.KEY_M);
    map['N'] = kms(ev.KEY_N);
    map['O'] = kms(ev.KEY_O);
    map['P'] = kms(ev.KEY_P);
    map['Q'] = kms(ev.KEY_Q);
    map['R'] = kms(ev.KEY_R);
    map['S'] = kms(ev.KEY_S);
    map['T'] = kms(ev.KEY_T);
    map['U'] = kms(ev.KEY_U);
    map['V'] = kms(ev.KEY_V);
    map['W'] = kms(ev.KEY_W);
    map['X'] = kms(ev.KEY_X);
    map['Y'] = kms(ev.KEY_Y);
    map['Z'] = kms(ev.KEY_Z);
    // 0x5b-0x60: [ \ ] ^ _ `
    map['['] = km(ev.KEY_LEFTBRACE);
    map['\\'] = km(ev.KEY_BACKSLASH);
    map[']'] = km(ev.KEY_RIGHTBRACE);
    map['^'] = kms(ev.KEY_6);
    map['_'] = kms(ev.KEY_MINUS);
    map['`'] = km(ev.KEY_GRAVE);
    // 0x61-0x7a: a-z (lowercase)
    map['a'] = km(ev.KEY_A);
    map['b'] = km(ev.KEY_B);
    map['c'] = km(ev.KEY_C);
    map['d'] = km(ev.KEY_D);
    map['e'] = km(ev.KEY_E);
    map['f'] = km(ev.KEY_F);
    map['g'] = km(ev.KEY_G);
    map['h'] = km(ev.KEY_H);
    map['i'] = km(ev.KEY_I);
    map['j'] = km(ev.KEY_J);
    map['k'] = km(ev.KEY_K);
    map['l'] = km(ev.KEY_L);
    map['m'] = km(ev.KEY_M);
    map['n'] = km(ev.KEY_N);
    map['o'] = km(ev.KEY_O);
    map['p'] = km(ev.KEY_P);
    map['q'] = km(ev.KEY_Q);
    map['r'] = km(ev.KEY_R);
    map['s'] = km(ev.KEY_S);
    map['t'] = km(ev.KEY_T);
    map['u'] = km(ev.KEY_U);
    map['v'] = km(ev.KEY_V);
    map['w'] = km(ev.KEY_W);
    map['x'] = km(ev.KEY_X);
    map['y'] = km(ev.KEY_Y);
    map['z'] = km(ev.KEY_Z);
    // 0x7b-0x7e: { | } ~
    map['{'] = kms(ev.KEY_LEFTBRACE);
    map['|'] = kms(ev.KEY_BACKSLASH);
    map['}'] = kms(ev.KEY_RIGHTBRACE);
    map['~'] = kms(ev.KEY_GRAVE);
    break :blk map;
};

// ──── Extracted pure types (testable without hardware) ────

/// State machine for panic sequence detection (Enter + Backspace + Escape).
/// Tracks which of the three keys are currently held and triggers when all three are.
pub const PanicDetector = struct {
    enter: bool = false,
    backspace: bool = false,
    escape: bool = false,

    /// Feed a key event. Returns true if all three panic keys are held simultaneously.
    pub fn feed(self: *PanicDetector, code: u16, pressed: bool) bool {
        switch (code) {
            ev.KEY_ENTER => self.enter = pressed,
            ev.KEY_BACKSPACE => self.backspace = pressed,
            ev.KEY_ESC => self.escape = pressed,
            else => {},
        }
        return self.enter and self.backspace and self.escape;
    }

    pub fn reset(self: *PanicDetector) void {
        self.* = .{};
    }
};

/// Actions returned by TriggerState transitions.
pub const TriggerAction = enum {
    none,
    start_recording, // trigger pressed — begin capture
    stop_recording, // trigger released — stop capture immediately
};

/// Pure state machine for trigger key press/release.
/// No debounce — release fires immediately for instant PTT cutoff.
pub const TriggerState = struct {
    held: bool = false,

    /// Process a key event (value: 1=press, 0=release, 2=repeat).
    pub fn keyEvent(self: *TriggerState, value: i32) TriggerAction {
        return switch (value) {
            1 => self.keyPress(),
            0 => self.keyRelease(),
            else => .none, // repeat
        };
    }

    fn keyPress(self: *TriggerState) TriggerAction {
        if (!self.held) {
            self.held = true;
            return .start_recording;
        }
        return .none;
    }

    fn keyRelease(self: *TriggerState) TriggerAction {
        if (self.held) {
            self.held = false;
            return .stop_recording;
        }
        return .none;
    }
};

/// Events generated for a single character keystroke.
pub const CharEvents = struct {
    events: [8]InputEvent = undefined,
    len: u4 = 0,

    pub fn slice(self: *const CharEvents) []const InputEvent {
        return self.events[0..self.len];
    }
};

/// Generate the sequence of input events needed to type a single ASCII character.
/// Returns empty CharEvents for non-ASCII or unmapped characters.
pub fn eventsForChar(ch: u8) CharEvents {
    var result = CharEvents{};
    if (ch >= 128) return result;
    const mapping = ascii_map[ch] orelse return result;

    if (mapping.shift) {
        result.events[result.len] = InputEvent.key(ev.KEY_LEFTSHIFT, 1);
        result.len += 1;
        result.events[result.len] = InputEvent.syn();
        result.len += 1;
    }
    result.events[result.len] = InputEvent.key(mapping.code, 1);
    result.len += 1;
    result.events[result.len] = InputEvent.syn();
    result.len += 1;
    result.events[result.len] = InputEvent.key(mapping.code, 0);
    result.len += 1;
    result.events[result.len] = InputEvent.syn();
    result.len += 1;
    if (mapping.shift) {
        result.events[result.len] = InputEvent.key(ev.KEY_LEFTSHIFT, 0);
        result.len += 1;
        result.events[result.len] = InputEvent.syn();
        result.len += 1;
    }
    return result;
}

/// Check if a specific key bit is set in an evdev bitmask.
pub fn hasKeyBit(bitmask: []const u8, key: u16) bool {
    const byte_idx = key / 8;
    if (byte_idx >= bitmask.len) return false;
    return (bitmask[byte_idx] >> @intCast(key % 8)) & 1 != 0;
}

/// Check if a bitmask represents a keyboard device (has standard letter/number keys).
/// Same heuristic as keyd: requires KEY_1-KEY_0, KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T, KEY_Y.
pub fn isKeyboardBitmask(keymask: []const u8) bool {
    const required = [_]u16{
        ev.KEY_1, ev.KEY_2, ev.KEY_3, ev.KEY_4,
        ev.KEY_5, ev.KEY_6, ev.KEY_7, ev.KEY_8,
        ev.KEY_9, ev.KEY_0, ev.KEY_Q, ev.KEY_W,
        ev.KEY_E, ev.KEY_R, ev.KEY_T, ev.KEY_Y,
    };
    for (required) |k| {
        if (!hasKeyBit(keymask, k)) return false;
    }
    return true;
}

// ──── Grabbed device tracking ────

const MAX_DEVICES = 32;

const GrabbedDevice = struct {
    fd: posix.fd_t,
    grabbed: bool,
    name: [64]u8,
    name_len: usize,
    path: [64]u8,
    path_len: usize,
    /// Set by `eventLoop` when the device stops answering, cleared by
    /// `deviceLoop` closing it. Nothing polls a dead device.
    dead: bool = false,
};

/// Index of the device we hold for `path`, or null if we do not hold it.
fn findDeviceByPath(devices: []const ?GrabbedDevice, path: []const u8) ?usize {
    for (devices, 0..) |maybe_dev, i| {
        if (maybe_dev) |dev| {
            if (std.mem.eql(u8, dev.path[0..dev.path_len], path)) return i;
        }
    }
    return null;
}

// ──── InputHandler ────

pub const InputHandler = struct {
    devices: [MAX_DEVICES]?GrabbedDevice = .{null} ** MAX_DEVICES,
    uinput_fd: posix.fd_t = -1,
    inotify_fd: posix.fd_t = -1,
    trigger_key: u16,
    trigger_passthrough: bool,
    type_delay_us: u64,
    live_fn: *const fn (bool) void,
    thread: ?std.Thread = null,
    device_thread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    uinput_mutex: std.Thread.Mutex = .{},
    /// Guards which slots of `devices` hold what. Held only across the memory
    /// that says so, never across an open, a close or a read — `eventLoop`
    /// waits on it every pass, so whatever holds it is on the keystroke path.
    devices_mutex: std.Thread.Mutex = .{},

    panic: PanicDetector = .{},
    trigger: TriggerState = .{},

    pub const Config = struct {
        trigger_key: u16 = ev.KEY_CAPSLOCK,
        trigger_passthrough: bool = false,
        type_delay_us: u64 = 12_000, // 12ms between keystrokes
        live_fn: *const fn (bool) void,
    };

    pub fn init(config: Config) !InputHandler {
        var self = InputHandler{
            .trigger_key = config.trigger_key,
            .trigger_passthrough = config.trigger_passthrough,
            .type_delay_us = config.type_delay_us,
            .live_fn = config.live_fn,
        };

        // Create uinput virtual keyboard
        self.uinput_fd = try createUinput();
        errdefer {
            doIoctl(self.uinput_fd, UI_DEV_DESTROY, 0) catch {};
            posix.close(self.uinput_fd);
        }

        // Scan and grab keyboards
        try self.scanDevices();

        // Hotplug: a node created later is announced rather than polled for.
        const inot_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
        if (inot_fd < 0) return error.InotifyFailed;
        self.inotify_fd = inot_fd;
        if (inotify_add_watch(inot_fd, "/dev/input/", IN_CREATE | IN_ATTRIB) < 0) {
            return error.InotifyFailed;
        }

        return self;
    }

    pub fn deinit(self: *InputHandler) void {
        self.shutdown.store(true, .monotonic);
        if (self.thread) |t| t.join();
        if (self.device_thread) |t| t.join();

        self.ungrabAll();


        if (self.uinput_fd >= 0) {
            doIoctl(self.uinput_fd, UI_DEV_DESTROY, 0) catch {};
            posix.close(self.uinput_fd);
        }
    }

    pub fn start(self: *InputHandler) !void {
        self.thread = try std.Thread.spawn(.{}, eventLoop, .{self});
        self.device_thread = try std.Thread.spawn(.{}, deviceLoop, .{self});
    }

    /// Inject text as keystrokes via uinput. Thread-safe.
    ///
    /// The lock is held for the whole transcript, delay between characters
    /// included, because a transcript is one sequence and not a run of
    /// independent characters. A key event means what the modifier state around
    /// it says it means, so a real keystroke landing between two injected ones
    /// is read in the transcript's context and the rest of the transcript in
    /// its: press a shortcut while this is running and the remaining characters
    /// arrive as chords of it. Making a character the unit of exclusion bought
    /// back some latency and paid for it in corruption, which is the wrong way
    /// round. The keyboard is blocked for as long as injection lasts, and that
    /// is the moment just after speaking, when nobody is typing.
    pub fn typeText(self: *InputHandler, text: []const u8) void {
        self.uinput_mutex.lock();
        defer self.uinput_mutex.unlock();

        for (text) |ch| {
            const char_ev = eventsForChar(ch);
            for (char_ev.slice()) |event| {
                self.writeEvent(event);
            }
            if (char_ev.len > 0 and self.type_delay_us > 0) {
                std.Thread.sleep(self.type_delay_us * std.time.ns_per_us);
            }
        }
    }

    /// Type-erased callback for use with server.zig TypeCallback
    pub fn typeTextCallback(ctx: *anyopaque, text: []const u8) void {
        const self: *InputHandler = @ptrCast(@alignCast(ctx));
        self.typeText(text);
    }

    // ──── Private ────

    fn eventLoop(self: *InputHandler) void {
        log.info("input handler thread started", .{});
        defer {
            self.ungrabAll();
            log.info("input handler thread exiting", .{});
        }

        while (!self.shutdown.load(.monotonic)) {
            // Poll every device we hold and have not retired.
            var fds: [MAX_DEVICES]posix.pollfd = undefined;
            var fd_map: [MAX_DEVICES]usize = undefined; // maps poll index → device index
            var nfds: usize = 0;
            {
                self.devices_mutex.lock();
                defer self.devices_mutex.unlock();
                for (self.devices, 0..) |maybe_dev, i| {
                    const dev = maybe_dev orelse continue;
                    if (dev.dead) continue;
                    fds[nfds] = .{ .fd = dev.fd, .events = posix.POLL.IN | posix.POLL.ERR, .revents = 0 };
                    fd_map[nfds] = i;
                    nfds += 1;
                }
            }

            const ready = posix.poll(fds[0..nfds], 200) catch |err| {
                if (err == error.Interrupted) continue;
                log.err("poll failed: {}", .{err});
                break;
            };

            // EVIOCGKEY safety net: verify trigger key is still physically held.
            // Catches lost evdev release events (the PTT-stuck bug).
            if (self.trigger.held and !self.isTriggerPhysicallyHeld()) {
                self.trigger.held = false;
                self.live_fn(false);
                log.warn("trigger key not physically held — forcing release", .{});
            }

            if (ready == 0) continue;

            for (0..nfds) |fi| {
                if (fds[fi].revents == 0) continue;
                const dev_idx = fd_map[fi];

                if (fds[fi].revents & posix.POLL.ERR != 0) {
                    self.retireDevice(dev_idx);
                    continue;
                }

                // Read events
                while (true) {
                    var event: InputEvent = undefined;
                    const n = posix.read(fds[fi].fd, std.mem.asBytes(&event)) catch |err| {
                        if (err == error.WouldBlock) break;
                        self.retireDevice(dev_idx);
                        break;
                    };
                    if (n != @sizeOf(InputEvent)) break;

                    self.processEvent(event);
                }
            }
        }
    }

    /// Everything that opens or closes an evdev node, on a thread that is not
    /// carrying anybody's keystrokes.
    ///
    /// Both cost real time: an open waits on a device that sleeps over USB —
    /// fifty milliseconds, measured — and a close costs an RCU grace period,
    /// ten to seventeen. Put either in `eventLoop` and it lands between a key
    /// and the screen. So `eventLoop` polls, reads and forwards, and this
    /// thread does the rest: it hears about a new node from inotify, waits for
    /// udev to finish with it, grabs it, and closes whatever `eventLoop` has
    /// stopped listening to.
    fn deviceLoop(self: *InputHandler) void {
        log.info("device thread started", .{});
        defer log.info("device thread exiting", .{});

        while (!self.shutdown.load(.monotonic)) {
            self.closeRetired();

            // The timeout is the reaping heartbeat, not a wait on anything:
            // a retired device is closed within 200ms of `eventLoop` marking
            // it, and nothing cares which side of that it happens on.
            var fds = [_]posix.pollfd{.{ .fd = self.inotify_fd, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, 200) catch |err| {
                if (err == error.Interrupted) continue;
                log.err("inotify poll failed: {}", .{err});
                return;
            };
            if (ready == 0) continue;

            self.grabHotplugged();
        }
    }

    fn processEvent(self: *InputHandler, event: InputEvent) void {
        // Only process key events
        if (event.type != EV_KEY) {
            self.forwardEvent(event);
            return;
        }

        // Panic sequence: Enter + Backspace + Escape
        if (self.panic.feed(event.code, event.value != 0)) {
            log.warn("PANIC: Enter+Backspace+Escape — ungrabbing all keyboards", .{});
            self.ungrabAll();
            self.shutdown.store(true, .monotonic);
            return;
        }

        // Trigger key handling
        if (event.code == self.trigger_key) {
            const action = self.trigger.keyEvent(event.value);
            switch (action) {
                .start_recording => {
                    self.live_fn(true);
                    log.info("trigger pressed — live", .{});
                },
                .stop_recording => {
                    self.live_fn(false);
                    log.info("trigger released — stopping", .{});
                },
                .none => {},
            }

            if (self.trigger_passthrough) {
                self.forwardEvent(event);
            }
            return;
        }

        // Forward all other keys
        self.forwardEvent(event);
    }

    fn forwardEvent(self: *InputHandler, event: InputEvent) void {
        self.uinput_mutex.lock();
        defer self.uinput_mutex.unlock();
        self.writeEvent(event);
    }

    fn writeEvent(self: *InputHandler, event: InputEvent) void {
        _ = posix.write(self.uinput_fd, std.mem.asBytes(&event)) catch {};
    }

    // ──── Device management ────

    fn scanDevices(self: *InputHandler) !void {
        var dir = std.fs.openDirAbsolute("/dev/input", .{ .iterate = true }) catch |err| {
            log.err("cannot open /dev/input: {} — is user in 'input' group?", .{err});
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "event")) continue;

            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/{s}", .{entry.name}) catch continue;

            self.tryGrabDevice(path) catch |err| {
                log.debug("skipping {s}: {}", .{ path, err });
            };
        }

        var count: usize = 0;
        for (self.devices) |d| {
            if (d != null) count += 1;
        }
        if (count == 0) {
            log.err("no keyboards found — check /dev/input/ permissions", .{});
            return error.NoKeyboards;
        }
        log.info("grabbed {d} keyboard(s)", .{count});
    }

    /// Open, grab and take ownership of one node. Runs on `deviceLoop`, the
    /// only thread allowed to open an evdev device.
    fn tryGrabDevice(self: *InputHandler, path: [:0]const u8) !void {
        if (self.holdsPath(path)) return error.AlreadyHeld;

        const fd = posix.openZ(path.ptr, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }, 0) catch {
            return error.OpenFailed;
        };
        errdefer posix.close(fd);

        // Check if it's our own virtual device
        var id: InputId = undefined;
        doIoctl(fd, EVIOCGID, @intFromPtr(&id)) catch return error.NotKeyboard;
        if (id.vendor == VIRTUAL_VENDOR) return error.VirtualDevice;

        // Check keyboard capability (must have letter keys)
        if (!isKeyboard(fd)) return error.NotKeyboard;

        // Get device name
        var name: [64]u8 = std.mem.zeroes([64]u8);
        doIoctl(fd, EVIOCGNAME(64), @intFromPtr(&name)) catch {};

        var name_len: usize = 0;
        for (name) |ch| {
            if (ch == 0) break;
            name_len += 1;
        }

        // Grab whatever the keys are doing. Declining a keyboard because
        // someone is leaning on it loses that keyboard for good, which is a
        // far worse outcome than the latched key `releaseHeldKeys` repairs.
        doIoctl(fd, EVIOCGRAB, 1) catch return error.GrabFailed;

        // Drain pending events
        var drain_buf: InputEvent = undefined;
        while (true) {
            _ = posix.read(fd, std.mem.asBytes(&drain_buf)) catch break;
        }

        self.releaseHeldKeys(fd, name[0..name_len]);

        var path_store: [64]u8 = std.mem.zeroes([64]u8);
        @memcpy(path_store[0..path.len], path);

        // Publish it. The lock covers the slot and nothing else: the open,
        // the grab and the drain above are all done by now.
        const stored = stored: {
            self.devices_mutex.lock();
            defer self.devices_mutex.unlock();
            for (&self.devices) |*slot| {
                if (slot.* != null) continue;
                slot.* = .{
                    .fd = fd,
                    .grabbed = true,
                    .name = name,
                    .name_len = name_len,
                    .path = path_store,
                    .path_len = path.len,
                };
                break :stored true;
            }
            break :stored false;
        };
        if (!stored) {
            doIoctl(fd, EVIOCGRAB, 0) catch {};
            return error.NoDeviceSlots; // errdefer closes the fd
        }
        log.info("grabbed: {s}", .{name[0..name_len]});
    }

    fn holdsPath(self: *InputHandler, path: []const u8) bool {
        self.devices_mutex.lock();
        defer self.devices_mutex.unlock();
        return findDeviceByPath(&self.devices, path) != null;
    }

    /// Say, on the virtual keyboard, that every key the device reports as held
    /// has come up.
    ///
    /// Grabbing mid-press splits a keypress in two: the press reached the
    /// desktop from the real device, and everything after the grab arrives
    /// from ours instead — with the trigger key's release swallowed outright
    /// when passthrough is off. Left alone that is a modifier stuck down until
    /// the user works out to tap it again, so send the releases ourselves.
    fn releaseHeldKeys(self: *InputHandler, fd: posix.fd_t, name: []const u8) void {
        const state_size = (KEY_MAX + 7) / 8 + 1;
        var state: [state_size]u8 = std.mem.zeroes([state_size]u8);
        doIoctl(fd, EVIOCGKEY(state_size), @intFromPtr(&state)) catch return;

        // These go to the same virtual keyboard a transcript is typed on, so
        // they take the same lock: half a released modifier in the middle of an
        // injected character is its own bug.
        self.uinput_mutex.lock();
        defer self.uinput_mutex.unlock();

        var released: usize = 0;
        for (0..KEY_MAX + 1) |code| {
            if (!hasKeyBit(&state, @intCast(code))) continue;
            self.writeEvent(InputEvent.key(@intCast(code), 0));
            released += 1;
        }
        if (released == 0) return;

        self.writeEvent(InputEvent.syn());
        log.info("released {d} key(s) held while grabbing {s}", .{ released, name });
    }

    /// Grab every keyboard inotify has just told us about.
    ///
    /// The node exists before it can be opened: devtmpfs creates it root-owned
    /// and udev chowns it to the `input` group afterwards, so the grab that
    /// IN_CREATE prompts gets EACCES. That chown is itself an inotify event —
    /// measured here, IN_CREATE and its open failing at 0.1ms, then IN_ATTRIB
    /// at 73ms and the open succeeding — so the wait needs no guess at how long
    /// udev takes. We simply try again each time the node's attributes change,
    /// and one of those times the permissions are ours. A failed open costs an
    /// EACCES and nothing else, and `holdsPath` makes a repeat attempt on a
    /// device we already hold free.
    fn grabHotplugged(self: *InputHandler) void {
        var buf: [4096]u8 = undefined;
        const n = posix.read(self.inotify_fd, &buf) catch return;

        var offset: usize = 0;
        while (offset + @sizeOf(InotifyEvent) <= n) {
            const inot: *const InotifyEvent = @ptrCast(@alignCast(buf[offset..].ptr));
            const name_start = offset + @sizeOf(InotifyEvent);
            offset += @sizeOf(InotifyEvent) + inot.len;

            if (inot.len == 0) continue;
            const name = std.mem.sliceTo(buf[name_start .. name_start + inot.len], 0);
            if (!std.mem.startsWith(u8, name, "event")) continue;

            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/{s}", .{name}) catch continue;
            self.tryGrabDevice(path) catch |err| {
                log.debug("skipping {s}: {}", .{ path, err });
            };
        }
    }

    /// Stop polling a device that has stopped answering. Called from
    /// `eventLoop`, so it must not close anything: it says the device is done
    /// with and leaves the fd for `deviceLoop` to close.
    fn retireDevice(self: *InputHandler, idx: usize) void {
        {
            self.devices_mutex.lock();
            defer self.devices_mutex.unlock();
            if (self.devices[idx]) |*dev| {
                if (dev.dead) return;
                dev.dead = true;
            } else return;
        }

        // If the trigger was held on that device, nothing will report its release.
        if (self.trigger.held and !self.isTriggerPhysicallyHeld()) {
            self.trigger.held = false;
            self.live_fn(false);
            log.warn("trigger device removed — forcing release", .{});
        }
    }

    /// Close the devices `eventLoop` has retired. Runs on `deviceLoop`.
    fn closeRetired(self: *InputHandler) void {
        var doomed: [MAX_DEVICES]GrabbedDevice = undefined;
        var count: usize = 0;

        {
            self.devices_mutex.lock();
            defer self.devices_mutex.unlock();
            for (&self.devices) |*slot| {
                const dev = slot.* orelse continue;
                if (!dev.dead) continue;
                doomed[count] = dev;
                count += 1;
                slot.* = null;
            }
        }

        for (doomed[0..count]) |dev| {
            if (dev.grabbed) doIoctl(dev.fd, EVIOCGRAB, 0) catch {};
            posix.close(dev.fd);
            log.info("device removed: {s}", .{dev.name[0..dev.name_len]});
        }
    }

    /// Check if the trigger key is physically held on any grabbed device
    /// using the EVIOCGKEY ioctl (reads kernel key state, not event stream).
    fn isTriggerPhysicallyHeld(self: *InputHandler) bool {
        self.devices_mutex.lock();
        defer self.devices_mutex.unlock();

        const state_size = (KEY_MAX + 7) / 8 + 1;
        for (self.devices) |maybe_dev| {
            const dev = maybe_dev orelse continue;
            if (dev.dead) continue;
            var state: [state_size]u8 = std.mem.zeroes([state_size]u8);
            doIoctl(dev.fd, EVIOCGKEY(state_size), @intFromPtr(&state)) catch continue;
            if (hasKeyBit(&state, self.trigger_key)) return true;
        }
        return false;
    }

    fn ungrabAll(self: *InputHandler) void {
        self.devices_mutex.lock();
        defer self.devices_mutex.unlock();

        for (&self.devices) |*slot| {
            if (slot.*) |*dev| {
                if (dev.grabbed) {
                    doIoctl(dev.fd, EVIOCGRAB, 0) catch {};
                    dev.grabbed = false;
                    log.info("ungrabbed: {s}", .{dev.name[0..dev.name_len]});
                }
            }
        }
    }

};

// ──── Standalone helpers ────

fn createUinput() !posix.fd_t {
    const fd = posix.openZ("/dev/uinput", .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |err| {
        log.err("cannot open /dev/uinput: {} — is user in 'input' group? udev rule set?", .{err});
        return err;
    };
    errdefer posix.close(fd);

    // Register event types.
    //
    // Deliberately not EV_REP. A device that declares it gets autorepeat from
    // the kernel, and the grabbed keyboard already has its own: its repeats
    // arrive here as EV_KEY value 2 and are forwarded like any other event. Ask
    // for both and the desktop sees each repeat twice — measured as pairs
    // 0.1ms apart on a 34ms cadence — so a held key doubles every character it
    // produces and a held shortcut fires twice as often.
    try doIoctl(fd, UI_SET_EVBIT, EV_SYN);
    try doIoctl(fd, UI_SET_EVBIT, EV_KEY);
    try doIoctl(fd, UI_SET_EVBIT, EV_LED);

    // Register all key codes
    var keycode: u32 = 0;
    while (keycode <= KEY_MAX) : (keycode += 1) {
        try doIoctl(fd, UI_SET_KEYBIT, keycode);
    }

    // Register LED bits
    try doIoctl(fd, UI_SET_LEDBIT, ev.LED_NUML);
    try doIoctl(fd, UI_SET_LEDBIT, ev.LED_CAPSL);
    try doIoctl(fd, UI_SET_LEDBIT, ev.LED_SCROLLL);

    // Device metadata
    var setup: UinputSetup = std.mem.zeroes(UinputSetup);
    const name = "capsper";
    @memcpy(setup.name[0..name.len], name);
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = VIRTUAL_VENDOR;
    setup.id.product = 0x0ADE;
    setup.id.version = 1;

    try doIoctl(fd, UI_DEV_SETUP, @intFromPtr(&setup));
    try doIoctl(fd, UI_DEV_CREATE, 0);

    // Let device settle
    std.Thread.sleep(200 * std.time.ns_per_ms);

    log.info("created uinput virtual keyboard", .{});
    return fd;
}

fn isKeyboard(fd: posix.fd_t) bool {
    const bitmask_size = (KEY_MAX + 7) / 8 + 1;
    var keymask: [bitmask_size]u8 = std.mem.zeroes([bitmask_size]u8);
    doIoctl(fd, EVIOCGBIT(EV_KEY, bitmask_size), @intFromPtr(&keymask)) catch return false;
    return isKeyboardBitmask(&keymask);
}

/// Parse a trigger key name to a Linux keycode
pub fn parseTriggerKey(name: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(name, "capslock")) return ev.KEY_CAPSLOCK;
    if (std.ascii.eqlIgnoreCase(name, "scrolllock")) return ev.KEY_SCROLLLOCK;
    if (std.ascii.eqlIgnoreCase(name, "numlock")) return ev.KEY_NUMLOCK;
    if (std.ascii.eqlIgnoreCase(name, "pause")) return ev.KEY_PAUSE;
    if (std.ascii.eqlIgnoreCase(name, "f13")) return ev.KEY_F13;
    if (std.ascii.eqlIgnoreCase(name, "f14")) return ev.KEY_F14;
    if (std.ascii.eqlIgnoreCase(name, "f15")) return ev.KEY_F15;
    if (std.ascii.eqlIgnoreCase(name, "f16")) return ev.KEY_F16;
    if (std.ascii.eqlIgnoreCase(name, "f17")) return ev.KEY_F17;
    if (std.ascii.eqlIgnoreCase(name, "f18")) return ev.KEY_F18;
    if (std.ascii.eqlIgnoreCase(name, "f19")) return ev.KEY_F19;
    if (std.ascii.eqlIgnoreCase(name, "f20")) return ev.KEY_F20;
    if (std.ascii.eqlIgnoreCase(name, "f21")) return ev.KEY_F21;
    if (std.ascii.eqlIgnoreCase(name, "f22")) return ev.KEY_F22;
    if (std.ascii.eqlIgnoreCase(name, "f23")) return ev.KEY_F23;
    if (std.ascii.eqlIgnoreCase(name, "f24")) return ev.KEY_F24;
    return null;
}

// ──── Tests ────

test "ascii_map covers printable ASCII" {
    for (32..127) |i| {
        const ch: u8 = @intCast(i);
        try std.testing.expect(ascii_map[ch] != null);
    }
}

test "ascii_map shift correctness" {
    // Lowercase letters: no shift
    try std.testing.expect(!ascii_map['a'].?.shift);
    try std.testing.expect(!ascii_map['z'].?.shift);
    // Uppercase letters: shift
    try std.testing.expect(ascii_map['A'].?.shift);
    try std.testing.expect(ascii_map['Z'].?.shift);
    // Digits: no shift
    try std.testing.expect(!ascii_map['0'].?.shift);
    try std.testing.expect(!ascii_map['9'].?.shift);
    // Symbols that need shift
    try std.testing.expect(ascii_map['!'].?.shift);
    try std.testing.expect(ascii_map['@'].?.shift);
    try std.testing.expect(ascii_map['?'].?.shift);
    // Symbols without shift
    try std.testing.expect(!ascii_map['-'].?.shift);
    try std.testing.expect(!ascii_map['='].?.shift);
    try std.testing.expect(!ascii_map['.'].?.shift);
}

test "ascii_map case pair consistency" {
    // For every a-z, uppercase uses same keycode but with shift
    for ('a'..'z' + 1) |i| {
        const lower: u8 = @intCast(i);
        const upper: u8 = lower - 32; // ASCII offset
        const lower_map = ascii_map[lower].?;
        const upper_map = ascii_map[upper].?;
        try std.testing.expectEqual(lower_map.code, upper_map.code);
        try std.testing.expect(!lower_map.shift);
        try std.testing.expect(upper_map.shift);
    }
}

test "ascii_map digit/symbol pairs share keycodes" {
    // Each digit key produces the digit unshifted and a symbol shifted
    const pairs = .{
        .{ '1', '!' }, .{ '2', '@' }, .{ '3', '#' }, .{ '4', '$' },
        .{ '5', '%' }, .{ '6', '^' }, .{ '7', '&' }, .{ '8', '*' },
        .{ '9', '(' }, .{ '0', ')' },
    };
    inline for (pairs) |pair| {
        const digit_map = ascii_map[pair[0]].?;
        const symbol_map = ascii_map[pair[1]].?;
        try std.testing.expectEqual(digit_map.code, symbol_map.code);
        try std.testing.expect(!digit_map.shift);
        try std.testing.expect(symbol_map.shift);
    }
}

test "ascii_map punctuation pairs share keycodes" {
    // Unshifted/shifted punctuation pairs
    const pairs = .{
        .{ '-', '_' }, .{ '=', '+' }, .{ '[', '{' }, .{ ']', '}' },
        .{ '\\', '|' }, .{ ';', ':' }, .{ '\'', '"' }, .{ ',', '<' },
        .{ '.', '>' }, .{ '/', '?' }, .{ '`', '~' },
    };
    inline for (pairs) |pair| {
        const unshifted = ascii_map[pair[0]].?;
        const shifted = ascii_map[pair[1]].?;
        try std.testing.expectEqual(unshifted.code, shifted.code);
        try std.testing.expect(!unshifted.shift);
        try std.testing.expect(shifted.shift);
    }
}

test "ascii_map no mapping for control chars" {
    // Only tab and newline should have mappings in 0..31
    for (0..32) |i| {
        const ch: u8 = @intCast(i);
        if (ch == '\t' or ch == '\n') {
            try std.testing.expect(ascii_map[ch] != null);
        } else {
            try std.testing.expect(ascii_map[ch] == null);
        }
    }
    // DEL (127) has no mapping
    try std.testing.expect(ascii_map[127] == null);
}

test "parseTriggerKey" {
    try std.testing.expectEqual(ev.KEY_CAPSLOCK, parseTriggerKey("capslock").?);
    try std.testing.expectEqual(ev.KEY_CAPSLOCK, parseTriggerKey("CapsLock").?);
    try std.testing.expectEqual(ev.KEY_F24, parseTriggerKey("f24").?);
    try std.testing.expectEqual(ev.KEY_F21, parseTriggerKey("f21").?);
    try std.testing.expectEqual(ev.KEY_F22, parseTriggerKey("f22").?);
    try std.testing.expectEqual(ev.KEY_F23, parseTriggerKey("f23").?);
    try std.testing.expectEqual(ev.KEY_SCROLLLOCK, parseTriggerKey("ScrollLock").?);
    try std.testing.expectEqual(ev.KEY_NUMLOCK, parseTriggerKey("NumLock").?);
    try std.testing.expectEqual(ev.KEY_PAUSE, parseTriggerKey("Pause").?);
    try std.testing.expect(parseTriggerKey("nonexistent") == null);
}

test "InputEvent size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(InputEvent));
}

// ──── PanicDetector tests ────

test "PanicDetector: all three keys triggers panic" {
    var pd = PanicDetector{};
    try std.testing.expect(!pd.feed(ev.KEY_ENTER, true));
    try std.testing.expect(!pd.feed(ev.KEY_BACKSPACE, true));
    try std.testing.expect(pd.feed(ev.KEY_ESC, true)); // all three held
}

test "PanicDetector: order independent" {
    // Any order of the three keys should trigger
    const orders = [_][3]u16{
        .{ ev.KEY_ESC, ev.KEY_ENTER, ev.KEY_BACKSPACE },
        .{ ev.KEY_BACKSPACE, ev.KEY_ESC, ev.KEY_ENTER },
        .{ ev.KEY_ENTER, ev.KEY_ESC, ev.KEY_BACKSPACE },
    };
    for (orders) |order| {
        var pd = PanicDetector{};
        try std.testing.expect(!pd.feed(order[0], true));
        try std.testing.expect(!pd.feed(order[1], true));
        try std.testing.expect(pd.feed(order[2], true));
    }
}

test "PanicDetector: release disarms" {
    var pd = PanicDetector{};
    _ = pd.feed(ev.KEY_ENTER, true);
    _ = pd.feed(ev.KEY_BACKSPACE, true);
    _ = pd.feed(ev.KEY_ENTER, false); // release enter
    try std.testing.expect(!pd.feed(ev.KEY_ESC, true)); // only 2 of 3 held
}

test "PanicDetector: unrelated keys ignored" {
    var pd = PanicDetector{};
    _ = pd.feed(ev.KEY_A, true);
    _ = pd.feed(ev.KEY_B, true);
    _ = pd.feed(ev.KEY_C, true);
    try std.testing.expect(!pd.feed(ev.KEY_D, true));
    // Now press panic keys
    _ = pd.feed(ev.KEY_ENTER, true);
    _ = pd.feed(ev.KEY_BACKSPACE, true);
    try std.testing.expect(pd.feed(ev.KEY_ESC, true));
}

test "PanicDetector: reset clears state" {
    var pd = PanicDetector{};
    _ = pd.feed(ev.KEY_ENTER, true);
    _ = pd.feed(ev.KEY_BACKSPACE, true);
    pd.reset();
    try std.testing.expect(!pd.feed(ev.KEY_ESC, true)); // reset cleared enter+backspace
}

// ──── TriggerState tests ────

test "TriggerState: press starts recording" {
    var ts = TriggerState{};
    try std.testing.expectEqual(TriggerAction.start_recording, ts.keyEvent(1));
    try std.testing.expect(ts.held);
}

test "TriggerState: release stops recording immediately" {
    var ts = TriggerState{};
    _ = ts.keyEvent(1); // press
    try std.testing.expectEqual(TriggerAction.stop_recording, ts.keyEvent(0));
    try std.testing.expect(!ts.held);
}

test "TriggerState: repeat ignored" {
    var ts = TriggerState{};
    _ = ts.keyEvent(1); // press
    try std.testing.expectEqual(TriggerAction.none, ts.keyEvent(2)); // repeat
    try std.testing.expect(ts.held);
}

test "TriggerState: double press is idempotent" {
    var ts = TriggerState{};
    try std.testing.expectEqual(TriggerAction.start_recording, ts.keyEvent(1));
    try std.testing.expectEqual(TriggerAction.none, ts.keyEvent(1)); // already held
}

test "TriggerState: double release is idempotent" {
    var ts = TriggerState{};
    _ = ts.keyEvent(1); // press
    try std.testing.expectEqual(TriggerAction.stop_recording, ts.keyEvent(0));
    try std.testing.expectEqual(TriggerAction.none, ts.keyEvent(0)); // already released
}

test "TriggerState: full press-release-press cycle" {
    var ts = TriggerState{};
    try std.testing.expectEqual(TriggerAction.start_recording, ts.keyEvent(1));
    try std.testing.expectEqual(TriggerAction.stop_recording, ts.keyEvent(0));
    try std.testing.expectEqual(TriggerAction.start_recording, ts.keyEvent(1));
    try std.testing.expect(ts.held);
}

// ──── eventsForChar tests ────

test "eventsForChar: unshifted character produces 4 events" {
    const result = eventsForChar('a');
    try std.testing.expectEqual(@as(u4, 4), result.len);
    // key_down, syn, key_up, syn
    try std.testing.expectEqual(EV_KEY, result.events[0].type);
    try std.testing.expectEqual(@as(i32, 1), result.events[0].value); // down
    try std.testing.expectEqual(EV_SYN, result.events[1].type);
    try std.testing.expectEqual(EV_KEY, result.events[2].type);
    try std.testing.expectEqual(@as(i32, 0), result.events[2].value); // up
    try std.testing.expectEqual(EV_SYN, result.events[3].type);
}

test "eventsForChar: shifted character produces 8 events" {
    const result = eventsForChar('A');
    try std.testing.expectEqual(@as(u4, 8), result.len);
    // shift_down, syn, key_down, syn, key_up, syn, shift_up, syn
    try std.testing.expectEqual(ev.KEY_LEFTSHIFT, result.events[0].code);
    try std.testing.expectEqual(@as(i32, 1), result.events[0].value);
    try std.testing.expectEqual(ev.KEY_LEFTSHIFT, result.events[6].code);
    try std.testing.expectEqual(@as(i32, 0), result.events[6].value);
}

test "eventsForChar: unmapped char produces 0 events" {
    try std.testing.expectEqual(@as(u4, 0), eventsForChar(0).len); // NUL
    try std.testing.expectEqual(@as(u4, 0), eventsForChar(127).len); // DEL
    try std.testing.expectEqual(@as(u4, 0), eventsForChar(128).len); // non-ASCII
    try std.testing.expectEqual(@as(u4, 0), eventsForChar(255).len); // non-ASCII
}

test "eventsForChar: case pairs use same keycode" {
    for ('a'..'z' + 1) |i| {
        const lower: u8 = @intCast(i);
        const upper: u8 = lower - 32;
        const lower_ev = eventsForChar(lower);
        const upper_ev = eventsForChar(upper);
        // Both should have key events at index 0 (lower) or 2 (upper, after shift)
        try std.testing.expectEqual(lower_ev.events[0].code, upper_ev.events[2].code);
    }
}

test "eventsForChar: every event pair ends with SYN" {
    // For every printable ASCII, verify SYN placement
    for (32..127) |i| {
        const ch: u8 = @intCast(i);
        const result = eventsForChar(ch);
        // Every odd-indexed event should be SYN
        var j: u4 = 1;
        while (j < result.len) : (j += 2) {
            try std.testing.expectEqual(EV_SYN, result.events[j].type);
        }
    }
}

test "eventsForChar slice" {
    const result = eventsForChar('x');
    const s = result.slice();
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqual(EV_KEY, s[0].type);
}

// ──── hasKeyBit / isKeyboardBitmask tests ────

test "hasKeyBit: set and unset bits" {
    var mask = [_]u8{ 0b00000101, 0b00000010 };
    try std.testing.expect(hasKeyBit(&mask, 0)); // bit 0 set
    try std.testing.expect(!hasKeyBit(&mask, 1)); // bit 1 not set
    try std.testing.expect(hasKeyBit(&mask, 2)); // bit 2 set
    try std.testing.expect(!hasKeyBit(&mask, 3));
    try std.testing.expect(hasKeyBit(&mask, 9)); // byte 1, bit 1
    try std.testing.expect(!hasKeyBit(&mask, 8)); // byte 1, bit 0
}

test "hasKeyBit: out of bounds returns false" {
    var mask = [_]u8{0xFF};
    try std.testing.expect(!hasKeyBit(&mask, 8)); // only 1 byte = 8 bits
    try std.testing.expect(!hasKeyBit(&mask, 100));
}

test "isKeyboardBitmask: all required keys set" {
    const bitmask_size = (KEY_MAX + 7) / 8 + 1;
    var mask: [bitmask_size]u8 = std.mem.zeroes([bitmask_size]u8);
    // Set all keyboard keys
    const required = [_]u16{
        ev.KEY_1, ev.KEY_2, ev.KEY_3, ev.KEY_4,
        ev.KEY_5, ev.KEY_6, ev.KEY_7, ev.KEY_8,
        ev.KEY_9, ev.KEY_0, ev.KEY_Q, ev.KEY_W,
        ev.KEY_E, ev.KEY_R, ev.KEY_T, ev.KEY_Y,
    };
    for (required) |k| {
        mask[k / 8] |= @as(u8, 1) << @intCast(k % 8);
    }
    try std.testing.expect(isKeyboardBitmask(&mask));
}

test "isKeyboardBitmask: missing one key fails" {
    const bitmask_size = (KEY_MAX + 7) / 8 + 1;
    var mask: [bitmask_size]u8 = std.mem.zeroes([bitmask_size]u8);
    const required = [_]u16{
        ev.KEY_1, ev.KEY_2, ev.KEY_3, ev.KEY_4,
        ev.KEY_5, ev.KEY_6, ev.KEY_7, ev.KEY_8,
        ev.KEY_9, ev.KEY_0, ev.KEY_Q, ev.KEY_W,
        ev.KEY_E, ev.KEY_R, ev.KEY_T, ev.KEY_Y,
    };
    // Set all except KEY_Y
    for (required[0 .. required.len - 1]) |k| {
        mask[k / 8] |= @as(u8, 1) << @intCast(k % 8);
    }
    try std.testing.expect(!isKeyboardBitmask(&mask));
}

test "isKeyboardBitmask: empty mask fails" {
    const bitmask_size = (KEY_MAX + 7) / 8 + 1;
    var mask: [bitmask_size]u8 = std.mem.zeroes([bitmask_size]u8);
    try std.testing.expect(!isKeyboardBitmask(&mask));
}

test "isKeyboardBitmask: short mask fails gracefully" {
    var mask = [_]u8{ 0xFF, 0xFF }; // too short to contain all required keys
    try std.testing.expect(!isKeyboardBitmask(&mask));
}

// ──── ioctl constant verification ────
// Computed values verified against linux/input.h and linux/uinput.h kernel headers.

// ──── findDeviceByPath tests ────

fn testDevice(path: []const u8) GrabbedDevice {
    var dev = GrabbedDevice{
        .fd = -1,
        .grabbed = true,
        .name = std.mem.zeroes([64]u8),
        .name_len = 0,
        .path = std.mem.zeroes([64]u8),
        .path_len = path.len,
    };
    @memcpy(dev.path[0..path.len], path);
    return dev;
}

test "findDeviceByPath: finds a held device" {
    const devices = [_]?GrabbedDevice{ null, testDevice("/dev/input/event23"), null };
    try std.testing.expectEqual(@as(?usize, 1), findDeviceByPath(&devices, "/dev/input/event23"));
}

test "findDeviceByPath: a device we skipped is not held" {
    const devices = [_]?GrabbedDevice{ testDevice("/dev/input/event22"), null };
    try std.testing.expectEqual(@as(?usize, null), findDeviceByPath(&devices, "/dev/input/event23"));
}

test "findDeviceByPath: does not match on a path prefix" {
    // event2 must not shadow event23 — a stale prefix match would leave the
    // real keyboard ungrabbed forever.
    const devices = [_]?GrabbedDevice{testDevice("/dev/input/event2")};
    try std.testing.expectEqual(@as(?usize, null), findDeviceByPath(&devices, "/dev/input/event23"));
}

test "findDeviceByPath: empty device table holds nothing" {
    const devices = [_]?GrabbedDevice{ null, null };
    try std.testing.expectEqual(@as(?usize, null), findDeviceByPath(&devices, "/dev/input/event23"));
}

test "ioctl constants: EVIOCGRAB" {
    try std.testing.expectEqual(@as(u32, 0x40044590), EVIOCGRAB);
}

test "ioctl constants: EVIOCGID" {
    try std.testing.expectEqual(@as(u32, 0x80084502), EVIOCGID);
}

test "ioctl constants: EVIOCGBIT" {
    // EVIOCGBIT(EV_KEY=1, 96)
    try std.testing.expectEqual(@as(u32, 0x80604521), EVIOCGBIT(EV_KEY, 96));
    // EVIOCGBIT(0, 4) — get event type bitmask
    try std.testing.expectEqual(@as(u32, 0x80044520), EVIOCGBIT(0, 4));
}

test "ioctl constants: EVIOCGKEY" {
    try std.testing.expectEqual(@as(u32, 0x80604518), EVIOCGKEY(96));
}

test "ioctl constants: EVIOCGNAME" {
    try std.testing.expectEqual(@as(u32, 0x80404506), EVIOCGNAME(64));
}

test "ioctl constants: UI_SET_EVBIT" {
    try std.testing.expectEqual(@as(u32, 0x40045564), UI_SET_EVBIT);
}

test "ioctl constants: UI_SET_KEYBIT" {
    try std.testing.expectEqual(@as(u32, 0x40045565), UI_SET_KEYBIT);
}

test "ioctl constants: UI_SET_LEDBIT" {
    try std.testing.expectEqual(@as(u32, 0x40045568), UI_SET_LEDBIT);
}

test "ioctl constants: UI_DEV_SETUP" {
    // sizeof(UinputSetup) = 8 (InputId) + 80 (name) + 4 (ff_effects_max) = 92 = 0x5C
    try std.testing.expectEqual(@as(u32, 0x405C5503), UI_DEV_SETUP);
}

test "ioctl constants: UI_DEV_CREATE and UI_DEV_DESTROY" {
    try std.testing.expectEqual(@as(u32, 0x00005501), UI_DEV_CREATE);
    try std.testing.expectEqual(@as(u32, 0x00005502), UI_DEV_DESTROY);
}


// ──── Injection tests ────
//
// These drive a real InputHandler with its uinput fd pointed at a pipe, so the
// stream of events it produces can be read back and checked without a device,
// and without a single keystroke reaching the desktop.

fn noopLive(_: bool) void {}

/// An InputHandler that types into a pipe. Returns it alongside the read end.
fn handlerOnPipe(read_fd: *posix.fd_t, delay_us: u64) !InputHandler {
    const fds = try posix.pipe2(.{ .NONBLOCK = true });
    read_fd.* = fds[0];
    return InputHandler{
        .trigger_key = ev.KEY_CAPSLOCK,
        .trigger_passthrough = false,
        .type_delay_us = delay_us,
        .live_fn = noopLive,
        .uinput_fd = fds[1],
    };
}

/// Drain whatever is readable, returning the events in the order written.
fn drainEvents(read_fd: posix.fd_t, out: []InputEvent) ![]InputEvent {
    var count: usize = 0;
    while (count < out.len) {
        var pfd = [_]posix.pollfd{.{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&pfd, 0) == 0) break;
        const n = try posix.read(read_fd, std.mem.sliceAsBytes(out[count..]));
        if (n == 0) break;
        count += n / @sizeOf(InputEvent);
    }
    return out[0..count];
}

const TypeRunner = struct {
    handler: *InputHandler,
    text: []const u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *TypeRunner) void {
        self.handler.typeText(self.text);
        self.done.store(true, .release);
    }
};

test "a forwarded keystroke never lands inside an injected transcript" {
    var read_fd: posix.fd_t = undefined;
    var handler = try handlerOnPipe(&read_fd, 5_000);
    defer {
        posix.close(handler.uinput_fd);
        posix.close(read_fd);
    }

    const text = "hello world";
    var runner = TypeRunner{ .handler = &handler, .text = text };
    const typing = try std.Thread.spawn(.{}, TypeRunner.run, .{&runner});

    // Wait until the first character is on the wire. The transcript is then
    // certainly in progress — eleven characters at 5ms each leaves 50ms of it
    // to go — so the keystroke below is one pressed mid-transcript, which is
    // the case the lock exists for.
    while (true) {
        var pfd = [_]posix.pollfd{.{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&pfd, 100) != 0) break;
    }

    // A key the ASCII map can never produce, so it is unmistakable in the stream.
    handler.forwardEvent(InputEvent.key(ev.KEY_F24, 1));
    typing.join();

    var buf: [512]InputEvent = undefined;
    const events = try drainEvents(read_fd, &buf);

    // The injected run must be unbroken: nothing between its first and last
    // event may be the forwarded key.
    var first: ?usize = null;
    var last: usize = 0;
    for (events, 0..) |e, i| {
        if (e.code == ev.KEY_F24) continue;
        if (first == null) first = i;
        last = i;
    }
    try std.testing.expect(first != null);
    for (events[first.?..last]) |e| {
        try std.testing.expect(e.code != ev.KEY_F24);
    }

    // And the whole transcript must be there: a release cannot truncate it.
    var expected: [512]InputEvent = undefined;
    var n: usize = 0;
    for (text) |ch| {
        for (eventsForChar(ch).slice()) |e| {
            expected[n] = e;
            n += 1;
        }
    }
    const injected = events[first.? .. last + 1];
    try std.testing.expectEqual(n, injected.len);
    for (expected[0..n], injected) |want, got| {
        try std.testing.expectEqual(want.type, got.type);
        try std.testing.expectEqual(want.code, got.code);
        try std.testing.expectEqual(want.value, got.value);
    }
}

test "the virtual keyboard does not repeat keys of its own accord" {
    // Needs /dev/uinput; where there is none there is nothing to assert.
    const fd = createUinput() catch return error.SkipZigTest;
    defer {
        doIoctl(fd, UI_DEV_DESTROY, 0) catch {};
        posix.close(fd);
    }

    var sys: [64]u8 = std.mem.zeroes([64]u8);
    try doIoctl(fd, UI_GET_SYSNAME(64), @intFromPtr(&sys));

    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/sys/class/input/{s}/capabilities/ev", .{std.mem.sliceTo(&sys, 0)});
    var caps_buf: [64]u8 = undefined;
    const caps = std.mem.trim(u8, try std.fs.cwd().readFile(path, &caps_buf), " \n");
    const mask = try std.fmt.parseInt(u64, caps, 16);

    // EV_REP asks the kernel to autorepeat this device. The grabbed keyboard's
    // own repeats are already forwarded through it, so setting it here delivers
    // every repeat twice.
    try std.testing.expectEqual(@as(u64, 0), mask & (@as(u64, 1) << @intCast(EV_REP)));
}

test "a dead device is handed to the device thread, not closed on the event loop" {
    var read_fd: posix.fd_t = undefined;
    var handler = try handlerOnPipe(&read_fd, 0);
    defer {
        posix.close(handler.uinput_fd);
        posix.close(read_fd);
    }

    // A device whose fd is a pipe we own, so nothing here touches a real one.
    const device = try posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(device[1]);
    handler.devices[0] = .{
        .fd = device[0],
        .grabbed = false, // no EVIOCGRAB to undo on a pipe
        .name = std.mem.zeroes([64]u8),
        .name_len = 0,
        .path = std.mem.zeroes([64]u8),
        .path_len = 0,
    };

    // The event loop only ever marks it. The fd must still be open afterwards,
    // because closing one costs an RCU grace period on the keystroke path.
    handler.retireDevice(0);
    try std.testing.expect(handler.devices[0] != null);
    try std.testing.expect(handler.devices[0].?.dead);
    var probe: [1]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(device[0], &probe));

    // The device thread is what actually closes it and frees the slot.
    handler.closeRetired();
    try std.testing.expect(handler.devices[0] == null);
    try std.testing.expectError(error.NotOpenForReading, posix.read(device[0], &probe));
}
