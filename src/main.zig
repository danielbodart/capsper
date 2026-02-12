const std = @import("std");
const c = @import("whisper_c.zig");
const Vad = @import("vad.zig").Vad;
const Pipeline = @import("pipeline.zig").Pipeline;
const Server = @import("server.zig").Server;
const utils = @import("utils.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    std.debug.print("GPA memory tracking enabled\n", .{});

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var model_path: [:0]const u8 = "whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin";
    var vad_model_path: [:0]const u8 = "whisper.cpp/models/ggml-silero-v5.1.2.bin";
    var port: u16 = 43007;
    var warmup_file: ?[:0]const u8 = "jfk.wav";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i < args.len) model_path = args[i];
        } else if (std.mem.eql(u8, arg, "--vad-model")) {
            i += 1;
            if (i < args.len) vad_model_path = args[i];
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) port = std.fmt.parseInt(u16, args[i], 10) catch 43007;
        } else if (std.mem.eql(u8, arg, "--warmup-file")) {
            i += 1;
            if (i < args.len) warmup_file = args[i];
        } else if (std.mem.eql(u8, arg, "--no-warmup")) {
            warmup_file = null;
        } else {
            std.debug.print("Usage: whisper-dictate [--model PATH] [--vad-model PATH] [--port PORT] [--warmup-file PATH] [--no-warmup]\n", .{});
            return;
        }
    }

    // Load whisper model
    std.debug.print("Loading model: {s}\n", .{model_path});
    var cparams = c.whisper_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = false;
    cparams.dtw_token_timestamps = true;
    cparams.dtw_aheads_preset = c.WHISPER_AHEADS_LARGE_V3_TURBO;

    const ctx = c.whisper_init_from_file_with_params(model_path.ptr, cparams) orelse {
        std.debug.print("Failed to load model\n", .{});
        return;
    };
    defer c.whisper_free(ctx);

    // Load VAD model
    std.debug.print("Loading VAD model: {s}\n", .{vad_model_path});
    var vad = Vad.init(vad_model_path) catch |err| {
        std.debug.print("Failed to init VAD: {}\n", .{err});
        return;
    };
    defer vad.deinit();

    // Warmup
    if (warmup_file) |wf| {
        std.debug.print("Warming up with: {s}\n", .{wf});
        const samples = loadWav(allocator, wf) catch |err| {
            std.debug.print("Warning: warmup file load failed: {}\n", .{err});
            return;
        };
        defer allocator.free(samples);

        var pipeline = try Pipeline.init(allocator, ctx, .{}, 4);
        defer pipeline.deinit();

        if (try pipeline.transcribe(samples, true)) |result| {
            std.debug.print("Warmup result: \"{s}\"\n", .{result.text});
            allocator.free(result.text);
        }
        std.debug.print("Warmup complete\n", .{});
    }

    // Start server
    var server = Server.init(allocator, ctx, vad, port);
    try server.run();
}

pub fn loadWav(allocator: std.mem.Allocator, path: [:0]const u8) ![]f32 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(data);

    const header = try utils.parseWavHeader(data);
    return utils.wavToFloat(allocator, data, header);
}
