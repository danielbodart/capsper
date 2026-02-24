const std = @import("std");

pub const TenVadNative = struct {
    pub const chunk_bytes: usize = 512; // 256 samples * 2 bytes — same hop as GGML

    const CreateFn = *const fn (*?*anyopaque, usize, f32) callconv(.c) c_int;
    const ProcessFn = *const fn (?*anyopaque, [*]const i16, usize, *f32, *c_int) callconv(.c) c_int;
    const DestroyFn = *const fn (*?*anyopaque) callconv(.c) c_int;

    handle: ?*anyopaque,
    lib: std.DynLib,
    create_fn: CreateFn,
    process_fn: ProcessFn,
    destroy_fn: DestroyFn,

    pub fn init() !TenVadNative {
        var lib = std.DynLib.open("libten_vad.so") catch return error.TenVadNativeLoadFailed;
        errdefer lib.close();

        const create_fn = lib.lookup(CreateFn, "ten_vad_create") orelse return error.TenVadNativeSymbolFailed;
        const process_fn = lib.lookup(ProcessFn, "ten_vad_process") orelse return error.TenVadNativeSymbolFailed;
        const destroy_fn = lib.lookup(DestroyFn, "ten_vad_destroy") orelse return error.TenVadNativeSymbolFailed;

        var handle: ?*anyopaque = null;
        const rc = create_fn(&handle, 256, 0.5);
        if (rc != 0 or handle == null) return error.TenVadNativeInitFailed;

        return .{
            .handle = handle,
            .lib = lib,
            .create_fn = create_fn,
            .process_fn = process_fn,
            .destroy_fn = destroy_fn,
        };
    }

    pub fn deinit(self: *TenVadNative) void {
        _ = self.destroy_fn(&self.handle);
        self.lib.close();
    }

    /// Get speech probability from S16_LE PCM.
    /// Processes 256-sample hops (ten-VAD's native size), returns max prob.
    pub fn chunkProbS16(self: *TenVadNative, chunk: []const u8) f32 {
        const hop_samples = 256;
        const hop_bytes = hop_samples * 2;
        var max_prob: f32 = 0;
        var offset: usize = 0;
        while (offset + hop_bytes <= chunk.len) {
            var i16_buf: [hop_samples]i16 = undefined;
            for (&i16_buf, 0..) |*out, i| {
                out.* = std.mem.readInt(i16, chunk[offset + i * 2 ..][0..2], .little);
            }
            var prob: f32 = 0;
            var flag: c_int = 0;
            _ = self.process_fn(self.handle, &i16_buf, hop_samples, &prob, &flag);
            if (prob > max_prob) max_prob = prob;
            offset += hop_bytes;
        }
        return max_prob;
    }

    pub fn reset(self: *TenVadNative) void {
        // Native library has no reset — destroy and recreate
        _ = self.destroy_fn(&self.handle);
        self.handle = null;
        _ = self.create_fn(&self.handle, 256, 0.5);
    }
};
