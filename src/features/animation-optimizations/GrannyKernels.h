#pragma once
// Optimized replacements for hot Granny 3D runtime functions. BG3 links Granny
// unoptimized (-O0): every operand is reloaded from the stack, small helpers
// are out-of-line calls, and its math has no vector code on ARM64. Each kernel
// here reproduces its Granny original bit for bit: the same multiplies and
// fused multiply-adds per element, in the same order, with contraction off so
// the compiler adds no fusions of its own. Kernels are pure; they read only
// their arguments.
#include <arm_neon.h>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace BG3MFXGranny {

namespace detail {
inline bool overlaps(const float *a, size_t aCount, const float *b, size_t bCount) {
    auto x = reinterpret_cast<uintptr_t>(a), y = reinterpret_cast<uintptr_t>(b);
    return x < y + bCount * sizeof(float) && y < x + aCount * sizeof(float);
}

// Arithmetic with its operands kept in Granny's order. A NaN result is the
// first NaN operand (the addend first for a fused multiply-add), and the
// compiler may otherwise commute a multiply or an add, so these use assembly.
inline float mul(float a, float b) { float r; asm("fmul %s0, %s1, %s2" : "=w"(r) : "w"(a), "w"(b)); return r; }
inline float add(float a, float b) { float r; asm("fadd %s0, %s1, %s2" : "=w"(r) : "w"(a), "w"(b)); return r; }
// a * b + c, as fmadd.
inline float fma(float a, float b, float c) { float r; asm("fmadd %s0, %s1, %s2, %s3" : "=w"(r) : "w"(a), "w"(b), "w"(c)); return r; }
// c - a * b, as fmsub.
inline float fms(float a, float b, float c) { float r; asm("fmsub %s0, %s1, %s2, %s3" : "=w"(r) : "w"(a), "w"(b), "w"(c)); return r; }
inline float32x4_t mul(float32x4_t a, float32x4_t b) { float32x4_t r; asm("fmul %0.4s, %1.4s, %2.4s" : "=w"(r) : "w"(a), "w"(b)); return r; }
inline float32x4_t add(float32x4_t a, float32x4_t b) { float32x4_t r; asm("fadd %0.4s, %1.4s, %2.4s" : "=w"(r) : "w"(a), "w"(b)); return r; }
// t + a * b, as fmla (the addend, then a, then b, for NaNs, as fmadd).
inline float32x4_t fma(float32x4_t a, float32x4_t b, float32x4_t t) { asm("fmla %0.4s, %1.4s, %2.4s" : "+w"(t) : "w"(a), "w"(b)); return t; }

// One row of A (A[4r..4r+2]) times B's 3x3 part, per lane j:
// fmadd(A2, B[8+j], fmadd(A0, B[j], A1 * B[4+j])). Lane 3 is unused.
inline float32x4_t row(const float *a, float32x4_t b0, float32x4_t b1, float32x4_t b2) {
    float32x4_t t = mul(vld1q_dup_f32(a + 1), b1);
    t = fma(vld1q_dup_f32(a), b0, t);
    return fma(vld1q_dup_f32(a + 2), b2, t);
}

inline float32x4_t translation(const float *b) {
    // B[12..14] without reading B[15], which Granny never reads.
    return vcombine_f32(vld1_f32(b + 12), vld1_lane_f32(b + 14, vdup_n_f32(0.0f), 0));
}

// Granny's own element order, for an output that overlaps an input: each
// element reads the inputs as left by the stores before it.
inline float element(const float *a, const float *b, int r, int j) {
    float t = mul(a[4 * r + 1], b[4 + j]);
    t = fma(a[4 * r], b[j], t);
    return fma(a[4 * r + 2], b[8 + j], t);
}
}

// granny::ColumnMatrixMultiply4x3Impl_Generic(float *D, const float *A,
// const float *B): D = A * B for affine 4x4 row-major matrices. Writes D[0..15]
// with D[3] = D[7] = D[11] = 0 and D[15] = 1; reads A and B[0..14].
inline void Multiply4x3(float *d, const float *a, const float *b) {
#pragma clang fp contract(off)
    if (detail::overlaps(d, 16, a, 15) || detail::overlaps(d, 16, b, 15)) {
        for (int r = 0; r < 4; ++r)
            for (int j = 0; j < 3; ++j) {
                float value = detail::element(a, b, r, j);
                d[4 * r + j] = r == 3 ? detail::add(value, b[12 + j]) : value;
            }
        d[11] = 0.0f; d[7] = 0.0f; d[3] = 0.0f; d[15] = 1.0f;
        return;
    }
    const float32x4_t b0 = vld1q_f32(b), b1 = vld1q_f32(b + 4), b2 = vld1q_f32(b + 8);
    vst1q_f32(d, vsetq_lane_f32(0.0f, detail::row(a, b0, b1, b2), 3));
    vst1q_f32(d + 4, vsetq_lane_f32(0.0f, detail::row(a + 4, b0, b1, b2), 3));
    vst1q_f32(d + 8, vsetq_lane_f32(0.0f, detail::row(a + 8, b0, b1, b2), 3));
    float32x4_t last = detail::add(detail::row(a + 12, b0, b1, b2), detail::translation(b));
    vst1q_f32(d + 12, vsetq_lane_f32(1.0f, last, 3));
}

// granny::ColumnMatrixMultiply4x3TransposeImpl_Generic: the same product,
// written as its transposed 3x4: D[4j + r] = (A * B)[r][j] for r = 0..3 and
// j = 0..2. Writes D[0..11].
inline void Multiply4x3Transpose(float *d, const float *a, const float *b) {
#pragma clang fp contract(off)
    if (detail::overlaps(d, 12, a, 15) || detail::overlaps(d, 12, b, 15)) {
        for (int j = 0; j < 3; ++j)
            for (int r = 0; r < 4; ++r) {
                float value = detail::element(a, b, r, j);
                d[4 * j + r] = r == 3 ? detail::add(value, b[12 + j]) : value;
            }
        return;
    }
    const float32x4_t b0 = vld1q_f32(b), b1 = vld1q_f32(b + 4), b2 = vld1q_f32(b + 8);
    float32x4_t r0 = detail::row(a, b0, b1, b2), r1 = detail::row(a + 4, b0, b1, b2);
    float32x4_t r2 = detail::row(a + 8, b0, b1, b2);
    float32x4_t r3 = detail::add(detail::row(a + 12, b0, b1, b2), detail::translation(b));
    float32x4_t t0 = vtrn1q_f32(r0, r1), t1 = vtrn2q_f32(r0, r1);
    float32x4_t t2 = vtrn1q_f32(r2, r3), t3 = vtrn2q_f32(r2, r3);
    vst1q_f32(d, vcombine_f32(vget_low_f32(t0), vget_low_f32(t2)));
    vst1q_f32(d + 4, vcombine_f32(vget_low_f32(t1), vget_low_f32(t3)));
    vst1q_f32(d + 8, vcombine_f32(vget_high_f32(t0), vget_high_f32(t2)));
}

// granny::MatrixEqualsQuaternion3x3(float *D, const float *Q): the rotation
// matrix of quaternion (x, y, z, w) = Q[0..3], row-major 3x3. Granny reads all
// of Q before writing D, so D may alias Q.
inline void MatrixEqualsQuaternion3x3(float *d, const float *q) {
#pragma clang fp contract(off)
    const float x = q[0], y = q[1], z = q[2], w = q[3];
    const float xx = x * x, yy = y * y, zz = z * z;
    const float xy = x * y, xz = x * z, yz = y * z;
    const float wx = w * x, wy = w * y, wz = w * z;
    const float m0 = std::fma(-2.0f, yy + zz, 1.0f), m1 = 2.0f * (xy - wz), m2 = 2.0f * (xz + wy);
    const float m3 = 2.0f * (xy + wz), m4 = std::fma(-2.0f, xx + zz, 1.0f), m5 = 2.0f * (yz - wx);
    const float m6 = 2.0f * (xz - wy), m7 = 2.0f * (yz + wx), m8 = std::fma(-2.0f, xx + yy, 1.0f);
    d[0] = m0; d[1] = m1; d[2] = m2; d[3] = m3; d[4] = m4; d[5] = m5; d[6] = m6; d[7] = m7; d[8] = m8;
}

// int FindKnotInteger<T>(int count, const T *knots, T value): the index of the
// first knot greater than value (std::upper_bound over knots[0..count)), or
// count - 1 when there is none. Granny's exact search order, so the result
// matches even for unsorted knots.
template <typename T> inline int FindKnotInteger(int count, const T *knots, T value) {
    const T *first = knots;
    ptrdiff_t remaining = count;
    while (remaining > 0) {
        ptrdiff_t step = remaining / 2;
        const T *probe = first + step;
        if (!(value < *probe)) {
            first = probe + 1;
            remaining -= step + 1;
        } else {
            remaining = step;
        }
    }
    ptrdiff_t index = first - knots;
    if (index == count) --index;
    return static_cast<int>(index);
}

// Granny's 15-bit quaternion component dequantization table: 16 (scale, offset)
// pairs. The installer checks the game's copy against these bits.
inline constexpr uint32_t ScaleOffsetTableBits[32] = {
    0x3fb504f3, 0xbf3504f3, 0x3f3504f3, 0xbeb504f3, 0x3eb504f3, 0xbf07c3b6, 0x3eb504f3, 0xbe3504f3,
    0x3eb504f3, 0x3e3504f3, 0x3e3504f3, 0xbe3504f3, 0x3e3504f3, 0xbdb504f3, 0x3e3504f3, 0x00000000,
    0xbfb504f3, 0x3f3504f3, 0xbf3504f3, 0x3eb504f3, 0xbeb504f3, 0x3f07c3b6, 0xbeb504f3, 0x3e3504f3,
    0xbeb504f3, 0xbe3504f3, 0xbe3504f3, 0x3e3504f3, 0xbe3504f3, 0x3db504f3, 0xbe3504f3, 0x80000000,
};

// Granny's curve2 layout as the D4n (unit quaternion) decoders read it:
// curve + 8 points at the curve data; data + 2 holds four 4-bit table
// selectors, data + 4 OneOverKnotScale, data + 8 the knot/control count in
// value units (times 4, read as int >> 2), and data + 0xc (unaligned) the
// value array: knots first, then 3 controls per knot.
namespace CurveD4n {
inline constexpr size_t Data = 0x8, Selectors = 0x2, OneOverKnotScale = 0x4, KnotCount = 0x8, Values = 0xc;
}
namespace CurveD4nK16uC15u = CurveD4n;

namespace detail {
inline float bitsToFloat(uint32_t bits) { float value; memcpy(&value, &bits, 4); return value; }

// D4nK16uC15u stores u16 values with 15-bit components (step 1/32767);
// D4nK8uC7u u8 values with 7-bit components (step 1/127). Granny converts a
// value through UnsignedShortToFloat's identity table, which is exactly
// (float)u.
template <typename T> struct D4nFormat;
template <> struct D4nFormat<uint16_t> { static constexpr uint32_t Step = 0x38000100, Sign = 0x8000, Bits = 15; };
template <> struct D4nFormat<uint8_t> { static constexpr uint32_t Step = 0x3c010204, Sign = 0x80, Bits = 7; };

// granny::CurveExtractKnotValuesD4n*(const curve2 &curve, int index, int
// count, float *knots, float *controls, const float *identity): decodes knots
// [index, index + count) and their unit quaternions. Each control stores three
// components; the sign bit of the first gives the sign of the dropped
// component, whose index is the top bits of the second and third, and the
// dropped component is sqrt(1 - sum of squares), taken in double.
template <typename T> inline void CurveExtractD4n(const void *curve, int index, int count, float *knots, float *controls) {
#pragma clang fp contract(off)
    namespace L = CurveD4n;
    using F = D4nFormat<T>;
    const uint8_t *data;
    memcpy(&data, static_cast<const uint8_t *>(curve) + L::Data, sizeof data);
    int32_t knotCount;
    memcpy(&knotCount, data + L::KnotCount, sizeof knotCount);
    const T *values;
    memcpy(&values, data + L::Values, sizeof values);
    if (knots) {
        float oneOverKnotScale;
        memcpy(&oneOverKnotScale, data + L::OneOverKnotScale, sizeof oneOverKnotScale);
        const float scale = 1.0f / oneOverKnotScale;
        const T *knot = values + index;
        for (int i = 0; i < count; ++i) knots[i] = scale * static_cast<float>(knot[i]);
    }
    if (!controls) return;
    uint16_t selectors;
    memcpy(&selectors, data + L::Selectors, sizeof selectors);
    float scales[4], offsets[4];
    const float step = bitsToFloat(F::Step);
    for (int i = 0; i < 4; ++i) {
        unsigned entry = selectors & 0xf;
        selectors = static_cast<uint16_t>(selectors >> 4);
        scales[i] = bitsToFloat(ScaleOffsetTableBits[2 * entry]) * step;
        offsets[i] = bitsToFloat(ScaleOffsetTableBits[2 * entry + 1]);
    }
    const T *control = values + (knotCount >> 2) + static_cast<ptrdiff_t>(static_cast<int32_t>(index * 3));
    for (int i = 0; i < count; ++i, control += 3, controls += 4) {
        const bool negative = (control[0] & F::Sign) != 0;
        const unsigned dropped = ((control[1] >> (F::Bits - 1)) & 2) | (control[2] >> F::Bits);
        unsigned component = dropped;
        float sum = 0.0f;
        for (int k = 0; k < 3; ++k) {
            component = (component + 1) & 3;
            float value = std::fma(scales[component], static_cast<float>(control[k] & (F::Sign - 1)), offsets[component]);
            sum = std::fma(value, value, sum);
            controls[component] = value;
        }
        float last = static_cast<float>(std::sqrt(static_cast<double>(1.0f - sum)));
        controls[dropped] = negative ? -last : last;
    }
}
}

// granny::CurveExtractKnotValuesD4nK16uC15u. identity is unused.
inline void CurveExtractKnotValuesD4nK16uC15u(const void *curve, int index, int count, float *knots, float *controls,
    const float *) {
    detail::CurveExtractD4n<uint16_t>(curve, index, count, knots, controls);
}

// granny::CurveExtractKnotValuesD4nK8uC7u. identity is unused.
inline void CurveExtractKnotValuesD4nK8uC7u(const void *curve, int index, int count, float *knots, float *controls,
    const float *) {
    detail::CurveExtractD4n<uint8_t>(curve, index, count, knots, controls);
}

// granny::CurveExtractKnotValuesD3K8uC8u: 3-component curves (positions,
// scale) with u8 knots and u8 controls. Data: + 2 the top half of the float
// OneOverKnotScale, + 4 three scales, + 0x10 three offsets, + 0x1c the u8
// count (times 4), + 0x20 the u8 values: knots, then 3 controls per knot.
namespace CurveD3K8uC8u {
inline constexpr size_t Data = 0x8, OneOverKnotScaleTop = 0x2, Scales = 0x4, Offsets = 0x10, KnotCount = 0x1c, Values = 0x20;
}
inline void CurveExtractKnotValuesD3K8uC8u(const void *curve, int index, int count, float *knots, float *controls,
    const float *) {
#pragma clang fp contract(off)
    namespace L = CurveD3K8uC8u;
    const uint8_t *data;
    memcpy(&data, static_cast<const uint8_t *>(curve) + L::Data, sizeof data);
    int32_t knotCount;
    memcpy(&knotCount, data + L::KnotCount, sizeof knotCount);
    const uint8_t *values;
    memcpy(&values, data + L::Values, sizeof values);
    if (knots) {
        uint16_t top;
        memcpy(&top, data + L::OneOverKnotScaleTop, sizeof top);
        const float scale = 1.0f / detail::bitsToFloat(static_cast<uint32_t>(top) << 16);
        const uint8_t *knot = values + index;
        for (int i = 0; i < count; ++i) knots[i] = scale * static_cast<float>(knot[i]);
    }
    if (!controls) return;
    float scales[3], offsets[3];
    memcpy(scales, data + L::Scales, sizeof scales);
    memcpy(offsets, data + L::Offsets, sizeof offsets);
    const uint8_t *control = values + (knotCount >> 2) + static_cast<ptrdiff_t>(static_cast<int32_t>(index * 3));
    for (int i = 0; i < count; ++i)
        for (int k = 0; k < 3; ++k) *controls++ = std::fma(scales[k], static_cast<float>(*control++), offsets[k]);
}

// granny::Normalize4(float *v): v / length, the length taken in double as
// granny::SquareRoot does, and multiplied by its float reciprocal.
inline float InnerProduct4(const float *v) {
#pragma clang fp contract(off)
    float sum = v[1] * v[1];
    sum = std::fma(v[0], v[0], sum);
    sum = std::fma(v[2], v[2], sum);
    return std::fma(v[3], v[3], sum);
}
inline void Normalize4(float *v) {
#pragma clang fp contract(off)
    const float length = static_cast<float>(std::sqrt(static_cast<double>(InnerProduct4(v))));
    const float scale = 1.0f / length;
    for (int k = 0; k < 4; ++k) v[k] = detail::mul(v[k], scale);
}

// granny::NormalizeWithTest4(float *v): near unit length (0.9 <= |v|^2 <=
// 1.1, or NaN), one Newton step toward 1/|v|; otherwise Normalize4.
inline void NormalizeWithTest4(float *v) {
#pragma clang fp contract(off)
    const float squared = InnerProduct4(v);
    if (squared > detail::bitsToFloat(0x3f8ccccd) || squared < detail::bitsToFloat(0x3f666666)) {
        Normalize4(v);
        return;
    }
    const float t = 3.0f - squared;
    const float scale = detail::mul(detail::mul(0.0625f, detail::fms(squared, t * t, 12.0f)), t);
    for (int k = 0; k < 4; ++k) v[k] = detail::mul(v[k], scale);
}

// granny::QuadraticCoefficients(t0, t1, t2, t3, t, &c0, &c1, &c2): the
// quadratic B-spline basis at t for knots t0..t3.
inline void QuadraticCoefficients(float t0, float t1, float t2, float t3, float t, float *c0, float *c1, float *c2) {
#pragma clang fp contract(off)
    const float a = t - t1, b = t - t0, c = t2 - t1, d = t2 - t0, e = t3 - t1;
    const float u = a / c, v = b / d, w = a / e;
    const float mid = detail::fms(u, v, detail::add(v, u));
    *c2 = detail::mul(u, w);
    *c1 = mid - *c2;
    *c0 = 1.0f - mid;
}

// granny::SampleBSpline2x<N>(const float *ti, const float *pi, float t, float
// *result): quadratic B-spline of N-component controls pi[-2N .. N), knots
// ti[-2 .. 1]. Element by element as Granny, so result may alias pi.
template <int N> inline void SampleBSpline2(const float *ti, const float *pi, float t, float *result) {
#pragma clang fp contract(off)
    float c0, c1, c2;
    QuadraticCoefficients(ti[-2], ti[-1], ti[0], ti[1], t, &c0, &c1, &c2);
    for (int k = 0; k < N; ++k) {
        float value = detail::mul(c1, pi[k - N]);
        value = detail::fma(c0, pi[k - 2 * N], value);
        result[k] = detail::fma(c2, pi[k], value);
    }
}
inline void SampleBSpline2x3(const float *ti, const float *pi, float t, float *result) { SampleBSpline2<3>(ti, pi, t, result); }
// granny::SampleBSpline2x4n: the 4-component (quaternion) spline, normalized.
inline void SampleBSpline2x4n(const float *ti, const float *pi, float t, float *result) {
    SampleBSpline2<4>(ti, pi, t, result);
    Normalize4(result);
}

// granny::MatrixMultiply3x3(float *D, const float *A, const float *B): D = A B
// for row-major 3x3, element by element in Granny's order.
inline void MatrixMultiply3x3(float *d, const float *a, const float *b) {
#pragma clang fp contract(off)
    for (int r = 0; r < 3; ++r)
        for (int j = 0; j < 3; ++j) {
            float value = detail::mul(a[3 * r + 1], b[3 + j]);
            value = detail::fma(a[3 * r], b[j], value);
            d[3 * r + j] = detail::fma(a[3 * r + 2], b[6 + j], value);
        }
}

// granny::transform: flags (bit 2: has scale/shear), position, orientation
// quaternion, 3x3 scale/shear.
namespace Transform {
inline constexpr size_t Flags = 0x0, Position = 0x4, Orientation = 0x10, ScaleShear = 0x20;
inline constexpr uint32_t HasScaleShear = 0x4;
}

// granny::BuildCompositeTransform4x4(const transform &t, float *D): the affine
// 4x4 of t, row-major with the 3x3 transposed (rotation times scale/shear) and
// the position in the last row.
inline void BuildCompositeTransform4x4(const void *transform, float *d) {
    const uint8_t *t = static_cast<const uint8_t *>(transform);
    float rotation[9], scaled[9];
    MatrixEqualsQuaternion3x3(rotation, reinterpret_cast<const float *>(t + Transform::Orientation));
    uint32_t flags;
    memcpy(&flags, t + Transform::Flags, sizeof flags);
    const float *m = rotation;
    if (flags & Transform::HasScaleShear) {
        MatrixMultiply3x3(scaled, rotation, reinterpret_cast<const float *>(t + Transform::ScaleShear));
        m = scaled;
    }
    // Granny reads the position after writing the 3x3 rows.
    for (int row = 0; row < 3; ++row) {
        d[4 * row] = m[row]; d[4 * row + 1] = m[3 + row]; d[4 * row + 2] = m[6 + row]; d[4 * row + 3] = 0.0f;
    }
    const float *position = reinterpret_cast<const float *>(t + Transform::Position);
    d[12] = position[0]; d[13] = position[1]; d[14] = position[2]; d[15] = 1.0f;
}

// granny::BuildFullWorldPoseOnly_Generic(const transform &t, const float
// *parent, float *result): result = composite(t) * parent.
inline void BuildFullWorldPoseOnly(const void *transform, const float *parent, float *result) {
    float composite[16];
    BuildCompositeTransform4x4(transform, composite);
    Multiply4x3(result, composite, parent);
}

// granny::BuildSingleCompositeFromWorldPoseTranspose_Generic(const float
// *inverseWorld, const float *world, float *result).
inline void BuildSingleCompositeFromWorldPoseTranspose(const float *inverseWorld, const float *world, float *result) {
    Multiply4x3Transpose(result, inverseWorld, world);
}

// granny::BuildIndexedCompositeBufferTransposed(const skeleton &, const
// world_pose &, const int *indices, int count, float (*buffer)[3][4]): for
// each listed bone, its inverse world transform times its world transform,
// transposed. Granny's argument checks return without writing.
namespace Skeleton { inline constexpr size_t BoneCount = 0x8, Bones = 0xc, BoneBytes = 0xa4, InverseWorld = 0x50; }
namespace WorldPose { inline constexpr size_t BoneCount = 0x0, World4x4 = 0x4; }
inline void BuildIndexedCompositeBufferTransposed(const void *skeleton, const void *worldPose, const int *indices, int count,
    float *buffer) {
    if (!buffer || !indices) return;
    const uint8_t *s = static_cast<const uint8_t *>(skeleton), *w = static_cast<const uint8_t *>(worldPose);
    int32_t skeletonBones, poseBones;
    memcpy(&skeletonBones, s + Skeleton::BoneCount, sizeof skeletonBones);
    memcpy(&poseBones, w + WorldPose::BoneCount, sizeof poseBones);
    if (count < 0 || count > skeletonBones || count > poseBones || reinterpret_cast<uintptr_t>(buffer) % 16) return;
    const uint8_t *bones;
    const float *world;
    memcpy(&bones, s + Skeleton::Bones, sizeof bones);
    memcpy(&world, w + WorldPose::World4x4, sizeof world);
    for (int i = 0; i < count; ++i, buffer += 12) {
        const int bone = indices[i];
        Multiply4x3Transpose(buffer, reinterpret_cast<const float *>(bones + static_cast<ptrdiff_t>(bone) * Skeleton::BoneBytes +
                                                                     Skeleton::InverseWorld),
                             world + static_cast<ptrdiff_t>(bone) * 16);
    }
}

}
