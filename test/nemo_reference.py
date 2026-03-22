#!/usr/bin/env python3
"""
NeMo reference script: dumps intermediate values at each processing stage.
Used for byte-for-byte verification of the Zig feature extraction pipeline.

Outputs binary .bin files with f32 values that Zig tests can load and compare.

Usage:
    uv run --with "nemo_toolkit[asr]" python3 test/nemo_reference.py test/jfk.wav test/reference/
"""
import sys
import os
import numpy as np
import torch
import soundfile as sf


def main():
    wav_path = sys.argv[1] if len(sys.argv) > 1 else "test/jfk.wav"
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "test/reference/"
    os.makedirs(out_dir, exist_ok=True)

    import nemo.collections.asr as nemo_asr

    model = nemo_asr.models.ASRModel.from_pretrained('nvidia/nemotron-speech-streaming-en-0.6b')
    model.eval()
    model = model.cuda()

    # Load raw audio
    audio, sr = sf.read(wav_path, dtype='float32')
    print(f"Audio: {len(audio)} samples, {sr}Hz, {len(audio)/sr:.2f}s")

    # Save raw audio as f32
    np.array(audio, dtype=np.float32).tofile(os.path.join(out_dir, "audio_f32.bin"))
    print(f"  audio_f32.bin: {audio.shape}")

    # === Stage 1: Preprocessor (mel spectrogram) ===
    audio_tensor = torch.tensor(audio).unsqueeze(0).cuda()
    audio_len = torch.tensor([len(audio)]).cuda()

    # Print preprocessor config
    pp = model.preprocessor
    print(f"\nPreprocessor config:")
    print(f"  sample_rate: {pp._cfg.sample_rate}")
    print(f"  features (n_mels): {pp._cfg.features}")
    print(f"  window_size: {pp._cfg.window_size}")
    print(f"  window_stride: {pp._cfg.window_stride}")
    print(f"  n_fft: {pp._cfg.n_fft}")
    print(f"  window: {pp._cfg.window}")
    print(f"  normalize: {pp._cfg.normalize}")
    print(f"  dither: {pp._cfg.dither}")
    print(f"  pad_to: {pp._cfg.pad_to}")

    featurizer = pp.featurizer
    preemph = getattr(featurizer, 'preemph', None)
    print(f"  preemph: {preemph}")

    with torch.no_grad():
        processed, processed_len = pp(input_signal=audio_tensor, length=audio_len)

    # processed is [B, n_mels, T]
    features = processed[0].cpu().numpy()  # [128, T]
    print(f"\nFeatures shape: {features.shape}")
    print(f"  min={features.min():.4f}, max={features.max():.4f}, mean={features.mean():.4f}")
    np.array(features, dtype=np.float32).tofile(os.path.join(out_dir, "mel_features.bin"))
    print(f"  mel_features.bin: {features.shape} (n_mels x T, row-major)")

    # Save feature dimensions
    with open(os.path.join(out_dir, "mel_features.meta"), 'w') as f:
        f.write(f"n_mels={features.shape[0]}\n")
        f.write(f"n_frames={features.shape[1]}\n")

    # === Stage 2: Encoder output (offline) ===
    with torch.no_grad():
        encoded, encoded_len = model.encoder(audio_signal=processed, length=processed_len)

    enc_out = encoded[0].cpu().numpy()  # [D, T_enc]
    print(f"\nEncoder output: {enc_out.shape}")
    np.array(enc_out, dtype=np.float32).tofile(os.path.join(out_dir, "encoder_output.bin"))

    # === Stage 3: RNNT decode ===
    with torch.no_grad():
        hyps = model.decoding.rnnt_decoder_predictions_tensor(encoded, encoded_len)

    text = hyps[0].text
    tokens = hyps[0].y_sequence.cpu().numpy()
    print(f"\nDecoded text: {text}")
    print(f"Token IDs ({len(tokens)}): {tokens.tolist()}")

    # Save tokens
    np.array(tokens, dtype=np.int32).tofile(os.path.join(out_dir, "tokens.bin"))
    with open(os.path.join(out_dir, "transcript.txt"), 'w') as f:
        f.write(text + '\n')

    # === Dump the mel filterbank weights for verification ===
    fb = featurizer.fb.cpu().numpy()
    print(f"\nFilterbank shape: {fb.shape}")
    np.array(fb, dtype=np.float32).tofile(os.path.join(out_dir, "filterbank.bin"))
    with open(os.path.join(out_dir, "filterbank.meta"), 'w') as f:
        f.write(f"rows={fb.shape[0]}\n")
        f.write(f"cols={fb.shape[1]}\n")

    # === Spot-check: first 5 frames ===
    print(f"\nFirst 5 frames, first 8 mels:")
    for frame in range(min(5, features.shape[1])):
        vals = features[:8, frame]
        print(f"  frame[{frame}]: {' '.join(f'{v:8.4f}' for v in vals)}")

    print(f"\nAll reference data saved to {out_dir}")


if __name__ == '__main__':
    main()
