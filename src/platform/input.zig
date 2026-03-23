const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("macos/input.zig")
else
    @import("linux/input.zig");

pub const InputHandler = impl.InputHandler;
pub const parseTriggerKey = impl.parseTriggerKey;
