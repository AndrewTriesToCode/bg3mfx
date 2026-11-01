#import "features/duplicate-shadow-fix/DuplicateShadowFix.h"
#import "features/custom-render-stages/CustomRenderStages.h"
#include "common/Feature.h"
#include <cstdint>
#include <vector>

namespace {
template<size_t... N> std::vector<uint8_t> join(const uint8_t (&...packs)[N]) {
    std::vector<uint8_t> codes;
    (codes.insert(codes.end(), packs, packs + N), ...);
    return codes;
}
}

BOOL BG3MFXInstallDuplicateShadowFix(void (*report)(NSDictionary *), NSError **error) {
    namespace P = BG3MFXStagePack;
    // BG3 passes the Shadow pack twice, so each view has two
    // CascadedShadowBuffer stages rendering the same cascades into the same
    // maps; nothing reads the first one's maps before the second redraws them
    // (docs/dev/baseline/frame-capture.md, finding 1). Keep the first: the
    // stages that capture the shadow buffer (Alpha, Lighting, CascadedShadowMask,
    // VertexProcessing) look up the first match. The Fullscreen view has none.
    const std::vector<uint8_t> window = join(P::First, P::Shadow, P::Second, P::Third);
    const std::vector<uint8_t> offscreen = join(P::First, P::EarlyVtResolve, P::Shadow, P::Second, P::Third, P::Additional);
    static const char *const feature = "duplicate-shadow-fix";
    if (!BG3MFXSetViewStages(BG3MFXViewKind::Game, feature, window.data(), window.size(), error) ||
        !BG3MFXSetViewStages(BG3MFXViewKind::Player, feature, window.data(), window.size(), error) ||
        !BG3MFXSetViewStages(BG3MFXViewKind::Offscreen, feature, offscreen.data(), offscreen.size(), error))
        return NO;
    if (report) report(@{@"event":@"duplicateShadowFixRegistered"});
    return YES;
}

namespace {
const char *const duplicateShadowFixRequires[] = {"custom-render-stages", nullptr};
BOOL installDuplicateShadowFix(const BG3MFXFeatureContext &context, NSError **error) {
    return BG3MFXInstallDuplicateShadowFix(context.report, error);
}
}
BG3MFX_FEATURE(duplicateShadowFix, {"duplicate-shadow-fix", duplicateShadowFixRequires, false, nullptr,
    installDuplicateShadowFix, nullptr});
