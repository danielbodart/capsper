const cimport = @cImport({
    @cInclude("whisper.h");
    @cInclude("ggml-backend.h");
});

// Re-export all declarations from the C import
pub const whisper_context = cimport.whisper_context;
pub const whisper_state = cimport.whisper_state;
pub const whisper_token = cimport.whisper_token;
pub const whisper_vad_context = cimport.whisper_vad_context;
pub const whisper_vad_params = cimport.whisper_vad_params;
pub const whisper_vad_segments = cimport.whisper_vad_segments;

// Context params and functions
pub const whisper_context_default_params = cimport.whisper_context_default_params;
pub const whisper_init_from_file_with_params = cimport.whisper_init_from_file_with_params;
pub const whisper_init_state = cimport.whisper_init_state;
pub const whisper_free = cimport.whisper_free;
pub const whisper_free_state = cimport.whisper_free_state;

// Processing
pub const whisper_pcm_to_mel_with_state = cimport.whisper_pcm_to_mel_with_state;
pub const whisper_set_mel_with_state = cimport.whisper_set_mel_with_state;
pub const whisper_encode_with_state = cimport.whisper_encode_with_state;
pub const whisper_decode_with_state_and_aheads = cimport.whisper_decode_with_state_and_aheads;
pub const whisper_state_get_aheads_cross_qks = cimport.whisper_state_get_aheads_cross_qks;
pub const whisper_get_logits_from_state = cimport.whisper_get_logits_from_state;

// Tokens
pub const whisper_token_sot = cimport.whisper_token_sot;
pub const whisper_token_eot = cimport.whisper_token_eot;
pub const whisper_token_lang = cimport.whisper_token_lang;
pub const whisper_token_transcribe = cimport.whisper_token_transcribe;
pub const whisper_token_not = cimport.whisper_token_not;
pub const whisper_token_beg = cimport.whisper_token_beg;
pub const whisper_token_to_str = cimport.whisper_token_to_str;
pub const whisper_lang_id = cimport.whisper_lang_id;
pub const whisper_n_vocab = cimport.whisper_n_vocab;
pub const whisper_n_len_from_state = cimport.whisper_n_len_from_state;
pub const whisper_model_n_mels = cimport.whisper_model_n_mels;
pub const whisper_token_prev = cimport.whisper_token_prev;
pub const whisper_tokenize = cimport.whisper_tokenize;

// Enums/constants
pub const WHISPER_AHEADS_LARGE_V3_TURBO = cimport.WHISPER_AHEADS_LARGE_V3_TURBO;
pub const WHISPER_SAMPLING_GREEDY = cimport.WHISPER_SAMPLING_GREEDY;

// High-level API (for warmup)
pub const whisper_full = cimport.whisper_full;
pub const whisper_full_default_params = cimport.whisper_full_default_params;
pub const whisper_full_n_segments = cimport.whisper_full_n_segments;
pub const whisper_full_get_segment_text = cimport.whisper_full_get_segment_text;

// VAD
pub const whisper_vad_default_context_params = cimport.whisper_vad_default_context_params;
pub const whisper_vad_default_params = cimport.whisper_vad_default_params;
pub const whisper_vad_init_from_file_with_params = cimport.whisper_vad_init_from_file_with_params;
pub const whisper_vad_detect_speech = cimport.whisper_vad_detect_speech;
pub const whisper_vad_n_probs = cimport.whisper_vad_n_probs;
pub const whisper_vad_probs = cimport.whisper_vad_probs;
pub const whisper_vad_segments_from_samples = cimport.whisper_vad_segments_from_samples;
pub const whisper_vad_segments_n_segments = cimport.whisper_vad_segments_n_segments;
pub const whisper_vad_segments_get_segment_t0 = cimport.whisper_vad_segments_get_segment_t0;
pub const whisper_vad_segments_get_segment_t1 = cimport.whisper_vad_segments_get_segment_t1;
pub const whisper_vad_free_segments = cimport.whisper_vad_free_segments;
pub const whisper_vad_free = cimport.whisper_vad_free;

// ggml backend device enumeration
pub const ggml_backend_dev_count = cimport.ggml_backend_dev_count;
pub const ggml_backend_dev_get = cimport.ggml_backend_dev_get;
pub const ggml_backend_dev_name = cimport.ggml_backend_dev_name;
pub const ggml_backend_dev_description = cimport.ggml_backend_dev_description;
pub const ggml_backend_dev_type = cimport.ggml_backend_dev_type;
pub const GGML_BACKEND_DEVICE_TYPE_GPU = cimport.GGML_BACKEND_DEVICE_TYPE_GPU;
