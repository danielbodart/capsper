const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("input_macos.zig")
else
    @import("input.zig");

pub const InputHandler = impl.InputHandler;
pub const parseTriggerKey = impl.parseTriggerKey;
