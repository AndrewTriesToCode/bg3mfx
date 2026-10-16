#pragma once

#include <cmath>
#include <cstdint>
#include <limits>

// Call only from a native vista pass so menus and unrelated rendering do not
// start the wall-clock comparison interval.
class BG3MFXVistaComparison {
public:
    struct Selection {
        bool half;
        bool changed;
        double elapsed;
        uint64_t period;
    };

    Selection select(uint64_t presentationFrame, double monotonicSeconds) {
        if (!started_) {
            started_ = true;
            epochSeconds_ = monotonicSeconds;
            lastFrame_ = presentationFrame;
            lastSelection_ = {false, true, 0.0, 0};
            return lastSelection_;
        }

        const double elapsed = elapsedSinceEpoch(monotonicSeconds);
        // Keep all vista passes and views for one presentation frame together.
        if (presentationFrame == lastFrame_) {
            return {lastSelection_.half, false, elapsed, lastSelection_.period};
        }

        const uint64_t period = periodForElapsed(elapsed);
        const bool changed = period != lastSelection_.period;
        lastFrame_ = presentationFrame;
        lastSelection_ = {(period & 1u) != 0, changed, elapsed, period};
        return lastSelection_;
    }

private:
    double elapsedSinceEpoch(double monotonicSeconds) const {
        const double elapsed = monotonicSeconds - epochSeconds_;
        return elapsed > 0.0 ? elapsed : 0.0;
    }

    static uint64_t periodForElapsed(double elapsed) {
        const long double value = std::floor(static_cast<long double>(elapsed) / 10.0L);
        const long double maximum = static_cast<long double>(std::numeric_limits<uint64_t>::max());
        if (!(value > 0.0L)) return 0;
        if (value >= maximum) return std::numeric_limits<uint64_t>::max();
        return static_cast<uint64_t>(value);
    }

    bool started_ = false;
    double epochSeconds_ = 0.0;
    uint64_t lastFrame_ = 0;
    Selection lastSelection_{false, false, 0.0, 0};
};
