// src/input_macos.zig — CGEventTap/CGEventPost input handling (macOS)
//
// Intercepts a trigger key (CapsLock remapped to F19 via hidutil) using
// CGEventTap, signals PTT state via live_fn callback, and injects
// transcribed text as Unicode keyboard events via CGEventPost.
//
// The CGEventTap runs on a dedicated thread with its own CFRunLoop.
// Text injection uses CGEventKeyboardSetUnicodeString which handles
// all Unicode characters directly — no keycode mapping needed.

const std = @import("std");

const log = std.log.scoped(.input);

// C helpers from input_helpers_macos.c
extern fn capsper_input_check_accessibility() c_int;
extern fn capsper_input_request_accessibility() c_int;
extern fn capsper_input_create_tap(trigger_keycode: c_int, on_press: *const fn () callconv(.c) void, on_release: *const fn () callconv(.c) void) c_int;
extern fn capsper_input_run_tap() void;
extern fn capsper_input_stop_tap() void;
extern fn capsper_input_destroy_tap() void;
extern fn capsper_input_tap_is_enabled() c_int;
extern fn capsper_input_type_text(text: [*]const u8, len: c_int) void;
extern fn capsper_input_remap_capslock() c_int;
extern fn capsper_input_restore_capslock() c_int;

// Global state for C callbacks (C can't capture Zig closures)
var g_live_fn: ?*const fn (bool) void = null;
var g_typing_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn onPress() callconv(.c) void {
    log.info("PTT press", .{});
    g_typing_cancel.store(false, .monotonic);
    if (g_live_fn) |f| f(true);
}

fn onRelease() callconv(.c) void {
    log.info("PTT release", .{});
    g_typing_cancel.store(true, .monotonic);
    if (g_live_fn) |f| f(false);
}

pub const InputHandler = struct {
    trigger_key: u16,
    trigger_passthrough: bool,
    type_delay_us: u64,
    thread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    did_remap: bool = false,

    pub const Config = struct {
        trigger_key: u16 = 57, // kVK_CapsLock
        trigger_passthrough: bool = false,
        type_delay_us: u64 = 12_000,
        live_fn: *const fn (bool) void,
    };

    pub fn init(config: Config) !InputHandler {
        g_live_fn = config.live_fn;

        // Ensure Accessibility permission before creating the event tap.
        // If not granted, show the system prompt and poll until the user grants it.
        if (capsper_input_check_accessibility() == 0) {
            log.info("Requesting Accessibility permission...", .{});
            _ = capsper_input_request_accessibility();

            const max_wait_s = 60;
            const poll_interval_ns: u64 = 2 * std.time.ns_per_s;
            var waited: u32 = 0;
            while (waited < max_wait_s) {
                std.Thread.sleep(poll_interval_ns);
                waited += 2;
                if (capsper_input_check_accessibility() != 0) break;
                log.info("Waiting for Accessibility permission... ({d}s)", .{waited});
            }
            if (capsper_input_check_accessibility() == 0) {
                log.err("Accessibility permission not granted after {d}s", .{max_wait_s});
                return error.AccessibilityPermissionDenied;
            }
            log.info("Accessibility permission granted", .{});
        }

        // Remap CapsLock → F19 via hidutil (if trigger is CapsLock)
        var did_remap = false;
        if (config.trigger_key == 57) { // kVK_CapsLock
            if (capsper_input_remap_capslock() == 0) {
                log.info("CapsLock remapped to F19 via hidutil", .{});
                did_remap = true;
            } else {
                log.warn("Failed to remap CapsLock — CapsLock LED will still toggle", .{});
            }
        }

        // The trigger keycode for CGEventTap:
        // If CapsLock was remapped to F19, intercept F19 (keycode 80)
        const tap_keycode: c_int = if (config.trigger_key == 57 and did_remap)
            80 // F19
        else
            @intCast(config.trigger_key);

        if (capsper_input_create_tap(tap_keycode, &onPress, &onRelease) != 0) {
            if (did_remap) _ = capsper_input_restore_capslock();
            return error.AccessibilityPermissionDenied;
        }

        log.info("CGEventTap created (keycode={d})", .{tap_keycode});

        return .{
            .trigger_key = config.trigger_key,
            .trigger_passthrough = config.trigger_passthrough,
            .type_delay_us = config.type_delay_us,
            .did_remap = did_remap,
        };
    }

    pub fn deinit(self: *InputHandler) void {
        self.shutdown.store(true, .monotonic);
        capsper_input_stop_tap();
        if (self.thread) |t| t.join();
        capsper_input_destroy_tap();

        // Restore CapsLock if we remapped it
        if (self.did_remap) {
            _ = capsper_input_restore_capslock();
            log.info("CapsLock remap restored", .{});
        }

        g_live_fn = null;
    }

    pub fn start(self: *InputHandler) !void {
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    fn runLoop(self: *InputHandler) void {
        _ = self;
        log.info("input handler thread started (CFRunLoop)", .{});
        capsper_input_run_tap(); // Blocks until stop_tap() is called
        log.info("input handler thread exiting", .{});
    }

    /// Inject text as Unicode keyboard events via CGEventPost.
    /// Checks typing_cancel between characters — stops on PTT release.
    pub fn typeText(self: *InputHandler, text: []const u8) void {
        _ = self;
        if (text.len == 0) return;

        // Inject the full text at once via CGEventKeyboardSetUnicodeString
        // The C helper handles UTF-8 → UTF-16 conversion and batching (20 chars/event)
        if (g_typing_cancel.load(.monotonic)) return;
        capsper_input_type_text(text.ptr, @intCast(text.len));
    }

    /// Type-erased callback for use with server.zig TypeCallback
    pub fn typeTextCallback(ctx: *anyopaque, text: []const u8) void {
        const self: *InputHandler = @ptrCast(@alignCast(ctx));
        self.typeText(text);
    }
};

/// Parse trigger key name to macOS virtual keycode.
pub fn parseTriggerKey(name: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(name, "capslock")) return 57; // kVK_CapsLock
    if (std.ascii.eqlIgnoreCase(name, "scrolllock")) return 107; // Same as F14 on macOS
    if (std.ascii.eqlIgnoreCase(name, "numlock")) return 71; // kVK_ANSI_KeypadClear
    if (std.ascii.eqlIgnoreCase(name, "f13")) return 105;
    if (std.ascii.eqlIgnoreCase(name, "f14")) return 107;
    if (std.ascii.eqlIgnoreCase(name, "f15")) return 113;
    if (std.ascii.eqlIgnoreCase(name, "f16")) return 106;
    if (std.ascii.eqlIgnoreCase(name, "f17")) return 64;
    if (std.ascii.eqlIgnoreCase(name, "f18")) return 79;
    if (std.ascii.eqlIgnoreCase(name, "f19")) return 80;
    if (std.ascii.eqlIgnoreCase(name, "f20")) return 90;
    return null;
}
