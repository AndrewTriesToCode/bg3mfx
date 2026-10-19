#include "common/native/SupportedBuild.h"
#import "features/shadows/ShadowDuplicateFix.h"
#include "common/native/CodePatch.h"
#include <mach/mach.h>
#include <cstring>

namespace Native = BG3MFXBuild::Shadows;

// BaseApp::InitFrameStages(rf::RenderView*) adds the stage-type list [2]
// (CascadedShadowBufferStage) twice for the game view: at 0x105d1a7d4-0x105d1a7ec
// and again at 0x105d1a818-0x105d1a830, around the [70, 54, ...] list. Both
// stages render identical cascades into the same shadow texture, and nothing
// reads the first stage's result before the second clears and redraws it
// (docs/dev/performance.md). Skipping the first add keeps the stage that renders where
// its consumers currently read from.
BOOL BG3MFXInstallShadowDuplicateFix(intptr_t slide, void (*report)(NSDictionary *), NSError **error) {
    auto fail=[&](NSString *message) {
        if(error) *error=[NSError errorWithDomain:@"BG3MFXShadowDuplicateFix" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // NativeMenu has already checked the executable UUID; also check both
    // stage-add sequences and the stage-type byte before changing anything.
    static const uint32_t firstAdd[]={0xb000dc35,0x913f0eb5,0x910006b6,0xa9005bf5,0xf9400288,0xf9416508,
        0x910003e2,0xaa1403e0,0xaa1303e1,0xd63f0100};
    static const uint32_t secondAdd[]={0xa9005bf5,0xf9400288,0xf9416508,0x910003e2,0xaa1403e0,0xaa1303e1,0xd63f0100};
    const auto *first=reinterpret_cast<const uint32_t *>(Native::FirstStageAdd+slide);
    const auto *second=reinterpret_cast<const uint32_t *>(Native::SecondStageAdd+slide);
    if (memcmp(first,firstAdd,sizeof firstAdd)!=0 || memcmp(second,secondAdd,sizeof secondAdd)!=0 ||
        *reinterpret_cast<const uint8_t *>(Native::StageType+slide)!=2)
        return fail(@"Unsupported native frame-stage setup.");
    uintptr_t call=reinterpret_cast<uintptr_t>(first+9);
    auto result=BG3MFXPatchCode({{call,4}},[&] {
        const uint32_t nop=0xd503201f;
        memcpy(reinterpret_cast<void *>(call),&nop,4);
    });
    if (result==BG3MFXCodePatchResult::NotWritable) return fail(@"Could not make the frame-stage setup writable.");
    // Written but not executable again: report it as installed, not skipped.
    if(report) report(@{@"event":@"shadowDuplicateFixInstalled",@"protectionRestored":@(result==BG3MFXCodePatchResult::Patched)});
    return YES;
}
