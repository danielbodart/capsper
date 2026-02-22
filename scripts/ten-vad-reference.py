#!/usr/bin/env python3
"""Reference validation harness for TEN-VAD using the prebuilt .so."""
import ctypes
import struct
import sys

PREBUILT_SO = "/home/dan/Projects/ten-vad/lib/Linux/x64/libten_vad.so"
HOP_SIZE = 256
THRESHOLD = 0.5

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <wav_file>", file=sys.stderr)
        sys.exit(1)

    wav_path = sys.argv[1]
    with open(wav_path, "rb") as f:
        data = f.read()

    # Parse WAV header — find "data" chunk
    assert data[:4] == b"RIFF", "Not a WAV file"
    idx = 12
    while idx < len(data) - 8:
        chunk_id = data[idx:idx+4]
        chunk_size = struct.unpack_from("<I", data, idx+4)[0]
        if chunk_id == b"data":
            pcm_start = idx + 8
            pcm_end = pcm_start + chunk_size
            break
        idx += 8 + chunk_size
    else:
        print("No data chunk found", file=sys.stderr)
        sys.exit(1)

    pcm = data[pcm_start:pcm_end]
    n_samples = len(pcm) // 2
    samples = (ctypes.c_int16 * n_samples).from_buffer_copy(pcm)

    # Load .so
    lib = ctypes.CDLL(PREBUILT_SO)
    lib.ten_vad_create.restype = ctypes.c_int
    lib.ten_vad_process.restype = ctypes.c_int
    lib.ten_vad_destroy.restype = ctypes.c_int

    handle = ctypes.c_void_p()
    rc = lib.ten_vad_create(ctypes.byref(handle), ctypes.c_size_t(HOP_SIZE), ctypes.c_float(THRESHOLD))
    assert rc == 0, f"ten_vad_create failed: {rc}"

    prob = ctypes.c_float()
    flag = ctypes.c_int()

    frame_idx = 0
    offset = 0
    while offset + HOP_SIZE <= n_samples:
        hop = (ctypes.c_int16 * HOP_SIZE).from_buffer_copy(
            pcm, offset * 2
        )
        rc = lib.ten_vad_process(handle, hop, ctypes.c_size_t(HOP_SIZE),
                                  ctypes.byref(prob), ctypes.byref(flag))
        assert rc == 0, f"ten_vad_process failed at frame {frame_idx}: {rc}"
        print(f"{frame_idx}\t{prob.value:.6f}\t{flag.value}")
        frame_idx += 1
        offset += HOP_SIZE

    lib.ten_vad_destroy(ctypes.byref(handle))
    print(f"# {frame_idx} frames processed", file=sys.stderr)

if __name__ == "__main__":
    main()
