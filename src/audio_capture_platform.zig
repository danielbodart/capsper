const builtin = @import("builtin");
const impl = if (builtin.os.tag == .macos)
    @import("audio_capture_macos.zig")
else
    @import("audio_capture.zig");

pub const AudioCapture = impl.AudioCapture;
