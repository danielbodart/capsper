const cimport = @cImport({
    @cInclude("c-api.h");
});

// Config structs
pub const SherpaOnnxOnlineTransducerModelConfig = cimport.SherpaOnnxOnlineTransducerModelConfig;
pub const SherpaOnnxOnlineModelConfig = cimport.SherpaOnnxOnlineModelConfig;
pub const SherpaOnnxFeatureConfig = cimport.SherpaOnnxFeatureConfig;
pub const SherpaOnnxOnlineRecognizerConfig = cimport.SherpaOnnxOnlineRecognizerConfig;

// Opaque types
pub const SherpaOnnxOnlineRecognizer = cimport.SherpaOnnxOnlineRecognizer;
pub const SherpaOnnxOnlineStream = cimport.SherpaOnnxOnlineStream;

// Result
pub const SherpaOnnxOnlineRecognizerResult = cimport.SherpaOnnxOnlineRecognizerResult;

// Recognizer lifecycle
pub const SherpaOnnxCreateOnlineRecognizer = cimport.SherpaOnnxCreateOnlineRecognizer;
pub const SherpaOnnxDestroyOnlineRecognizer = cimport.SherpaOnnxDestroyOnlineRecognizer;

// Stream lifecycle
pub const SherpaOnnxCreateOnlineStream = cimport.SherpaOnnxCreateOnlineStream;
pub const SherpaOnnxDestroyOnlineStream = cimport.SherpaOnnxDestroyOnlineStream;

// Streaming inference
pub const SherpaOnnxOnlineStreamAcceptWaveform = cimport.SherpaOnnxOnlineStreamAcceptWaveform;
pub const SherpaOnnxIsOnlineStreamReady = cimport.SherpaOnnxIsOnlineStreamReady;
pub const SherpaOnnxDecodeOnlineStream = cimport.SherpaOnnxDecodeOnlineStream;

// Results
pub const SherpaOnnxGetOnlineStreamResult = cimport.SherpaOnnxGetOnlineStreamResult;
pub const SherpaOnnxDestroyOnlineRecognizerResult = cimport.SherpaOnnxDestroyOnlineRecognizerResult;

// Stream control
pub const SherpaOnnxOnlineStreamReset = cimport.SherpaOnnxOnlineStreamReset;
pub const SherpaOnnxOnlineStreamInputFinished = cimport.SherpaOnnxOnlineStreamInputFinished;
