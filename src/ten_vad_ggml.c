/**
 * TEN-VAD via GGML — feature extraction + model loading + inference.
 *
 * Feature extraction ported from ten-vad/src/aed.cc with exact numerical parity:
 *   Pre-emphasis → STFT (Hann768, FFT1024) → Power spectrum → Mel filterbank
 *   → Log → Z-normalize → Context stack [3][41] → GGML inference
 *
 * Model architecture:
 *   SepConv2D(1→16) → SepConv1D(16→16) → SepConv1D(16→16) → MaxPool → Flatten(80)
 *   → LSTM(80→64) → LSTM(64→64) → Concat(128) → Dense(128→32) → Dense(32→1) → Sigmoid
 */

#include "ten_vad_ggml.h"
#include "ten_vad_fft.h"

#include <ggml.h>
#include <ggml-alloc.h>
#include <ggml-backend.h>
#include <ggml-cpu.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Constants from TEN-VAD ── */

#define TV_FS            16000
#define TV_HOP_SIZE      256
#define TV_WINDOW_SIZE   768
#define TV_FFT_SIZE      1024
#define TV_N_BINS        (TV_FFT_SIZE / 2 + 1)  /* 513 */
#define TV_MEL_BANDS     40
#define TV_FEA_LEN       (TV_MEL_BANDS + 1)     /* 41 = 40 mel + 1 pitch */
#define TV_CONTEXT_LEN   3
#define TV_HIDDEN_DIM    64
#define TV_EPS           1e-20f
#define TV_PREEMPH       0.97f

#define GGML_FILE_MAGIC  0x67676d6c

/* ── Hardcoded normalization constants from coeff.h ── */

static const float TV_FEATURE_MEANS[TV_FEA_LEN] = {
    -8.198236465454e+00f, -6.265716552734e+00f, -5.483818531036e+00f,
    -4.758691310883e+00f, -4.417088985443e+00f, -4.142892837524e+00f,
    -3.912850379944e+00f, -3.845927953720e+00f, -3.657090425491e+00f,
    -3.723418712616e+00f, -3.876134157181e+00f, -3.843890905380e+00f,
    -3.690405130386e+00f, -3.756065845490e+00f, -3.698696136475e+00f,
    -3.650463104248e+00f, -3.700468778610e+00f, -3.567321300507e+00f,
    -3.498900175095e+00f, -3.477807044983e+00f, -3.458816051483e+00f,
    -3.444923877716e+00f, -3.401328563690e+00f, -3.306261301041e+00f,
    -3.278556823730e+00f, -3.233250856400e+00f, -3.198616027832e+00f,
    -3.204526424408e+00f, -3.208798646927e+00f, -3.257838010788e+00f,
    -3.381376743317e+00f, -3.534021377563e+00f, -3.640867948532e+00f,
    -3.726858854294e+00f, -3.773730993271e+00f, -3.804667234421e+00f,
    -3.832901000977e+00f, -3.871120452881e+00f, -3.990592956543e+00f,
    -4.480289459229e+00f, 9.235690307617e+01f
};

static const float TV_FEATURE_STDS[TV_FEA_LEN] = {
    5.166063785553e+00f, 4.977209568024e+00f, 4.698895931244e+00f,
    4.630621433258e+00f, 4.634347915649e+00f, 4.641156196594e+00f,
    4.640676498413e+00f, 4.666367053986e+00f, 4.650534629822e+00f,
    4.640020847321e+00f, 4.637400150299e+00f, 4.620099067688e+00f,
    4.596316337585e+00f, 4.562654972076e+00f, 4.554360389709e+00f,
    4.566910743713e+00f, 4.562489986420e+00f, 4.562412738800e+00f,
    4.585299491882e+00f, 4.600179672241e+00f, 4.592845916748e+00f,
    4.585922718048e+00f, 4.583496570587e+00f, 4.626092910767e+00f,
    4.626957893372e+00f, 4.626289367676e+00f, 4.637005805969e+00f,
    4.683015823364e+00f, 4.726813793182e+00f, 4.734289646149e+00f,
    4.753227233887e+00f, 4.849722862244e+00f, 4.869434833527e+00f,
    4.884482860565e+00f, 4.921327114105e+00f, 4.959212303162e+00f,
    4.996619224548e+00f, 5.044823646545e+00f, 5.072216987610e+00f,
    5.096439361572e+00f, 1.152136917114e+02f
};

static const float TV_HANN_WINDOW[TV_WINDOW_SIZE] = {
    0.0000000e+00f, 1.6733041e-05f, 6.6931045e-05f, 1.5059065e-04f,
    2.6770626e-04f, 4.1827004e-04f, 6.0227190e-04f, 8.1969953e-04f,
    1.0705384e-03f, 1.3547717e-03f, 1.6723803e-03f, 2.0233432e-03f,
    2.4076367e-03f, 2.8252351e-03f, 3.2761105e-03f, 3.7602327e-03f,
    4.2775693e-03f, 4.8280857e-03f, 5.4117450e-03f, 6.0285082e-03f,
    6.6783340e-03f, 7.3611788e-03f, 8.0769970e-03f, 8.8257407e-03f,
    9.6073598e-03f, 1.0421802e-02f, 1.1269013e-02f, 1.2148935e-02f,
    1.3061510e-02f, 1.4006678e-02f, 1.4984373e-02f, 1.5994532e-02f,
    1.7037087e-02f, 1.8111967e-02f, 1.9219101e-02f, 2.0358415e-02f,
    2.1529832e-02f, 2.2733274e-02f, 2.3968661e-02f, 2.5235910e-02f,
    2.6534935e-02f, 2.7865651e-02f, 2.9227967e-02f, 3.0621794e-02f,
    3.2047037e-02f, 3.3503601e-02f, 3.4991388e-02f, 3.6510300e-02f,
    3.8060234e-02f, 3.9641086e-02f, 4.1252752e-02f, 4.2895122e-02f,
    4.4568088e-02f, 4.6271536e-02f, 4.8005353e-02f, 4.9769424e-02f,
    5.1563629e-02f, 5.3387849e-02f, 5.5241962e-02f, 5.7125844e-02f,
    5.9039368e-02f, 6.0982406e-02f, 6.2954829e-02f, 6.4956504e-02f,
    6.6987298e-02f, 6.9047074e-02f, 7.1135695e-02f, 7.3253021e-02f,
    7.5398909e-02f, 7.7573217e-02f, 7.9775799e-02f, 8.2006508e-02f,
    8.4265194e-02f, 8.6551706e-02f, 8.8865891e-02f, 9.1207593e-02f,
    9.3576658e-02f, 9.5972925e-02f, 9.8396234e-02f, 1.0084642e-01f,
    1.0332333e-01f, 1.0582679e-01f, 1.0835663e-01f, 1.1091268e-01f,
    1.1349477e-01f, 1.1610274e-01f, 1.1873640e-01f, 1.2139558e-01f,
    1.2408010e-01f, 1.2678978e-01f, 1.2952444e-01f, 1.3228389e-01f,
    1.3506796e-01f, 1.3787646e-01f, 1.4070919e-01f, 1.4356597e-01f,
    1.4644661e-01f, 1.4935091e-01f, 1.5227868e-01f, 1.5522973e-01f,
    1.5820385e-01f, 1.6120085e-01f, 1.6422052e-01f, 1.6726267e-01f,
    1.7032709e-01f, 1.7341358e-01f, 1.7652192e-01f, 1.7965192e-01f,
    1.8280336e-01f, 1.8597603e-01f, 1.8916971e-01f, 1.9238420e-01f,
    1.9561929e-01f, 1.9887474e-01f, 2.0215035e-01f, 2.0544589e-01f,
    2.0876115e-01f, 2.1209590e-01f, 2.1544993e-01f, 2.1882300e-01f,
    2.2221488e-01f, 2.2562536e-01f, 2.2905421e-01f, 2.3250119e-01f,
    2.3596607e-01f, 2.3944863e-01f, 2.4294863e-01f, 2.4646583e-01f,
    2.5000000e-01f, 2.5355090e-01f, 2.5711830e-01f, 2.6070196e-01f,
    2.6430163e-01f, 2.6791708e-01f, 2.7154806e-01f, 2.7519434e-01f,
    2.7885565e-01f, 2.8253178e-01f, 2.8622245e-01f, 2.8992744e-01f,
    2.9364649e-01f, 2.9737934e-01f, 3.0112576e-01f, 3.0488549e-01f,
    3.0865828e-01f, 3.1244388e-01f, 3.1624203e-01f, 3.2005248e-01f,
    3.2387498e-01f, 3.2770926e-01f, 3.3155507e-01f, 3.3541216e-01f,
    3.3928027e-01f, 3.4315913e-01f, 3.4704849e-01f, 3.5094809e-01f,
    3.5485766e-01f, 3.5877695e-01f, 3.6270569e-01f, 3.6664362e-01f,
    3.7059048e-01f, 3.7454600e-01f, 3.7850991e-01f, 3.8248196e-01f,
    3.8646187e-01f, 3.9044938e-01f, 3.9444422e-01f, 3.9844613e-01f,
    4.0245484e-01f, 4.0647007e-01f, 4.1049157e-01f, 4.1451906e-01f,
    4.1855226e-01f, 4.2259092e-01f, 4.2663476e-01f, 4.3068351e-01f,
    4.3473690e-01f, 4.3879466e-01f, 4.4285652e-01f, 4.4692220e-01f,
    4.5099143e-01f, 4.5506394e-01f, 4.5913946e-01f, 4.6321772e-01f,
    4.6729844e-01f, 4.7138134e-01f, 4.7546616e-01f, 4.7955263e-01f,
    4.8364046e-01f, 4.8772939e-01f, 4.9181913e-01f, 4.9590943e-01f,
    5.0000000e-01f, 5.0409057e-01f, 5.0818087e-01f, 5.1227061e-01f,
    5.1635954e-01f, 5.2044737e-01f, 5.2453384e-01f, 5.2861866e-01f,
    5.3270156e-01f, 5.3678228e-01f, 5.4086054e-01f, 5.4493606e-01f,
    5.4900857e-01f, 5.5307780e-01f, 5.5714348e-01f, 5.6120534e-01f,
    5.6526310e-01f, 5.6931649e-01f, 5.7336524e-01f, 5.7740908e-01f,
    5.8144774e-01f, 5.8548094e-01f, 5.8950843e-01f, 5.9352993e-01f,
    5.9754516e-01f, 6.0155387e-01f, 6.0555578e-01f, 6.0955062e-01f,
    6.1353813e-01f, 6.1751804e-01f, 6.2149009e-01f, 6.2545400e-01f,
    6.2940952e-01f, 6.3335638e-01f, 6.3729431e-01f, 6.4122305e-01f,
    6.4514234e-01f, 6.4905191e-01f, 6.5295151e-01f, 6.5684087e-01f,
    6.6071973e-01f, 6.6458784e-01f, 6.6844493e-01f, 6.7229074e-01f,
    6.7612502e-01f, 6.7994752e-01f, 6.8375797e-01f, 6.8755612e-01f,
    6.9134172e-01f, 6.9511451e-01f, 6.9887424e-01f, 7.0262066e-01f,
    7.0635351e-01f, 7.1007256e-01f, 7.1377755e-01f, 7.1746822e-01f,
    7.2114435e-01f, 7.2480566e-01f, 7.2845194e-01f, 7.3208292e-01f,
    7.3569837e-01f, 7.3929804e-01f, 7.4288170e-01f, 7.4644910e-01f,
    7.5000000e-01f, 7.5353417e-01f, 7.5705137e-01f, 7.6055137e-01f,
    7.6403393e-01f, 7.6749881e-01f, 7.7094579e-01f, 7.7437464e-01f,
    7.7778512e-01f, 7.8117700e-01f, 7.8455007e-01f, 7.8790410e-01f,
    7.9123885e-01f, 7.9455411e-01f, 7.9784965e-01f, 8.0112526e-01f,
    8.0438071e-01f, 8.0761580e-01f, 8.1083029e-01f, 8.1402397e-01f,
    8.1719664e-01f, 8.2034808e-01f, 8.2347808e-01f, 8.2658642e-01f,
    8.2967291e-01f, 8.3273733e-01f, 8.3577948e-01f, 8.3879915e-01f,
    8.4179615e-01f, 8.4477027e-01f, 8.4772132e-01f, 8.5064909e-01f,
    8.5355339e-01f, 8.5643403e-01f, 8.5929081e-01f, 8.6212354e-01f,
    8.6493204e-01f, 8.6771611e-01f, 8.7047556e-01f, 8.7321022e-01f,
    8.7591990e-01f, 8.7860442e-01f, 8.8126360e-01f, 8.8389726e-01f,
    8.8650523e-01f, 8.8908732e-01f, 8.9164337e-01f, 8.9417321e-01f,
    8.9667667e-01f, 8.9915358e-01f, 9.0160377e-01f, 9.0402708e-01f,
    9.0642334e-01f, 9.0879241e-01f, 9.1113411e-01f, 9.1344829e-01f,
    9.1573481e-01f, 9.1799349e-01f, 9.2022420e-01f, 9.2242678e-01f,
    9.2460109e-01f, 9.2674698e-01f, 9.2886431e-01f, 9.3095293e-01f,
    9.3301270e-01f, 9.3504350e-01f, 9.3704517e-01f, 9.3901759e-01f,
    9.4096063e-01f, 9.4287416e-01f, 9.4475804e-01f, 9.4661215e-01f,
    9.4843637e-01f, 9.5023058e-01f, 9.5199465e-01f, 9.5372846e-01f,
    9.5543191e-01f, 9.5710488e-01f, 9.5874725e-01f, 9.6035891e-01f,
    9.6193977e-01f, 9.6348970e-01f, 9.6500861e-01f, 9.6649640e-01f,
    9.6795296e-01f, 9.6937821e-01f, 9.7077203e-01f, 9.7213435e-01f,
    9.7346506e-01f, 9.7476409e-01f, 9.7603134e-01f, 9.7726673e-01f,
    9.7847017e-01f, 9.7964159e-01f, 9.8078090e-01f, 9.8188803e-01f,
    9.8296291e-01f, 9.8400547e-01f, 9.8501563e-01f, 9.8599332e-01f,
    9.8693849e-01f, 9.8785107e-01f, 9.8873099e-01f, 9.8957820e-01f,
    9.9039264e-01f, 9.9117426e-01f, 9.9192300e-01f, 9.9263882e-01f,
    9.9332167e-01f, 9.9397149e-01f, 9.9458825e-01f, 9.9517191e-01f,
    9.9572243e-01f, 9.9623977e-01f, 9.9672389e-01f, 9.9717476e-01f,
    9.9759236e-01f, 9.9797666e-01f, 9.9832762e-01f, 9.9864523e-01f,
    9.9892946e-01f, 9.9918030e-01f, 9.9939773e-01f, 9.9958173e-01f,
    9.9973229e-01f, 9.9984941e-01f, 9.9993307e-01f, 9.9998327e-01f,
    1.0000000e+00f, 9.9998327e-01f, 9.9993307e-01f, 9.9984941e-01f,
    9.9973229e-01f, 9.9958173e-01f, 9.9939773e-01f, 9.9918030e-01f,
    9.9892946e-01f, 9.9864523e-01f, 9.9832762e-01f, 9.9797666e-01f,
    9.9759236e-01f, 9.9717476e-01f, 9.9672389e-01f, 9.9623977e-01f,
    9.9572243e-01f, 9.9517191e-01f, 9.9458825e-01f, 9.9397149e-01f,
    9.9332167e-01f, 9.9263882e-01f, 9.9192300e-01f, 9.9117426e-01f,
    9.9039264e-01f, 9.8957820e-01f, 9.8873099e-01f, 9.8785107e-01f,
    9.8693849e-01f, 9.8599332e-01f, 9.8501563e-01f, 9.8400547e-01f,
    9.8296291e-01f, 9.8188803e-01f, 9.8078090e-01f, 9.7964159e-01f,
    9.7847017e-01f, 9.7726673e-01f, 9.7603134e-01f, 9.7476409e-01f,
    9.7346506e-01f, 9.7213435e-01f, 9.7077203e-01f, 9.6937821e-01f,
    9.6795296e-01f, 9.6649640e-01f, 9.6500861e-01f, 9.6348970e-01f,
    9.6193977e-01f, 9.6035891e-01f, 9.5874725e-01f, 9.5710488e-01f,
    9.5543191e-01f, 9.5372846e-01f, 9.5199465e-01f, 9.5023058e-01f,
    9.4843637e-01f, 9.4661215e-01f, 9.4475804e-01f, 9.4287416e-01f,
    9.4096063e-01f, 9.3901759e-01f, 9.3704517e-01f, 9.3504350e-01f,
    9.3301270e-01f, 9.3095293e-01f, 9.2886431e-01f, 9.2674698e-01f,
    9.2460109e-01f, 9.2242678e-01f, 9.2022420e-01f, 9.1799349e-01f,
    9.1573481e-01f, 9.1344829e-01f, 9.1113411e-01f, 9.0879241e-01f,
    9.0642334e-01f, 9.0402708e-01f, 9.0160377e-01f, 8.9915358e-01f,
    8.9667667e-01f, 8.9417321e-01f, 8.9164337e-01f, 8.8908732e-01f,
    8.8650523e-01f, 8.8389726e-01f, 8.8126360e-01f, 8.7860442e-01f,
    8.7591990e-01f, 8.7321022e-01f, 8.7047556e-01f, 8.6771611e-01f,
    8.6493204e-01f, 8.6212354e-01f, 8.5929081e-01f, 8.5643403e-01f,
    8.5355339e-01f, 8.5064909e-01f, 8.4772132e-01f, 8.4477027e-01f,
    8.4179615e-01f, 8.3879915e-01f, 8.3577948e-01f, 8.3273733e-01f,
    8.2967291e-01f, 8.2658642e-01f, 8.2347808e-01f, 8.2034808e-01f,
    8.1719664e-01f, 8.1402397e-01f, 8.1083029e-01f, 8.0761580e-01f,
    8.0438071e-01f, 8.0112526e-01f, 7.9784965e-01f, 7.9455411e-01f,
    7.9123885e-01f, 7.8790410e-01f, 7.8455007e-01f, 7.8117700e-01f,
    7.7778512e-01f, 7.7437464e-01f, 7.7094579e-01f, 7.6749881e-01f,
    7.6403393e-01f, 7.6055137e-01f, 7.5705137e-01f, 7.5353417e-01f,
    7.5000000e-01f, 7.4644910e-01f, 7.4288170e-01f, 7.3929804e-01f,
    7.3569837e-01f, 7.3208292e-01f, 7.2845194e-01f, 7.2480566e-01f,
    7.2114435e-01f, 7.1746822e-01f, 7.1377755e-01f, 7.1007256e-01f,
    7.0635351e-01f, 7.0262066e-01f, 6.9887424e-01f, 6.9511451e-01f,
    6.9134172e-01f, 6.8755612e-01f, 6.8375797e-01f, 6.7994752e-01f,
    6.7612502e-01f, 6.7229074e-01f, 6.6844493e-01f, 6.6458784e-01f,
    6.6071973e-01f, 6.5684087e-01f, 6.5295151e-01f, 6.4905191e-01f,
    6.4514234e-01f, 6.4122305e-01f, 6.3729431e-01f, 6.3335638e-01f,
    6.2940952e-01f, 6.2545400e-01f, 6.2149009e-01f, 6.1751804e-01f,
    6.1353813e-01f, 6.0955062e-01f, 6.0555578e-01f, 6.0155387e-01f,
    5.9754516e-01f, 5.9352993e-01f, 5.8950843e-01f, 5.8548094e-01f,
    5.8144774e-01f, 5.7740908e-01f, 5.7336524e-01f, 5.6931649e-01f,
    5.6526310e-01f, 5.6120534e-01f, 5.5714348e-01f, 5.5307780e-01f,
    5.4900857e-01f, 5.4493606e-01f, 5.4086054e-01f, 5.3678228e-01f,
    5.3270156e-01f, 5.2861866e-01f, 5.2453384e-01f, 5.2044737e-01f,
    5.1635954e-01f, 5.1227061e-01f, 5.0818087e-01f, 5.0409057e-01f,
    5.0000000e-01f, 4.9590943e-01f, 4.9181913e-01f, 4.8772939e-01f,
    4.8364046e-01f, 4.7955263e-01f, 4.7546616e-01f, 4.7138134e-01f,
    4.6729844e-01f, 4.6321772e-01f, 4.5913946e-01f, 4.5506394e-01f,
    4.5099143e-01f, 4.4692220e-01f, 4.4285652e-01f, 4.3879466e-01f,
    4.3473690e-01f, 4.3068351e-01f, 4.2663476e-01f, 4.2259092e-01f,
    4.1855226e-01f, 4.1451906e-01f, 4.1049157e-01f, 4.0647007e-01f,
    4.0245484e-01f, 3.9844613e-01f, 3.9444422e-01f, 3.9044938e-01f,
    3.8646187e-01f, 3.8248196e-01f, 3.7850991e-01f, 3.7454600e-01f,
    3.7059048e-01f, 3.6664362e-01f, 3.6270569e-01f, 3.5877695e-01f,
    3.5485766e-01f, 3.5094809e-01f, 3.4704849e-01f, 3.4315913e-01f,
    3.3928027e-01f, 3.3541216e-01f, 3.3155507e-01f, 3.2770926e-01f,
    3.2387498e-01f, 3.2005248e-01f, 3.1624203e-01f, 3.1244388e-01f,
    3.0865828e-01f, 3.0488549e-01f, 3.0112576e-01f, 2.9737934e-01f,
    2.9364649e-01f, 2.8992744e-01f, 2.8622245e-01f, 2.8253178e-01f,
    2.7885565e-01f, 2.7519434e-01f, 2.7154806e-01f, 2.6791708e-01f,
    2.6430163e-01f, 2.6070196e-01f, 2.5711830e-01f, 2.5355090e-01f,
    2.5000000e-01f, 2.4646583e-01f, 2.4294863e-01f, 2.3944863e-01f,
    2.3596607e-01f, 2.3250119e-01f, 2.2905421e-01f, 2.2562536e-01f,
    2.2221488e-01f, 2.1882300e-01f, 2.1544993e-01f, 2.1209590e-01f,
    2.0876115e-01f, 2.0544589e-01f, 2.0215035e-01f, 1.9887474e-01f,
    1.9561929e-01f, 1.9238420e-01f, 1.8916971e-01f, 1.8597603e-01f,
    1.8280336e-01f, 1.7965192e-01f, 1.7652192e-01f, 1.7341358e-01f,
    1.7032709e-01f, 1.6726267e-01f, 1.6422052e-01f, 1.6120085e-01f,
    1.5820385e-01f, 1.5522973e-01f, 1.5227868e-01f, 1.4935091e-01f,
    1.4644661e-01f, 1.4356597e-01f, 1.4070919e-01f, 1.3787646e-01f,
    1.3506796e-01f, 1.3228389e-01f, 1.2952444e-01f, 1.2678978e-01f,
    1.2408010e-01f, 1.2139558e-01f, 1.1873640e-01f, 1.1610274e-01f,
    1.1349477e-01f, 1.1091268e-01f, 1.0835663e-01f, 1.0582679e-01f,
    1.0332333e-01f, 1.0084642e-01f, 9.8396234e-02f, 9.5972925e-02f,
    9.3576658e-02f, 9.1207593e-02f, 8.8865891e-02f, 8.6551706e-02f,
    8.4265194e-02f, 8.2006508e-02f, 7.9775799e-02f, 7.7573217e-02f,
    7.5398909e-02f, 7.3253021e-02f, 7.1135695e-02f, 6.9047074e-02f,
    6.6987298e-02f, 6.4956504e-02f, 6.2954829e-02f, 6.0982406e-02f,
    5.9039368e-02f, 5.7125844e-02f, 5.5241962e-02f, 5.3387849e-02f,
    5.1563629e-02f, 4.9769424e-02f, 4.8005353e-02f, 4.6271536e-02f,
    4.4568088e-02f, 4.2895122e-02f, 4.1252752e-02f, 3.9641086e-02f,
    3.8060234e-02f, 3.6510300e-02f, 3.4991388e-02f, 3.3503601e-02f,
    3.2047037e-02f, 3.0621794e-02f, 2.9227967e-02f, 2.7865651e-02f,
    2.6534935e-02f, 2.5235910e-02f, 2.3968661e-02f, 2.2733274e-02f,
    2.1529832e-02f, 2.0358415e-02f, 1.9219101e-02f, 1.8111967e-02f,
    1.7037087e-02f, 1.5994532e-02f, 1.4984373e-02f, 1.4006678e-02f,
    1.3061510e-02f, 1.2148935e-02f, 1.1269013e-02f, 1.0421802e-02f,
    9.6073598e-03f, 8.8257407e-03f, 8.0769970e-03f, 7.3611788e-03f,
    6.6783340e-03f, 6.0285082e-03f, 5.4117450e-03f, 4.8280857e-03f,
    4.2775693e-03f, 3.7602327e-03f, 3.2761105e-03f, 2.8252351e-03f,
    2.4076367e-03f, 2.0233432e-03f, 1.6723803e-03f, 1.3547717e-03f,
    1.0705384e-03f, 8.1969953e-04f, 6.0227190e-04f, 4.1827004e-04f,
    2.6770626e-04f, 1.5059065e-04f, 6.6931045e-05f, 1.6733041e-05f
};

/* ══════════════════════════════════════════════════════════════════════
 * Feature extraction state
 * ══════════════════════════════════════════════════════════════════════ */

typedef struct {
    /* Pre-emphasis */
    float preemph_prev;

    /* STFT overlap buffer (window_size samples, slides by hop_size) */
    float input_q[TV_WINDOW_SIZE];

    /* FFT work buffers */
    float fft_in[TV_FFT_SIZE];
    float fft_out[TV_FFT_SIZE];

    /* Mel filterbank coefficients [TV_MEL_BANDS][TV_N_BINS] */
    float mel_fb[TV_MEL_BANDS * TV_N_BINS];

    /* Mel bin boundaries [TV_MEL_BANDS + 2] */
    int mel_bins[TV_MEL_BANDS + 2];

    /* Feature context stack [TV_CONTEXT_LEN][TV_FEA_LEN] */
    float feat_stack[TV_CONTEXT_LEN * TV_FEA_LEN];
} tv_features;

/* ══════════════════════════════════════════════════════════════════════
 * Model weights
 * ══════════════════════════════════════════════════════════════════════ */

typedef struct {
    /* Separable conv layers (3 layers × dw + pw + bias) */
    struct ggml_tensor * sep_conv_dw[3];
    struct ggml_tensor * sep_conv_pw[3];
    struct ggml_tensor * sep_conv_bias[3];

    /* LSTM layers (2 layers × ih_weight + hh_weight + ih_bias + hh_bias) */
    struct ggml_tensor * lstm_ih_weight[2];
    struct ggml_tensor * lstm_hh_weight[2];
    struct ggml_tensor * lstm_ih_bias[2];
    struct ggml_tensor * lstm_hh_bias[2];

    /* Dense layers (2 layers × weight + bias) */
    struct ggml_tensor * dense_weight[2];
    struct ggml_tensor * dense_bias[2];
} tv_model;

/* ══════════════════════════════════════════════════════════════════════
 * Full context
 * ══════════════════════════════════════════════════════════════════════ */

struct ten_vad_ctx {
    tv_features feat;
    tv_model    model;

    /* GGML contexts and buffers */
    struct ggml_context * ctx_weight;      /* weight tensor metadata */
    ggml_backend_buffer_t buf_weight;      /* weight data */

    struct ggml_context * ctx_state;       /* LSTM state tensor metadata */
    ggml_backend_buffer_t buf_state;       /* LSTM state data */

    /* LSTM hidden/cell states (4 tensors: h1,c1,h2,c2) */
    struct ggml_tensor * h_state[2];
    struct ggml_tensor * c_state[2];

    /* Backend */
    ggml_backend_t backend;

    /* Compute graph scheduling */
    uint8_t * meta_buf;
    size_t    meta_size;
    struct ggml_cgraph * gf;
    ggml_backend_sched_t sched;
};

/* ══════════════════════════════════════════════════════════════════════
 * Feature extraction
 * ══════════════════════════════════════════════════════════════════════ */

static void tv_init_mel_filterbank(tv_features * f) {
    float low_mel  = 2595.0f * log10f(1.0f + 0.0f / 700.0f);
    float high_mel = 2595.0f * log10f(1.0f + 8000.0f / 700.0f);

    for (int i = 0; i < TV_MEL_BANDS + 2; i++) {
        float mel = i * (high_mel - low_mel) / ((float)TV_MEL_BANDS + 1.0f) + low_mel;
        float hz  = 700.0f * (powf(10.0f, mel / 2595.0f) - 1.0f);
        f->mel_bins[i] = (int)((TV_FFT_SIZE + 1.0f) * hz / (float)TV_FS);
    }

    memset(f->mel_fb, 0, sizeof(f->mel_fb));
    for (int j = 0; j < TV_MEL_BANDS; j++) {
        for (int i = f->mel_bins[j]; i < f->mel_bins[j + 1]; i++) {
            f->mel_fb[j * TV_N_BINS + i] = (float)(i - f->mel_bins[j]) /
                                            (float)(f->mel_bins[j + 1] - f->mel_bins[j]);
        }
        for (int i = f->mel_bins[j + 1]; i < f->mel_bins[j + 2]; i++) {
            f->mel_fb[j * TV_N_BINS + i] = (float)(f->mel_bins[j + 2] - i) /
                                            (float)(f->mel_bins[j + 2] - f->mel_bins[j + 1]);
        }
    }
}

static void tv_features_reset(tv_features * f) {
    f->preemph_prev = 0.0f;
    memset(f->input_q, 0, sizeof(f->input_q));
    memset(f->feat_stack, 0, sizeof(f->feat_stack));
}

/**
 * Extract one frame of features from a hop of raw int16 samples.
 * Writes TV_FEA_LEN floats into the context stack and returns pointer
 * to the full [TV_CONTEXT_LEN][TV_FEA_LEN] feature buffer.
 */
static const float * tv_extract_features(tv_features * f, const int16_t * samples, int n_samples) {
    /* 1. Convert int16 → float (NO normalization — TEN-VAD uses raw int16 scale) */
    float raw[TV_HOP_SIZE];
    for (int i = 0; i < n_samples && i < TV_HOP_SIZE; i++) {
        raw[i] = (float)samples[i];
    }

    /* 2. Pre-emphasis: y[n] = x[n] - 0.97 * x[n-1] */
    float emph[TV_HOP_SIZE];
    for (int i = 0; i < n_samples && i < TV_HOP_SIZE; i++) {
        emph[i] = raw[i] - TV_PREEMPH * f->preemph_prev;
        f->preemph_prev = raw[i];
    }

    /* 3. STFT: overlap buffer, window, zero-pad, FFT */
    /* Slide overlap buffer: shift left by hop_size, append new emphasized samples */
    memmove(f->input_q, f->input_q + TV_HOP_SIZE,
            sizeof(float) * (TV_WINDOW_SIZE - TV_HOP_SIZE));
    memcpy(f->input_q + (TV_WINDOW_SIZE - TV_HOP_SIZE), emph,
           sizeof(float) * TV_HOP_SIZE);

    /* Apply Hanning window */
    for (int i = 0; i < TV_WINDOW_SIZE; i++) {
        f->fft_in[i] = f->input_q[i] * TV_HANN_WINDOW[i];
    }
    /* Zero-pad to FFT_SIZE */
    for (int i = TV_WINDOW_SIZE; i < TV_FFT_SIZE; i++) {
        f->fft_in[i] = 0.0f;
    }

    /* FFT (real-to-complex, 1024-point) — output in format2 */
    AUP_FFTW_r2c_1024(f->fft_in, f->fft_out);
    /* Convert format2 → format1 for bin power calculation */
    AUP_FFTW_InplaceTransf(1, TV_FFT_SIZE, f->fft_out);
    AUP_FFTW_RescaleFFTOut(TV_FFT_SIZE, f->fft_out);

    /* 4. Power spectrum (format1 layout) */
    float bin_pow[TV_N_BINS];
    /* bin 0 */
    bin_pow[0] = f->fft_out[0] * f->fft_out[0];
    /* Nyquist bin */
    bin_pow[TV_N_BINS - 1] = f->fft_out[1] * f->fft_out[1];
    /* bins 1..N-2 */
    for (int i = 1; i < TV_N_BINS - 1; i++) {
        int ri = i * 2;
        bin_pow[i] = f->fft_out[ri] * f->fft_out[ri] +
                     f->fft_out[ri + 1] * f->fft_out[ri + 1];
    }

    /* 5. Context stack: shift left, new frame goes at the end */
    memmove(f->feat_stack, f->feat_stack + TV_FEA_LEN,
            sizeof(float) * (TV_CONTEXT_LEN - 1) * TV_FEA_LEN);
    float * cur = f->feat_stack + (TV_CONTEXT_LEN - 1) * TV_FEA_LEN;

    /* 6. Mel filterbank → log → z-normalize */
    float power_norm = 32768.0f * 32768.0f;
    for (int i = 0; i < TV_MEL_BANDS; i++) {
        float sum = 0.0f;
        const float * coef = f->mel_fb + i * TV_N_BINS;
        for (int j = 0; j < TV_N_BINS; j++) {
            sum += bin_pow[j] * coef[j];
        }
        sum = sum / power_norm;
        sum = logf(sum + TV_EPS);
        cur[i] = (sum - TV_FEATURE_MEANS[i]) / (TV_FEATURE_STDS[i] + TV_EPS);
    }

    /* 7. Pitch = 0.0, normalized */
    cur[TV_MEL_BANDS] = (0.0f - TV_FEATURE_MEANS[TV_MEL_BANDS]) /
                        (TV_FEATURE_STDS[TV_MEL_BANDS] + TV_EPS);

    return f->feat_stack;
}

/* ══════════════════════════════════════════════════════════════════════
 * GGML model loading
 * ══════════════════════════════════════════════════════════════════════ */

static int tv_read_i32(FILE * fp) {
    int32_t val;
    if (fread(&val, sizeof(val), 1, fp) != 1) return -1;
    return val;
}

static struct ggml_cgraph * tv_build_graph(ten_vad_ctx * ctx);

ten_vad_ctx * ten_vad_ggml_init(const char * model_path) {
    FILE * fp = fopen(model_path, "rb");
    if (!fp) {
        fprintf(stderr, "ten_vad_ggml: cannot open %s\n", model_path);
        return NULL;
    }

    /* Verify magic */
    uint32_t magic;
    if (fread(&magic, 4, 1, fp) != 1 || magic != GGML_FILE_MAGIC) {
        fprintf(stderr, "ten_vad_ggml: bad magic\n");
        fclose(fp);
        return NULL;
    }

    /* Read model type string */
    int str_len = tv_read_i32(fp);
    char type_buf[64] = {0};
    if (str_len > 0 && str_len < 64) {
        fread(type_buf, 1, str_len, fp);
    }

    /* Read version */
    int major = tv_read_i32(fp);
    int minor = tv_read_i32(fp);
    int patch = tv_read_i32(fp);
    fprintf(stderr, "ten_vad_ggml: model=%s v%d.%d.%d\n", type_buf, major, minor, patch);

    /* Read hyperparams (we verify but don't need to store most) */
    int n_sep_conv  = tv_read_i32(fp);
    int n_lstm      = tv_read_i32(fp);
    int hidden_dim  = tv_read_i32(fp);
    int lstm1_in    = tv_read_i32(fp);
    int lstm2_in    = tv_read_i32(fp);
    int dense1_in   = tv_read_i32(fp);
    int dense1_out  = tv_read_i32(fp);
    int dense2_out  = tv_read_i32(fp);
    (void)n_sep_conv; (void)n_lstm; (void)lstm1_in; (void)lstm2_in;
    (void)dense1_in; (void)dense1_out; (void)dense2_out;

    if (hidden_dim != TV_HIDDEN_DIM) {
        fprintf(stderr, "ten_vad_ggml: unexpected hidden_dim=%d\n", hidden_dim);
        fclose(fp);
        return NULL;
    }

    /* Allocate context */
    ten_vad_ctx * ctx = calloc(1, sizeof(ten_vad_ctx));
    if (!ctx) { fclose(fp); return NULL; }

    /* Initialize feature extraction */
    tv_init_mel_filterbank(&ctx->feat);
    tv_features_reset(&ctx->feat);

    /* CPU backend */
    ctx->backend = ggml_backend_cpu_init();
    if (!ctx->backend) {
        fprintf(stderr, "ten_vad_ggml: failed to init CPU backend\n");
        free(ctx);
        fclose(fp);
        return NULL;
    }

    /* ── Create weight tensors ── */
    /* 21 weight tensors */
    #define N_WEIGHT_TENSORS 21
    size_t ctx_size = N_WEIGHT_TENSORS * ggml_tensor_overhead() + ggml_graph_overhead();
    struct ggml_init_params params = {
        .mem_size   = ctx_size,
        .mem_buffer = NULL,
        .no_alloc   = true,
    };
    ctx->ctx_weight = ggml_init(params);
    if (!ctx->ctx_weight) {
        fprintf(stderr, "ten_vad_ggml: failed to init weight context\n");
        goto fail;
    }

    /* Define tensor shapes (matching converter output) */
    tv_model * m = &ctx->model;

    /* Tensor name→pointer mapping for loading */
    struct { const char * name; struct ggml_tensor ** ptr; } tensor_map[N_WEIGHT_TENSORS];
    int ti = 0;

    /* Sep conv 0: dw(1,1,3,3) pw(16,1,1,1) bias(16) */
    m->sep_conv_dw[0]   = ggml_new_tensor_4d(ctx->ctx_weight, GGML_TYPE_F32, 3, 3, 1, 1);
    m->sep_conv_pw[0]   = ggml_new_tensor_4d(ctx->ctx_weight, GGML_TYPE_F32, 1, 1, 1, 16);
    m->sep_conv_bias[0] = ggml_new_tensor_1d(ctx->ctx_weight, GGML_TYPE_F32, 16);
    ggml_set_name(m->sep_conv_dw[0], "sep_conv_0_dw");
    ggml_set_name(m->sep_conv_pw[0], "sep_conv_0_pw");
    ggml_set_name(m->sep_conv_bias[0], "sep_conv_0_bias");
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "sep_conv_0_dw", .ptr = &m->sep_conv_dw[0]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "sep_conv_0_pw", .ptr = &m->sep_conv_pw[0]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "sep_conv_0_bias", .ptr = &m->sep_conv_bias[0]};

    /* Sep conv 1: dw(16,1,1,3) pw(16,16,1,1) bias(16) */
    m->sep_conv_dw[1]   = ggml_new_tensor_4d(ctx->ctx_weight, GGML_TYPE_F32, 3, 1, 1, 16);
    m->sep_conv_pw[1]   = ggml_new_tensor_4d(ctx->ctx_weight, GGML_TYPE_F32, 1, 1, 16, 16);
    m->sep_conv_bias[1] = ggml_new_tensor_1d(ctx->ctx_weight, GGML_TYPE_F32, 16);
    ggml_set_name(m->sep_conv_dw[1], "sep_conv_1_dw");
    ggml_set_name(m->sep_conv_pw[1], "sep_conv_1_pw");
    ggml_set_name(m->sep_conv_bias[1], "sep_conv_1_bias");
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "sep_conv_1_dw", .ptr = &m->sep_conv_dw[1]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "sep_conv_1_pw", .ptr = &m->sep_conv_pw[1]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "sep_conv_1_bias", .ptr = &m->sep_conv_bias[1]};

    /* Sep conv 2: same as 1 */
    m->sep_conv_dw[2]   = ggml_new_tensor_4d(ctx->ctx_weight, GGML_TYPE_F32, 3, 1, 1, 16);
    m->sep_conv_pw[2]   = ggml_new_tensor_4d(ctx->ctx_weight, GGML_TYPE_F32, 1, 1, 16, 16);
    m->sep_conv_bias[2] = ggml_new_tensor_1d(ctx->ctx_weight, GGML_TYPE_F32, 16);
    ggml_set_name(m->sep_conv_dw[2], "sep_conv_2_dw");
    ggml_set_name(m->sep_conv_pw[2], "sep_conv_2_pw");
    ggml_set_name(m->sep_conv_bias[2], "sep_conv_2_bias");
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "sep_conv_2_dw", .ptr = &m->sep_conv_dw[2]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "sep_conv_2_pw", .ptr = &m->sep_conv_pw[2]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "sep_conv_2_bias", .ptr = &m->sep_conv_bias[2]};

    /* LSTM 0: ih(256,80) hh(256,64) ih_bias(256) hh_bias(256) */
    m->lstm_ih_weight[0] = ggml_new_tensor_2d(ctx->ctx_weight, GGML_TYPE_F32, 80, 256);
    m->lstm_hh_weight[0] = ggml_new_tensor_2d(ctx->ctx_weight, GGML_TYPE_F32, 64, 256);
    m->lstm_ih_bias[0]   = ggml_new_tensor_1d(ctx->ctx_weight, GGML_TYPE_F32, 256);
    m->lstm_hh_bias[0]   = ggml_new_tensor_1d(ctx->ctx_weight, GGML_TYPE_F32, 256);
    ggml_set_name(m->lstm_ih_weight[0], "lstm_0_ih_weight");
    ggml_set_name(m->lstm_hh_weight[0], "lstm_0_hh_weight");
    ggml_set_name(m->lstm_ih_bias[0], "lstm_0_ih_bias");
    ggml_set_name(m->lstm_hh_bias[0], "lstm_0_hh_bias");
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "lstm_0_ih_weight", .ptr = &m->lstm_ih_weight[0]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "lstm_0_hh_weight", .ptr = &m->lstm_hh_weight[0]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "lstm_0_ih_bias", .ptr = &m->lstm_ih_bias[0]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "lstm_0_hh_bias", .ptr = &m->lstm_hh_bias[0]};

    /* LSTM 1: ih(256,64) hh(256,64) ih_bias(256) hh_bias(256) */
    m->lstm_ih_weight[1] = ggml_new_tensor_2d(ctx->ctx_weight, GGML_TYPE_F32, 64, 256);
    m->lstm_hh_weight[1] = ggml_new_tensor_2d(ctx->ctx_weight, GGML_TYPE_F32, 64, 256);
    m->lstm_ih_bias[1]   = ggml_new_tensor_1d(ctx->ctx_weight, GGML_TYPE_F32, 256);
    m->lstm_hh_bias[1]   = ggml_new_tensor_1d(ctx->ctx_weight, GGML_TYPE_F32, 256);
    ggml_set_name(m->lstm_ih_weight[1], "lstm_1_ih_weight");
    ggml_set_name(m->lstm_hh_weight[1], "lstm_1_hh_weight");
    ggml_set_name(m->lstm_ih_bias[1], "lstm_1_ih_bias");
    ggml_set_name(m->lstm_hh_bias[1], "lstm_1_hh_bias");
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "lstm_1_ih_weight", .ptr = &m->lstm_ih_weight[1]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "lstm_1_hh_weight", .ptr = &m->lstm_hh_weight[1]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "lstm_1_ih_bias", .ptr = &m->lstm_ih_bias[1]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "lstm_1_hh_bias", .ptr = &m->lstm_hh_bias[1]};

    /* Dense 0: weight [128, 32] in ggml ne[] order (ne[0]=128 matches input dim) */
    m->dense_weight[0] = ggml_new_tensor_2d(ctx->ctx_weight, GGML_TYPE_F32, 128, 32);
    m->dense_bias[0]   = ggml_new_tensor_1d(ctx->ctx_weight, GGML_TYPE_F32, 32);
    ggml_set_name(m->dense_weight[0], "dense_0_weight");
    ggml_set_name(m->dense_bias[0], "dense_0_bias");
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "dense_0_weight", .ptr = &m->dense_weight[0]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "dense_0_bias", .ptr = &m->dense_bias[0]};

    /* Dense 1: weight [32, 1] in ggml ne[] order */
    m->dense_weight[1] = ggml_new_tensor_2d(ctx->ctx_weight, GGML_TYPE_F32, 32, 1);
    m->dense_bias[1]   = ggml_new_tensor_1d(ctx->ctx_weight, GGML_TYPE_F32, 1);
    ggml_set_name(m->dense_weight[1], "dense_1_weight");
    ggml_set_name(m->dense_bias[1], "dense_1_bias");
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "dense_1_weight", .ptr = &m->dense_weight[1]};
    tensor_map[ti++] = (typeof(tensor_map[0])){.name = "dense_1_bias", .ptr = &m->dense_bias[1]};

    /* Allocate weight buffer */
    ctx->buf_weight = ggml_backend_alloc_ctx_tensors(ctx->ctx_weight, ctx->backend);
    if (!ctx->buf_weight) {
        fprintf(stderr, "ten_vad_ggml: failed to allocate weight buffer\n");
        goto fail;
    }

    /* ── Load tensor data from file ── */
    int loaded = 0;
    while (!feof(fp)) {
        int32_t n_dims, name_len, ttype;
        if (fread(&n_dims, 4, 1, fp) != 1) break;
        if (fread(&name_len, 4, 1, fp) != 1) break;
        if (fread(&ttype, 4, 1, fp) != 1) break;

        int32_t ne[4] = {1, 1, 1, 1};
        for (int d = 0; d < n_dims; d++) {
            if (fread(&ne[d], 4, 1, fp) != 1) goto fail;
        }

        char name[128] = {0};
        if (name_len > 0 && name_len < 128) {
            if (fread(name, 1, name_len, fp) != (size_t)name_len) goto fail;
        }

        /* Find matching tensor */
        struct ggml_tensor * tensor = NULL;
        for (int j = 0; j < N_WEIGHT_TENSORS; j++) {
            if (strcmp(name, tensor_map[j].name) == 0) {
                tensor = *tensor_map[j].ptr;
                break;
            }
        }
        if (!tensor) {
            fprintf(stderr, "ten_vad_ggml: unknown tensor '%s'\n", name);
            goto fail;
        }

        /* Read data */
        size_t nbytes = ggml_nbytes(tensor);
        void * buf = malloc(nbytes);
        if (!buf || fread(buf, 1, nbytes, fp) != nbytes) {
            free(buf);
            goto fail;
        }
        ggml_backend_tensor_set(tensor, buf, 0, nbytes);
        free(buf);
        loaded++;
    }
    fclose(fp); fp = NULL;

    if (loaded != N_WEIGHT_TENSORS) {
        fprintf(stderr, "ten_vad_ggml: loaded %d/%d tensors\n", loaded, N_WEIGHT_TENSORS);
        goto fail;
    }

    fprintf(stderr, "ten_vad_ggml: loaded %d tensors (%.1f KB)\n",
            loaded, ggml_backend_buffer_get_size(ctx->buf_weight) / 1024.0f);

    /* ── LSTM state context (h1,c1,h2,c2) ── */
    {
        size_t state_ctx_size = 4 * ggml_tensor_overhead();
        struct ggml_init_params sp = {
            .mem_size   = state_ctx_size,
            .mem_buffer = NULL,
            .no_alloc   = true,
        };
        ctx->ctx_state = ggml_init(sp);
        if (!ctx->ctx_state) goto fail;

        for (int i = 0; i < 2; i++) {
            ctx->h_state[i] = ggml_new_tensor_1d(ctx->ctx_state, GGML_TYPE_F32, TV_HIDDEN_DIM);
            ctx->c_state[i] = ggml_new_tensor_1d(ctx->ctx_state, GGML_TYPE_F32, TV_HIDDEN_DIM);
            char hname[16], cname[16];
            snprintf(hname, sizeof(hname), "h%d", i);
            snprintf(cname, sizeof(cname), "c%d", i);
            ggml_set_name(ctx->h_state[i], hname);
            ggml_set_name(ctx->c_state[i], cname);
        }
        ctx->buf_state = ggml_backend_alloc_ctx_tensors(ctx->ctx_state, ctx->backend);
        if (!ctx->buf_state) goto fail;
        ggml_backend_buffer_clear(ctx->buf_state, 0);
    }

    /* ── Build and schedule the compute graph ── */
    {
        /* Metadata buffer for graph building */
        ctx->meta_size = ggml_tensor_overhead() * 128 + ggml_graph_overhead();
        ctx->meta_buf = malloc(ctx->meta_size);
        if (!ctx->meta_buf) goto fail;

        /* Build graph once to determine compute buffer sizes */
        ctx->gf = tv_build_graph(ctx);
        if (!ctx->gf) goto fail;

        /* Create scheduler */
        ctx->sched = ggml_backend_sched_new(&ctx->backend, NULL, 1, ctx->meta_size, false, false);
        if (!ctx->sched) goto fail;

        if (!ggml_backend_sched_alloc_graph(ctx->sched, ctx->gf)) {
            fprintf(stderr, "ten_vad_ggml: failed to alloc compute graph\n");
            goto fail;
        }
    }

    return ctx;

fail:
    if (fp) fclose(fp);
    ten_vad_ggml_free(ctx);
    return NULL;
}

/* ══════════════════════════════════════════════════════════════════════
 * GGML graph construction
 * ══════════════════════════════════════════════════════════════════════ */

static struct ggml_tensor * tv_build_lstm_layer(
    struct ggml_context * ctx0, ten_vad_ctx * vctx, int layer,
    struct ggml_tensor * cur, struct ggml_cgraph * gf)
{
    tv_model * m = &vctx->model;
    const int hdim = TV_HIDDEN_DIM;

    struct ggml_tensor * x_t = ggml_transpose(ctx0, cur);

    /* Input gate */
    struct ggml_tensor * inp_gate = ggml_mul_mat(ctx0, m->lstm_ih_weight[layer], x_t);
    inp_gate = ggml_add(ctx0, inp_gate, m->lstm_ih_bias[layer]);

    /* Hidden gate */
    struct ggml_tensor * hid_gate = ggml_mul_mat(ctx0, m->lstm_hh_weight[layer], vctx->h_state[layer]);
    hid_gate = ggml_add(ctx0, hid_gate, m->lstm_hh_bias[layer]);

    /* Combined preactivations */
    struct ggml_tensor * gates = ggml_add(ctx0, inp_gate, hid_gate);

    const size_t hdim_bytes = ggml_row_size(gates->type, hdim);

    /* PyTorch gate order: i, f, g, o */
    struct ggml_tensor * i_t = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, gates, hdim, 0 * hdim_bytes));
    struct ggml_tensor * f_t = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, gates, hdim, 1 * hdim_bytes));
    struct ggml_tensor * g_t = ggml_tanh(ctx0, ggml_view_1d(ctx0, gates, hdim, 2 * hdim_bytes));
    struct ggml_tensor * o_t = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, gates, hdim, 3 * hdim_bytes));

    /* Cell state update: c = f*c_prev + i*g */
    struct ggml_tensor * c_out = ggml_add(ctx0,
        ggml_mul(ctx0, f_t, vctx->c_state[layer]),
        ggml_mul(ctx0, i_t, g_t));
    ggml_build_forward_expand(gf, ggml_cpy(ctx0, c_out, vctx->c_state[layer]));

    /* Hidden state: h = o * tanh(c) */
    struct ggml_tensor * h_out = ggml_mul(ctx0, o_t, ggml_tanh(ctx0, c_out));
    ggml_build_forward_expand(gf, ggml_cpy(ctx0, h_out, vctx->h_state[layer]));

    return h_out;
}

static struct ggml_cgraph * tv_build_graph(ten_vad_ctx * ctx) {
    struct ggml_init_params params = {
        .mem_size   = ctx->meta_size,
        .mem_buffer = ctx->meta_buf,
        .no_alloc   = true,
    };

    struct ggml_context * ctx0 = ggml_init(params);
    if (!ctx0) return NULL;

    struct ggml_cgraph * gf = ggml_new_graph(ctx0);

    /*
     * The ONNX model does: input[1,3,41] → reshape[1,1,3,41] → Conv2D pipeline
     * But ggml conv ops are complex. Since we only ever have a single frame
     * (batch=1, the conv outputs are tiny), we do feature extraction in C
     * and feed the flattened [80] output directly into the LSTMs.
     *
     * So: run the conv layers in C, pass the 80-dim vector to GGML for LSTM+Dense.
     */

    /* Input: 80-dim vector (post-conv features), stored as column [1, 80] */
    struct ggml_tensor * input = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, 1, 80);
    ggml_set_name(input, "input");
    ggml_set_input(input);

    /* LSTM layer 0: input_size=80, hidden_size=64 */
    struct ggml_tensor * h0 = tv_build_lstm_layer(ctx0, ctx, 0, input, gf);

    /* LSTM layer 1: input_size=64, hidden_size=64 */
    struct ggml_tensor * h1_in = ggml_reshape_2d(ctx0, h0, 1, TV_HIDDEN_DIM);
    struct ggml_tensor * h1 = tv_build_lstm_layer(ctx0, ctx, 1, h1_in, gf);

    /* Concat h0 + h1 → [128] */
    struct ggml_tensor * concat = ggml_concat(ctx0, h0, h1, 0);

    /* Dense 0: [128] → [32] + ReLU */
    struct ggml_tensor * d0 = ggml_mul_mat(ctx0, ctx->model.dense_weight[0], concat);
    d0 = ggml_add(ctx0, d0, ctx->model.dense_bias[0]);
    d0 = ggml_relu(ctx0, d0);

    /* Dense 1: [32] → [1] + Sigmoid */
    struct ggml_tensor * d1 = ggml_mul_mat(ctx0, ctx->model.dense_weight[1], d0);
    d1 = ggml_add(ctx0, d1, ctx->model.dense_bias[1]);
    d1 = ggml_sigmoid(ctx0, d1);

    ggml_set_name(d1, "prob");
    ggml_set_output(d1);

    ggml_build_forward_expand(gf, d1);
    ggml_free(ctx0);

    return gf;
}

/* ══════════════════════════════════════════════════════════════════════
 * Separable conv layers (run in C, feed result to GGML)
 *
 * Because the conv layers operate on tiny inputs (3×41 → 16 channels),
 * running them as explicit loops in C is simpler and faster than building
 * a complex ggml graph with 2D convolutions.
 * ══════════════════════════════════════════════════════════════════════ */

/**
 * Run all 3 separable conv layers + maxpool + flatten on the feature stack.
 * Input: features[TV_CONTEXT_LEN][TV_FEA_LEN] = [3][41]
 * Output: flat[80]
 */
static void tv_run_convs(ten_vad_ctx * ctx, const float * features, float * out80) {
    tv_model * m = &ctx->model;

    /* We need to read weight data from ggml tensors */
    /* Conv layer sizes: after reshape, input is [1, 1, 3, 41] */
    /* Layer 0: dw(1,1,3,3) pw(16,1,1,1) → output [1,16,1,41] then maxpool → [1,16,1,20] */
    /* Layer 1: dw(16,1,1,3) pw(16,16,1,1) stride=2 → [1,16,1,10] */
    /* Layer 2: dw(16,1,1,3) pw(16,16,1,1) stride=2 → [1,16,1,5] */
    /* Flatten: 16*5 = 80 */

    /* Read all weights into local buffers */
    float dw0[9], pw0[16], b0[16];
    float dw1[48], pw1[256], b1[16];
    float dw2[48], pw2[256], b2[16];

    ggml_backend_tensor_get(m->sep_conv_dw[0], dw0, 0, sizeof(dw0));
    ggml_backend_tensor_get(m->sep_conv_pw[0], pw0, 0, sizeof(pw0));
    ggml_backend_tensor_get(m->sep_conv_bias[0], b0, 0, sizeof(b0));
    ggml_backend_tensor_get(m->sep_conv_dw[1], dw1, 0, sizeof(dw1));
    ggml_backend_tensor_get(m->sep_conv_pw[1], pw1, 0, sizeof(pw1));
    ggml_backend_tensor_get(m->sep_conv_bias[1], b1, 0, sizeof(b1));
    ggml_backend_tensor_get(m->sep_conv_dw[2], dw2, 0, sizeof(dw2));
    ggml_backend_tensor_get(m->sep_conv_pw[2], pw2, 0, sizeof(pw2));
    ggml_backend_tensor_get(m->sep_conv_bias[2], b2, 0, sizeof(b2));

    /* ── Layer 0: SeparableConv2D on [1,1,3,41] ── */
    /* Depthwise conv: kernel (3,3), 1 input channel, padding=same → output [1,1,3,41] */
    float dw0_out[3 * 41];
    memset(dw0_out, 0, sizeof(dw0_out));
    /* dw0 kernel is [1,1,3,3] in ONNX = 3×3 spatial */
    for (int h = 0; h < 3; h++) {
        for (int w = 0; w < 41; w++) {
            float sum = 0.0f;
            for (int kh = 0; kh < 3; kh++) {
                for (int kw = 0; kw < 3; kw++) {
                    int ih = h + kh - 1;
                    int iw = w + kw - 1;
                    if (ih >= 0 && ih < 3 && iw >= 0 && iw < 41) {
                        sum += features[ih * 41 + iw] * dw0[kh * 3 + kw];
                    }
                }
            }
            dw0_out[h * 41 + w] = sum;
        }
    }

    /* Pointwise conv: (16,1,1,1) = 16 output channels, each is a scalar multiply */
    /* + bias + ReLU → output [16, 3, 41] */
    float pw0_out[16 * 3 * 41];
    for (int oc = 0; oc < 16; oc++) {
        for (int i = 0; i < 3 * 41; i++) {
            float val = dw0_out[i] * pw0[oc] + b0[oc];
            pw0_out[oc * 3 * 41 + i] = val > 0.0f ? val : 0.0f; /* ReLU */
        }
    }

    /* MaxPool: kernel(1,3), stride(1,2), no padding → output [16, 3, 20] */
    /* Pool along W dimension: for each (oc,h), pool w with kernel=3, stride=2 */
    float pool_out[16 * 3 * 20];
    for (int oc = 0; oc < 16; oc++) {
        for (int h = 0; h < 3; h++) {
            for (int ow = 0; ow < 20; ow++) {
                int w_start = ow * 2;
                float mx = -1e30f;
                for (int k = 0; k < 3; k++) {
                    int iw = w_start + k;
                    if (iw < 41) {
                        float v = pw0_out[oc * 3 * 41 + h * 41 + iw];
                        if (v > mx) mx = v;
                    }
                }
                pool_out[oc * 3 * 20 + h * 20 + ow] = mx;
            }
        }
    }

    /* ── Layer 1: SeparableConv1D on [16, 3, 20] ── */
    /* The ONNX graph does: unsqueeze → conv2d(dw) with kernel(1,3) stride(2,2) → conv2d(pw) → squeeze */
    /* With stride=(2,2) on [3,20]: output H = ceil(3/2)=2, output W = ceil(20/2)=10 */
    /* But ONNX has padding [0,0,0,1] = pad_h_begin=0, pad_h_end=0, pad_w_begin=0, pad_w_end=1 */
    /* Depthwise: each of 16 channels independently */
    float dw1_out[16 * 2 * 10];
    memset(dw1_out, 0, sizeof(dw1_out));
    for (int ch = 0; ch < 16; ch++) {
        /* dw1 kernel for this channel: [1, 1, 1, 3] → just 3 weights along W */
        const float * kw = dw1 + ch * 3;
        for (int oh = 0; oh < 2; oh++) {
            for (int ow = 0; ow < 10; ow++) {
                int ih = oh * 2;
                float sum = 0.0f;
                for (int k = 0; k < 3; k++) {
                    int iw = ow * 2 + k;
                    if (ih < 3 && iw < 20) {
                        sum += pool_out[ch * 3 * 20 + ih * 20 + iw] * kw[k];
                    }
                }
                dw1_out[ch * 2 * 10 + oh * 10 + ow] = sum;
            }
        }
    }

    /* Pointwise + bias + ReLU */
    float pw1_out[16 * 2 * 10];
    for (int oc = 0; oc < 16; oc++) {
        for (int i = 0; i < 2 * 10; i++) {
            float sum = b1[oc];
            for (int ic = 0; ic < 16; ic++) {
                sum += dw1_out[ic * 2 * 10 + i] * pw1[oc * 16 + ic];
            }
            pw1_out[oc * 2 * 10 + i] = sum > 0.0f ? sum : 0.0f;
        }
    }

    /* ── Layer 2: SeparableConv1D on [16, 2, 10] ── */
    /* Same structure: stride(2,2), kernel(1,3), pad [0,0,0,1] */
    /* Output: H = ceil(2/2)=1, W = ceil(10/2)=5 → [16, 1, 5] */
    float dw2_out[16 * 1 * 5];
    memset(dw2_out, 0, sizeof(dw2_out));
    for (int ch = 0; ch < 16; ch++) {
        const float * kw = dw2 + ch * 3;
        for (int ow = 0; ow < 5; ow++) {
            int ih = 0;
            float sum = 0.0f;
            for (int k = 0; k < 3; k++) {
                int iw = ow * 2 + k;
                if (iw < 10) {
                    sum += pw1_out[ch * 2 * 10 + ih * 10 + iw] * kw[k];
                }
            }
            dw2_out[ch * 5 + ow] = sum;
        }
    }

    /* Pointwise + bias + ReLU */
    float pw2_out[16 * 5];
    for (int oc = 0; oc < 16; oc++) {
        for (int i = 0; i < 5; i++) {
            float sum = b2[oc];
            for (int ic = 0; ic < 16; ic++) {
                sum += dw2_out[ic * 5 + i] * pw2[oc * 16 + ic];
            }
            pw2_out[oc * 5 + i] = sum > 0.0f ? sum : 0.0f;
        }
    }

    /* ── Flatten: [16, 1, 5] → [80] ── */
    /* The ONNX graph does: transpose(perm=[0,2,1]) then reshape to [seq, batch, 80] */
    /* After layer 2 squeeze we have [16, 5] → transpose → [5, 16] → flatten → [80] */
    /* But we just interleave: out[w*16+ch] = pw2_out[ch*5+w] */
    for (int w = 0; w < 5; w++) {
        for (int ch = 0; ch < 16; ch++) {
            out80[w * 16 + ch] = pw2_out[ch * 5 + w];
        }
    }
}

/* ══════════════════════════════════════════════════════════════════════
 * Inference
 * ══════════════════════════════════════════════════════════════════════ */

float ten_vad_ggml_process(ten_vad_ctx * ctx, const int16_t * samples, int n_samples) {
    /* 1. Extract features → [3][41] context stack */
    const float * features = tv_extract_features(&ctx->feat, samples, n_samples);

    /* 2. Run conv layers in C → [80] vector */
    float conv_out[80];
    tv_run_convs(ctx, features, conv_out);

    /* 3. Set input tensor for GGML graph */
    struct ggml_tensor * input = ggml_graph_get_tensor(ctx->gf, "input");
    struct ggml_tensor * prob  = ggml_graph_get_tensor(ctx->gf, "prob");
    if (!input || !prob) return 0.0f;

    ggml_backend_tensor_set(input, conv_out, 0, sizeof(conv_out));

    /* 4. Compute graph (reuse without reset — LSTM state carries over) */
    if (!ggml_backend_sched_graph_compute(ctx->sched, ctx->gf)) {
        return 0.0f;
    }

    /* 5. Read output probability */
    float result = 0.0f;
    ggml_backend_tensor_get(prob, &result, 0, sizeof(float));
    return result;
}

void ten_vad_ggml_reset(ten_vad_ctx * ctx) {
    if (!ctx) return;
    /* Reset LSTM states to zero */
    ggml_backend_buffer_clear(ctx->buf_state, 0);
    /* Reset feature extraction state */
    tv_features_reset(&ctx->feat);
}

void ten_vad_ggml_free(ten_vad_ctx * ctx) {
    if (!ctx) return;

    if (ctx->sched) ggml_backend_sched_free(ctx->sched);
    free(ctx->meta_buf);
    if (ctx->buf_state) ggml_backend_buffer_free(ctx->buf_state);
    if (ctx->ctx_state) ggml_free(ctx->ctx_state);
    if (ctx->buf_weight) ggml_backend_buffer_free(ctx->buf_weight);
    if (ctx->ctx_weight) ggml_free(ctx->ctx_weight);
    if (ctx->backend) ggml_backend_free(ctx->backend);
    free(ctx);
}
