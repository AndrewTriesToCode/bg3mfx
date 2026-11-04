#include "common/Feature.h"
#import "features/metalfx/MetalFX.h"

// The metalfx feature: MetalFX Spatial and Temporal upscaling, Temporal's
// jitter and Dynamic resolution, Frame Generation and the FSR_Tonemap skip,
// with their Video options. Its renderer work is the metalfx-renderer feature
// (MetalFXRenderer.mm), metal-hooks' renderer extension; Temporal's jitter is
// temporal-upscaling, and Dynamic resolution, wanted with it,
// dynamic-resolution.

namespace {
BOOL installMetalFX(const BG3MFXFeatureContext &context, NSError **) {
    BG3MFXInstallMetalFXOptions(context.slide);
    return YES;
}
BOOL activateMetalFX(const BG3MFXFeatureContext &, NSError **) {
    BG3MFXRestoreMetalFXChoices();
    return YES;
}
const char *const metalFXRequires[] = {"custom-menu", "metal-hooks", "metalfx-renderer", "temporal-upscaling", nullptr};
}
BG3MFX_FEATURE(metalFX, {"metalfx", metalFXRequires, true, nullptr, installMetalFX, activateMetalFX});
