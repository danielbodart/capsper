#!/usr/bin/env python3
"""Convert TEN-VAD ONNX model to GGML format for capsper.

Follows whisper.cpp's convert-silero-vad-to-ggml.py pattern.
Handles ONNX LSTM gate reordering (i/o/f/c → i/f/g/o) and bias splitting.

Usage:
    python3 scripts/convert-ten-vad-to-ggml.py [--onnx PATH] [--output PATH]
"""
import argparse
import os
import struct
import numpy as np

GGML_FILE_MAGIC = 0x67676d6c

# ONNX LSTM gate order: i, o, f, c
# PyTorch/whisper.cpp gate order: i, f, g, o
# Reorder: take ONNX blocks [0, 2, 3, 1]
GATE_REORDER = [0, 2, 3, 1]


def reorder_lstm_gates(arr, hidden_dim, axis):
    """Reorder LSTM gate blocks from ONNX (i/o/f/c) to PyTorch (i/f/g/o)."""
    chunks = np.split(arr, 4, axis=axis)
    return np.concatenate([chunks[i] for i in GATE_REORDER], axis=axis)


def write_tensor(fout, name, data, ftype=0):
    """Write a single tensor in GGML format."""
    name_bytes = name.encode("utf-8")
    shape = list(data.shape)
    n_dims = len(shape)

    # GGML stores dimensions in reverse order
    ggml_shape = list(reversed(shape))

    fout.write(struct.pack("i", n_dims))
    fout.write(struct.pack("i", len(name_bytes)))
    fout.write(struct.pack("i", ftype))
    for d in ggml_shape:
        fout.write(struct.pack("i", d))
    fout.write(name_bytes)
    data.tofile(fout)

    print(f"  {name}: shape={shape} ggml={ggml_shape} "
          f"{'f16' if ftype == 1 else 'f32'} "
          f"{data.nbytes} bytes")


def convert(onnx_path, output_path):
    import onnx
    from onnx import numpy_helper

    model = onnx.load(onnx_path)

    # Build name→array lookup
    weights = {}
    for init in model.graph.initializer:
        weights[init.name] = numpy_helper.to_array(init)

    hidden_dim = 64

    with open(output_path, "wb") as fout:
        # ── Header ──
        fout.write(struct.pack("i", GGML_FILE_MAGIC))

        model_type = "ten-vad"
        fout.write(struct.pack("i", len(model_type)))
        fout.write(model_type.encode("utf-8"))

        # Version 1.0.0
        fout.write(struct.pack("iii", 1, 0, 0))

        # Hyperparams
        fout.write(struct.pack("i", 3))   # n_sep_conv_layers
        fout.write(struct.pack("i", 2))   # n_lstm_layers
        fout.write(struct.pack("i", 64))  # lstm_hidden_size
        fout.write(struct.pack("i", 80))  # lstm1_input_size
        fout.write(struct.pack("i", 64))  # lstm2_input_size
        fout.write(struct.pack("i", 128)) # dense1_in (concat h1+h2)
        fout.write(struct.pack("i", 32))  # dense1_out
        fout.write(struct.pack("i", 1))   # dense2_out

        print(f"\nWriting tensors:")

        # ── Separable Conv Layer 0 (2D) ──
        # dw: const_fold_opt__178 (1,1,3,3) → squeeze to (1,1,3,3)
        dw0 = weights["const_fold_opt__178"].astype(np.float32)
        write_tensor(fout, "sep_conv_0_dw", dw0)

        # pw: (16,1,1,1)
        pw0 = weights["StatefulPartitionedCall/vad_model/separable_conv2d/separable_conv2d/ReadVariableOp_1:0"].astype(np.float32)
        write_tensor(fout, "sep_conv_0_pw", pw0)

        # bias: (16,)
        b0 = weights["StatefulPartitionedCall/vad_model/separable_conv2d/BiasAdd/ReadVariableOp:0"].astype(np.float32)
        write_tensor(fout, "sep_conv_0_bias", b0)

        # ── Separable Conv Layer 1 (1D) ──
        dw1 = weights["const_fold_opt__179"].astype(np.float32)
        write_tensor(fout, "sep_conv_1_dw", dw1)

        pw1 = weights["StatefulPartitionedCall/vad_model/separable_conv1d/ExpandDims_2:0"].astype(np.float32)
        write_tensor(fout, "sep_conv_1_pw", pw1)

        b1 = weights["StatefulPartitionedCall/vad_model/separable_conv1d/BiasAdd/ReadVariableOp:0"].astype(np.float32)
        write_tensor(fout, "sep_conv_1_bias", b1)

        # ── Separable Conv Layer 2 (1D) ──
        dw2 = weights["const_fold_opt__180"].astype(np.float32)
        write_tensor(fout, "sep_conv_2_dw", dw2)

        pw2 = weights["StatefulPartitionedCall/vad_model/separable_conv1d_1/ExpandDims_2:0"].astype(np.float32)
        write_tensor(fout, "sep_conv_2_pw", pw2)

        b2 = weights["StatefulPartitionedCall/vad_model/separable_conv1d_1/BiasAdd/ReadVariableOp:0"].astype(np.float32)
        write_tensor(fout, "sep_conv_2_bias", b2)

        # ── LSTM Layer 0 ──
        # W: (1, 256, 80) → squeeze to (256, 80), reorder gates
        W0 = weights["W0__70"].squeeze(0)  # (256, 80)
        W0 = reorder_lstm_gates(W0, hidden_dim, axis=0)
        write_tensor(fout, "lstm_0_ih_weight", W0)

        # R: (1, 256, 64) → squeeze to (256, 64), reorder gates
        R0 = weights["R0__71"].squeeze(0)  # (256, 64)
        R0 = reorder_lstm_gates(R0, hidden_dim, axis=0)
        write_tensor(fout, "lstm_0_hh_weight", R0)

        # B: (1, 512) → squeeze to (512,), split into ih_bias[256] + hh_bias[256]
        B0 = weights["B0__72"].squeeze(0)  # (512,)
        B0_ih = B0[:256]  # input-hidden bias
        B0_hh = B0[256:]  # hidden-hidden bias
        B0_ih = reorder_lstm_gates(B0_ih.reshape(4, hidden_dim), hidden_dim, axis=0).flatten()
        B0_hh = reorder_lstm_gates(B0_hh.reshape(4, hidden_dim), hidden_dim, axis=0).flatten()
        write_tensor(fout, "lstm_0_ih_bias", B0_ih)
        write_tensor(fout, "lstm_0_hh_bias", B0_hh)

        # ── LSTM Layer 1 ──
        W1 = weights["W0__99"].squeeze(0)  # (256, 64)
        W1 = reorder_lstm_gates(W1, hidden_dim, axis=0)
        write_tensor(fout, "lstm_1_ih_weight", W1)

        R1 = weights["R0__100"].squeeze(0)  # (256, 64)
        R1 = reorder_lstm_gates(R1, hidden_dim, axis=0)
        write_tensor(fout, "lstm_1_hh_weight", R1)

        B1 = weights["B0__101"].squeeze(0)  # (512,)
        B1_ih = B1[:256]
        B1_hh = B1[256:]
        B1_ih = reorder_lstm_gates(B1_ih.reshape(4, hidden_dim), hidden_dim, axis=0).flatten()
        B1_hh = reorder_lstm_gates(B1_hh.reshape(4, hidden_dim), hidden_dim, axis=0).flatten()
        write_tensor(fout, "lstm_1_ih_bias", B1_ih)
        write_tensor(fout, "lstm_1_hh_bias", B1_hh)

        # ── Dense Layer 0 (128→32) ──
        # Transpose so ggml gets ne[0]=in_features for mul_mat
        d0_w = weights["StatefulPartitionedCall/vad_model/dense_3/Tensordot/ReadVariableOp:0"].astype(np.float32)
        write_tensor(fout, "dense_0_weight", d0_w.T.copy())  # (128,32) → (32,128) → ggml [128,32]

        d0_b = weights["StatefulPartitionedCall/vad_model/dense_3/BiasAdd/ReadVariableOp:0"].astype(np.float32)
        write_tensor(fout, "dense_0_bias", d0_b)  # (32,)

        # ── Dense Layer 1 (32→1) ──
        d1_w = weights["StatefulPartitionedCall/vad_model/dense_5/Tensordot/ReadVariableOp:0"].astype(np.float32)
        write_tensor(fout, "dense_1_weight", d1_w.T.copy())  # (32,1) → (1,32) → ggml [32,1]

        d1_b = weights["StatefulPartitionedCall/vad_model/dense_5/BiasAdd/ReadVariableOp:0"].astype(np.float32)
        write_tensor(fout, "dense_1_bias", d1_b)  # (1,)

    file_size = os.path.getsize(output_path)
    print(f"\nDone! Written to {output_path} ({file_size} bytes, {file_size/1024:.1f} KB)")
    n_tensors = 9 + 8 + 4  # 3 conv layers * 3 + 2 LSTM * 4 + 2 dense * 2
    print(f"Total tensors: {n_tensors}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert TEN-VAD ONNX to GGML")
    parser.add_argument("--onnx", default="/home/dan/Projects/ten-vad/src/onnx_model/ten-vad.onnx",
                        help="Path to ONNX model")
    parser.add_argument("--output", default="dist/models/ten-vad-ggml.bin",
                        help="Path to output GGML file")
    args = parser.parse_args()
    convert(args.onnx, args.output)
