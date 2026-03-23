/// CoreML backend loading (macOS).
/// Loads encoder + fused decoder+joint CoreML models.
const std = @import("std");
const tokenizer = @import("../../shared/tokenizer.zig");
const ContextGraph = @import("../../shared/context_graph.zig").ContextGraph;
const pipeline_mod = @import("pipeline.zig");
const Pipeline = pipeline_mod.CoreMLPipeline;
const Config = pipeline_mod.CoreMLConfig;

pub const BackendState = struct {
    allocator: std.mem.Allocator,
    verbose: bool,
    filterbank: []const f32,
    token_map: *tokenizer.TokenMap,
    context_graph: ?*const ContextGraph,
    coreml_models: *pipeline_mod.CapsperCoreMLModels,

    pub fn createPipeline(self: *BackendState, alloc: std.mem.Allocator) !*Pipeline {
        const config = Config{
            .models = self.coreml_models,
            .filterbank = self.filterbank,
            .token_map = self.token_map,
            .context_graph = self.context_graph,
        };
        const p = try alloc.create(Pipeline);
        p.* = try Pipeline.init(alloc, config, self.verbose);
        return p;
    }

    pub fn deinit(self: *BackendState) void {
        const release = @extern(*const fn (*pipeline_mod.CapsperCoreMLModels) callconv(.c) void, .{ .name = "capsper_coreml_release" });
        release(self.coreml_models);
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

    const coreml_load = @extern(*const fn ([*:0]const u8) callconv(.c) ?*pipeline_mod.CapsperCoreMLModels, .{ .name = "capsper_coreml_load" });
    const coreml_path = std.fs.path.joinZ(allocator, &.{ model_path, "../nemotron-coreml" }) catch {
        std.debug.print("Failed to build CoreML model path\n", .{});
        allocator.destroy(state);
        return null;
    };
    defer allocator.free(coreml_path);

    state.* = .{
        .allocator = allocator,
        .verbose = verbose,
        .filterbank = filterbank,
        .token_map = token_map,
        .context_graph = context_graph,
        .coreml_models = coreml_load(coreml_path.ptr) orelse {
            std.debug.print("Failed to load CoreML models\n", .{});
            allocator.destroy(state);
            return null;
        },
    };
    std.debug.print("Nemotron: using CoreML (ANE + CPU)\n", .{});
    return state;
}
