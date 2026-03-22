#!/usr/bin/env python3
"""Convert Nemotron Speech 600M streaming RNNT to CoreML.

Exports 2 CoreML models:
1. Encoder (streaming FastConformer) -- explicit cache I/O, targets ANE
2. Fused Decoder+Joint (RNNT prediction LSTM + joiner) -- CPU only

Usage:
    cd tools/coreml-convert
    uv sync
    uv run python convert.py
    uv run python convert.py --output-dir ../../dist/models/nemotron-coreml
    uv run python convert.py --no-compile  # skip xcrun coremlcompiler step
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

import nemo.collections.asr as nemo_asr

from wrappers import EncoderWrapper, FusedDecoderJointWrapper

MODEL_ID = "nvidia/nemotron-speech-streaming-en-0.6b"

# Capsper streaming config: 560ms chunks
CHUNK_MEL_FRAMES = 56   # mel frames per encoder chunk
PRE_ENCODE_CACHE = 9    # mel frames prepended from previous chunk
TOTAL_MEL_FRAMES = CHUNK_MEL_FRAMES + PRE_ENCODE_CACHE  # 65


def load_model():
    """Load NeMo model and configure streaming."""
    print(f"Loading {MODEL_ID}...")
    model = nemo_asr.models.EncDecRNNTBPEModel.from_pretrained(MODEL_ID, map_location="cpu")
    model.set_export_config({"cache_aware": True})
    model.encoder.setup_streaming_params()

    if hasattr(model.encoder, 'streaming_cfg') and model.encoder.streaming_cfg is not None:
        cfg = model.encoder.streaming_cfg
        print(f"  Streaming config: chunk_size={cfg.chunk_size}, "
              f"pre_encode_cache_size={cfg.pre_encode_cache_size}")

    # Get initial cache state for shape discovery
    cache_ch, cache_time, cache_len = model.encoder.get_initial_cache_state(
        batch_size=1, device="cpu"
    )
    print(f"  Cache shapes: channel={list(cache_ch.shape)}, "
          f"time={list(cache_time.shape)}, len={list(cache_len.shape)}")
    print(f"  Decoder hidden={model.decoder.pred_hidden}, "
          f"layers={model.decoder.pred_rnn_layers}, "
          f"blank_idx={model.decoder.blank_idx}")
    print(f"  Joint children: {[name for name, _ in model.joint.named_children()]}")

    return model, cache_ch, cache_time, cache_len


def create_wrappers(model):
    """Create PyTorch wrapper modules."""
    print("\nCreating wrappers...")

    enc_wrapper = EncoderWrapper(
        encoder=model.encoder,
        total_mel_frames=TOTAL_MEL_FRAMES,
    )
    enc_wrapper.eval()

    dec_wrapper = FusedDecoderJointWrapper(
        decoder=model.decoder,
        joint=model.joint,
    )
    dec_wrapper.eval()

    # Enable RNNT export mode on decoder
    model.decoder._rnnt_export = True

    return enc_wrapper, dec_wrapper


def trace_encoder(enc_wrapper, cache_ch, cache_time, cache_len):
    """Trace encoder wrapper with example inputs."""
    print("\nTracing encoder...")
    mel_example = torch.randn(1, 128, TOTAL_MEL_FRAMES)

    # Batch-first caches for the wrapper
    cache_ch_b = cache_ch.transpose(0, 1).contiguous()
    cache_time_b = cache_time.transpose(0, 1).contiguous()
    cache_len_i32 = cache_len.to(dtype=torch.int32)

    with torch.no_grad():
        out, out_len, _, _, _ = enc_wrapper(
            mel_example, cache_ch_b, cache_time_b, cache_len_i32
        )
        print(f"  Encoder output shape: {list(out.shape)}, len={out_len.item()}")

        traced = torch.jit.trace(
            enc_wrapper,
            (mel_example, cache_ch_b, cache_time_b, cache_len_i32),
            strict=False,
        )

    print("  Traced encoder OK")
    return traced


def trace_decoder(dec_wrapper, model):
    """Trace fused decoder+joint wrapper with example inputs."""
    print("\nTracing fused decoder+joint...")
    decoder_hidden = int(model.decoder.pred_hidden)
    decoder_layers = int(model.decoder.pred_rnn_layers)
    blank_idx = int(model.decoder.blank_idx)

    enc_frame = torch.randn(1, 1024, 1)
    targets = torch.tensor([[blank_idx]], dtype=torch.int32)
    target_length = torch.tensor([1], dtype=torch.int32)
    h = torch.zeros(decoder_layers, 1, decoder_hidden)
    c = torch.zeros(decoder_layers, 1, decoder_hidden)

    with torch.no_grad():
        logits, new_h, new_c = dec_wrapper(enc_frame, targets, target_length, h, c)
        print(f"  Decoder output: logits={list(logits.shape)}, "
              f"h={list(new_h.shape)}, c={list(new_c.shape)}")

        traced = torch.jit.trace(
            dec_wrapper,
            (enc_frame, targets, target_length, h, c),
            strict=False,
        )

    print("  Traced decoder+joint OK")
    return traced


def convert_encoder(traced_encoder, cache_ch_shape, cache_time_shape):
    """Convert traced encoder to CoreML with explicit cache I/O."""
    print("\nConverting encoder to CoreML...")

    # Batch-first cache shapes: [B, L, ...]
    b_ch = (cache_ch_shape[1], cache_ch_shape[0], cache_ch_shape[2], cache_ch_shape[3])
    b_time = (cache_time_shape[1], cache_time_shape[0], cache_time_shape[2], cache_time_shape[3])

    encoder_ml = ct.convert(
        traced_encoder,
        inputs=[
            ct.TensorType(shape=(1, 128, TOTAL_MEL_FRAMES), name="audio_signal", dtype=np.float32),
            ct.TensorType(shape=b_ch, name="cache_last_channel", dtype=np.float32),
            ct.TensorType(shape=b_time, name="cache_last_time", dtype=np.float32),
            ct.TensorType(shape=(1,), name="cache_last_channel_len", dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="encoded", dtype=np.float16),
            ct.TensorType(name="encoded_length", dtype=np.int32),
            ct.TensorType(name="cache_channel_out", dtype=np.float16),
            ct.TensorType(name="cache_time_out", dtype=np.float16),
            ct.TensorType(name="cache_len_out", dtype=np.int32),
        ],
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )

    print("  Encoder converted")
    return encoder_ml


def convert_decoder(traced_decoder, model):
    """Convert traced fused decoder+joint to CoreML."""
    print("\nConverting fused decoder+joint to CoreML...")
    decoder_hidden = int(model.decoder.pred_hidden)
    decoder_layers = int(model.decoder.pred_rnn_layers)

    decoder_ml = ct.convert(
        traced_decoder,
        inputs=[
            ct.TensorType(shape=(1, 1024, 1), name="encoder_outputs", dtype=np.float32),
            ct.TensorType(shape=(1, 1), name="targets", dtype=np.int32),
            ct.TensorType(shape=(1,), name="target_length", dtype=np.int32),
            ct.TensorType(shape=(decoder_layers, 1, decoder_hidden), name="input_states_1", dtype=np.float32),
            ct.TensorType(shape=(decoder_layers, 1, decoder_hidden), name="input_states_2", dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="outputs", dtype=np.float16),
            ct.TensorType(name="output_states_1", dtype=np.float16),
            ct.TensorType(name="output_states_2", dtype=np.float16),
        ],
        compute_units=ct.ComputeUnit.CPU_ONLY,
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )

    print("  Decoder+joint converted")
    return decoder_ml


def compile_mlpackage(src_path: str, dst_dir: str):
    """Compile .mlpackage to .mlmodelc using xcrun coremlcompiler."""
    name = Path(src_path).name
    print(f"  Compiling {name}...")
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", src_path, dst_dir],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"  Warning: coremlcompiler failed for {name}: {result.stderr.strip()}")
    else:
        print(f"  Compiled {name}")


def save_metadata(output_dir: Path, model, cache_ch_shape, cache_time_shape):
    """Save model metadata for the Zig runtime."""
    metadata = {
        "model": MODEL_ID,
        "sample_rate": int(model.cfg.preprocessor.sample_rate),
        "mel_features": int(model.cfg.preprocessor.features),
        "chunk_mel_frames": CHUNK_MEL_FRAMES,
        "pre_encode_cache": PRE_ENCODE_CACHE,
        "total_mel_frames": TOTAL_MEL_FRAMES,
        "vocab_size": int(model.tokenizer.vocab_size),
        "blank_idx": int(model.decoder.blank_idx),
        "encoder_dim": 1024,
        "decoder_hidden": int(model.decoder.pred_hidden),
        "decoder_layers": int(model.decoder.pred_rnn_layers),
        "cache_channel_shape": list(cache_ch_shape),
        "cache_time_shape": list(cache_time_shape),
    }
    (output_dir / "metadata.json").write_text(json.dumps(metadata, indent=2))
    print("  Saved metadata.json")


def main():
    parser = argparse.ArgumentParser(description="Convert Nemotron to CoreML")
    parser.add_argument(
        "--output-dir", type=Path, default=Path("output"),
        help="Output directory for CoreML models",
    )
    parser.add_argument(
        "--no-compile", action="store_true",
        help="Save .mlpackage only, skip coremlcompiler",
    )
    args = parser.parse_args()

    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    # Phase 1: Load model
    model, cache_ch, cache_time, cache_len = load_model()
    cache_ch_shape = tuple(int(d) for d in cache_ch.shape)
    cache_time_shape = tuple(int(d) for d in cache_time.shape)

    # Phase 2: Create wrappers
    enc_wrapper, dec_wrapper = create_wrappers(model)

    # Phase 3: Trace
    traced_encoder = trace_encoder(enc_wrapper, cache_ch, cache_time, cache_len)
    traced_decoder = trace_decoder(dec_wrapper, model)

    # Phase 4: Convert to CoreML
    encoder_ml = convert_encoder(traced_encoder, cache_ch_shape, cache_time_shape)
    decoder_ml = convert_decoder(traced_decoder, model)

    # Phase 5: Save
    print("\nSaving models...")
    enc_path = str(output_dir / "encoder.mlpackage")
    dec_path = str(output_dir / "decoder.mlpackage")
    encoder_ml.save(enc_path)
    decoder_ml.save(dec_path)
    print(f"  Saved {enc_path}")
    print(f"  Saved {dec_path}")

    # Phase 6: Compile (optional)
    if not args.no_compile:
        print("\nCompiling to .mlmodelc...")
        compile_mlpackage(enc_path, str(output_dir))
        compile_mlpackage(dec_path, str(output_dir))

    # Phase 7: Metadata
    print("\nSaving metadata...")
    save_metadata(output_dir, model, cache_ch_shape, cache_time_shape)

    print(f"\nDone! Models saved to {output_dir}/")


if __name__ == "__main__":
    main()
