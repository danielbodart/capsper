const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("macos/sink.zig")
else
    @import("linux/sink.zig");

pub const VirtualSink = impl.VirtualSink;
pub const SinkWatch = impl.SinkWatch;
pub const EchoCanceller = impl.EchoCanceller;
