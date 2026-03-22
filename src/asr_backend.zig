/// ASR backend — platform dispatch between CoreML (macOS) and ONNX (Linux).
const builtin = @import("builtin");

const coreml = if (builtin.os.tag == .macos) @import("pipeline_coreml.zig") else struct {};
const nemotron = @import("nemotron_pipeline.zig");

pub const AsrConfig = if (builtin.os.tag == .macos) coreml.CoreMLConfig else nemotron.NemotronConfig;
pub const AsrPipeline = if (builtin.os.tag == .macos) coreml.CoreMLPipeline else nemotron.NemotronPipeline;
pub const TranscribeResult = @import("asr_types.zig").TranscribeResult;
