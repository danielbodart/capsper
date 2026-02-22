#!/usr/bin/env python3
"""Debug TEN-VAD GGML reimplementation by comparing against the native .so.

Pipeline: int16 → pre-emphasis → STFT (Hann768, FFT1024) → format2→format1
          → power spectrum → mel → log → z-norm → context stack
          → conv layers → LSTM → dense → sigmoid

Usage:
    python3 scripts/debug-ten-vad-ggml.py test/jfk.wav
    python3 scripts/debug-ten-vad-ggml.py test/jfk.wav --onnx /path/to/ten-vad.onnx
    python3 scripts/debug-ten-vad-ggml.py test/jfk.wav --features-only  # skip model, just compare features
"""
import argparse
import ctypes
import os
import struct
import sys
import wave

import numpy as np

# ── Constants (must match ten_vad_ggml.c and ten-vad/src exactly) ──

FS = 16000
HOP_SIZE = 256
WINDOW_SIZE = 768
FFT_SIZE = 1024
N_BINS = FFT_SIZE // 2 + 1  # 513
MEL_BANDS = 40
FEA_LEN = MEL_BANDS + 1     # 41 = 40 mel + 1 pitch
CONTEXT_LEN = 3
HIDDEN_DIM = 64
EPS = 1e-20
PREEMPH = 0.97

# ── Hardcoded normalization constants from coeff.h ──

FEATURE_MEANS = np.array([
    -8.198236465454e+00, -6.265716552734e+00, -5.483818531036e+00,
    -4.758691310883e+00, -4.417088985443e+00, -4.142892837524e+00,
    -3.912850379944e+00, -3.845927953720e+00, -3.657090425491e+00,
    -3.723418712616e+00, -3.876134157181e+00, -3.843890905380e+00,
    -3.690405130386e+00, -3.756065845490e+00, -3.698696136475e+00,
    -3.650463104248e+00, -3.700468778610e+00, -3.567321300507e+00,
    -3.498900175095e+00, -3.477807044983e+00, -3.458816051483e+00,
    -3.444923877716e+00, -3.401328563690e+00, -3.306261301041e+00,
    -3.278556823730e+00, -3.233250856400e+00, -3.198616027832e+00,
    -3.204526424408e+00, -3.208798646927e+00, -3.257838010788e+00,
    -3.381376743317e+00, -3.534021377563e+00, -3.640867948532e+00,
    -3.726858854294e+00, -3.773730993271e+00, -3.804667234421e+00,
    -3.832901000977e+00, -3.871120452881e+00, -3.990592956543e+00,
    -4.480289459229e+00, 9.235690307617e+01,
], dtype=np.float32)

FEATURE_STDS = np.array([
    5.166063785553e+00, 4.977209568024e+00, 4.698895931244e+00,
    4.630621433258e+00, 4.634347915649e+00, 4.641156196594e+00,
    4.640676498413e+00, 4.666367053986e+00, 4.650534629822e+00,
    4.640020847321e+00, 4.637400150299e+00, 4.620099067688e+00,
    4.596316337585e+00, 4.562654972076e+00, 4.554360389709e+00,
    4.566910743713e+00, 4.562489986420e+00, 4.562412738800e+00,
    4.585299491882e+00, 4.600179672241e+00, 4.592845916748e+00,
    4.585922718048e+00, 4.583496570587e+00, 4.626092910767e+00,
    4.626957893372e+00, 4.626289367676e+00, 4.637005805969e+00,
    4.683015823364e+00, 4.726813793182e+00, 4.734289646149e+00,
    4.753227233887e+00, 4.849722862244e+00, 4.869434833527e+00,
    4.884482860565e+00, 4.921327114105e+00, 4.959212303162e+00,
    4.996619224548e+00, 5.044823646545e+00, 5.072216987610e+00,
    5.096439361572e+00, 1.152136917114e+02,
], dtype=np.float32)

# Hann window from coeff.h (768-point, matches exactly)
HANN_WINDOW = np.array([
    0.0000000e+00, 1.6733041e-05, 6.6931045e-05, 1.5059065e-04,
    2.6770626e-04, 4.1827004e-04, 6.0227190e-04, 8.1969953e-04,
    1.0705384e-03, 1.3547717e-03, 1.6723803e-03, 2.0233432e-03,
    2.4076367e-03, 2.8252351e-03, 3.2761105e-03, 3.7602327e-03,
    4.2775693e-03, 4.8280857e-03, 5.4117450e-03, 6.0285082e-03,
    6.6783340e-03, 7.3611788e-03, 8.0769970e-03, 8.8257407e-03,
    9.6073598e-03, 1.0421802e-02, 1.1269013e-02, 1.2148935e-02,
    1.3061510e-02, 1.4006678e-02, 1.4984373e-02, 1.5994532e-02,
    1.7037087e-02, 1.8111967e-02, 1.9219101e-02, 2.0358415e-02,
    2.1529832e-02, 2.2733274e-02, 2.3968661e-02, 2.5235910e-02,
    2.6534935e-02, 2.7865651e-02, 2.9227967e-02, 3.0621794e-02,
    3.2047037e-02, 3.3503601e-02, 3.4991388e-02, 3.6510300e-02,
    3.8060234e-02, 3.9641086e-02, 4.1252752e-02, 4.2895122e-02,
    4.4568088e-02, 4.6271536e-02, 4.8005353e-02, 4.9769424e-02,
    5.1563629e-02, 5.3387849e-02, 5.5241962e-02, 5.7125844e-02,
    5.9039368e-02, 6.0982406e-02, 6.2954829e-02, 6.4956504e-02,
    6.6987298e-02, 6.9047074e-02, 7.1135695e-02, 7.3253021e-02,
    7.5398909e-02, 7.7573217e-02, 7.9775799e-02, 8.2006508e-02,
    8.4265194e-02, 8.6551706e-02, 8.8865891e-02, 9.1207593e-02,
    9.3576658e-02, 9.5972925e-02, 9.8396234e-02, 1.0084642e-01,
    1.0332333e-01, 1.0582679e-01, 1.0835663e-01, 1.1091268e-01,
    1.1349477e-01, 1.1610274e-01, 1.1873640e-01, 1.2139558e-01,
    1.2408010e-01, 1.2678978e-01, 1.2952444e-01, 1.3228389e-01,
    1.3506796e-01, 1.3787646e-01, 1.4070919e-01, 1.4356597e-01,
    1.4644661e-01, 1.4935091e-01, 1.5227868e-01, 1.5522973e-01,
    1.5820385e-01, 1.6120085e-01, 1.6422052e-01, 1.6726267e-01,
    1.7032709e-01, 1.7341358e-01, 1.7652192e-01, 1.7965192e-01,
    1.8280336e-01, 1.8597603e-01, 1.8916971e-01, 1.9238420e-01,
    1.9561929e-01, 1.9887474e-01, 2.0215035e-01, 2.0544589e-01,
    2.0876115e-01, 2.1209590e-01, 2.1544993e-01, 2.1882300e-01,
    2.2221488e-01, 2.2562536e-01, 2.2905421e-01, 2.3250119e-01,
    2.3596607e-01, 2.3944863e-01, 2.4294863e-01, 2.4646583e-01,
    2.5000000e-01, 2.5355090e-01, 2.5711830e-01, 2.6070196e-01,
    2.6430163e-01, 2.6791708e-01, 2.7154806e-01, 2.7519434e-01,
    2.7885565e-01, 2.8253178e-01, 2.8622245e-01, 2.8992744e-01,
    2.9364649e-01, 2.9737934e-01, 3.0112576e-01, 3.0488549e-01,
    3.0865828e-01, 3.1244388e-01, 3.1624203e-01, 3.2005248e-01,
    3.2387498e-01, 3.2770926e-01, 3.3155507e-01, 3.3541216e-01,
    3.3928027e-01, 3.4315913e-01, 3.4704849e-01, 3.5094809e-01,
    3.5485766e-01, 3.5877695e-01, 3.6270569e-01, 3.6664362e-01,
    3.7059048e-01, 3.7454600e-01, 3.7850991e-01, 3.8248196e-01,
    3.8646187e-01, 3.9044938e-01, 3.9444422e-01, 3.9844613e-01,
    4.0245484e-01, 4.0647007e-01, 4.1049157e-01, 4.1451906e-01,
    4.1855226e-01, 4.2259092e-01, 4.2663476e-01, 4.3068351e-01,
    4.3473690e-01, 4.3879466e-01, 4.4285652e-01, 4.4692220e-01,
    4.5099143e-01, 4.5506394e-01, 4.5913946e-01, 4.6321772e-01,
    4.6729844e-01, 4.7138134e-01, 4.7546616e-01, 4.7955263e-01,
    4.8364046e-01, 4.8772939e-01, 4.9181913e-01, 4.9590943e-01,
    5.0000000e-01, 5.0409057e-01, 5.0818087e-01, 5.1227061e-01,
    5.1635954e-01, 5.2044737e-01, 5.2453384e-01, 5.2861866e-01,
    5.3270156e-01, 5.3678228e-01, 5.4086054e-01, 5.4493606e-01,
    5.4900857e-01, 5.5307780e-01, 5.5714348e-01, 5.6120534e-01,
    5.6526310e-01, 5.6931649e-01, 5.7336524e-01, 5.7740908e-01,
    5.8144774e-01, 5.8548094e-01, 5.8950843e-01, 5.9352993e-01,
    5.9754516e-01, 6.0155387e-01, 6.0555578e-01, 6.0955062e-01,
    6.1353813e-01, 6.1751804e-01, 6.2149009e-01, 6.2545400e-01,
    6.2940952e-01, 6.3335638e-01, 6.3729431e-01, 6.4122305e-01,
    6.4514234e-01, 6.4905191e-01, 6.5295151e-01, 6.5684087e-01,
    6.6071973e-01, 6.6458784e-01, 6.6844493e-01, 6.7229074e-01,
    6.7612502e-01, 6.7994752e-01, 6.8375797e-01, 6.8755612e-01,
    6.9134172e-01, 6.9511451e-01, 6.9887424e-01, 7.0262066e-01,
    7.0635351e-01, 7.1007256e-01, 7.1377755e-01, 7.1746822e-01,
    7.2114435e-01, 7.2480566e-01, 7.2845194e-01, 7.3208292e-01,
    7.3569837e-01, 7.3929804e-01, 7.4288170e-01, 7.4644910e-01,
    7.5000000e-01, 7.5353417e-01, 7.5705137e-01, 7.6055137e-01,
    7.6403393e-01, 7.6749881e-01, 7.7094579e-01, 7.7437464e-01,
    7.7778512e-01, 7.8117700e-01, 7.8455007e-01, 7.8790410e-01,
    7.9123885e-01, 7.9455411e-01, 7.9784965e-01, 8.0112526e-01,
    8.0438071e-01, 8.0761580e-01, 8.1083029e-01, 8.1402397e-01,
    8.1719664e-01, 8.2034808e-01, 8.2347808e-01, 8.2658642e-01,
    8.2967291e-01, 8.3273733e-01, 8.3577948e-01, 8.3879915e-01,
    8.4179615e-01, 8.4477027e-01, 8.4772132e-01, 8.5064909e-01,
    8.5355339e-01, 8.5643403e-01, 8.5929081e-01, 8.6212354e-01,
    8.6493204e-01, 8.6771611e-01, 8.7047556e-01, 8.7321022e-01,
    8.7591990e-01, 8.7860442e-01, 8.8126360e-01, 8.8389726e-01,
    8.8650523e-01, 8.8908732e-01, 8.9164337e-01, 8.9417321e-01,
    8.9667667e-01, 8.9915358e-01, 9.0160377e-01, 9.0402708e-01,
    9.0642334e-01, 9.0879241e-01, 9.1113411e-01, 9.1344829e-01,
    9.1573481e-01, 9.1799349e-01, 9.2022420e-01, 9.2242678e-01,
    9.2460109e-01, 9.2674698e-01, 9.2886431e-01, 9.3095293e-01,
    9.3301270e-01, 9.3504350e-01, 9.3704517e-01, 9.3901759e-01,
    9.4096063e-01, 9.4287416e-01, 9.4475804e-01, 9.4661215e-01,
    9.4843637e-01, 9.5023058e-01, 9.5199465e-01, 9.5372846e-01,
    9.5543191e-01, 9.5710488e-01, 9.5874725e-01, 9.6035891e-01,
    9.6193977e-01, 9.6348970e-01, 9.6500861e-01, 9.6649640e-01,
    9.6795296e-01, 9.6937821e-01, 9.7077203e-01, 9.7213435e-01,
    9.7346506e-01, 9.7476409e-01, 9.7603134e-01, 9.7726673e-01,
    9.7847017e-01, 9.7964159e-01, 9.8078090e-01, 9.8188803e-01,
    9.8296291e-01, 9.8400547e-01, 9.8501563e-01, 9.8599332e-01,
    9.8693849e-01, 9.8785107e-01, 9.8873099e-01, 9.8957820e-01,
    9.9039264e-01, 9.9117426e-01, 9.9192300e-01, 9.9263882e-01,
    9.9332167e-01, 9.9397149e-01, 9.9458825e-01, 9.9517191e-01,
    9.9572243e-01, 9.9623977e-01, 9.9672389e-01, 9.9717476e-01,
    9.9759236e-01, 9.9797666e-01, 9.9832762e-01, 9.9864523e-01,
    9.9892946e-01, 9.9918030e-01, 9.9939773e-01, 9.9958173e-01,
    9.9973229e-01, 9.9984941e-01, 9.9993307e-01, 9.9998327e-01,
    1.0000000e+00, 9.9998327e-01, 9.9993307e-01, 9.9984941e-01,
    9.9973229e-01, 9.9958173e-01, 9.9939773e-01, 9.9918030e-01,
    9.9892946e-01, 9.9864523e-01, 9.9832762e-01, 9.9797666e-01,
    9.9759236e-01, 9.9717476e-01, 9.9672389e-01, 9.9623977e-01,
    9.9572243e-01, 9.9517191e-01, 9.9458825e-01, 9.9397149e-01,
    9.9332167e-01, 9.9263882e-01, 9.9192300e-01, 9.9117426e-01,
    9.9039264e-01, 9.8957820e-01, 9.8873099e-01, 9.8785107e-01,
    9.8693849e-01, 9.8599332e-01, 9.8501563e-01, 9.8400547e-01,
    9.8296291e-01, 9.8188803e-01, 9.8078090e-01, 9.7964159e-01,
    9.7847017e-01, 9.7726673e-01, 9.7603134e-01, 9.7476409e-01,
    9.7346506e-01, 9.7213435e-01, 9.7077203e-01, 9.6937821e-01,
    9.6795296e-01, 9.6649640e-01, 9.6500861e-01, 9.6348970e-01,
    9.6193977e-01, 9.6035891e-01, 9.5874725e-01, 9.5710488e-01,
    9.5543191e-01, 9.5372846e-01, 9.5199465e-01, 9.5023058e-01,
    9.4843637e-01, 9.4661215e-01, 9.4475804e-01, 9.4287416e-01,
    9.4096063e-01, 9.3901759e-01, 9.3704517e-01, 9.3504350e-01,
    9.3301270e-01, 9.3095293e-01, 9.2886431e-01, 9.2674698e-01,
    9.2460109e-01, 9.2242678e-01, 9.2022420e-01, 9.1799349e-01,
    9.1573481e-01, 9.1344829e-01, 9.1113411e-01, 9.0879241e-01,
    9.0642334e-01, 9.0402708e-01, 9.0160377e-01, 8.9915358e-01,
    8.9667667e-01, 8.9417321e-01, 8.9164337e-01, 8.8908732e-01,
    8.8650523e-01, 8.8389726e-01, 8.8126360e-01, 8.7860442e-01,
    8.7591990e-01, 8.7321022e-01, 8.7047556e-01, 8.6771611e-01,
    8.6493204e-01, 8.6212354e-01, 8.5929081e-01, 8.5643403e-01,
    8.5355339e-01, 8.5064909e-01, 8.4772132e-01, 8.4477027e-01,
    8.4179615e-01, 8.3879915e-01, 8.3577948e-01, 8.3273733e-01,
    8.2967291e-01, 8.2658642e-01, 8.2347808e-01, 8.2034808e-01,
    8.1719664e-01, 8.1402397e-01, 8.1083029e-01, 8.0761580e-01,
    8.0438071e-01, 8.0112526e-01, 7.9784965e-01, 7.9455411e-01,
    7.9123885e-01, 7.8790410e-01, 7.8455007e-01, 7.8117700e-01,
    7.7778512e-01, 7.7437464e-01, 7.7094579e-01, 7.6749881e-01,
    7.6403393e-01, 7.6055137e-01, 7.5705137e-01, 7.5353417e-01,
    7.5000000e-01, 7.4644910e-01, 7.4288170e-01, 7.3929804e-01,
    7.3569837e-01, 7.3208292e-01, 7.2845194e-01, 7.2480566e-01,
    7.2114435e-01, 7.1746822e-01, 7.1377755e-01, 7.1007256e-01,
    7.0635351e-01, 7.0262066e-01, 6.9887424e-01, 6.9511451e-01,
    6.9134172e-01, 6.8755612e-01, 6.8375797e-01, 6.7994752e-01,
    6.7612502e-01, 6.7229074e-01, 6.6844493e-01, 6.6458784e-01,
    6.6071973e-01, 6.5684087e-01, 6.5295151e-01, 6.4905191e-01,
    6.4514234e-01, 6.4122305e-01, 6.3729431e-01, 6.3335638e-01,
    6.2940952e-01, 6.2545400e-01, 6.2149009e-01, 6.1751804e-01,
    6.1353813e-01, 6.0955062e-01, 6.0555578e-01, 6.0155387e-01,
    5.9754516e-01, 5.9352993e-01, 5.8950843e-01, 5.8548094e-01,
    5.8144774e-01, 5.7740908e-01, 5.7336524e-01, 5.6931649e-01,
    5.6526310e-01, 5.6120534e-01, 5.5714348e-01, 5.5307780e-01,
    5.4900857e-01, 5.4493606e-01, 5.4086054e-01, 5.3678228e-01,
    5.3270156e-01, 5.2861866e-01, 5.2453384e-01, 5.2044737e-01,
    5.1635954e-01, 5.1227061e-01, 5.0818087e-01, 5.0409057e-01,
    5.0000000e-01, 4.9590943e-01, 4.9181913e-01, 4.8772939e-01,
    4.8364046e-01, 4.7955263e-01, 4.7546616e-01, 4.7138134e-01,
    4.6729844e-01, 4.6321772e-01, 4.5913946e-01, 4.5506394e-01,
    4.5099143e-01, 4.4692220e-01, 4.4285652e-01, 4.3879466e-01,
    4.3473690e-01, 4.3068351e-01, 4.2663476e-01, 4.2259092e-01,
    4.1855226e-01, 4.1451906e-01, 4.1049157e-01, 4.0647007e-01,
    4.0245484e-01, 3.9844613e-01, 3.9444422e-01, 3.9044938e-01,
    3.8646187e-01, 3.8248196e-01, 3.7850991e-01, 3.7454600e-01,
    3.7059048e-01, 3.6664362e-01, 3.6270569e-01, 3.5877695e-01,
    3.5485766e-01, 3.5094809e-01, 3.4704849e-01, 3.4315913e-01,
    3.3928027e-01, 3.3541216e-01, 3.3155507e-01, 3.2770926e-01,
    3.2387498e-01, 3.2005248e-01, 3.1624203e-01, 3.1244388e-01,
    3.0865828e-01, 3.0488549e-01, 3.0112576e-01, 2.9737934e-01,
    2.9364649e-01, 2.8992744e-01, 2.8622245e-01, 2.8253178e-01,
    2.7885565e-01, 2.7519434e-01, 2.7154806e-01, 2.6791708e-01,
    2.6430163e-01, 2.6070196e-01, 2.5711830e-01, 2.5355090e-01,
    2.5000000e-01, 2.4646583e-01, 2.4294863e-01, 2.3944863e-01,
    2.3596607e-01, 2.3250119e-01, 2.2905421e-01, 2.2562536e-01,
    2.2221488e-01, 2.1882300e-01, 2.1544993e-01, 2.1209590e-01,
    2.0876115e-01, 2.0544589e-01, 2.0215035e-01, 1.9887474e-01,
    1.9561929e-01, 1.9238420e-01, 1.8916971e-01, 1.8597603e-01,
    1.8280336e-01, 1.7965192e-01, 1.7652192e-01, 1.7341358e-01,
    1.7032709e-01, 1.6726267e-01, 1.6422052e-01, 1.6120085e-01,
    1.5820385e-01, 1.5522973e-01, 1.5227868e-01, 1.4935091e-01,
    1.4644661e-01, 1.4356597e-01, 1.4070919e-01, 1.3787646e-01,
    1.3506796e-01, 1.3228389e-01, 1.2952444e-01, 1.2678978e-01,
    1.2408010e-01, 1.2139558e-01, 1.1873640e-01, 1.1610274e-01,
    1.1349477e-01, 1.1091268e-01, 1.0835663e-01, 1.0582679e-01,
    1.0332333e-01, 1.0084642e-01, 9.8396234e-02, 9.5972925e-02,
    9.3576658e-02, 9.1207593e-02, 8.8865891e-02, 8.6551706e-02,
    8.4265194e-02, 8.2006508e-02, 7.9775799e-02, 7.7573217e-02,
    7.5398909e-02, 7.3253021e-02, 7.1135695e-02, 6.9047074e-02,
    6.6987298e-02, 6.4956504e-02, 6.2954829e-02, 6.0982406e-02,
    5.9039368e-02, 5.7125844e-02, 5.5241962e-02, 5.3387849e-02,
    5.1563629e-02, 4.9769424e-02, 4.8005353e-02, 4.6271536e-02,
    4.4568088e-02, 4.2895122e-02, 4.1252752e-02, 3.9641086e-02,
    3.8060234e-02, 3.6510300e-02, 3.4991388e-02, 3.3503601e-02,
    3.2047037e-02, 3.0621794e-02, 2.9227967e-02, 2.7865651e-02,
    2.6534935e-02, 2.5235910e-02, 2.3968661e-02, 2.2733274e-02,
    2.1529832e-02, 2.0358415e-02, 1.9219101e-02, 1.8111967e-02,
    1.7037087e-02, 1.5994532e-02, 1.4984373e-02, 1.4006678e-02,
    1.3061510e-02, 1.2148935e-02, 1.1269013e-02, 1.0421802e-02,
    9.6073598e-03, 8.8257407e-03, 8.0769970e-03, 7.3611788e-03,
    6.6783340e-03, 6.0285082e-03, 5.4117450e-03, 4.8280857e-03,
    4.2775693e-03, 3.7602327e-03, 3.2761105e-03, 2.8252351e-03,
    2.4076367e-03, 2.0233432e-03, 1.6723803e-03, 1.3547717e-03,
    1.0705384e-03, 8.1969953e-04, 6.0227190e-04, 4.1827004e-04,
    2.6770626e-04, 1.5059065e-04, 6.6931045e-05, 1.6733041e-05,
], dtype=np.float32)


# ══════════════════════════════════════════════════════════════════════
# Feature extraction (Python reimplementation matching C code exactly)
# ══════════════════════════════════════════════════════════════════════

def build_mel_filterbank():
    """Build mel filterbank coefficients, matching C tv_init_mel_filterbank."""
    low_mel = 2595.0 * np.log10(1.0 + 0.0 / 700.0)
    high_mel = 2595.0 * np.log10(1.0 + 8000.0 / 700.0)

    mel_bins = np.zeros(MEL_BANDS + 2, dtype=np.int32)
    for i in range(MEL_BANDS + 2):
        mel = i * (high_mel - low_mel) / (MEL_BANDS + 1.0) + low_mel
        hz = 700.0 * (10.0 ** (mel / 2595.0) - 1.0)
        mel_bins[i] = int((FFT_SIZE + 1.0) * hz / FS)

    mel_fb = np.zeros((MEL_BANDS, N_BINS), dtype=np.float32)
    for j in range(MEL_BANDS):
        for i in range(mel_bins[j], mel_bins[j + 1]):
            mel_fb[j, i] = (i - mel_bins[j]) / (mel_bins[j + 1] - mel_bins[j])
        for i in range(mel_bins[j + 1], mel_bins[j + 2]):
            mel_fb[j, i] = (mel_bins[j + 2] - i) / (mel_bins[j + 2] - mel_bins[j + 1])

    return mel_fb


def fft_format2_to_format1(buf):
    """Convert FFT output from format2 to format1 (in-place).

    format2: [Real-0, Real-1, (-1)*Imag-1, Real-2, (-1)*Imag-2, ..., Real-Nyq]
    format1: [Real-0, Real-Nyq, Real-1, Imag-1, Real-2, Imag-2, ...]

    From fftw.c AUP_FFTW_InplaceTransf(direction=1):
      nyqReal = buf[fftSz - 1]
      for idx = fftSz-1 down to 3 step -2:
          buf[idx] = -(buf[idx - 1])
          buf[idx - 1] = buf[idx - 2]
      buf[1] = nyqReal
    """
    n = len(buf)
    out = buf.copy()
    nyq_real = out[n - 1]
    for idx in range(n - 1, 2, -2):
        out[idx] = -out[idx - 1]
        out[idx - 1] = out[idx - 2]
    out[1] = nyq_real
    return out


def fft_rescale(buf, fft_size):
    """Rescale FFT output: multiply by fft_size.

    From fftw.c AUP_FFTW_RescaleFFTOut.
    """
    return buf * fft_size


class FeatureExtractor:
    """Python reimplementation of tv_features / tv_extract_features."""

    def __init__(self):
        self.mel_fb = build_mel_filterbank()
        self.preemph_prev = np.float32(0.0)
        self.input_q = np.zeros(WINDOW_SIZE, dtype=np.float32)
        self.feat_stack = np.zeros((CONTEXT_LEN, FEA_LEN), dtype=np.float32)

    def reset(self):
        self.preemph_prev = np.float32(0.0)
        self.input_q[:] = 0.0
        self.feat_stack[:] = 0.0

    def extract(self, samples_i16):
        """Extract one frame of features from HOP_SIZE int16 samples.
        Returns the [CONTEXT_LEN, FEA_LEN] feature stack.
        """
        # 1. int16 → float (NO normalization)
        raw = samples_i16.astype(np.float32)

        # 2. Pre-emphasis: y[n] = x[n] - 0.97 * x[n-1]
        emph = np.empty_like(raw)
        for i in range(len(raw)):
            emph[i] = raw[i] - PREEMPH * self.preemph_prev
            self.preemph_prev = raw[i]

        # 3. STFT: slide overlap buffer, window, zero-pad, FFT
        self.input_q = np.roll(self.input_q, -HOP_SIZE)
        self.input_q[-HOP_SIZE:] = emph

        # Apply Hann window
        fft_in = np.zeros(FFT_SIZE, dtype=np.float32)
        fft_in[:WINDOW_SIZE] = self.input_q * HANN_WINDOW

        # FFT (real-to-complex, 1024-point)
        # numpy rfft gives N/2+1 complex bins
        fft_complex = np.fft.rfft(fft_in)

        # Convert numpy rfft output to format2, then to format1, then rescale
        # numpy rfft: complex array of length N/2+1
        # format2: [Real-0, Real-1, (-1)*Imag-1, Real-2, (-1)*Imag-2, ..., Real-Nyq]
        fft_out_format2 = np.zeros(FFT_SIZE, dtype=np.float32)
        fft_out_format2[0] = np.float32(fft_complex[0].real)
        for k in range(1, N_BINS - 1):
            fft_out_format2[2 * k - 1] = np.float32(fft_complex[k].real)
            fft_out_format2[2 * k] = np.float32(-fft_complex[k].imag)
        fft_out_format2[FFT_SIZE - 1] = np.float32(fft_complex[N_BINS - 1].real)

        # format2 → format1
        fft_out_f1 = fft_format2_to_format1(fft_out_format2)
        # Rescale: multiply by FFT_SIZE
        fft_out_f1 = fft_rescale(fft_out_f1, FFT_SIZE)

        # 4. Power spectrum (format1 layout)
        # format1: [Real-0, Real-Nyq, Real-1, Imag-1, Real-2, Imag-2, ...]
        bin_pow = np.zeros(N_BINS, dtype=np.float32)
        bin_pow[0] = fft_out_f1[0] * fft_out_f1[0]
        bin_pow[N_BINS - 1] = fft_out_f1[1] * fft_out_f1[1]
        for i in range(1, N_BINS - 1):
            ri = i * 2
            bin_pow[i] = fft_out_f1[ri] * fft_out_f1[ri] + fft_out_f1[ri + 1] * fft_out_f1[ri + 1]

        # 5. Context stack: shift left, new frame at end
        self.feat_stack[:-1] = self.feat_stack[1:]

        # 6. Mel filterbank → log → z-normalize
        power_norm = np.float32(32768.0 * 32768.0)
        cur = np.zeros(FEA_LEN, dtype=np.float32)
        for i in range(MEL_BANDS):
            val = np.float32(np.sum(bin_pow * self.mel_fb[i]))
            val = val / power_norm
            val = np.float32(np.log(val + EPS))
            cur[i] = (val - FEATURE_MEANS[i]) / (FEATURE_STDS[i] + EPS)

        # 7. Pitch = 0.0, z-normalized
        cur[MEL_BANDS] = (np.float32(0.0) - FEATURE_MEANS[MEL_BANDS]) / (FEATURE_STDS[MEL_BANDS] + EPS)

        self.feat_stack[-1] = cur
        return self.feat_stack.copy()


# ══════════════════════════════════════════════════════════════════════
# Native .so wrapper
# ══════════════════════════════════════════════════════════════════════

class NativeVAD:
    """Wrapper for libten_vad.so via ctypes."""

    def __init__(self, lib_path):
        # Need to set LD_LIBRARY_PATH for libc++ dependency
        lib_dir = os.path.dirname(os.path.abspath(lib_path))
        self.lib = ctypes.CDLL(lib_path)

        # int ten_vad_create(ten_vad_handle_t *handle, size_t hop_size, float threshold)
        self.lib.ten_vad_create.argtypes = [
            ctypes.POINTER(ctypes.c_void_p), ctypes.c_size_t, ctypes.c_float
        ]
        self.lib.ten_vad_create.restype = ctypes.c_int

        # int ten_vad_process(handle, audio_data, length, out_prob, out_flag)
        self.lib.ten_vad_process.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_int16),
            ctypes.c_size_t,
            ctypes.POINTER(ctypes.c_float),
            ctypes.POINTER(ctypes.c_int),
        ]
        self.lib.ten_vad_process.restype = ctypes.c_int

        # int ten_vad_destroy(ten_vad_handle_t *handle)
        self.lib.ten_vad_destroy.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        self.lib.ten_vad_destroy.restype = ctypes.c_int

        self.handle = ctypes.c_void_p(None)
        ret = self.lib.ten_vad_create(ctypes.byref(self.handle), HOP_SIZE, 0.5)
        if ret != 0:
            raise RuntimeError(f"ten_vad_create failed: {ret}")

    def process(self, samples_i16):
        """Process one hop of int16 samples, return probability."""
        buf = (ctypes.c_int16 * len(samples_i16))(*samples_i16)
        prob = ctypes.c_float(0.0)
        flag = ctypes.c_int(0)
        ret = self.lib.ten_vad_process(
            self.handle, buf, len(samples_i16),
            ctypes.byref(prob), ctypes.byref(flag)
        )
        if ret != 0:
            raise RuntimeError(f"ten_vad_process failed: {ret}")
        return prob.value

    def __del__(self):
        if hasattr(self, 'handle') and self.handle:
            self.lib.ten_vad_destroy(ctypes.byref(self.handle))


# ══════════════════════════════════════════════════════════════════════
# ONNX model runner (optional, for conv+LSTM validation)
# ══════════════════════════════════════════════════════════════════════

class OnnxVAD:
    """Run the ONNX model directly for ground truth on the neural network part."""

    def __init__(self, onnx_path):
        import onnxruntime as ort
        self.sess = ort.InferenceSession(onnx_path)
        self.input_names = [inp.name for inp in self.sess.get_inputs()]
        self.output_names = [out.name for out in self.sess.get_outputs()]
        # Initialize hidden states to zero
        self.h_states = [np.zeros((1, HIDDEN_DIM), dtype=np.float32) for _ in range(4)]

    def process(self, features_3x41):
        """Run ONNX model on feature stack [3, 41].
        Returns probability and updates hidden states.
        """
        inp = features_3x41.reshape(1, CONTEXT_LEN, FEA_LEN).astype(np.float32)
        feeds = {self.input_names[0]: inp}
        for i in range(4):
            feeds[self.input_names[i + 1]] = self.h_states[i]

        outputs = self.sess.run(self.output_names, feeds)
        prob = outputs[0].item()
        for i in range(4):
            self.h_states[i] = outputs[i + 1]
        return prob

    def reset(self):
        self.h_states = [np.zeros((1, HIDDEN_DIM), dtype=np.float32) for _ in range(4)]


# ══════════════════════════════════════════════════════════════════════
# GGML model weight loader (for conv layer validation)
# ══════════════════════════════════════════════════════════════════════

def load_ggml_weights(model_path):
    """Load weights from the GGML .bin file.
    Returns dict of name → numpy array.
    """
    weights = {}
    with open(model_path, "rb") as f:
        magic = struct.unpack("I", f.read(4))[0]
        assert magic == 0x67676d6c, f"Bad magic: {magic:#x}"

        # Model type string
        str_len = struct.unpack("i", f.read(4))[0]
        if str_len > 0:
            f.read(str_len)

        # Version
        f.read(12)  # major, minor, patch

        # Hyperparams (8 ints)
        f.read(32)

        # Read tensors
        while True:
            hdr = f.read(4)
            if len(hdr) < 4:
                break
            n_dims = struct.unpack("i", hdr)[0]
            name_len = struct.unpack("i", f.read(4))[0]
            ttype = struct.unpack("i", f.read(4))[0]

            # GGML stores shape in reverse order
            ggml_shape = []
            for _ in range(n_dims):
                ggml_shape.append(struct.unpack("i", f.read(4))[0])

            name = f.read(name_len).decode("utf-8")

            # Reverse to get numpy shape
            np_shape = list(reversed(ggml_shape))
            n_elements = 1
            for d in np_shape:
                n_elements *= d

            data = np.frombuffer(f.read(n_elements * 4), dtype=np.float32).copy()
            data = data.reshape(np_shape)
            weights[name] = data

    return weights


# ══════════════════════════════════════════════════════════════════════
# Conv layers (Python reimplementation for validation)
# ══════════════════════════════════════════════════════════════════════

def run_convs_python(features_3x41, weights):
    """Reimplement the C tv_run_convs in Python.
    Input: features[3][41], weights dict from GGML file.
    Output: flat[80]

    Verified against ONNX intermediate outputs (max diff < 2e-6).

    ONNX pipeline:
      Layer 0: dw(1,1,3,3) VALID pad → [1,1,1,39], pw(16,1,1,1)+ReLU → [1,16,1,39]
      MaxPool(1,3) stride(1,2) → [1,16,1,19]
      Layer 1: dw(16,1,1,3) stride(2,2) pad[0,1,0,1] → [1,16,1,10], pw+ReLU
      Layer 2: dw(16,1,1,3) stride(2,2) pad[0,0,0,1] → [1,16,1,5], pw+ReLU
      Transpose [16,5]→[5,16], flatten → [80]
    """
    dw0 = weights["sep_conv_0_dw"].flatten()  # 9 floats
    pw0 = weights["sep_conv_0_pw"].flatten()  # 16 floats
    b0 = weights["sep_conv_0_bias"].flatten()  # 16 floats
    dw1 = weights["sep_conv_1_dw"].flatten()  # 48 floats
    pw1 = weights["sep_conv_1_pw"].flatten()  # 256 floats
    b1 = weights["sep_conv_1_bias"].flatten()  # 16 floats
    dw2 = weights["sep_conv_2_dw"].flatten()  # 48 floats
    pw2 = weights["sep_conv_2_pw"].flatten()  # 256 floats
    b2 = weights["sep_conv_2_bias"].flatten()  # 16 floats

    inp = features_3x41.flatten()  # [3*41]

    # ── Layer 0: SeparableConv2D on [1,1,3,41] ──
    # Depthwise: kernel(3,3), VALID padding → output [1,1,1,39]
    # H: 3-3+1=1, W: 41-3+1=39
    dw0_out = np.zeros(39, dtype=np.float32)
    for w in range(39):
        s = np.float32(0.0)
        for kh in range(3):
            for kw in range(3):
                s += inp[kh * 41 + (w + kw)] * dw0[kh * 3 + kw]
        dw0_out[w] = s

    # Pointwise: (16,1,1,1) + bias + ReLU → [16, 1, 39]
    pw0_out = np.zeros(16 * 39, dtype=np.float32)
    for oc in range(16):
        for i in range(39):
            val = dw0_out[i] * pw0[oc] + b0[oc]
            pw0_out[oc * 39 + i] = max(val, 0.0)

    # MaxPool: kernel(1,3), stride(1,2) → [16, 1, 19]
    # W: floor((39-3)/2) + 1 = 19
    pool_out = np.zeros(16 * 19, dtype=np.float32)
    for oc in range(16):
        for ow in range(19):
            w_start = ow * 2
            mx = -1e30
            for k in range(3):
                iw = w_start + k
                if iw < 39:
                    v = pw0_out[oc * 39 + iw]
                    if v > mx:
                        mx = v
            pool_out[oc * 19 + ow] = mx

    # ── Layer 1: SeparableConv1D on [16, 1, 19] ──
    # Depthwise: kernel(1,3) stride(2,2) pad[0,1,0,1] (symmetric W pad)
    # Padded W: 19+1+1=21, output W: floor((21-3)/2)+1 = 10
    dw1_out = np.zeros(16 * 10, dtype=np.float32)
    for ch in range(16):
        kw = dw1[ch * 3: ch * 3 + 3]
        for ow in range(10):
            s = np.float32(0.0)
            for k in range(3):
                iw = ow * 2 + k - 1  # -1 for pad_w_begin=1
                if 0 <= iw < 19:
                    s += pool_out[ch * 19 + iw] * kw[k]
            dw1_out[ch * 10 + ow] = s

    # Pointwise + bias + ReLU
    pw1_out = np.zeros(16 * 10, dtype=np.float32)
    for oc in range(16):
        for i in range(10):
            s = b1[oc]
            for ic in range(16):
                s += dw1_out[ic * 10 + i] * pw1[oc * 16 + ic]
            pw1_out[oc * 10 + i] = max(s, 0.0)

    # ── Layer 2: SeparableConv1D on [16, 1, 10] ──
    # Depthwise: kernel(1,3) stride(2,2) pad[0,0,0,1] (pad W end only)
    # Padded W: 10+0+1=11, output W: floor((11-3)/2)+1 = 5
    dw2_out = np.zeros(16 * 5, dtype=np.float32)
    for ch in range(16):
        kw = dw2[ch * 3: ch * 3 + 3]
        for ow in range(5):
            s = np.float32(0.0)
            for k in range(3):
                iw = ow * 2 + k  # no pad_w_begin
                if iw < 10:
                    s += pw1_out[ch * 10 + iw] * kw[k]
            dw2_out[ch * 5 + ow] = s

    # Pointwise + bias + ReLU
    pw2_out = np.zeros(16 * 5, dtype=np.float32)
    for oc in range(16):
        for i in range(5):
            s = b2[oc]
            for ic in range(16):
                s += dw2_out[ic * 5 + i] * pw2[oc * 16 + ic]
            pw2_out[oc * 5 + i] = max(s, 0.0)

    # ── Flatten: [16, 1, 5] → transpose → [5, 16] → [80] ──
    out80 = np.zeros(80, dtype=np.float32)
    for w in range(5):
        for ch in range(16):
            out80[w * 16 + ch] = pw2_out[ch * 5 + w]

    return out80


# ══════════════════════════════════════════════════════════════════════
# LSTM + Dense (Python reimplementation)
# ══════════════════════════════════════════════════════════════════════

def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -500, 500)))


def run_lstm_dense_python(conv_out_80, weights, h_states, c_states):
    """Reimplement LSTM + Dense layers in Python.
    h_states: [h0[64], h1[64]]
    c_states: [c0[64], c1[64]]
    Returns (prob, h_states, c_states).
    """
    x = conv_out_80.reshape(1, -1)  # [1, 80]

    for layer in range(2):
        ih_w = weights[f"lstm_{layer}_ih_weight"]  # [256, input_dim]
        hh_w = weights[f"lstm_{layer}_hh_weight"]  # [256, 64]
        ih_b = weights[f"lstm_{layer}_ih_bias"]    # [256]
        hh_b = weights[f"lstm_{layer}_hh_bias"]    # [256]

        # gates = ih_w @ x^T + ih_b + hh_w @ h^T + hh_b
        inp_gate = ih_w @ x.T + ih_b.reshape(-1, 1)  # [256, 1]
        hid_gate = hh_w @ h_states[layer].reshape(-1, 1) + hh_b.reshape(-1, 1)
        gates = (inp_gate + hid_gate).flatten()  # [256]

        hdim = HIDDEN_DIM
        # PyTorch gate order: i, f, g, o
        i_t = sigmoid(gates[0*hdim:1*hdim])
        f_t = sigmoid(gates[1*hdim:2*hdim])
        g_t = np.tanh(gates[2*hdim:3*hdim])
        o_t = sigmoid(gates[3*hdim:4*hdim])

        c_states[layer] = f_t * c_states[layer] + i_t * g_t
        h_states[layer] = o_t * np.tanh(c_states[layer])

        x = h_states[layer].reshape(1, -1)  # [1, 64] for next layer

    # Concat h1 + h0 → [128] (ONNX model concatenates LSTM1 output first)
    concat = np.concatenate([h_states[1], h_states[0]])

    # Dense 0: [128] → [32] + ReLU
    d0_w = weights["dense_0_weight"]  # [32, 128] in ggml layout
    d0_b = weights["dense_0_bias"]    # [32]
    d0 = d0_w @ concat + d0_b
    d0 = np.maximum(d0, 0.0)

    # Dense 1: [32] → [1] + Sigmoid
    d1_w = weights["dense_1_weight"]  # [1, 32]
    d1_b = weights["dense_1_bias"]    # [1]
    d1 = d1_w @ d0 + d1_b
    prob = sigmoid(d1.item())

    return prob, h_states, c_states


# ══════════════════════════════════════════════════════════════════════
# Main comparison
# ══════════════════════════════════════════════════════════════════════

def load_wav(path):
    """Load 16kHz mono int16 WAV."""
    with wave.open(path, "rb") as wf:
        assert wf.getnchannels() == 1, f"Expected mono, got {wf.getnchannels()} channels"
        assert wf.getsampwidth() == 2, f"Expected 16-bit, got {wf.getsampwidth() * 8}-bit"
        assert wf.getframerate() == 16000, f"Expected 16kHz, got {wf.getframerate()}"
        data = wf.readframes(wf.getnframes())
    return np.frombuffer(data, dtype=np.int16)


def main():
    parser = argparse.ArgumentParser(description="Debug TEN-VAD GGML reimplementation")
    parser.add_argument("wav", help="Path to 16kHz mono WAV file")
    parser.add_argument("--lib", default="dist/lib/libten_vad.so",
                        help="Path to native libten_vad.so")
    parser.add_argument("--onnx", default="ten-vad/src/onnx_model/ten-vad.onnx",
                        help="Path to ONNX model (for conv+LSTM validation)")
    parser.add_argument("--ggml", default="whisper.cpp/models/ten-vad-ggml.bin",
                        help="Path to GGML model file (for weight loading)")
    parser.add_argument("--features-only", action="store_true",
                        help="Only compare feature extraction, skip model inference")
    parser.add_argument("--max-frames", type=int, default=0,
                        help="Stop after N frames (0 = all)")
    parser.add_argument("--dump-frame", type=int, default=-1,
                        help="Dump full intermediates for this frame number")
    args = parser.parse_args()

    samples = load_wav(args.wav)
    n_frames = len(samples) // HOP_SIZE
    print(f"Loaded {args.wav}: {len(samples)} samples, {n_frames} frames, {len(samples)/FS:.2f}s")

    # ── Load native library ──
    native = None
    try:
        native = NativeVAD(args.lib)
        print(f"Loaded native library: {args.lib}")
    except Exception as e:
        print(f"WARNING: Could not load native library: {e}")
        print("  Will only show Python feature extraction output")

    # ── Load ONNX model (optional) ──
    onnx_vad = None
    if not args.features_only:
        try:
            onnx_vad = OnnxVAD(args.onnx)
            print(f"Loaded ONNX model: {args.onnx}")
        except Exception as e:
            print(f"WARNING: Could not load ONNX model: {e}")
            print("  pip install onnxruntime if needed")

    # ── Load GGML weights (for conv validation) ──
    ggml_weights = None
    if not args.features_only and os.path.exists(args.ggml):
        try:
            ggml_weights = load_ggml_weights(args.ggml)
            print(f"Loaded GGML weights: {args.ggml} ({len(ggml_weights)} tensors)")
        except Exception as e:
            print(f"WARNING: Could not load GGML weights: {e}")

    # ── Feature extractor ──
    feat_ext = FeatureExtractor()

    # ── LSTM state for Python full pipeline ──
    h_states = [np.zeros(HIDDEN_DIM, dtype=np.float32) for _ in range(2)]
    c_states = [np.zeros(HIDDEN_DIM, dtype=np.float32) for _ in range(2)]

    print()
    print(f"{'Frame':>5}  {'Native':>8}  {'ONNX':>8}  {'PyFull':>8}  {'Δ Nat-ONNX':>10}  {'Δ Nat-Py':>10}")
    print("-" * 65)

    max_frames = args.max_frames if args.max_frames > 0 else n_frames
    first_diverge = None

    for frame_idx in range(min(n_frames, max_frames)):
        start = frame_idx * HOP_SIZE
        hop = samples[start:start + HOP_SIZE]
        if len(hop) < HOP_SIZE:
            break

        # Native probability
        native_prob = None
        if native:
            native_prob = native.process(hop)

        # Python feature extraction
        feat_stack = feat_ext.extract(hop)

        # ONNX probability
        onnx_prob = None
        if onnx_vad:
            onnx_prob = onnx_vad.process(feat_stack)

        # Python full pipeline: features → convs → LSTM → dense
        py_full_prob = None
        if ggml_weights and not args.features_only:
            conv_out = run_convs_python(feat_stack, ggml_weights)
            py_full_prob, h_states, c_states = run_lstm_dense_python(
                conv_out, ggml_weights, h_states, c_states
            )

        # Print comparison
        nat_str = f"{native_prob:.4f}" if native_prob is not None else "  N/A "
        onnx_str = f"{onnx_prob:.4f}" if onnx_prob is not None else "  N/A "
        py_str = f"{py_full_prob:.4f}" if py_full_prob is not None else "  N/A "

        delta_no = ""
        if native_prob is not None and onnx_prob is not None:
            d = abs(native_prob - onnx_prob)
            delta_no = f"{d:.6f}"
            if d > 0.01 and first_diverge is None:
                first_diverge = ("native-onnx", frame_idx, native_prob, onnx_prob)

        delta_np = ""
        if native_prob is not None and py_full_prob is not None:
            d = abs(native_prob - py_full_prob)
            delta_np = f"{d:.6f}"

        print(f"{frame_idx:5d}  {nat_str:>8}  {onnx_str:>8}  {py_str:>8}  {delta_no:>10}  {delta_np:>10}")

        # Dump intermediates for specific frame
        if frame_idx == args.dump_frame:
            print(f"\n=== DUMP FRAME {frame_idx} ===")
            print(f"  Input hop (first 10): {hop[:10]}")
            print(f"  Feature stack [2] (current frame, first 10): {feat_stack[2, :10]}")
            print(f"  Feature stack [1] (prev frame, first 10): {feat_stack[1, :10]}")
            print(f"  Feature stack [0] (oldest, first 10): {feat_stack[0, :10]}")
            if ggml_weights:
                conv_out_dump = run_convs_python(feat_stack, ggml_weights)
                print(f"  Conv output (first 10): {conv_out_dump[:10]}")
                print(f"  Conv output (last 10): {conv_out_dump[-10:]}")
            print(f"=== END DUMP ===\n")

    print()
    if first_diverge:
        kind, fidx, v1, v2 = first_diverge
        print(f"FIRST SIGNIFICANT DIVERGENCE ({kind}) at frame {fidx}: {v1:.6f} vs {v2:.6f}")
    elif native_prob is not None and onnx_prob is not None:
        print("No significant divergence detected (all deltas < 0.01)")

    # Summary statistics
    if native_prob is not None:
        print(f"\nNative final prob: {native_prob:.6f}")
    if onnx_prob is not None:
        print(f"ONNX final prob: {onnx_prob:.6f}")
    if py_full_prob is not None:
        print(f"Python full pipeline final prob: {py_full_prob:.6f}")


if __name__ == "__main__":
    main()
