const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("macos/audio.zig")
else
    @import("linux/audio.zig");

pub const AudioCapture = impl.AudioCapture;
