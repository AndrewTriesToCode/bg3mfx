#include "features/shadows/VistaComparison.h"

#include <cmath>
#include <cstdio>

namespace {
bool expect(const char *label, const BG3MFXVistaComparison::Selection &actual,
            bool half, bool changed, double elapsed, uint64_t period) {
    if (actual.half == half && actual.changed == changed &&
        std::fabs(actual.elapsed - elapsed) < 1e-9 && actual.period == period) {
        return true;
    }
    std::fprintf(stderr,
                 "%s: got half=%d changed=%d elapsed=%.6f period=%llu; "
                 "expected half=%d changed=%d elapsed=%.6f period=%llu\n",
                 label, actual.half, actual.changed, actual.elapsed,
                 static_cast<unsigned long long>(actual.period), half, changed,
                 elapsed, static_cast<unsigned long long>(period));
    return false;
}
}

int main() {
    bool ok = true;

    BG3MFXVistaComparison comparison;
    ok &= expect("first frame zero", comparison.select(0, 100.0), false, true, 0.0, 0);
    ok &= expect("first period", comparison.select(1, 109.999), false, false, 9.999, 0);
    ok &= expect("boundary enters half", comparison.select(2, 110.0), true, true, 10.0, 1);
    ok &= expect("half period", comparison.select(3, 119.999), true, false, 19.999, 1);
    ok &= expect("boundary returns full", comparison.select(4, 120.0), false, true, 20.0, 2);

    BG3MFXVistaComparison repeatedFrame;
    ok &= expect("repeat initial frame", repeatedFrame.select(7, 5.0), false, true, 0.0, 0);
    ok &= expect("frame before boundary", repeatedFrame.select(8, 14.0), false, false, 9.0, 0);
    ok &= expect("same frame across boundary", repeatedFrame.select(8, 15.0), false, false, 10.0, 0);
    ok &= expect("next frame observes boundary", repeatedFrame.select(9, 15.0), true, true, 10.0, 1);

    BG3MFXVistaComparison skippedPeriods;
    ok &= expect("skip epoch", skippedPeriods.select(0, 20.0), false, true, 0.0, 0);
    ok &= expect("long gap derives period", skippedPeriods.select(1, 65.0), false, true, 45.0, 4);
    ok &= expect("long gap period remains", skippedPeriods.select(2, 65.0), false, false, 45.0, 4);
    ok &= expect("alternate after long gap", skippedPeriods.select(3, 70.0), true, true, 50.0, 5);

    BG3MFXVistaComparison backwardClock;
    ok &= expect("backward-clock epoch", backwardClock.select(30, 50.0), false, true, 0.0, 0);
    ok &= expect("negative elapsed clamps", backwardClock.select(31, 49.0), false, false, 0.0, 0);
    ok &= expect("clock catches up", backwardClock.select(32, 60.0), true, true, 10.0, 1);

    if (!ok) return 1;
    std::puts("Vista comparison timer: boundaries, frame latching, skipped periods and clock clamp passed");
    return 0;
}
