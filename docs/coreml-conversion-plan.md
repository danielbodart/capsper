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
WER on LibriSpeech test-clean (locally at ~/Projects/mobius/). We reference their
patterns but make our own architectural decisions for capsper's needs.

---

## Progress

### Phase 1: Python Conversion Pipeline -- DONE

`tools/coreml-convert/` is a complete, validated conversion pipeline.

**What was built:**
- `pyproject.toml` -- Python 3.10, torch 2.7.x, coremltools 9.0b1, nemo_toolkit
- `wrappers.py` -- EncoderWrapper (explicit cache I/O) + FusedDecoderJointWrapper
- `convert.py` -- load NeMo model, wrap, trace, convert to CoreML, save
- `validate.py` -- 3-level validation (wrapper equiv, CoreML vs PyTorch, end-to-end)

**Key decisions made:**
- **Two models, not three**: encoder + fused decoder+joint (matches Zig dec_session)
- **Explicit I/O caches** (not StateType -- ct.StateType failed with
  `generate_tensor_assignment_ops` error due to cache transpose in traced graph)
- **No ANE optimizations yet** -- get correct first, profile, then optimize
- **coremltools 9.0b1 required** (8.1 has `int` op conversion bug with NeMo encoder)
- **Python 3.10 required** (NeMo deps like kaldialign lack 3.13+ wheels)

**Validation results:**
- Encoder: max_err=0.004, cos_sim > 0.999 across 20 chunks of JFK audio
- End-to-end: identical transcript on test/jfk.wav
- Wrapper equivalence: bit-perfect (zero error)

**Run:** `cd tools/coreml-convert && uv sync --prerelease=allow && uv run python convert.py`

### Phase 2: ANE Transformer Optimizations -- DEFERRED

Deferred until after profiling ANE utilization with Instruments. The optimizations
(Linear→Conv2d, channels-first 4D layout, per-head attention split) add complexity
to the conversion pipeline. Profile first to see if the coremltools compiler
already routes enough ops to ANE without manual transforms.

### Phase 3: Zig Integration -- DONE

**Architecture: per-platform build variants with comptime dispatch.**

build.zig provides `-Dbackend=coreml|ort_cuda|ort_cpu`. Comptime dispatch
files (`src/backend/pipeline.zig`, `src/backend/init.zig`) switch on the
build option -- only the active backend's `@import` is evaluated, so the
macOS binary has zero ORT symbols and Linux binaries have no CoreML deps.

Source tree reorganized into `src/shared/`, `src/backend/{ort,coreml}/`,
`src/platform/{linux,macos}/` with consistent naming. Server.zig calls the
concrete pipeline type directly (no vtable, no runtime dispatch).

**Files:**
- `src/backend/coreml/helpers.m` -- Obj-C bridge: model load, encoder/decoder
  predict, cache state management. Tries .mlmodelc first, falls back to
  runtime-compiled .mlpackage.
- `src/backend/coreml/pipeline.zig` -- CoreML streaming pipeline
- `src/backend/coreml/init.zig` -- CoreML model loading
- `src/backend/ort/pipeline.zig` -- ORT streaming pipeline
- `src/backend/ort/init.zig` -- ORT model loading (CUDA fatal in ort_cuda,
  skipped in ort_cpu)
- `src/backend/pipeline.zig` -- comptime switch to concrete Pipeline type
- `src/backend/init.zig` -- comptime switch to backend-specific init
- `build.zig` -- `-Dbackend` option, per-backend linking and binary naming

### Phase 4: Runtime Bug -- FIXED

**Root cause: CoreML output MLMultiArrays have non-contiguous strides (ANE
padding).** For example, the encoder output [1, 1024, 7] has strides
[32768, 32, 1] instead of C-contiguous [7168, 7, 1]. Each row of 7 elements
is padded to 32 in physical storage. The original `copy_to_f32` did a flat
`memcpy` that treated the padded storage as contiguous data, copying garbage
padding bytes as if they were real tensor values.

**Fix:** Rewrote `copy_to_f32` to detect non-contiguous strides via
`is_contiguous()` and use stride-aware indexing (flat → multi-dim → physical
offset) when needed. The contiguous fast path is preserved for inputs and
any outputs that happen to be contiguous.

**Additional fixes in the same change:**
- Cache output copies now use `copy_to_f32` (FP16→FP32 with stride handling)
  instead of raw `memcpy` which also had a dtype mismatch (FP16 src → FP32 dst)
- `make_zeros` memset size now correctly handles FP16 (was hardcoded to 4 bytes)
- `cache_len` copy now guards dtype like `enc_len` does
- Model loading prefers .mlmodelc, falls back to runtime .mlpackage compilation

**Note:** `.mlpackage` CAN be loaded at runtime via `MLModel.compileModel(at:)`
-- it just requires compilation first (unlike .mlmodelc which is pre-compiled).
The loader tries .mlmodelc first for speed, falls back to .mlpackage.

### Phase 5: Validation and Testing -- READY

Once runtime inference works:
- Run full regression suite (./run.ts) with CoreML backend
- Compare WER/coverage against ONNX pipeline on same test files
- ca-stream.test.ts (BlackHole loopback) already updated for CoreML path

### Phase 6: Distribution -- NOT STARTED

- Compile .mlmodelc on CI (macOS runner)
- Upload to HuggingFace (separate repo from ONNX models)
- Update install.sh to download CoreML models on macOS
- distMacOS() in run.ts packages CoreML models in tarball
- Update run.ts for dual Linux builds (capsper-cuda + capsper-cpu)
- Create Linux launcher script (bin/capsper → detects GPU → exec sub-binary)
- Update install.sh for new binary variant structure

---

## Architecture

### Two CoreML Models (actual, not three as originally planned)

| Model | Input | Output | Compute |
|-------|-------|--------|---------|
| Encoder | mel [1,128,65] + caches (explicit I/O) | encoded [1,1024,7] + caches | CPU_AND_NE |
| Fused Decoder+Joint | enc_frame [1,1024,1] + token [1,1] + LSTM h,c | logits [1,1025] + LSTM h,c | CPU_ONLY |

The decoder and joint are fused into a single model to match the existing Zig
ONNX dec_session interface (one call per decode step, not two).

Mel spectrogram stays in Zig (shared/nemo_mel_state.zig) -- no CoreML preprocessor.

### 560ms Chunk Math

- 560ms = 8960 samples at 16kHz
- Mel: hop=160, win=400 -> 56 mel frames per chunk
- Pre-cache: 9 mel frames from previous chunk
- Encoder input: 9 + 56 = 65 mel frames -> [1, 128, 65]
- 8x subsampling -> 7 encoder output frames per chunk
- RNNT greedy decode: up to 10 tokens per encoder frame x 7 frames

### Encoder Cache Shapes (batch-first for CoreML, 24-layer FastConformer)

| Cache | Shape | Description |
|-------|-------|-------------|
| cache_last_channel | [1, 24, 70, 1024] | Attention left context |
| cache_last_time | [1, 24, 1024, 8] | Convolution time context |
| cache_last_channel_len | [1] | Cache fill level (int32) |

NeMo uses layer-first [L, B, ...] internally. The wrapper transposes to/from
batch-first [B, L, ...] for CoreML.

### Decoder State (2-layer LSTM, 640 hidden)

| State | Shape |
|-------|-------|
| lstm_h | [2, 1, 640] |
| lstm_c | [2, 1, 640] |

### Zig Architecture: Comptime Backend Dispatch

```
// build.zig: -Dbackend=coreml|ort_cuda|ort_cpu

// src/backend/pipeline.zig (comptime switch):
Pipeline = switch (build_options.backend) {
    .coreml => CoreMLPipeline,
    .ort_cuda, .ort_cpu => NemotronPipeline,
};
```

Server.zig uses the concrete `Pipeline` type directly -- no vtable, no
runtime dispatch. Backend selection happens at compile time via the build
option. Each binary variant contains only the code for its backend.

### Model Paths

```
dist/models/nemotron/           # Shared + ONNX
  filterbank.bin                # shared
  tokens.txt                    # shared
  encoder_model.onnx            # Linux only
  decoder_model.onnx            # Linux only
dist/models/nemotron-coreml/    # macOS only
  encoder.mlmodelc/             # compiled CoreML
  decoder.mlmodelc/             # compiled CoreML
```

---

## Open Questions

1. ~~**CoreML StateType vs explicit I/O caches**~~ RESOLVED: explicit I/O.
   StateType failed with coremltools due to cache transpose pattern in traced
   graph. Can revisit if coremltools adds better support.

2. **INT8 quantization**: coremltools 9.0b1 adds INT8 on ANE. Could halve
   encoder size. Benchmark after FP16 works.

3. ~~**First-load compilation**~~ RESOLVED: ship pre-compiled .mlmodelc.
   Loader tries .mlmodelc first, falls back to runtime .mlpackage compilation
   via `MLModel.compileModel(at:)`.

4. **Relative positional encoding**: Profile to check if dynamic gather ops
   cause ANE->CPU transitions. Precompute positional bias if so.

5. **Depthwise conv kernel sizes**: FastConformer uses kernel_size=31 (ANE
   limit is 13). May fall back to CPU for this op. Profile first.

6. ~~**Data format bridge**~~ RESOLVED: Zig stays f32, coreml_helpers.m
   handles f32↔f16 conversion via copy_to_f32() which checks MLMultiArray
   dataType and converts FP16→FP32 using ARM NEON __fp16 casts. Also handles
   non-contiguous strides (CoreML pads output arrays for ANE alignment).

7. ~~**onnxruntime link on macOS**~~ RESOLVED: per-platform build variants
   (`-Dbackend=coreml`) mean the macOS binary never imports ORT code at all.
   Zero ORT symbols in the macOS binary.

---

## References

- Apple: Deploying Transformers on ANE -- https://machinelearning.apple.com/research/neural-engine-transformers
- Apple: ml-ane-transformers -- https://github.com/apple/ml-ane-transformers
- coremltools docs -- https://apple.github.io/coremltools/docs-guides/source/
- coremltools stateful models -- https://apple.github.io/coremltools/docs-guides/source/stateful-models.html
- FluidInference/mobius -- https://github.com/FluidInference/mobius (local: ~/Projects/mobius/)
- FluidInference/FluidAudio -- https://github.com/FluidInference/FluidAudio
- NeMo cache-aware streaming -- docs/cache-aware-streaming-asr.md (local)
- hollance/neural-engine unsupported layers -- https://github.com/hollance/neural-engine/blob/master/docs/unsupported-layers.md
