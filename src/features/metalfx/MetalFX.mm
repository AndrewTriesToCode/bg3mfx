#include "common/Feature.h"
#import "common/Notice.h"
#import "features/metalfx/MetalFX.h"
#import "features/metalfx/dynamic-resolution/DynamicResolution.h"

// The metalfx feature: MetalFX Spatial and Temporal upscaling, Temporal's
// jitter and Dynamic resolution, Frame Generation and the FSR_Tonemap skip,
// with their Video options. Its install puts in each part: Temporal's native
// jitter (temporal-upscaling/), Dynamic resolution (dynamic-resolution/), the
// renderer as metal-hooks' renderer extension (renderer/) and the options.
//
// The test runtime (BG3MFX_STANDALONE_TEST_HOOKS) runs outside BG3, where the
// native parts and the menu cannot install: there metalfx is not native,
// requires only metal-hooks and installs only the renderer.

namespace {
#ifndef BG3MFX_STANDALONE_TEST_HOOKS
BOOL installMetalFX(const BG3MFXFeatureContext &context, NSError **error) {
    if (!BG3MFXInstallTemporalJitter(context.slide, error)) {
        // Without the menu options nothing selects MetalFX, so BG3 renders as usual.
        NSString *reason = (error && *error ? (*error).localizedDescription : nil) ?: @"Temporal's jitter could not be installed.";
        BG3MFXFail([@"MetalFX could not start: " stringByAppendingString:reason], @"MetalFX could not start",
            [reason stringByAppendingString:@"\n\nThe game continues without MetalFX."]);
        return NO;
    }
    // Dynamic is optional: without it MetalFX starts and does not offer it.
    NSError *dynamicError = nil;
    if (!BG3MFXInstallDynamicResolution(context.slide, &dynamicError))
        BG3MFXFail([@"Dynamic resolution is unavailable: " stringByAppendingString:
            dynamicError.localizedDescription ?: @"its installation failed."], nil, nil);
    if (!BG3MFXInstallMetalFXRenderer(error)) return NO;
    BG3MFXInstallMetalFXOptions(context.slide);
    return YES;
}
BOOL activateMetalFX(const BG3MFXFeatureContext &, NSError **) {
    BG3MFXActivateMetalFXRenderer();
    BG3MFXRestoreMetalFXChoices();
    return YES;
}
const char *const metalFXRequires[] = {"custom-menu", "metal-hooks", nullptr};
constexpr bool metalFXNative = true;
#else
BOOL installMetalFX(const BG3MFXFeatureContext &, NSError **error) { return BG3MFXInstallMetalFXRenderer(error); }
BOOL activateMetalFX(const BG3MFXFeatureContext &, NSError **) {
    BG3MFXActivateMetalFXRenderer();
    return YES;
}
const char *const metalFXRequires[] = {"metal-hooks", nullptr};
constexpr bool metalFXNative = false;
#endif
}
BG3MFX_FEATURE(metalFX, {"metalfx", metalFXRequires, metalFXNative, nullptr, installMetalFX, activateMetalFX});
