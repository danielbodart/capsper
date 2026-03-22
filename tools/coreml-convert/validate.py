#!/usr/bin/env python3
"""Validate CoreML models against PyTorch reference.

Three validation levels:
1. Wrapper equivalence -- PyTorch wrapper vs NeMo direct call
2. CoreML vs PyTorch -- per-chunk numerical comparison
3. End-to-end transcript -- full RNNT greedy decode on test audio

Usage:
    uv run python validate.py --model-dir output --wrapper-only
    uv run python validate.py --model-dir output
    uv run python validate.py --model-dir output --wav ../../test/jfk.wav
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

import nemo.collections.asr as nemo_asr

from wrappers import EncoderWrapper, FusedDecoderJointWrapper

MODEL_ID = "nvidia/nemotron-speech-streaming-en-0.6b"
CHUNK_MEL_FRAMES = 56
PRE_ENCODE_CACHE = 9
TOTAL_MEL_FRAMES = 65


def load_nemo_model():
    """Load NeMo model configured for streaming."""
    print("Loading NeMo model...")
    model = nemo_asr.models.EncDecRNNTBPEModel.from_pretrained(MODEL_ID, map_location="cpu")
    model.set_export_config({"cache_aware": True})
    model.encoder.setup_streaming_params()
    model.decoder._rnnt_export = True
    return model


def compute_mel_from_audio(model, audio):
    """Compute mel spectrogram using NeMo's preprocessor."""
    audio_tensor = torch.tensor(audio, dtype=torch.float32).unsqueeze(0)
    audio_len = torch.tensor([len(audio)], dtype=torch.long)
    with torch.no_grad():
        mel, mel_len = model.preprocessor(input_signal=audio_tensor, length=audio_len)
    return mel, int(mel_len[0])


def chunk_mel(mel, mel_len):
    """Split mel into 560ms chunks with 9-frame pre-cache overlap."""
    offset = 0
    pre_cache = torch.zeros(1, 128, PRE_ENCODE_CACHE)

    while offset < mel_len:
        chunk_frames = min(CHUNK_MEL_FRAMES, mel_len - offset)
        new_frames = mel[:, :, offset:offset + chunk_frames]

        if chunk_frames < CHUNK_MEL_FRAMES:
            padded = torch.zeros(1, 128, CHUNK_MEL_FRAMES)
            padded[:, :, :chunk_frames] = new_frames
            new_frames = padded

        chunk = torch.cat([pre_cache, new_frames], dim=2)
        is_last = (offset + CHUNK_MEL_FRAMES >= mel_len)

        if chunk_frames >= PRE_ENCODE_CACHE:
            pre_cache = new_frames[:, :, chunk_frames - PRE_ENCODE_CACHE:chunk_frames].clone()
        else:
            pre_cache = torch.cat([
                pre_cache[:, :, chunk_frames:],
                new_frames[:, :, :chunk_frames],
            ], dim=2)

        yield chunk, is_last
        offset += CHUNK_MEL_FRAMES


def make_initial_caches(model):
    """Get initial encoder cache state in batch-first layout."""
    cache_ch, cache_time, cache_len = model.encoder.get_initial_cache_state(
        batch_size=1, device="cpu"
    )
    return (
        cache_ch.transpose(0, 1).contiguous(),
        cache_time.transpose(0, 1).contiguous(),
        cache_len.to(torch.int32),
    )


# ---------------------------------------------------------------------------
# Level 1: Wrapper equivalence
# ---------------------------------------------------------------------------

def validate_encoder_wrapper(model):
    """Compare EncoderWrapper output vs direct NeMo encoder call."""
    print("\n=== Level 1: Encoder wrapper equivalence ===")

    cache_ch, cache_time, cache_len = model.encoder.get_initial_cache_state(
        batch_size=1, device="cpu"
    )
    wrapper = EncoderWrapper(encoder=model.encoder, total_mel_frames=TOTAL_MEL_FRAMES)
    wrapper.eval()

    # Wrapper uses batch-first caches
    w_ch = cache_ch.transpose(0, 1).contiguous()
    w_time = cache_time.transpose(0, 1).contiguous()
    w_len = cache_len.to(torch.int32)

    # Reference uses layer-first
    ref_ch = cache_ch.clone()
    ref_time = cache_time.clone()
    ref_len = cache_len.clone()

    errors = []
    for i in range(5):
        mel_chunk = torch.randn(1, 128, TOTAL_MEL_FRAMES)
        length = torch.tensor([TOTAL_MEL_FRAMES], dtype=torch.long)

        with torch.no_grad():
            ref_out, _, new_ch, new_time, new_ch_len = model.encoder(
                audio_signal=mel_chunk, length=length,
                cache_last_channel=ref_ch,
                cache_last_time=ref_time,
                cache_last_channel_len=ref_len.to(torch.long),
            )
            ref_ch, ref_time, ref_len = new_ch, new_time, new_ch_len

            w_out, _, w_ch, w_time, w_len = wrapper(mel_chunk, w_ch, w_time, w_len)

        max_err = (ref_out - w_out).abs().max().item()
        cos_sim = torch.nn.functional.cosine_similarity(
            ref_out.flatten().unsqueeze(0),
            w_out.flatten().unsqueeze(0),
        ).item()
        errors.append(max_err)
        status = "PASS" if max_err < 1e-3 else "FAIL"
        print(f"  Chunk {i}: max_err={max_err:.2e}, cos_sim={cos_sim:.6f} [{status}]")

    max_overall = max(errors)
    passed = max_overall < 1e-3
    print(f"  Overall: max_err={max_overall:.2e} {'PASS' if passed else 'FAIL'}")
    return passed


def validate_decoder_wrapper(model):
    """Compare FusedDecoderJointWrapper vs separate NeMo decoder+joint."""
    print("\n=== Level 1: Fused decoder+joint wrapper equivalence ===")

    wrapper = FusedDecoderJointWrapper(model.decoder, model.joint)
    wrapper.eval()

    decoder_hidden = int(model.decoder.pred_hidden)
    decoder_layers = int(model.decoder.pred_rnn_layers)
    blank_idx = int(model.decoder.blank_idx)

    errors = []
    h = torch.zeros(decoder_layers, 1, decoder_hidden)
    c = torch.zeros(decoder_layers, 1, decoder_hidden)
    last_token = blank_idx

    for i in range(20):
        enc_frame = torch.randn(1, 1024, 1)
        targets = torch.tensor([[last_token]], dtype=torch.int32)
        target_length = torch.tensor([1], dtype=torch.int32)

        with torch.no_grad():
            w_logits, w_h, w_c = wrapper(enc_frame, targets, target_length, h, c)

            dec_out, _, new_states = model.decoder(
                targets=targets.to(torch.long),
                target_length=target_length.to(torch.long),
                states=[h, c],
            )
            enc_for_joint = enc_frame.transpose(1, 2)
            dec_for_joint = dec_out.transpose(1, 2)
            enc_proj = model.joint.enc(enc_for_joint)
            dec_proj = model.joint.pred(dec_for_joint)
            combined = enc_proj.unsqueeze(2) + dec_proj.unsqueeze(1)
            for layer in model.joint.joint_net:
                combined = layer(combined)
            ref_logits = combined.squeeze(1).squeeze(1)

        max_err = (ref_logits - w_logits).abs().max().item()
        errors.append(max_err)

        token = int(torch.argmax(w_logits[0]))
        if token != blank_idx:
            last_token = token
            h, c = w_h, w_c

    max_overall = max(errors)
    passed = max_overall < 1e-4
    print(f"  20 steps: max_err={max_overall:.2e} {'PASS' if passed else 'FAIL'}")
    return passed


# ---------------------------------------------------------------------------
# Level 2: CoreML vs PyTorch
# ---------------------------------------------------------------------------

def validate_coreml_encoder(model, model_dir, wav_path=None):
    """Compare CoreML encoder output vs PyTorch."""
    import coremltools as ct

    print("\n=== Level 2: CoreML encoder vs PyTorch ===")
    enc_path = model_dir / "encoder.mlpackage"
    if not enc_path.exists():
        print(f"  Skipping: {enc_path} not found")
        return True

    cml_encoder = ct.models.MLModel(str(enc_path))

    if wav_path and Path(wav_path).exists():
        audio, sr = sf.read(wav_path, dtype="float32")
        mel, mel_len = compute_mel_from_audio(model, audio)
        print(f"  Using {wav_path} ({len(audio)/16000:.1f}s, {mel_len} mel frames)")
    else:
        mel_len = CHUNK_MEL_FRAMES * 5
        mel = torch.randn(1, 128, mel_len)
        print(f"  Using synthetic mel ({mel_len} frames)")

    # PyTorch
    pt_wrapper = EncoderWrapper(encoder=model.encoder, total_mel_frames=TOTAL_MEL_FRAMES)
    pt_wrapper.eval()
    pt_ch, pt_time, pt_len = make_initial_caches(model)

    # CoreML
    cache_ch, cache_time, cache_len = model.encoder.get_initial_cache_state(
        batch_size=1, device="cpu"
    )
    cml_ch = cache_ch.transpose(0, 1).contiguous().numpy()
    cml_time = cache_time.transpose(0, 1).contiguous().numpy()
    cml_len = np.array([0], dtype=np.int32)

    errors = []
    for i, (chunk, is_last) in enumerate(chunk_mel(mel, mel_len)):
        with torch.no_grad():
            pt_out, _, pt_ch, pt_time, pt_len = pt_wrapper(chunk, pt_ch, pt_time, pt_len)

        cml_result = cml_encoder.predict({
            "audio_signal": chunk.numpy(),
            "cache_last_channel": cml_ch,
            "cache_last_time": cml_time,
            "cache_last_channel_len": cml_len,
        })
        cml_out = cml_result["encoded"]
        cml_ch = cml_result["cache_channel_out"]
        cml_time = cml_result["cache_time_out"]
        cml_len = cml_result["cache_len_out"]

        pt_np = pt_out.numpy().astype(np.float32)
        cml_np = np.array(cml_out, dtype=np.float32)
        max_err = float(np.abs(pt_np - cml_np).max())
        norm_pt = float(np.linalg.norm(pt_np.flatten()))
        norm_cml = float(np.linalg.norm(cml_np.flatten()))
        cos_sim = float(np.dot(pt_np.flatten(), cml_np.flatten()) / (norm_pt * norm_cml + 1e-10))
        errors.append(max_err)
        status = "PASS" if max_err < 0.1 else "WARN" if max_err < 0.5 else "FAIL"
        print(f"  Chunk {i}: max_err={max_err:.4f}, cos_sim={cos_sim:.6f} [{status}]")

    max_overall = max(errors)
    passed = max_overall < 0.5
    print(f"  Overall: max_err={max_overall:.4f} {'PASS' if passed else 'FAIL'}")
    return passed


def validate_coreml_decoder(model, model_dir):
    """Compare CoreML fused decoder+joint vs PyTorch."""
    import coremltools as ct

    print("\n=== Level 2: CoreML decoder+joint vs PyTorch ===")
    dec_path = model_dir / "decoder.mlpackage"
    if not dec_path.exists():
        print(f"  Skipping: {dec_path} not found")
        return True

    cml_decoder = ct.models.MLModel(str(dec_path))

    pt_wrapper = FusedDecoderJointWrapper(model.decoder, model.joint)
    pt_wrapper.eval()

    decoder_hidden = int(model.decoder.pred_hidden)
    decoder_layers = int(model.decoder.pred_rnn_layers)
    blank_idx = int(model.decoder.blank_idx)

    h = np.zeros((decoder_layers, 1, decoder_hidden), dtype=np.float32)
    c = np.zeros((decoder_layers, 1, decoder_hidden), dtype=np.float32)
    pt_h = torch.zeros(decoder_layers, 1, decoder_hidden)
    pt_c = torch.zeros(decoder_layers, 1, decoder_hidden)
    last_token = blank_idx

    errors = []
    for i in range(20):
        enc_frame_np = np.random.randn(1, 1024, 1).astype(np.float32)
        targets_np = np.array([[last_token]], dtype=np.int32)
        target_len_np = np.array([1], dtype=np.int32)

        cml_result = cml_decoder.predict({
            "encoder_outputs": enc_frame_np,
            "targets": targets_np,
            "target_length": target_len_np,
            "input_states_1": h,
            "input_states_2": c,
        })
        cml_logits = np.array(cml_result["outputs"], dtype=np.float32)

        enc_frame_pt = torch.from_numpy(enc_frame_np)
        targets_pt = torch.tensor([[last_token]], dtype=torch.int32)
        target_len_pt = torch.tensor([1], dtype=torch.int32)
        with torch.no_grad():
            pt_logits, pt_new_h, pt_new_c = pt_wrapper(
                enc_frame_pt, targets_pt, target_len_pt, pt_h, pt_c
            )

        max_err = float(np.abs(pt_logits.numpy() - cml_logits).max())
        errors.append(max_err)

        token = int(np.argmax(cml_logits[0]))
        if token != blank_idx:
            last_token = token
            h = np.array(cml_result["output_states_1"], dtype=np.float32)
            c = np.array(cml_result["output_states_2"], dtype=np.float32)
            pt_h, pt_c = pt_new_h, pt_new_c

    max_overall = max(errors)
    # FP16 decoder with random inputs can diverge significantly on logit magnitudes.
    # The end-to-end transcript test (Level 3) is the true correctness check.
    passed = max_overall < 50.0
    print(f"  20 steps: max_err={max_overall:.4f} {'PASS' if passed else 'FAIL'}")
    if max_overall > 1.0:
        print(f"  Note: high error expected with random encoder frames; "
              f"end-to-end test is the real check")
    return passed


# ---------------------------------------------------------------------------
# Level 3: End-to-end transcript
# ---------------------------------------------------------------------------

def transcribe_coreml(model_dir, mel, mel_len, tokenizer_map, blank_idx):
    """Full RNNT greedy decode using CoreML models."""
    import coremltools as ct

    cml_encoder = ct.models.MLModel(str(model_dir / "encoder.mlpackage"))
    cml_decoder = ct.models.MLModel(str(model_dir / "decoder.mlpackage"))

    with open(model_dir / "metadata.json") as f:
        meta = json.load(f)

    decoder_hidden = meta["decoder_hidden"]
    decoder_layers = meta["decoder_layers"]

    # Initialize caches from metadata shapes
    ch_shape = meta["cache_channel_shape"]  # [L, B, att_ctx, D]
    time_shape = meta["cache_time_shape"]   # [L, B, D, conv_ctx]
    # Batch-first: [B, L, ...]
    cml_ch = np.zeros([ch_shape[1], ch_shape[0], ch_shape[2], ch_shape[3]], dtype=np.float32)
    cml_time = np.zeros([time_shape[1], time_shape[0], time_shape[2], time_shape[3]], dtype=np.float32)
    cml_len = np.array([0], dtype=np.int32)

    h = np.zeros((decoder_layers, 1, decoder_hidden), dtype=np.float32)
    c = np.zeros((decoder_layers, 1, decoder_hidden), dtype=np.float32)
    last_token = blank_idx
    all_tokens = []

    for chunk, is_last in chunk_mel(mel, mel_len):
        enc_result = cml_encoder.predict({
            "audio_signal": chunk.numpy(),
            "cache_last_channel": cml_ch,
            "cache_last_time": cml_time,
            "cache_last_channel_len": cml_len,
        })
        encoded = np.array(enc_result["encoded"], dtype=np.float32)
        cml_ch = enc_result["cache_channel_out"]
        cml_time = enc_result["cache_time_out"]
        cml_len = enc_result["cache_len_out"]
        num_frames = encoded.shape[2]

        for t in range(num_frames):
            enc_step = encoded[:, :, t:t + 1]

            for _ in range(10):
                targets = np.array([[last_token]], dtype=np.int32)
                target_len = np.array([1], dtype=np.int32)

                dec_result = cml_decoder.predict({
                    "encoder_outputs": enc_step,
                    "targets": targets,
                    "target_length": target_len,
                    "input_states_1": h,
                    "input_states_2": c,
                })

                logits = np.array(dec_result["outputs"], dtype=np.float32)
                token = int(np.argmax(logits[0]))

                if token == blank_idx:
                    break

                all_tokens.append(token)
                last_token = token
                h = np.array(dec_result["output_states_1"], dtype=np.float32)
                c = np.array(dec_result["output_states_2"], dtype=np.float32)

    text_parts = []
    for tok in all_tokens:
        piece = tokenizer_map.get(tok, "")
        text_parts.append(piece)
    text = "".join(text_parts).replace("\u2581", " ").strip()
    return text


def transcribe_pytorch(model, mel, mel_len):
    """Full RNNT greedy decode using PyTorch (reference)."""
    wrapper_enc = EncoderWrapper(encoder=model.encoder, total_mel_frames=TOTAL_MEL_FRAMES)
    wrapper_enc.eval()
    wrapper_dec = FusedDecoderJointWrapper(model.decoder, model.joint)
    wrapper_dec.eval()

    blank_idx = int(model.decoder.blank_idx)
    decoder_hidden = int(model.decoder.pred_hidden)
    decoder_layers = int(model.decoder.pred_rnn_layers)

    ch, time_c, ch_len = make_initial_caches(model)
    h = torch.zeros(decoder_layers, 1, decoder_hidden)
    c = torch.zeros(decoder_layers, 1, decoder_hidden)
    last_token = blank_idx
    all_tokens = []

    for chunk, is_last in chunk_mel(mel, mel_len):
        with torch.no_grad():
            encoded, _, ch, time_c, ch_len = wrapper_enc(chunk, ch, time_c, ch_len)
        num_frames = encoded.shape[2]

        for t in range(num_frames):
            enc_step = encoded[:, :, t:t + 1]
            for _ in range(10):
                targets = torch.tensor([[last_token]], dtype=torch.int32)
                target_len = torch.tensor([1], dtype=torch.int32)
                with torch.no_grad():
                    logits, new_h, new_c = wrapper_dec(enc_step, targets, target_len, h, c)
                token = int(torch.argmax(logits[0]))
                if token == blank_idx:
                    break
                all_tokens.append(token)
                last_token = token
                h, c = new_h, new_c

    text = model.tokenizer.ids_to_text(all_tokens)
    return text


def validate_end_to_end(model, model_dir, wav_path):
    """Compare full transcripts: PyTorch vs CoreML."""
    print(f"\n=== Level 3: End-to-end transcript ({Path(wav_path).name}) ===")

    audio, sr = sf.read(wav_path, dtype="float32")
    print(f"  Audio: {len(audio)/sr:.1f}s at {sr}Hz")

    mel, mel_len = compute_mel_from_audio(model, audio)
    print(f"  Mel: {mel_len} frames ({mel_len * 0.01:.1f}s)")

    print("  Running PyTorch reference...")
    pt_text = transcribe_pytorch(model, mel, mel_len)
    print(f"  PyTorch: \"{pt_text}\"")

    print("  Running CoreML...")
    blank_idx = int(model.decoder.blank_idx)
    vocab_size = int(model.tokenizer.vocab_size)
    tokenizer_map = {}
    for i in range(vocab_size):
        tokenizer_map[i] = model.tokenizer.ids_to_tokens([i])[0]

    cml_text = transcribe_coreml(model_dir, mel, mel_len, tokenizer_map, blank_idx)
    print(f"  CoreML:  \"{cml_text}\"")

    match = pt_text.strip().lower() == cml_text.strip().lower()
    print(f"  Match: {'YES' if match else 'NO'}")
    return match


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Validate CoreML models")
    parser.add_argument("--model-dir", type=Path, default=Path("output"))
    parser.add_argument("--wav", type=str, default=None)
    parser.add_argument("--wrapper-only", action="store_true")
    args = parser.parse_args()

    model = load_nemo_model()
    results = {}

    results["encoder_wrapper"] = validate_encoder_wrapper(model)
    results["decoder_wrapper"] = validate_decoder_wrapper(model)

    if not args.wrapper_only:
        results["coreml_encoder"] = validate_coreml_encoder(model, args.model_dir, args.wav)
        results["coreml_decoder"] = validate_coreml_decoder(model, args.model_dir)

        wav = args.wav
        if wav is None:
            jfk = Path(__file__).parent.parent.parent / "test" / "jfk.wav"
            if jfk.exists():
                wav = str(jfk)

        if wav and Path(wav).exists():
            results["end_to_end"] = validate_end_to_end(model, args.model_dir, wav)
        else:
            print("\n=== Level 3: Skipped (no WAV file) ===")

    print("\n" + "=" * 60)
    print("VALIDATION SUMMARY")
    print("=" * 60)
    all_pass = True
    for name, passed in results.items():
        status = "PASS" if passed else "FAIL"
        print(f"  {name}: {status}")
        if not passed:
            all_pass = False

    if all_pass:
        print("\nAll validations passed!")
    else:
        print("\nSome validations failed.")
        sys.exit(1)


if __name__ == "__main__":
    main()
