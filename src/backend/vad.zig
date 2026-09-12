/// Comptime-resolved voice activity gate.
/// build.zig selects the backend; only the active branch is compiled.
const build_options = @import("build_options");

const impl = switch (build_options.backend) {
    .coreml => @import("coreml/vad.zig"),
    .ort_cuda, .ort_cpu => @import("ort/vad.zig"),
};

pub const Vad = impl.Vad;
pub const load = impl.load;
pub const window_ms = impl.window_ms;
