const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("macos/mic_level.zig")
else
    @import("linux/mic_level.zig");

pub const MicLevel = impl.MicLevel;
