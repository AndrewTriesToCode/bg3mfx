#include "common/native/SupportedBuild.h"
#include "features/improved-draw-distance/ImprovedDrawDistance.h"
#include <cstdio>
#include <cstring>

// Checks improved-draw-distance's patch words against the instruction and constant they
// replace: encoding BG3's own 50 m must reproduce both originals, and the
// patched distance must be loadable by the same instruction. Synthetic, CPU only.
namespace Native = BG3MFXBuild::ImprovedDrawDistance;

int main() {
    int failures = 0;
    const float native = 50.0f;
    uint32_t nativeBits;
    memcpy(&nativeBits, &native, sizeof nativeBits);
    if (BG3MFXImprovedDrawDistanceMove(native) != Native::ResetDistanceMoveOriginal ||
        Native::ResetConstantOriginal[Native::ResetConstantDistanceWord] != nativeBits) {
        std::printf("Draw distance patch words don't match BG3's 50 m.\n");
        ++failures;
    }
    const uint32_t move = BG3MFXImprovedDrawDistanceMove(BG3MFXImprovedDrawDistance);
    uint32_t loaded = (move >> 5 & 0xffff) << 16;
    float distance;
    memcpy(&distance, &loaded, sizeof distance);
    if (!move || (move & ~(0xffffu << 5)) != (Native::ResetDistanceMoveOriginal & ~(0xffffu << 5)) ||
        distance != BG3MFXImprovedDrawDistance) {
        std::printf("The draw distance is not loaded by BG3's instruction.\n");
        ++failures;
    }
    if (BG3MFXImprovedDrawDistanceMove(100.1f)) {
        std::printf("A distance one instruction cannot load was accepted.\n");
        ++failures;
    }
    if (!failures) std::printf("Improved draw distance: patch words and %.0f m encoding passed.\n", BG3MFXImprovedDrawDistance);
    return failures ? 1 : 0;
}
