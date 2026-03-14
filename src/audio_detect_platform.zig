const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("audio_detect_macos.zig")
else
    @import("pw_detect.zig");

pub const detectChannel = impl.detectChannel;
