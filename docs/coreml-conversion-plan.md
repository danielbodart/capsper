# CoreML Native Conversion Plan

Convert the Nemotron Speech 600M streaming RNNT model from ONNX to native CoreML
for Apple Neural Engine (ANE) execution on macOS.

## Goal

Match the ONNX pipeline exactly: same 560ms chunk size, same model architecture,
same streaming behavior, same numerical accuracy. Apply Apple's ANE transformer
optimizations for maximum Neural Engine utilization.

## Background

ONNX Runtime's CoreML EP only handles 50/2851 ONNX nodes for this model -- the
ORT-to-CoreML op converter can't handle Einsum, dynamic MatMul (both inputs
runtime tensors), or Scatter. Native CoreML via coremltools supports all needed
ops and enables true ANE execution.

FluidInference/mobius has conversion scripts for the same model achieving 1.79%
WER on LibriSpeech test-clean. We're doing our own conversion to: control chunk
size (560ms vs their 1.12s), apply all ANE optimizations, and validate per-layer
numerical accuracy against the PyTorch reference.

---

## Architecture

### Three CoreML Models

| Model | Input Shape | Output Shape | Compute | ANE |
|-------|-------------|--------------|---------|-----|
| Encoder | mel [1,128,65] + caches | encoded [1,1024,7] + caches | CPU_AND_NE | Yes |
| Decoder | token [1,1] + LSTM h,c | prediction [1,640,1] + h,c | CPU_ONLY | No |
| Joint | enc [1,1024,1] + dec [1,640,1] | logits [1,1025] | CPU_ONLY | No |

The mel spectrogram stays in Zig (nemo_mel_state.zig) -- no CoreML preprocessor needed.

### 560ms Chunk Math

- 560ms = 8960 samples at 16kHz
- Mel: hop=160, win=400 -> 56 mel frames per chunk
- Pre-cache: 9 mel frames from previous chunk
- Encoder input: 9 + 56 = 65 mel frames -> [1, 128, 65]
- 8x subsampling -> 7 encoder output frames per chunk
- RNNT greedy decode: up to 10 tokens per encoder frame x 7 frames

### Encoder Cache Shapes (24-layer FastConformer)

| Cache | Shape | Description |
|-------|-------|-------------|
| cache_last_channel | [1, 24, 70, 1024] | Attention left context (att_context_size=70) |
| cache_last_time | [1, 24, 1024, 8] | Convolution time context |
| cache_last_channel_len | [1] | Cache fill level (int32) |

### Decoder State (2-layer LSTM, 640 hidden)

| State | Shape |
|-------|-------|
| lstm_h | [2, 1, 640] |
| lstm_c | [2, 1, 640] |

---

## Phase 1: Python Conversion Pipeline

### 1.1 Environment Setup

```
# In capsper/tools/coreml-convert/
uv init
uv add torch nemo_toolkit[asr] coremltools numpy
```

### 1.2 Load and Inspect Model

```python
import nemo.collections.asr as nemo_asr

model = nemo_asr.models.EncDecRNNTBPEModel.from_pretrained(
    "nvidia/nemotron-speech-streaming-en-0.6b"
)
model.set_export_config({"cache_aware": True})
model.encoder.setup_streaming_params(
    chunk_size=56,           # 560ms at hop=160
    left_chunks=-1,          # unlimited left context (att_context=70 handles window)
    shift_size=56,           # no overlap between chunks
    max_context=70,          # att_context_size left
)
```

### 1.3 Wrapper Classes

Create ANE-optimized wrappers for each component:

**EncoderWrapper:**
- Accepts mel [1, 128, 65] + cache tensors
- Internally applies ANE optimizations (see Phase 2)
- Returns encoded output [1, 1024, 7] + updated caches

**DecoderWrapper:**
- Accepts token [1, 1] + LSTM states
- Returns prediction embedding + updated states

**JointWrapper:**
- Accepts encoder frame + decoder prediction
- Returns logits [1, 1025] (1024 vocab + blank)

### 1.4 Trace and Convert

```python
import coremltools as ct

# Trace each component with torch.jit.trace
traced_encoder = torch.jit.trace(encoder_wrapper, example_encoder_inputs)
traced_decoder = torch.jit.trace(decoder_wrapper, example_decoder_inputs)
traced_joint = torch.jit.trace(joint_wrapper, example_joint_inputs)

# Convert encoder (ANE target)
encoder_ml = ct.convert(
    traced_encoder,
    inputs=[
        ct.TensorType(shape=(1, 128, 65), name="audio_signal"),
        ct.TensorType(shape=(1, 24, 70, 1024), name="cache_last_channel"),
        ct.TensorType(shape=(1, 24, 1024, 8), name="cache_last_time"),
        ct.TensorType(shape=(1,), name="cache_last_channel_len"),
    ],
    compute_units=ct.ComputeUnit.CPU_AND_NE,
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)

# Convert decoder (CPU -- LSTM can't run on ANE)
decoder_ml = ct.convert(
    traced_decoder,
    inputs=[
        ct.TensorType(shape=(1, 1), name="targets"),
        ct.TensorType(shape=(2, 1, 640), name="input_states_1"),
        ct.TensorType(shape=(2, 1, 640), name="input_states_2"),
    ],
    compute_units=ct.ComputeUnit.CPU_ONLY,
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)

# Convert joint (CPU -- tiny model)
joint_ml = ct.convert(
    traced_joint,
    inputs=[
        ct.TensorType(shape=(1, 1024, 1), name="encoder_outputs"),
        ct.TensorType(shape=(1, 640, 1), name="decoder_outputs"),
    ],
    compute_units=ct.ComputeUnit.CPU_ONLY,
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)
```

### 1.5 Per-Layer Numerical Validation

For each component, compare PyTorch vs CoreML on reference audio:

- Max absolute error (target: < 1e-2 for FP16)
- Cosine similarity (target: > 0.999)
- Run on multiple audio samples: short, multi-chunk, silence, loud speech
- Validate cache state accumulation across multiple chunks (not just single-chunk)

### 1.6 End-to-End Transcription Validation

Run full streaming transcription on test/jfk.wav through both pipelines:
- PyTorch (reference)
- CoreML

Output text must be identical or differ only at edge-case token boundaries.

---

## Phase 2: ANE Transformer Optimizations

Applied in the EncoderWrapper before tracing. Based on Apple's "Deploying
Transformers on Apple Neural Engine" paper and ml-ane-transformers reference.

### 2.1 Replace nn.Linear with nn.Conv2d(1x1)

ANE hardware is optimized for convolution. Every Linear layer in the encoder
becomes a 1x1 Conv2d:

```python
# Weight conversion: [out, in] -> [out, in, 1, 1]
for name, param in encoder.named_parameters():
    if 'weight' in name and param.dim() == 2:
        param.data = param.data[:, :, None, None]
```

Applies to: Q/K/V projections, output projections, FFN layers, subsampling.

### 2.2 Channels-First 4D Layout

All tensors reshaped from (B, S, C) to (B, C, 1, S):

- Sequence length in last dimension (ANE requires last axis contiguous)
- Embed dimension in channels dimension
- Singleton "1" in height dimension

### 2.3 Per-Head Attention Split

Split multi-head attention into per-head computations using tensor.split():

```python
dim_per_head = dim // n_heads
mh_q = q.split(dim_per_head, dim=1)  # list of [B, d_h, 1, S]
mh_k = k.transpose(1, 3).split(dim_per_head, dim=3)
mh_v = v.split(dim_per_head, dim=1)
```

Use Apple-recommended einsum patterns:
- Q*K: 'bchq,bkhc->bkhq' (one transpose)
- attn*V: 'bkhq,bchk->bchq' (one transpose)

### 2.4 Precompute Relative Positional Encodings

FastConformer uses relative positional encoding with dynamic gather ops (not
ANE-compatible). Precompute the positional bias tensor for the fixed chunk
size (65 frames) and bake it as a constant.

### 2.5 Numerical Precision

- Layer norm eps: 1e-7 (not 1e-12) for FP16 stability on ANE
- Fixed input shapes only -- no dynamic shapes (guarantees ANE dispatch)

### 2.6 Validation

After each optimization, re-run per-layer numerical validation (Phase 1.5)
to ensure the transformation didn't change model behavior.

---

## Phase 3: Objective-C CoreML Inference Helper

New file: src/coreml_helpers.m

Flat C API callable from Zig:

```c
// Model lifecycle
CapsperCoreMLModels* capsper_coreml_load(const char* model_dir);
void capsper_coreml_release(CapsperCoreMLModels* models);

// Encoder: mel + caches -> encoded + new caches
int capsper_coreml_run_encoder(
    CapsperCoreMLModels* models,
    const void* mel_data,           // [1, 128, 65] float16
    const void* cache_channel,      // [1, 24, 70, 1024]
    const void* cache_time,         // [1, 24, 1024, 8]
    int32_t cache_len,
    void* out_encoded,              // [1, 1024, 7]
    void* out_cache_channel,
    void* out_cache_time,
    int32_t* out_cache_len,
    int32_t* out_encoded_len
);

// Decoder: token + LSTM state -> prediction + new state
int capsper_coreml_run_decoder(
    CapsperCoreMLModels* models,
    int32_t token,
    const void* state_h,            // [2, 1, 640]
    const void* state_c,
    void* out_prediction,           // [1, 640, 1]
    void* out_state_h,
    void* out_state_c
);

// Joint: enc_frame + dec_prediction -> logits
int capsper_coreml_run_joint(
    CapsperCoreMLModels* models,
    const void* encoder_output,     // [1, 1024, 1]
    const void* decoder_output,     // [1, 640, 1]
    float* out_logits               // [1, 1025] -- float32 for argmax precision
);
```

Implementation uses MLModel, MLMultiArray, and MLPredictionOptions.
Model compilation/specialization happens on first load (cached by CoreML
framework in ~/Library/Caches/).

---

## Phase 4: Zig Pipeline Integration

### Option A: Comptime Platform Dispatch in nemotron_pipeline.zig (preferred)

The pipeline structure (mel -> encoder chunks -> RNNT decode) is identical on
both platforms. Only the model invocation calls differ:

```
Per-chunk cycle (560ms):
1. mel_state.feed(samples)                              // Zig (existing)
2. mel_state.exportBandMajor(chunk)                     // Zig (existing)
3. prepend pre_cache to chunk                           // Zig (existing)
4. encoder_output = coreml_run_encoder(chunk, caches)   // CoreML (new)
5. update caches from encoder output                    // Zig (existing)
6. for each encoder frame:                              // Zig (existing)
     dec_out = coreml_run_decoder(token, lstm_state)    // CoreML (new)
     logits = coreml_run_joint(enc_frame, dec_out)      // CoreML (new)
     apply context biasing to logits                    // Zig (existing)
     argmax -> emit token or break on BLANK             // Zig (existing)
```

Use comptime branching:
```zig
const is_macos = builtin.os.tag == .macos;
// In runEncoderChunk: call coreml_helpers vs ort_c based on is_macos
```

### Option B: Separate pipeline_coreml.zig

If the code paths diverge too much, dispatch via asr_backend.zig:
```zig
pub const AsrPipeline = if (builtin.os.tag == .macos)
    @import("pipeline_coreml.zig").CoreMLPipeline
else
    @import("nemotron_pipeline.zig").NemotronPipeline;
```

### Model Path

CoreML models ship as .mlmodelc (compiled) directories:
```
dist/models/nemotron-coreml/
  encoder.mlmodelc/
  decoder.mlmodelc/
  joint.mlmodelc/
```

Shared files (filterbank.bin, tokens.txt) stay in dist/models/nemotron/.

### Build System Changes

- build.zig: Add coreml_helpers.m to macOS C sources, link CoreML.framework
- run.ts: distMacOS() packages CoreML models in tarball
- install.sh: detect_model_variant() downloads CoreML models for Apple Silicon

---

## Phase 5: Validation and Testing

### 5.1 Numerical Equivalence

Compare ONNX (Linux) vs CoreML (macOS) on reference audio:
```bash
# Both should produce identical or near-identical text:
./dist/bin/capsper --transcribe test/jfk.wav
```

### 5.2 Streaming Regression Suite

Run the full regression test suite on macOS with CoreML backend:
- short-test: 4 files (<15s)
- medium-test: 2 files (15-40s)
- long-test: 3 files (>60s)

WER and coverage thresholds must match across platforms.

### 5.3 Performance Benchmarks

Measure on Apple Silicon:
- Encoder chunk latency (target: <100ms for 560ms of audio = >5x RTF)
- RNNT decode latency per token
- End-to-end RTF (must be well above 1x for real-time streaming)
- Memory footprint
- ANE utilization (Instruments or coreml-cli profiler)

### 5.4 CoreAudio Integration Test

test/ca-stream.test.ts -- streams audio via BlackHole loopback, verifies
transcription output with CoreML backend.

---

## Phase 6: Distribution

### Model Packaging

CoreML compiled models (.mlmodelc) are directories. Options:
1. Download at install time (preferred -- matches ONNX model download flow)
2. Commit to LFS (large -- 2.2GB encoder alone)
3. Ship .mlpackage and compile on first run (slow first launch)

Option 1: Add CoreML model download to install.sh. detect_model_variant()
already returns "fp16" for Apple Silicon -- add a CoreML download path:

```bash
if [ "$(uname -s)" = "Darwin" ]; then
    download_coreml_models "$model_dir"
fi
```

Host pre-compiled .mlmodelc bundles on HuggingFace alongside the ONNX models.

### Build System

- build.zig: Link CoreML.framework on macOS, add coreml_helpers.m
- run.ts: No changes needed (model download is install-time)
- ci.yml: macOS CI tests use CoreML backend automatically (comptime dispatch)

---

## Open Questions

1. **CoreML StateType vs explicit I/O caches**: StateType (macOS 15+) gives
   in-place cache updates (no copy overhead). Explicit I/O works on macOS 12+
   but copies large cache tensors. Recommendation: target macOS 15+ (current
   release, reasonable floor) and use StateType.

2. **INT8 quantization**: coremltools 9.0b1 adds INT8 on ANE. Could halve
   encoder from 2.2GB to 1.1GB and improve throughput. Benchmark after FP16
   works -- need to verify no WER impact.

3. **First-load compilation**: CoreML compiles .mlpackage to .mlmodelc on
   first load (minutes for large models). Ship pre-compiled .mlmodelc to
   skip this. Requires compiling on the same macOS version family.

4. **Relative positional encoding**: If dynamic gather ops cause ANE->CPU
   transitions, precompute the positional bias tensor for the fixed 65-frame
   chunk size to eliminate them. Profile first to confirm it matters.

5. **Depthwise conv kernel sizes**: Standard (non-dilated) depthwise conv
   runs on ANE if kernel <= 13. FastConformer typically uses kernel_size=31
   for the conv module -- need to verify this doesn't fall back. If it does,
   consider splitting into smaller kernels or accepting CPU fallback for
   this op (it's a small fraction of total compute).

6. **Data format bridge**: Zig pipeline uses f32 buffers. CoreML ANE uses
   f16 internally. The coreml_helpers.m layer needs to handle f32<->f16
   conversion efficiently, or we switch the Zig pipeline to f16 on macOS.

---

## References

- Apple: Deploying Transformers on ANE -- https://machinelearning.apple.com/research/neural-engine-transformers
- Apple: ml-ane-transformers -- https://github.com/apple/ml-ane-transformers
- coremltools docs -- https://apple.github.io/coremltools/docs-guides/source/
- coremltools stateful models -- https://apple.github.io/coremltools/docs-guides/source/stateful-models.html
- FluidInference/mobius -- https://github.com/FluidInference/mobius
- FluidInference/FluidAudio -- https://github.com/FluidInference/FluidAudio
- NeMo cache-aware streaming -- docs/cache-aware-streaming-asr.md (local)
- hollance/neural-engine unsupported layers -- https://github.com/hollance/neural-engine/blob/master/docs/unsupported-layers.md
