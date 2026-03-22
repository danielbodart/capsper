/// Thin Zig wrapper around the onnxruntime C API.
/// Only exposes the subset needed for RNNT inference.
const std = @import("std");

const cimport = @cImport({
    @cInclude("onnxruntime_c_api.h");
});

// Re-export types
pub const OrtApi = cimport.OrtApi;
pub const OrtEnv = cimport.OrtEnv;
pub const OrtSession = cimport.OrtSession;
pub const OrtSessionOptions = cimport.OrtSessionOptions;
pub const OrtRunOptions = cimport.OrtRunOptions;
pub const OrtValue = cimport.OrtValue;
pub const OrtMemoryInfo = cimport.OrtMemoryInfo;
pub const OrtStatus = cimport.OrtStatus;
pub const OrtAllocator = cimport.OrtAllocator;
pub const OrtTensorTypeAndShapeInfo = cimport.OrtTensorTypeAndShapeInfo;

pub const ORT_LOGGING_LEVEL_WARNING = cimport.ORT_LOGGING_LEVEL_WARNING;
pub const ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT = cimport.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
pub const ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32 = cimport.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32;
pub const ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 = cimport.ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
pub const OrtCUDAProviderOptions = cimport.OrtCUDAProviderOptions;

// Entry point
pub const OrtGetApiBase = cimport.OrtGetApiBase;

/// Get the OrtApi for the current version.
pub fn getApi() *const OrtApi {
    const base = OrtGetApiBase();
    return base.*.GetApi.?(cimport.ORT_API_VERSION).?;
}

/// Check an OrtStatus and return an error if non-null.
pub fn check(api: *const OrtApi, status: ?*OrtStatus) !void {
    if (status) |s| {
        const msg = api.GetErrorMessage.?(s);
        if (msg) |m| {
            std.debug.print("ORT error: {s}\n", .{std.mem.span(m)});
        }
        api.ReleaseStatus.?(s);
        return error.OrtError;
    }
}
