#include "common/Feature.h"
#import "features/metal-hooks/MetalHooks.h"

// The render-thread-optimizations feature: redundant bind filtering. The
// rules are metal-hooks' own (its BindFilter.h), inline in its bind hooks once
// this turns them on; a call per bind would cost more than the filter saves.

namespace {
BOOL installRenderThreadOptimizations(const BG3MFXFeatureContext &, NSError **) {
    BG3MFXMetalHooksFilterRedundantBinds();
    return YES;
}
const char *const renderThreadOptimizationsRequires[] = {"metal-hooks", nullptr};
}
BG3MFX_FEATURE(renderThreadOptimizations, {"render-thread-optimizations", renderThreadOptimizationsRequires, false, nullptr,
                                           installRenderThreadOptimizations, nullptr});
