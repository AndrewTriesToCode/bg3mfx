#import "features/custom-menu/RefreshRepair.h"
#include "common/native/SupportedBuild.h"
#import "common/ScreenTiming.h"
#import "features/metal-hooks/MetalHooks.h"
#include <cmath>
#include <cstring>

namespace {
uintptr_t settingsGlobal;

template<class T> T read(const void *p, size_t offset) {
    T value; memcpy(&value, static_cast<const char *>(p) + offset, sizeof value); return value;
}
// BG3's own duration, 1/(settings refresh + 1), becomes 1/(screen rate + 1).
// Other durations, and BG3's while the screen is unknown, pass through.
double repairDuration(double duration) {
    namespace Temporal = BG3MFXBuild::Temporal::Layout;
    const void *settings = *reinterpret_cast<void *const *>(settingsGlobal);
    double minimum = BG3MFXScreenTimingCurrent().minimumInterval;
    if (!settings || minimum <= 0) return duration;
    int32_t numerator = read<int32_t>(settings, Temporal::SettingsRefreshNumerator);
    int32_t denominator = read<int32_t>(settings, Temporal::SettingsRefreshDenominator);
    if (numerator <= 0 || denominator <= 0) return duration;
    double settingsRate = double(numerator) / denominator;
    if (std::fabs(duration - 1.0 / (settingsRate + 1)) > 1e-5) return duration;
    return 1.0 / (1.0 / minimum + 1);
}
}

bool BG3MFXInstallRefreshRepair(intptr_t slide) {
    settingsGlobal = BG3MFXBuild::Temporal::Settings + slide;
    if (!BG3MFXMetalHooksFilterPresentDuration(repairDuration)) return false;
    BG3MFXScreenTimingStart();
    return true;
}
