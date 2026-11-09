#include "common/native/SupportedBuild.h"
#include "common/Feature.h"
#import "features/animation-optimizations/AnimationOptimizations.h"
#include "features/animation-optimizations/GrannyKernels.h"
#include "common/native/CodePatch.h"
#include <atomic>
#include <cstring>

// BG3 links the Granny 3D animation runtime unoptimized (-O0), and character
// animation spends most of its Granny time in small functions: matrix
// products, composite transforms, quaternion-to-matrix and normalization, knot
// searches, spline sampling and curve decoding. Each is replaced by a kernel
// from GrannyKernels.h that computes the same bits. Functions Granny calls
// through its writable function pointers are swapped there; the others are
// entered through a jump over their first four instructions.
namespace Native = BG3MFXBuild::Animation;

namespace {
void multiply4x3(float *d, const float *a, const float *b) { BG3MFXGranny::Multiply4x3(d, a, b); }
void multiply4x3Transpose(float *d, const float *a, const float *b) { BG3MFXGranny::Multiply4x3Transpose(d, a, b); }
void matrixEqualsQuaternion3x3(float *d, const float *q) { BG3MFXGranny::MatrixEqualsQuaternion3x3(d, q); }
void curveExtract(const void *curve, int index, int count, float *knots, float *controls, const float *identity) {
    BG3MFXGranny::CurveExtractKnotValuesD4nK16uC15u(curve, index, count, knots, controls, identity);
}
void curveExtractD4nK8uC7u(const void *curve, int index, int count, float *knots, float *controls, const float *identity) {
    BG3MFXGranny::CurveExtractKnotValuesD4nK8uC7u(curve, index, count, knots, controls, identity);
}
void curveExtractD3K8uC8u(const void *curve, int index, int count, float *knots, float *controls, const float *identity) {
    BG3MFXGranny::CurveExtractKnotValuesD3K8uC8u(curve, index, count, knots, controls, identity);
}
void normalize4(float *v) { BG3MFXGranny::Normalize4(v); }
void normalizeWithTest4(float *v) { BG3MFXGranny::NormalizeWithTest4(v); }
void quadraticCoefficients(float t0, float t1, float t2, float t3, float t, float *c0, float *c1, float *c2) {
    BG3MFXGranny::QuadraticCoefficients(t0, t1, t2, t3, t, c0, c1, c2);
}
void sampleBSpline2x4n(const float *ti, const float *pi, float t, float *result) { BG3MFXGranny::SampleBSpline2x4n(ti, pi, t, result); }
void sampleBSpline2x3(const float *ti, const float *pi, float t, float *result) { BG3MFXGranny::SampleBSpline2x3(ti, pi, t, result); }
void matrixMultiply3x3(float *d, const float *a, const float *b) { BG3MFXGranny::MatrixMultiply3x3(d, a, b); }
void buildCompositeTransform4x4(const void *transform, float *d) { BG3MFXGranny::BuildCompositeTransform4x4(transform, d); }
void buildFullWorldPoseOnly(const void *transform, const float *parent, float *result) {
    BG3MFXGranny::BuildFullWorldPoseOnly(transform, parent, result);
}
void buildCompositeTranspose(const float *inverseWorld, const float *world, float *result) {
    BG3MFXGranny::BuildSingleCompositeFromWorldPoseTranspose(inverseWorld, world, result);
}
void buildIndexedCompositeBufferTransposed(const void *skeleton, const void *worldPose, const int *indices, int count, float *buffer) {
    BG3MFXGranny::BuildIndexedCompositeBufferTransposed(skeleton, worldPose, indices, count, buffer);
}
int findKnotU8(int count, const uint8_t *knots, uint8_t value) { return BG3MFXGranny::FindKnotInteger(count, knots, value); }
int findKnotU16(int count, const uint16_t *knots, uint16_t value) { return BG3MFXGranny::FindKnotInteger(count, knots, value); }
int findKnotU32(int count, const uint32_t *knots, uint32_t value) { return BG3MFXGranny::FindKnotInteger(count, knots, value); }

struct Entry { uintptr_t address; const uint32_t *original; void *hook; };
struct Slot { uintptr_t address, original; void *hook; };
template <typename F> void *hook(F *function) { return reinterpret_cast<void *>(function); }
}

BOOL BG3MFXInstallAnimationOptimizations(intptr_t slide, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXAnimationOptimizations" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // Root has already checked the executable UUID; also check every pointer,
    // entry and the curve decoder's table.
    const Slot slots[] = {
        {Native::Multiply4x3Slot, Native::Multiply4x3Generic, hook(&multiply4x3)},
        {Native::Multiply4x3TransposeSlot, Native::Multiply4x3TransposeGeneric, hook(&multiply4x3Transpose)},
        {Native::FullWorldPoseSlot, Native::FullWorldPoseGeneric, hook(&buildFullWorldPoseOnly)},
        {Native::CompositeTransposeSlot, Native::CompositeTransposeGeneric, hook(&buildCompositeTranspose)},
    };
    for (const Slot &slot : slots)
        if (reinterpret_cast<std::atomic<uintptr_t> *>(slot.address + slide)->load() != slot.original + slide)
            return fail(@"Unsupported Granny matrix functions.");
    if (memcmp(reinterpret_cast<const void *>(Native::ScaleOffsetTable + slide), BG3MFXGranny::ScaleOffsetTableBits,
               sizeof BG3MFXGranny::ScaleOffsetTableBits) != 0)
        return fail(@"Unsupported Granny curve table.");
    const auto *identity = reinterpret_cast<const float *>(Native::IdentityTable + slide);
    for (int i = 0; i < 256; ++i)
        if (identity[i] != static_cast<float>(i)) return fail(@"Unsupported Granny curve table.");
    const Entry entries[] = {
        {Native::MatrixEqualsQuaternion3x3, Native::MatrixEqualsQuaternion3x3Entry, hook(&matrixEqualsQuaternion3x3)},
        {Native::CurveExtractKnotValuesD4nK16uC15u, Native::CurveExtractEntry, hook(&curveExtract)},
        {Native::CurveExtractKnotValuesD4nK8uC7u, Native::CurveD4nK8uC7uEntry, hook(&curveExtractD4nK8uC7u)},
        {Native::CurveExtractKnotValuesD3K8uC8u, Native::Frame0x80Entry, hook(&curveExtractD3K8uC8u)},
        {Native::FindKnotU8, Native::FindKnotEntry, hook(&findKnotU8)},
        {Native::FindKnotU16, Native::FindKnotEntry, hook(&findKnotU16)},
        {Native::FindKnotU32, Native::FindKnotEntry, hook(&findKnotU32)},
        {Native::Normalize4, Native::Normalize4Entry, hook(&normalize4)},
        {Native::NormalizeWithTest4, Native::NormalizeWithTest4Entry, hook(&normalizeWithTest4)},
        {Native::QuadraticCoefficients, Native::QuadraticCoefficientsEntry, hook(&quadraticCoefficients)},
        {Native::SampleBSpline2x4n, Native::SampleBSplineEntry, hook(&sampleBSpline2x4n)},
        {Native::SampleBSpline2x3, Native::SampleBSplineEntry, hook(&sampleBSpline2x3)},
        {Native::MatrixMultiply3x3, Native::MatrixMultiply3x3Entry, hook(&matrixMultiply3x3)},
        {Native::BuildCompositeTransform4x4, Native::BuildCompositeTransform4x4Entry, hook(&buildCompositeTransform4x4)},
        {Native::BuildIndexedCompositeBufferTransposed, Native::Frame0x80Entry, hook(&buildIndexedCompositeBufferTransposed)},
    };
    std::vector<std::pair<uintptr_t, size_t>> ranges;
    for (const Entry &entry : entries) {
        if (memcmp(reinterpret_cast<const void *>(entry.address + slide), entry.original, 16) != 0)
            return fail(@"Unsupported Granny animation functions.");
        ranges.push_back({entry.address + slide, 16});
    }
    auto result = BG3MFXPatchCode(ranges, [&] {
        for (const Entry &entry : entries) {
            // ldr x16, #8; br x16; .quad hook
            uint32_t code[4] = {0x58000050, 0xd61f0200, 0, 0};
            memcpy(code + 2, &entry.hook, 8);
            memcpy(reinterpret_cast<void *>(entry.address + slide), code, sizeof code);
        }
    });
    if (result == BG3MFXCodePatchResult::NotWritable) return fail(@"Could not make Granny animation code writable.");
    // The pointers are in writable data.
    for (const Slot &slot : slots)
        reinterpret_cast<std::atomic<uintptr_t> *>(slot.address + slide)->store(reinterpret_cast<uintptr_t>(slot.hook));
    // Written but not executable again still counts as installed, not skipped.
    return YES;
}

namespace {
BOOL installAnimationOptimizations(const BG3MFXFeatureContext &context, NSError **error) {
    return BG3MFXInstallAnimationOptimizations(context.slide, error);
}
}
BG3MFX_FEATURE(animationOptimizationsFeature, {"animation-optimizations", nullptr, true, installAnimationOptimizations, nullptr});
