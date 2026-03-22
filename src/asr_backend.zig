/// ASR backend — thin re-export of NemotronPipeline types.
///
/// Previously this was a tagged union dispatching between whisper and nemotron.
/// Now there is only one backend (Nemotron RNNT), so this module just re-exports
/// the relevant types for use by main.zig and server.zig.
const nemotron = @import("nemotron_pipeline.zig");

pub const AsrConfig = nemotron.NemotronConfig;
pub const AsrPipeline = nemotron.NemotronPipeline;
pub const TranscribeResult = @import("asr_types.zig").TranscribeResult;
