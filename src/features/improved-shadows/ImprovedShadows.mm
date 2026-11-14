#import "features/improved-shadows/DuplicateShadowFix.h"
#import "features/improved-shadows/PointLightShadowFix.h"
#import "features/improved-shadows/ShadowMask.h"
#include "common/Feature.h"

// Improved shadows: BG3's sun shadow maps rendered once per frame
// (DuplicateShadowFix), its sun shadow mask drawn with the G-buffer normal
// (ShadowMask), and each point light's tetrahedron faces kept to their own
// triangles (PointLightShadowFix). See README.md.
namespace {
BOOL install(const BG3MFXFeatureContext &context, NSError **error) {
    return BG3MFXInstallDuplicateShadowFix(error) && BG3MFXInstallShadowMask(context, error) &&
        BG3MFXInstallPointLightShadowFix(error);
}
const char *const requires[] = {"custom-render-stages", "custom-pipeline-bundles", "metal-hooks", nullptr};
}
// Native: the shadow mask calls BG3's functions at the supported build's addresses.
BG3MFX_FEATURE(improvedShadows, {"improved-shadows", requires, true, install, nullptr});
