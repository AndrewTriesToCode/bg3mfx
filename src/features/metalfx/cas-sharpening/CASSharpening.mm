#include "common/native/SupportedBuild.h"
#import "features/metalfx/cas-sharpening/CASSharpening.h"
#import "features/metalfx/MetalFX.h"
#include "common/native/CodePatch.h"
#include <atomic>

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
    installed = true;
    return YES;
}
