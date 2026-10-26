const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("macos/output_duck.zig")
else
    @import("linux/output_duck.zig");

pub const OutputDuck = impl.OutputDuck;
