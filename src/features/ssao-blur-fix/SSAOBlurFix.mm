#include "common/native/SupportedBuild.h"
#include "common/Feature.h"
#import "features/ssao-blur-fix/SSAOBlurFix.h"
#include "common/native/CodePatch.h"
#include <libkern/OSCacheControl.h>
#include <cstring>

// BG3's SSAO blurs its AO in two 5-tap passes, horizontal then vertical,
// through one DynamicCB. On unified memory, each bind is recorded as a
// reference to the DynamicCB, and replay binds whichever ring slot its
// counter names then: the vertical direction, for both passes. The patched
// bind records the slot it just wrote, as BG3 already does without unified
// memory (op 0x07 with a buffer), so each pass replays with its own direction.
namespace Native = BG3MFXBuild::SSAOBlur;

namespace {
constexpr size_t bindWords = sizeof Native::BindOriginal / 4;
const size_t islandOffset = BG3MFXBuild::Islands::SSAOBlur.offset, islandBytes = BG3MFXBuild::Islands::SSAOBlur.bytes;
static_assert(sizeof Native::BindIsland <= BG3MFXBuild::Islands::SSAOBlur.bytes, "the SSAO blur island fits its reservation");
}

BOOL BG3MFXInstallSSAOBlurFix(intptr_t slide, void (*report)(NSDictionary *), NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXSSAOBlurFix" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // Root has already checked the executable UUID; also check the whole branch.
    const uintptr_t bind = Native::Bind + slide;
    if (memcmp(reinterpret_cast<const void *>(bind), Native::BindOriginal, sizeof Native::BindOriginal))
        return fail(@"Unsupported SSAO blur constant binding.");
    const uintptr_t island = BG3MFXBuild::HeaderPadding + slide + islandOffset, call = bind + Native::BufferWord * 4;
    for (size_t i = 0; i < islandBytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(island + i)) return fail(@"SSAO blur island space is in use.");
    if (!BG3MFXBranchReaches(call, island)) return fail(@"The SSAO blur island is out of range.");
    auto result = BG3MFXPatchCode({{island, islandBytes}, {bind, sizeof Native::BindOriginal}}, [&] {
        memcpy(reinterpret_cast<void *>(island), Native::BindIsland, sizeof Native::BindIsland);
        sys_icache_invalidate(reinterpret_cast<void *>(island), islandBytes);
        uint32_t words[bindWords];
        memcpy(words, Native::BindOriginal, sizeof words);
        words[Native::OpWord] = Native::OpPatched;
        words[Native::BufferWord] = 0x94000000 | (BG3MFXBranch(call, island) & 0x03ffffff);
        memcpy(reinterpret_cast<void *>(bind), words, sizeof words);
    });
    if (result == BG3MFXCodePatchResult::NotWritable) return fail(@"Could not make the SSAO blur binding writable.");
    // Written but not executable again: report it as installed, not skipped.
    if (report) report(@{@"event": @"ssaoBlurFixInstalled", @"protectionRestored": @(result == BG3MFXCodePatchResult::Patched)});
    return YES;
}

namespace {
BOOL installSSAOBlurFix(const BG3MFXFeatureContext &context, NSError **error) {
    return BG3MFXInstallSSAOBlurFix(context.slide, context.report, error);
}
}
BG3MFX_FEATURE(ssaoBlurFixFeature, {"ssao-blur-fix", nullptr, true, nullptr, installSSAOBlurFix, nullptr});
