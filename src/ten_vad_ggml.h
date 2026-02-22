/**
 * TEN-VAD via GGML runtime — zero extra dependencies beyond whisper.cpp's ggml.
 *
 * Feature extraction (pre-emphasis, STFT, mel filterbank) ported from TEN-VAD.
 * Model inference uses ggml graph with weights loaded from ten-vad-ggml.bin.
 */
#ifndef TEN_VAD_GGML_H
#define TEN_VAD_GGML_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ten_vad_ctx ten_vad_ctx;

/**
 * Load TEN-VAD GGML model and initialize feature extraction state.
 * Returns NULL on failure.
 */
ten_vad_ctx * ten_vad_ggml_init(const char * model_path);

/**
 * Process one hop of raw int16 PCM audio (256 samples at 16kHz).
 * Returns speech probability in [0, 1].
 * State (LSTM hidden/cell, STFT overlap, feature context) is carried across calls.
 */
float ten_vad_ggml_process(ten_vad_ctx * ctx, const int16_t * samples, int n_samples);

/**
 * Reset all stateful components (LSTM states, STFT buffer, feature context).
 * Call at segment boundaries.
 */
void ten_vad_ggml_reset(ten_vad_ctx * ctx);

/**
 * Free all resources.
 */
void ten_vad_ggml_free(ten_vad_ctx * ctx);

#ifdef __cplusplus
}
#endif

#endif /* TEN_VAD_GGML_H */
