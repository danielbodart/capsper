const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("macos/lid.zig")
else
    @import("linux/lid.zig");

pub const Lid = impl.Lid;
