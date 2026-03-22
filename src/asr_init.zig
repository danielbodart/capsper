/// Platform-specific ASR backend loading.
///
/// On macOS: loads CoreML models (encoder + fused decoder+joint).
/// On Linux: loads ONNX models via onnxruntime (with optional CUDA).
///
/// Returns a BackendState that owns the loaded models and provides
/// a PipelineFactory for creating per-connection pipelines.
const std = @import("std");
const builtin = @import("builtin");
const nemo_mel = @import("nemo_mel.zig");
const tokenizer = @import("tokenizer.zig");
const ContextGraph = @import("context_graph.zig").ContextGraph;
const AsrPipeline = @import("asr_backend.zig").AsrPipeline;
const PipelineFactory = @import("server.zig").PipelineFactory;

const is_macos = builtin.os.tag == .macos;

// Platform-specific imports (only resolved on the target platform)
const coreml_pipeline = if (is_macos) @import("pipeline_coreml.zig") else struct {};
const ort_pipeline = if (!is_macos) @import("nemotron_pipeline.zig") else struct {};
const ort_c = if (!is_macos) @import("ort_c.zig") else struct {};

pub const BackendState = struct {
    allocator: std.mem.Allocator,
    verbose: bool,

    // Shared resources
    filterbank: []const f32,
    token_map: *tokenizer.TokenMap,
    context_graph: ?*const ContextGraph,

    // Platform-specific state (only one is active, other is zero-initialized)
    coreml_models: if (is_macos) *coreml_pipeline.CapsperCoreMLModels else void,
    ort_api: if (!is_macos) *const ort_c.OrtApi else void,
    ort_env: if (!is_macos) *ort_c.OrtEnv else void,
    ort_enc_session: if (!is_macos) *ort_c.OrtSession else void,
    ort_dec_session: if (!is_macos) *ort_c.OrtSession else void,
    ort_mem_info: if (!is_macos) *ort_c.OrtMemoryInfo else void,
    ort_session_opts: if (!is_macos) *ort_c.OrtSessionOptions else void,

    pub fn factory(self: *BackendState) PipelineFactory {
        return .{ .ctx = self, .createFn = createPipeline };
    }

    fn createPipeline(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!AsrPipeline {
        const self: *BackendState = @ptrCast(@alignCast(ctx));
        if (is_macos) {
            const config = coreml_pipeline.CoreMLConfig{
                .models = self.coreml_models,
                .filterbank = self.filterbank,
                .token_map = self.token_map,
                .context_graph = self.context_graph,
            };
            var p = try alloc.create(coreml_pipeline.CoreMLPipeline);
            p.* = try coreml_pipeline.CoreMLPipeline.init(alloc, config, self.verbose);
            return p.asrPipeline();
        } else {
            const config = ort_pipeline.NemotronConfig{
                .api = self.ort_api,
                .enc_session = self.ort_enc_session,
                .dec_session = self.ort_dec_session,
                .mem_info = self.ort_mem_info,
                .filterbank = self.filterbank,
                .token_map = self.token_map,
                .context_graph = self.context_graph,
            };
            var p = try alloc.create(ort_pipeline.NemotronPipeline);
            p.* = try ort_pipeline.NemotronPipeline.init(alloc, config, self.verbose);
            return p.asrPipeline();
        }
    }

    pub fn deinit(self: *BackendState) void {
        if (is_macos) {
            const release = @extern(*const fn (*coreml_pipeline.CapsperCoreMLModels) callconv(.c) void, .{ .name = "capsper_coreml_release" });
            release(self.coreml_models);
        } else {
            const api = self.ort_api;
            api.ReleaseSessionOptions.?(self.ort_session_opts);
            api.ReleaseSession.?(self.ort_dec_session);
            api.ReleaseSession.?(self.ort_enc_session);
            api.ReleaseMemoryInfo.?(self.ort_mem_info);
            api.ReleaseEnv.?(self.ort_env);
        }
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    model_path: [:0]const u8,
    filterbank: []const f32,
    token_map: *tokenizer.TokenMap,
    context_graph: ?*const ContextGraph,
    no_cuda: bool,
    verbose: bool,
) ?*BackendState {
    const state = allocator.create(BackendState) catch {
        std.debug.print("Failed to allocate backend state\n", .{});
        return null;
    };
    state.* = .{
        .allocator = allocator,
        .verbose = verbose,
        .filterbank = filterbank,
        .token_map = token_map,
        .context_graph = context_graph,
        .coreml_models = if (is_macos) undefined else {},
        .ort_api = if (!is_macos) undefined else {},
        .ort_env = if (!is_macos) undefined else {},
        .ort_enc_session = if (!is_macos) undefined else {},
        .ort_dec_session = if (!is_macos) undefined else {},
        .ort_mem_info = if (!is_macos) undefined else {},
        .ort_session_opts = if (!is_macos) undefined else {},
    };

    if (is_macos) {
        const coreml_load = @extern(*const fn ([*:0]const u8) callconv(.c) ?*coreml_pipeline.CapsperCoreMLModels, .{ .name = "capsper_coreml_load" });
        const coreml_path = std.fs.path.joinZ(allocator, &.{ model_path, "../nemotron-coreml" }) catch {
            std.debug.print("Failed to build CoreML model path\n", .{});
            allocator.destroy(state);
            return null;
        };
        defer allocator.free(coreml_path);
        state.coreml_models = coreml_load(coreml_path.ptr) orelse {
            std.debug.print("Failed to load CoreML models\n", .{});
            allocator.destroy(state);
            return null;
        };
        std.debug.print("Nemotron: using CoreML (ANE + CPU)\n", .{});
    } else {
        const api = ort_c.getApi();
        state.ort_api = api;

        var env: ?*ort_c.OrtEnv = null;
        ort_c.check(api, api.CreateEnv.?(ort_c.ORT_LOGGING_LEVEL_WARNING, "nemotron", @ptrCast(&env))) catch {
            std.debug.print("Failed to create ORT environment\n", .{});
            allocator.destroy(state);
            return null;
        };
        state.ort_env = env.?;

        var opts: ?*ort_c.OrtSessionOptions = null;
        ort_c.check(api, api.CreateSessionOptions.?(&opts)) catch {
            std.debug.print("Failed to create ORT session options\n", .{});
            allocator.destroy(state);
            return null;
        };
        state.ort_session_opts = opts.?;

        if (no_cuda) {
            std.debug.print("Nemotron: using CPU (--no-cuda)\n", .{});
        } else {
            var cuda_opts: ort_c.OrtCUDAProviderOptions = std.mem.zeroes(ort_c.OrtCUDAProviderOptions);
            const cuda_status = api.SessionOptionsAppendExecutionProvider_CUDA.?(opts.?, &cuda_opts);
            if (cuda_status) |s| {
                api.ReleaseStatus.?(s);
                std.debug.print("Nemotron: using CPU\n", .{});
            } else {
                std.debug.print("Nemotron: using CUDA\n", .{});
            }
        }

        const enc_path = std.fs.path.joinZ(allocator, &.{ model_path, "encoder_model.onnx" }) catch {
            std.debug.print("Failed to build encoder path\n", .{});
            allocator.destroy(state);
            return null;
        };
        defer allocator.free(enc_path);
        var enc: ?*ort_c.OrtSession = null;
        ort_c.check(api, api.CreateSession.?(env.?, enc_path.ptr, opts.?, @ptrCast(&enc))) catch {
            std.debug.print("Failed to load encoder ONNX model\n", .{});
            allocator.destroy(state);
            return null;
        };
        state.ort_enc_session = enc.?;

        const dec_path = std.fs.path.joinZ(allocator, &.{ model_path, "decoder_model.onnx" }) catch {
            std.debug.print("Failed to build decoder path\n", .{});
            allocator.destroy(state);
            return null;
        };
        defer allocator.free(dec_path);
        var dec: ?*ort_c.OrtSession = null;
        ort_c.check(api, api.CreateSession.?(env.?, dec_path.ptr, opts.?, @ptrCast(&dec))) catch {
            std.debug.print("Failed to load decoder ONNX model\n", .{});
            allocator.destroy(state);
            return null;
        };
        state.ort_dec_session = dec.?;

        var mem: ?*ort_c.OrtMemoryInfo = null;
        ort_c.check(api, api.CreateCpuMemoryInfo.?(0, 0, @ptrCast(&mem))) catch {
            std.debug.print("Failed to create ORT memory info\n", .{});
            allocator.destroy(state);
            return null;
        };
        state.ort_mem_info = mem.?;
    }

    std.debug.print("Nemotron model loaded successfully\n", .{});
    return state;
}
