// src/input_macos.zig — CGEventTap/CGEventPost input handling (macOS)
//
// Stub implementation for Phase 1 (Metal validation via --stream-wav).
// Full implementation will follow in Phase 3.

const std = @import("std");

const log = std.log.scoped(.input);

pub const InputHandler = struct {
    trigger_key: u16,

    pub const Config = struct {
        trigger_key: u16,
        trigger_passthrough: bool = false,
        type_delay_us: u64 = 12_000,
        live_fn: *const fn (bool) void,
    };

    pub fn init(_config: Config) !InputHandler {
        _ = _config;
        return error.NotImplemented;
    }

    pub fn deinit(_: *InputHandler) void {}

    pub fn start(_: *InputHandler) !void {
        return error.NotImplemented;
    }

    pub fn typeTextCallback(_ctx: *anyopaque, _text: []const u8) void {
        _ = _ctx;
        _ = _text;
    }
};

/// Parse trigger key name to macOS virtual keycode.
pub fn parseTriggerKey(name: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(name, "capslock")) return 57; // kVK_CapsLock
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
