#include "common/native/SupportedBuild.h"
#import "features/metalfx/cas-sharpening/CASSharpening.h"
#import "features/metalfx/MetalFX.h"
#include "common/native/CodePatch.h"
#include <atomic>
#include <cstring>

namespace Native = BG3MFXBuild::CASRendering;

namespace {
std::atomic<bool> installed{false};
intptr_t gameSlide;

// Replaces ls::PostProcessStep_CAS::UpdateIsRenderingInternal, entered after its
// first instruction, so it returns straight to the caller.
void updateIsRendering(void *step) {
    const uint8_t *settings = *reinterpret_cast<uint8_t *const *>(BG3MFXBuild::Temporal::Settings + gameSlide);
    bool on = settings && BG3MFXCASRenders(settings[Native::SettingsCASEnabled] != 0,
                                           static_cast<int8_t>(settings[Native::SettingsUpscalingType]),
                                           BG3MFXSelectedScalingMode());
    *reinterpret_cast<uint8_t *>(reinterpret_cast<uintptr_t>(step) + Native::StepIsRendering) = on;
}
}

BOOL BG3MFXCASSharpeningInstalled(void) { return installed.load(); }

BOOL BG3MFXInstallCASSharpening(intptr_t slide, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXCASSharpening" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    gameSlide = slide;
    const uintptr_t island = BG3MFXBuild::HeaderPadding + slide + BG3MFXBuild::Islands::CASRendering.offset;
    if (const char *failure = BG3MFXHookEntry(Native::UpdateIsRendering + slide, Native::UpdateIsRenderingFirst, island,
                                              reinterpret_cast<void *>(updateIsRendering)))
        return fail([NSString stringWithFormat:@"Could not hook BG3's CAS stage: %s.", failure]);
    // BG3's Apply drops a ticked CAS box under the FSR type MetalFX runs on, so
    // the choice would not stick.
    const uintptr_t typeCheck = Native::ApplyTickBoxTypeCheck + slide;
    if (*reinterpret_cast<const uint32_t *>(typeCheck) != Native::ApplyTickBoxTypeCheckOriginal)
        return fail(@"Unsupported CAS tick box apply code.");
    auto result = BG3MFXPatchCode({{typeCheck, 4}}, [&] {
        const uint32_t type = Native::ApplyTickBoxTypeCheckPatched;
        memcpy(reinterpret_cast<void *>(typeCheck), &type, 4);
    });
    if (result != BG3MFXCodePatchResult::Patched) return fail(@"Could not patch BG3's CAS tick box apply.");
    installed = true;
    return YES;
}
