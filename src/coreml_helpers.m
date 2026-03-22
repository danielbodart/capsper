// coreml_helpers.m — CoreML inference bridge for Nemotron RNNT
//
// Flat C API callable from Zig. Loads encoder + fused decoder+joint
// CoreML models, runs predictions, manages cache state.
//
// All tensor data is f32 on the Zig side. CoreML handles f32↔f16
// conversion internally (models were converted with FP16 precision).

#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// Use void* for ObjC objects in a C struct (ARC can't manage objects in plain C structs).
// Ownership is managed manually via CFBridgingRetain/CFBridgingRelease.
typedef struct {
    void *encoder;       // MLModel* (retained)
    void *decoder;       // MLModel* (retained)
    void *cache_channel; // MLMultiArray* (retained)
    void *cache_time;    // MLMultiArray* (retained)
    void *cache_len;     // MLMultiArray* (retained)
} CapsperCoreMLModels;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Create an MLMultiArray wrapping an existing f32 buffer (zero-copy).
/// The caller must ensure the buffer outlives the MLMultiArray.
static MLMultiArray *wrap_f32(float *data, NSArray<NSNumber *> *shape, NSInteger count) {
    NSMutableArray<NSNumber *> *strides = [NSMutableArray arrayWithCapacity:shape.count];
    NSInteger stride = count;
    for (NSNumber *dim in shape) {
        stride /= dim.integerValue;
        [strides addObject:@(stride)];
    }
    NSError *error = nil;
    MLMultiArray *arr = [[MLMultiArray alloc]
        initWithDataPointer:data
                      shape:shape
                   dataType:MLMultiArrayDataTypeFloat32
                    strides:strides
                deallocator:^(void *bytes) { /* Zig owns the memory */ }
                      error:&error];
    if (error) {
        NSLog(@"capsper_coreml: wrap_f32 error: %@", error);
        return nil;
    }
    return arr;
}

/// Create an MLMultiArray wrapping an existing i32 buffer (zero-copy).
static MLMultiArray *wrap_i32(int32_t *data, NSArray<NSNumber *> *shape, NSInteger count) {
    NSMutableArray<NSNumber *> *strides = [NSMutableArray arrayWithCapacity:shape.count];
    NSInteger stride = count;
    for (NSNumber *dim in shape) {
        stride /= dim.integerValue;
        [strides addObject:@(stride)];
    }
    NSError *error = nil;
    MLMultiArray *arr = [[MLMultiArray alloc]
        initWithDataPointer:data
                      shape:shape
                   dataType:MLMultiArrayDataTypeInt32
                    strides:strides
                deallocator:^(void *bytes) { /* Zig owns the memory */ }
                      error:&error];
    if (error) {
        NSLog(@"capsper_coreml: wrap_i32 error: %@", error);
        return nil;
    }
    return arr;
}

/// Create a fresh zero-filled MLMultiArray.
static MLMultiArray *make_zeros(NSArray<NSNumber *> *shape, MLMultiArrayDataType dtype) {
    NSError *error = nil;
    MLMultiArray *arr = [[MLMultiArray alloc] initWithShape:shape
                                                  dataType:dtype
                                                     error:&error];
    if (error) {
        NSLog(@"capsper_coreml: make_zeros error: %@", error);
        return nil;
    }
    // MLMultiArray is not guaranteed to be zero-initialized
    memset(arr.dataPointer, 0, arr.count * (dtype == MLMultiArrayDataTypeFloat32 ? 4 : 4));
    return arr;
}

/// Copy MLMultiArray float data into a flat f32 buffer.
/// Handles f16→f32 conversion if the MLMultiArray is Float16.
static void copy_to_f32(MLMultiArray *src, float *dst, NSInteger count) {
    if (src.dataType == MLMultiArrayDataTypeFloat32) {
        memcpy(dst, src.dataPointer, count * sizeof(float));
    } else if (src.dataType == MLMultiArrayDataTypeFloat16) {
        // vImage f16→f32 conversion
        const uint16_t *f16 = (const uint16_t *)src.dataPointer;
        for (NSInteger i = 0; i < count; i++) {
            // Use ARM NEON half-precision conversion
            __fp16 h;
            memcpy(&h, &f16[i], sizeof(__fp16));
            dst[i] = (float)h;
        }
    } else {
        NSLog(@"capsper_coreml: unexpected dtype %ld", (long)src.dataType);
        memset(dst, 0, count * sizeof(float));
    }
}

/// Copy MLMultiArray to another MLMultiArray (for cache updates).
static void copy_array(MLMultiArray *src, MLMultiArray *dst) {
    NSInteger bytes = src.count;
    if (src.dataType == MLMultiArrayDataTypeFloat32) bytes *= 4;
    else if (src.dataType == MLMultiArrayDataTypeFloat16) bytes *= 2;
    else if (src.dataType == MLMultiArrayDataTypeInt32) bytes *= 4;
    memcpy(dst.dataPointer, src.dataPointer, bytes);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Load CoreML models from a directory containing encoder.mlpackage and decoder.mlpackage.
/// Returns NULL on failure.
CapsperCoreMLModels *capsper_coreml_load(const char *model_dir) {
    @autoreleasepool {
        NSString *dir = [NSString stringWithUTF8String:model_dir];

        MLModelConfiguration *config = [[MLModelConfiguration alloc] init];
        config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;

        NSError *error = nil;

        // Load encoder
        NSString *enc_path = [dir stringByAppendingPathComponent:@"encoder.mlpackage"];
        NSURL *enc_url = [NSURL fileURLWithPath:enc_path];
        MLModel *encoder = [MLModel modelWithContentsOfURL:enc_url
                                             configuration:config
                                                     error:&error];
        if (error || !encoder) {
            // Try .mlmodelc (compiled) format
            enc_path = [dir stringByAppendingPathComponent:@"encoder.mlmodelc"];
            enc_url = [NSURL fileURLWithPath:enc_path];
            error = nil;
            encoder = [MLModel modelWithContentsOfURL:enc_url
                                        configuration:config
                                                error:&error];
            if (error || !encoder) {
                NSLog(@"capsper_coreml: failed to load encoder: %@", error);
                return NULL;
            }
        }

        // Load decoder (CPU only)
        MLModelConfiguration *dec_config = [[MLModelConfiguration alloc] init];
        dec_config.computeUnits = MLComputeUnitsCPUOnly;

        NSString *dec_path = [dir stringByAppendingPathComponent:@"decoder.mlpackage"];
        NSURL *dec_url = [NSURL fileURLWithPath:dec_path];
        error = nil;
        MLModel *decoder = [MLModel modelWithContentsOfURL:dec_url
                                             configuration:dec_config
                                                     error:&error];
        if (error || !decoder) {
            dec_path = [dir stringByAppendingPathComponent:@"decoder.mlmodelc"];
            dec_url = [NSURL fileURLWithPath:dec_path];
            error = nil;
            decoder = [MLModel modelWithContentsOfURL:dec_url
                                        configuration:dec_config
                                                error:&error];
            if (error || !decoder) {
                NSLog(@"capsper_coreml: failed to load decoder: %@", error);
                return NULL;
            }
        }

        CapsperCoreMLModels *models = (CapsperCoreMLModels *)calloc(1, sizeof(CapsperCoreMLModels));
        models->encoder = (void *)CFBridgingRetain(encoder);
        models->decoder = (void *)CFBridgingRetain(decoder);

        // Initialize cache state (batch-first: [1, 24, 70, 1024], [1, 24, 1024, 8], [1])
        models->cache_channel = (void *)CFBridgingRetain(
            make_zeros(@[@1, @24, @70, @1024], MLMultiArrayDataTypeFloat32));
        models->cache_time = (void *)CFBridgingRetain(
            make_zeros(@[@1, @24, @1024, @8], MLMultiArrayDataTypeFloat32));
        models->cache_len = (void *)CFBridgingRetain(
            make_zeros(@[@1], MLMultiArrayDataTypeInt32));

        NSLog(@"capsper_coreml: models loaded from %@", dir);
        return models;
    }
}

/// Release all CoreML models and cache state.
void capsper_coreml_release(CapsperCoreMLModels *models) {
    if (!models) return;
    @autoreleasepool {
        if (models->encoder) CFBridgingRelease(models->encoder);
        if (models->decoder) CFBridgingRelease(models->decoder);
        if (models->cache_channel) CFBridgingRelease(models->cache_channel);
        if (models->cache_time) CFBridgingRelease(models->cache_time);
        if (models->cache_len) CFBridgingRelease(models->cache_len);
        free(models);
    }
}

/// Reset encoder cache state to zeros (call between utterances).
void capsper_coreml_reset_state(CapsperCoreMLModels *models) {
    if (!models) return;
    @autoreleasepool {
        MLMultiArray *ch = (__bridge MLMultiArray *)(models->cache_channel);
        MLMultiArray *t = (__bridge MLMultiArray *)(models->cache_time);
        MLMultiArray *l = (__bridge MLMultiArray *)(models->cache_len);
        memset(ch.dataPointer, 0, ch.count * sizeof(float));
        memset(t.dataPointer, 0, t.count * sizeof(float));
        memset(l.dataPointer, 0, l.count * sizeof(int32_t));
    }
}

/// Run encoder on one mel chunk.
///
/// Inputs:
///   mel_data: [1, 128, 65] f32 (band-major mel spectrogram)
///
/// Outputs:
///   out_encoded: [1, 1024, T_out] f32 (encoder features, band-major)
///   out_encoded_len: number of valid encoder output frames
///
/// Encoder caches are managed internally — updated in-place after each call.
/// Returns 0 on success, -1 on error.
int capsper_coreml_run_encoder(
    CapsperCoreMLModels *models,
    const float *mel_data,
    float *out_encoded,
    int32_t *out_encoded_len
) {
    @autoreleasepool {
        MLModel *encoder = (__bridge MLModel *)(models->encoder);
        MLMultiArray *cache_ch = (__bridge MLMultiArray *)(models->cache_channel);
        MLMultiArray *cache_time = (__bridge MLMultiArray *)(models->cache_time);
        MLMultiArray *cache_len = (__bridge MLMultiArray *)(models->cache_len);

        // Wrap mel input (zero-copy)
        MLMultiArray *mel = wrap_f32((float *)mel_data, @[@1, @128, @65], 1 * 128 * 65);
        if (!mel) return -1;

        // Build feature provider
        NSError *error = nil;
        MLDictionaryFeatureProvider *input = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{
                @"audio_signal": mel,
                @"cache_last_channel": cache_ch,
                @"cache_last_time": cache_time,
                @"cache_last_channel_len": cache_len,
            }
            error:&error];
        if (error) {
            NSLog(@"capsper_coreml: encoder input error: %@", error);
            return -1;
        }

        // Run prediction
        id<MLFeatureProvider> output = [encoder predictionFromFeatures:input error:&error];
        if (error) {
            NSLog(@"capsper_coreml: encoder prediction error: %@", error);
            return -1;
        }

        // Extract outputs
        MLMultiArray *encoded = [output featureValueForName:@"encoded"].multiArrayValue;
        MLMultiArray *enc_len = [output featureValueForName:@"encoded_length"].multiArrayValue;
        MLMultiArray *new_ch = [output featureValueForName:@"cache_channel_out"].multiArrayValue;
        MLMultiArray *new_time = [output featureValueForName:@"cache_time_out"].multiArrayValue;
        MLMultiArray *new_len = [output featureValueForName:@"cache_len_out"].multiArrayValue;

        if (!encoded || !enc_len || !new_ch || !new_time || !new_len) {
            NSLog(@"capsper_coreml: encoder missing output");
            return -1;
        }

        // Copy encoded output to caller's buffer
        copy_to_f32(encoded, out_encoded, encoded.count);

        // Read encoded length
        if (enc_len.dataType == MLMultiArrayDataTypeInt32) {
            *out_encoded_len = ((int32_t *)enc_len.dataPointer)[0];
        } else {
            *out_encoded_len = (int32_t)[[enc_len objectAtIndexedSubscript:0] intValue];
        }

        // Update caches in-place
        copy_array(new_ch, cache_ch);
        copy_array(new_time, cache_time);
        copy_array(new_len, cache_len);

        return 0;
    }
}

/// Run fused decoder+joint on one encoder frame.
///
/// Inputs:
///   enc_frame: [1, 1024, 1] f32 (single encoder output frame)
///   token: last emitted token ID (i32)
///   state_h: [2, 1, 640] f32 (LSTM hidden state)
///   state_c: [2, 1, 640] f32 (LSTM cell state)
///
/// Outputs:
///   out_logits: [1025] f32 (vocab logits, first element of [1, 1025])
///   out_state_h: [2, 1, 640] f32 (updated LSTM hidden)
///   out_state_c: [2, 1, 640] f32 (updated LSTM cell)
///
/// Returns 0 on success, -1 on error.
int capsper_coreml_run_decoder(
    CapsperCoreMLModels *models,
    const float *enc_frame,
    int32_t token,
    const float *state_h,
    const float *state_c,
    float *out_logits,
    float *out_state_h,
    float *out_state_c
) {
    @autoreleasepool {
        MLModel *decoder = (__bridge MLModel *)(models->decoder);

        // Wrap inputs (zero-copy where possible)
        MLMultiArray *enc = wrap_f32((float *)enc_frame, @[@1, @1024, @1], 1024);
        if (!enc) return -1;

        // targets: [1, 1] i32
        int32_t targets_buf[1] = { token };
        MLMultiArray *targets = wrap_i32(targets_buf, @[@1, @1], 1);
        if (!targets) return -1;

        // target_length: [1] i32
        int32_t tgt_len_buf[1] = { 1 };
        MLMultiArray *tgt_len = wrap_i32(tgt_len_buf, @[@1], 1);
        if (!tgt_len) return -1;

        // LSTM states: [2, 1, 640] f32
        MLMultiArray *h = wrap_f32((float *)state_h, @[@2, @1, @640], 2 * 640);
        MLMultiArray *c = wrap_f32((float *)state_c, @[@2, @1, @640], 2 * 640);
        if (!h || !c) return -1;

        NSError *error = nil;
        MLDictionaryFeatureProvider *input = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{
                @"encoder_outputs": enc,
                @"targets": targets,
                @"target_length": tgt_len,
                @"input_states_1": h,
                @"input_states_2": c,
            }
            error:&error];
        if (error) {
            NSLog(@"capsper_coreml: decoder input error: %@", error);
            return -1;
        }

        id<MLFeatureProvider> output = [decoder predictionFromFeatures:input error:&error];
        if (error) {
            NSLog(@"capsper_coreml: decoder prediction error: %@", error);
            return -1;
        }

        MLMultiArray *logits = [output featureValueForName:@"outputs"].multiArrayValue;
        MLMultiArray *new_h = [output featureValueForName:@"output_states_1"].multiArrayValue;
        MLMultiArray *new_c = [output featureValueForName:@"output_states_2"].multiArrayValue;

        if (!logits || !new_h || !new_c) {
            NSLog(@"capsper_coreml: decoder missing output");
            return -1;
        }

        copy_to_f32(logits, out_logits, logits.count);
        copy_to_f32(new_h, out_state_h, new_h.count);
        copy_to_f32(new_c, out_state_c, new_c.count);

        return 0;
    }
}
