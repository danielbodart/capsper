/// Comptime-resolved backend initialization.
const build_options = @import("build_options");

const backend_init = switch (build_options.backend) {
    .coreml => @import("coreml/init.zig"),
    .ort_cuda, .ort_cpu => @import("ort/init.zig"),
};

pub const BackendState = backend_init.BackendState;
pub const load = backend_init.load;
