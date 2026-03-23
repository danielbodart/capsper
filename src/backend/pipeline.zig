/// Comptime-resolved ASR pipeline type.
/// build.zig selects the backend; only the active branch is compiled.
const build_options = @import("build_options");

pub const Pipeline = switch (build_options.backend) {
    .coreml => @import("coreml/pipeline.zig").CoreMLPipeline,
    .ort_cuda, .ort_cpu => @import("ort/pipeline.zig").NemotronPipeline,
};

pub const Config = switch (build_options.backend) {
    .coreml => @import("coreml/pipeline.zig").CoreMLConfig,
    .ort_cuda, .ort_cpu => @import("ort/pipeline.zig").NemotronConfig,
};
