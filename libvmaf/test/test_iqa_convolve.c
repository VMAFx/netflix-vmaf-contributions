/**
 *
 *  Copyright 2016-2020 Netflix, Inc.
 *
 *     Licensed under the BSD+Patent License (the "License");
 *     you may not use this file except in compliance with the License.
 *     You may obtain a copy of the License at
 *
 *         https://opensource.org/licenses/BSDplusPatent
 *
 *     Unless required by applicable law or agreed to in writing, software
 *     distributed under the License is distributed on an "AS IS" BASIS,
 *     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *     See the License for the specific language governing permissions and
 *     limitations under the License.
 *
 */

#include <math.h>

#include "test.h"
#include "feature/iqa/convolve.h"

#define W 6
#define H 5

static int almost_equal(float a, float b)
{
    return fabsf(a - b) < 1e-4f;
}

static void fill_image(float *img)
{
    for (int i = 0; i < W * H; i++)
        img[i] = (float)((i * 37) % 11);
}

/* A non-normalized separable kernel must give the same result as the
 * equivalent normalized kernel: each 1D pass is scaled by its own sum. */
static char *test_convolve_unnormalized_separable()
{
    float k_h[3] = {1.0f, 2.0f, 1.0f};
    float k_v[3] = {1.0f, 4.0f, 1.0f};
    float k_2d[9];
    float n_h[3], n_v[3], n_2d[9];
    float img[W * H], out[W * H], ref[W * H];
    int rw, rh;

    for (int v = 0; v < 3; v++) {
        n_h[v] = k_h[v] / 4.0f;
        n_v[v] = k_v[v] / 6.0f;
        for (int u = 0; u < 3; u++) {
            k_2d[v * 3 + u] = k_v[v] * k_h[u];
            n_2d[v * 3 + u] = n_v[v] * n_h[u];
        }
    }

    struct _kernel unnormalized = {
        .kernel = k_2d, .kernel_h = k_h, .kernel_v = k_v,
        .w = 3, .h = 3, .normalized = 0, .bnd_opt = KBND_SYMMETRIC,
    };
    struct _kernel normalized = {
        .kernel = n_2d, .kernel_h = n_h, .kernel_v = n_v,
        .w = 3, .h = 3, .normalized = 1, .bnd_opt = KBND_SYMMETRIC,
    };

    fill_image(img);
    _iqa_convolve(img, W, H, &normalized, ref, &rw, &rh);
    mu_assert("unexpected output width", rw == W - 2);
    mu_assert("unexpected output height", rh == H - 2);

    fill_image(img);
    _iqa_convolve(img, W, H, &unnormalized, out, &rw, &rh);
    for (int i = 0; i < rw * rh; i++)
        mu_assert("unnormalized kernel not scaled by its sum",
                  almost_equal(out[i], ref[i]));

    /* a constant image stays constant under a normalized filter */
    for (int i = 0; i < W * H; i++)
        img[i] = 3.0f;
    _iqa_convolve(img, W, H, &unnormalized, out, &rw, &rh);
    for (int i = 0; i < rw * rh; i++)
        mu_assert("constant image not preserved", almost_equal(out[i], 3.0f));

    return NULL;
}

char *run_tests()
{
    mu_run_test(test_convolve_unnormalized_separable);
    return NULL;
}
