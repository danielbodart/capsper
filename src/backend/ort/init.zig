/// ONNX Runtime backend loading (Linux CUDA + CPU).
/// Loads encoder + decoder ONNX models via onnxruntime C API.
const std = @import("std");
const build_options = @import("build_options");
const tokenizer = @import("../../shared/tokenizer.zig");
const ContextGraph = @import("../../shared/context_graph.zig").ContextGraph;
const ort_c = @import("ort_c.zig");
const pipeline_mod = @import("pipeline.zig");
const Pipeline = pipeline_mod.NemotronPipeline;
const Config = pipeline_mod.NemotronConfig;

pub const BackendState = struct {
    allocator: std.mem.Allocator,
    verbose: bool,
    filterbank: []const f32,
    token_map: *tokenizer.TokenMap,
    context_graph: ?*const ContextGraph,
    ort_api: *const ort_c.OrtApi,
    ort_env: *ort_c.OrtEnv,
    ort_enc_session: *ort_c.OrtSession,
    ort_dec_session: *ort_c.OrtSession,
    ort_mem_info: *ort_c.OrtMemoryInfo,
    ort_session_opts: *ort_c.OrtSessionOptions,

    pub fn createPipeline(self: *BackendState, alloc: std.mem.Allocator) !*Pipeline {
        const config = Config{
            .api = self.ort_api,
            .enc_session = self.ort_enc_session,
            .dec_session = self.ort_dec_session,
            .mem_info = self.ort_mem_info,
            .filterbank = self.filterbank,
            .token_map = self.token_map,
            .context_graph = self.context_graph,
        };
        const p = try alloc.create(Pipeline);
        p.* = try Pipeline.init(alloc, config, self.verbose);
        return p;
    }

    pub fn deinit(self: *BackendState) void {
        const api = self.ort_api;
        api.ReleaseSessionOptions.?(self.ort_session_opts);
        api.ReleaseSession.?(self.ort_dec_session);
        api.ReleaseSession.?(self.ort_enc_session);
        api.ReleaseMemoryInfo.?(self.ort_mem_info);
        api.ReleaseEnv.?(self.ort_env);
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    model_path: [:0]const u8,
    filterbank: []const f32,
    token_map: *tokenizer.TokenMap,
    context_graph: ?*const ContextGraph,
    verbose: bool,
) ?*BackendState {
    const state = allocator.create(BackendState) catch {
        std.debug.print("Failed to allocate backend state\n", .{});
        return null;
    };

    const api = ort_c.getApi();

    var env: ?*ort_c.OrtEnv = null;
    ort_c.check(api, api.CreateEnv.?(ort_c.ORT_LOGGING_LEVEL_WARNING, "nemotron", @ptrCast(&env))) catch {
        std.debug.print("Failed to create ORT environment\n", .{});
        allocator.destroy(state);
        return null;
    };

    var opts: ?*ort_c.OrtSessionOptions = null;
    ort_c.check(api, api.CreateSessionOptions.?(&opts)) catch {
        std.debug.print("Failed to create ORT session options\n", .{});
        allocator.destroy(state);
        return null;
    };

    // CUDA configuration based on build variant
    const backend = build_options.backend;
    if (backend == .ort_cuda) {
        var cuda_opts: ort_c.OrtCUDAProviderOptions = std.mem.zeroes(ort_c.OrtCUDAProviderOptions);
        const cuda_status = api.SessionOptionsAppendExecutionProvider_CUDA.?(opts.?, &cuda_opts);
        if (cuda_status) |s| {
            api.ReleaseStatus.?(s);
            std.debug.print("Nemotron: CUDA not available. This binary requires a CUDA-capable GPU.\n", .{});
            api.ReleaseSessionOptions.?(opts.?);
            api.ReleaseEnv.?(env.?);
            allocator.destroy(state);
            return null;
        }
        std.debug.print("Nemotron: using CUDA\n", .{});
    } else {
        std.debug.print("Nemotron: using CPU\n", .{});
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

    var mem: ?*ort_c.OrtMemoryInfo = null;
    ort_c.check(api, api.CreateCpuMemoryInfo.?(0, 0, @ptrCast(&mem))) catch {
        std.debug.print("Failed to create ORT memory info\n", .{});
        allocator.destroy(state);
        return null;
    };

    state.* = .{
        .allocator = allocator,
        .verbose = verbose,
        .filterbank = filterbank,
        .token_map = token_map,
        .context_graph = context_graph,
        .ort_api = api,
        .ort_env = env.?,
        .ort_enc_session = enc.?,
        .ort_dec_session = dec.?,
        .ort_mem_info = mem.?,
        .ort_session_opts = opts.?,
    };
    return state;
}
