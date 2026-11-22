#include "common/native/SupportedBuild.h"
#include "common/Feature.h"
#include "features/improved-draw-distance/ImprovedDrawDistance.h"
#include "common/native/CodePatch.h"
#include <cstring>

// Raises the distance D at which BG3's size cull reaches full strength (see
// DrawDistance.h). ls::GlobalSwitches::Reset, which every GlobalSwitches
// construction runs, writes D for each Detail Distance value: setting 0 from
// the last float of a 16-byte constant only Reset loads, settings 1 and 2 from
// a `mov w9` immediate. Both are patched before BG3 creates its switches.
namespace Native = BG3MFXBuild::ImprovedDrawDistance;

namespace {
BOOL installImprovedDrawDistance(const BG3MFXFeatureContext &context, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXImprovedDrawDistance" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    const float distance = BG3MFXImprovedDrawDistance;
    const uint32_t move = BG3MFXImprovedDrawDistanceMove(distance);
    if (!move) return fail(@"The draw distance cannot be loaded by one instruction.");
    // Root has already checked the executable UUID; also check both sites.
    const uintptr_t constant = Native::ResetConstant + context.slide, moveSite = Native::ResetDistanceMove + context.slide;
    if (memcmp(reinterpret_cast<const void *>(constant), Native::ResetConstantOriginal, sizeof Native::ResetConstantOriginal) ||
        *reinterpret_cast<const uint32_t *>(moveSite) != Native::ResetDistanceMoveOriginal)
        return fail(@"Unsupported size cull distance.");
    const uintptr_t constantDistance = constant + Native::ResetConstantDistanceWord * 4;
    auto result = BG3MFXPatchCode({{constantDistance, 4}, {moveSite, 4}}, [&] {
        memcpy(reinterpret_cast<void *>(constantDistance), &distance, 4);
        memcpy(reinterpret_cast<void *>(moveSite), &move, 4);
    });
    if (result == BG3MFXCodePatchResult::NotWritable) return fail(@"Could not make the size cull distance writable.");
    // Written but not executable again still counts as installed, not skipped.
    return YES;
}
}
BG3MFX_FEATURE(improvedDrawDistanceFeature, {"improved-draw-distance", nullptr, true, installImprovedDrawDistance, nullptr});
