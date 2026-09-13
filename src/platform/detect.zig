const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("macos/detect.zig")
else
    @import("linux/detect.zig");

pub const detectChannel = impl.detectChannel;
pub const listSources = impl.listSources;
