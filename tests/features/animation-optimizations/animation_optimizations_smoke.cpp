#include "features/animation-optimizations/GrannyKernels.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <random>

// Checks the vector Granny kernels against scalar references written in
// Granny's own per-element order (the order the game's -O0 code runs, checked
// bit for bit against the executable during development), including outputs
// that alias an input, and a curve decoded by hand. Synthetic, CPU only.
namespace G = BG3MFXGranny;
#pragma clang fp contract(off)

namespace {
int failures = 0;
void check(bool ok, const char *what, int i) {
    if (!ok && failures++ < 10) fprintf(stderr, "animation-optimizations-smoke: %s mismatch (case %d)\n", what, i);
}
bool same(const float *a, const float *b, int n) { return memcmp(a, b, n * sizeof(float)) == 0; }

void referenceMultiply(float *d, const float *a, const float *b, bool transpose) {
    for (int outer = 0; outer < (transpose ? 3 : 4); ++outer)
        for (int inner = 0; inner < (transpose ? 4 : 3); ++inner) {
            int r = transpose ? inner : outer, j = transpose ? outer : inner;
            float t = a[4 * r + 1] * b[4 + j];
            t = std::fma(a[4 * r], b[j], t);
            t = std::fma(a[4 * r + 2], b[8 + j], t);
            if (r == 3) t = t + b[12 + j];
            d[transpose ? 4 * j + r : 4 * r + j] = t;
        }
    if (!transpose) { d[11] = 0; d[7] = 0; d[3] = 0; d[15] = 1; }
}
}

int main() {
    std::mt19937 random(7);
    std::uniform_real_distribution<float> unit(-2.0f, 2.0f);
    for (int i = 0; i < 20000; ++i) {
        float a[16], b[16], expected[16], actual[16];
        for (int k = 0; k < 16; ++k) a[k] = unit(random), b[k] = unit(random);
        for (int transpose = 0; transpose < 2; ++transpose) {
            int n = transpose ? 12 : 16;
            memset(expected, 0x7f, sizeof expected); memcpy(actual, expected, sizeof actual);
            referenceMultiply(expected, a, b, transpose);
            (transpose ? G::Multiply4x3Transpose : G::Multiply4x3)(actual, a, b);
            check(same(expected, actual, 16), transpose ? "Multiply4x3Transpose" : "Multiply4x3", i);
            // In place: D == A, then D == B.
            for (int alias = 0; alias < 2; ++alias) {
                float e[16], x[16], other[16];
                memcpy(e, alias ? b : a, sizeof e); memcpy(x, e, sizeof x); memcpy(other, alias ? a : b, sizeof other);
                referenceMultiply(e, alias ? other : e, alias ? e : other, transpose);
                (transpose ? G::Multiply4x3Transpose : G::Multiply4x3)(x, alias ? other : x, alias ? x : other);
                check(same(e, x, n), "aliased multiply", i);
            }
        }
        float q[4] = {unit(random), unit(random), unit(random), unit(random)}, m[9], e[9];
        const float x = q[0], y = q[1], z = q[2], w = q[3];
        e[0] = std::fma(-2.0f, y * y + z * z, 1.0f); e[1] = 2.0f * (x * y - w * z); e[2] = 2.0f * (x * z + w * y);
        e[3] = 2.0f * (x * y + w * z); e[4] = std::fma(-2.0f, x * x + z * z, 1.0f); e[5] = 2.0f * (y * z - w * x);
        e[6] = 2.0f * (x * z - w * y); e[7] = 2.0f * (y * z + w * x); e[8] = std::fma(-2.0f, x * x + y * y, 1.0f);
        G::MatrixEqualsQuaternion3x3(m, q);
        check(same(e, m, 9), "MatrixEqualsQuaternion3x3", i);
        float aliased[9] = {q[0], q[1], q[2], q[3]};
        G::MatrixEqualsQuaternion3x3(aliased, aliased);
        check(same(e, aliased, 9), "aliased MatrixEqualsQuaternion3x3", i);
    }

    // Knot searches, sorted and unsorted, against a linear upper bound.
    for (int i = 0; i < 20000; ++i) {
        uint16_t knots[40];
        int count = 1 + random() % 40;
        for (int k = 0; k < count; ++k) knots[k] = random() % 64;
        if (i & 1) std::sort(knots, knots + count);
        uint16_t value = random() % 70;
        int expected = 0;
        if (i & 1) {
            while (expected < count && !(value < knots[expected])) ++expected;
            if (expected == count) --expected;
            check(G::FindKnotInteger(count, knots, value) == expected, "FindKnotInteger", i);
        }
        int index = G::FindKnotInteger(count, knots, value);
        check(index >= 0 && index < count, "FindKnotInteger range", i);
    }

    // A two-knot D4nK16uC15u curve: selectors 0x0123 give components scales
    // table[6], table[4], table[2], table[0] (times 1/32767-ish) and offsets.
    struct alignas(4) Data { uint8_t format[2]; uint16_t selectors; float oneOverKnotScale; int32_t knotCount;
                             uint8_t values[8]; } __attribute__((packed));
    uint16_t values[2 + 6] = {10, 30, 0x8000 | 100, 0x4000 | 2000, 0x8000 | 30000, 5, 32767, 1234};
    Data data = {{0, 0}, 0x0123, 4.0f, 2 << 2, {}};
    const uint16_t *pointer = values;
    memcpy(data.values, &pointer, 8);
    uint8_t curve[16] = {};
    const Data *dataPointer = &data;
    memcpy(curve + G::CurveD4nK16uC15u::Data, &dataPointer, 8);
    float knots[2], controls[8];
    G::CurveExtractKnotValuesD4nK16uC15u(curve, 0, 2, knots, controls, nullptr);
    check(knots[0] == 0.25f * 10 && knots[1] == 0.25f * 30, "curve knots", 0);
    float table[32];
    memcpy(table, G::ScaleOffsetTableBits, sizeof table);
    const float step = [] { uint32_t bits = 0x38000100; float v; memcpy(&v, &bits, 4); return v; }();
    const unsigned entry[4] = {3, 2, 1, 0};
    for (int k = 0; k < 2; ++k) {
        const uint16_t *c = values + 2 + 3 * k;
        unsigned dropped = ((c[1] >> 14) & 2) | (c[2] >> 15), component = dropped;
        float expected[4], sum = 0;
        for (int n = 0; n < 3; ++n) {
            component = (component + 1) & 3;
            float v = std::fma(table[2 * entry[component]] * step, float(c[n] & 0x7fff), table[2 * entry[component] + 1]);
            sum = std::fma(v, v, sum);
            expected[component] = v;
        }
        float last = float(std::sqrt(double(1.0f - sum)));
        expected[dropped] = (c[0] & 0x8000) ? -last : last;
        check(same(expected, controls + 4 * k, 4), "curve controls", k);
    }
    // Normalization: near unit length takes Granny's Newton step, otherwise a
    // full normalize.
    for (int i = 0; i < 20000; ++i) {
        float v[4], e[4];
        for (float &x : v) x = unit(random);
        if (i & 1) { float s = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3]); for (float &x : v) x /= s; }
        memcpy(e, v, sizeof e);
        float squared = std::fma(e[3], e[3], std::fma(e[2], e[2], std::fma(e[0], e[0], e[1] * e[1])));
        float scale;
        if (squared > 1.1f || squared < 0.9f) scale = 1.0f / float(std::sqrt(double(squared)));
        else { float t = 3.0f - squared; scale = (0.0625f * std::fma(-squared, t * t, 12.0f)) * t; }
        for (float &x : e) x = x * scale;
        G::NormalizeWithTest4(v);
        check(same(e, v, 4), "NormalizeWithTest4", i);
    }

    // Quadratic B-spline of 3-vectors at the middle of uniform knots: basis
    // 1/8, 3/4, 1/8.
    {
        const float ti[4] = {0, 1, 2, 3}, pi[9] = {8, 16, 24, 0, 0, 0, 8, 16, 24};
        float result[3], c0, c1, c2;
        G::QuadraticCoefficients(0, 1, 2, 3, 1.5f, &c0, &c1, &c2);
        check(c0 == 0.125f && c1 == 0.75f && c2 == 0.125f, "QuadraticCoefficients", 0);
        G::SampleBSpline2x3(ti + 2, pi + 6, 1.5f, result);
        check(result[0] == 2 && result[1] == 4 && result[2] == 6, "SampleBSpline2x3", 0);
    }

    // A composite transform: a quarter turn about z, scale 2 in x, position.
    {
        alignas(16) uint8_t transform[0x44] = {};
        const uint32_t flags = 4;
        const float position[3] = {1, 2, 3}, q[4] = {0, 0, std::sqrt(0.5f), std::sqrt(0.5f)}, scale[9] = {2, 0, 0, 0, 1, 0, 0, 0, 1};
        memcpy(transform, &flags, 4); memcpy(transform + 4, position, 12); memcpy(transform + 0x10, q, 16); memcpy(transform + 0x20, scale, 36);
        float d[16], rotation[9], m[9];
        G::BuildCompositeTransform4x4(transform, d);
        G::MatrixEqualsQuaternion3x3(rotation, q);
        G::MatrixMultiply3x3(m, rotation, scale);
        const float expected[16] = {m[0], m[3], m[6], 0, m[1], m[4], m[7], 0, m[2], m[5], m[8], 0, 1, 2, 3, 1};
        check(same(expected, d, 16), "BuildCompositeTransform4x4", 0);
        float world[16];
        G::BuildFullWorldPoseOnly(transform, expected, world);
        float product[16];
        G::Multiply4x3(product, expected, expected);
        check(same(product, world, 16), "BuildFullWorldPoseOnly", 0);
    }

    if (failures) return fprintf(stderr, "animation-optimizations-smoke: %d failures\n", failures), 1;
    puts("animation-optimizations-smoke: ok");
    return 0;
}
