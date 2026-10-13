#import "FrameLog.h"
#include <os/log.h>
#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

namespace {
std::atomic<unsigned> rendered{0}, shown[2], dropped[2], missing[2], methods[4];
std::mutex timesLock;
std::vector<double> times;  // presented times of shown images since the last report
dispatch_source_t reportTimer;  // keeps the 2 s report timer alive
double lastReport;              // start of the current report window

void report() {
    double now = CACurrentMediaTime(), span = now - lastReport; lastReport = now;
    if (span <= 0) return;
    std::vector<double> taken;
    { std::lock_guard<std::mutex> lock(timesLock); taken.swap(times); }
    std::sort(taken.begin(), taken.end());
    std::vector<double> gaps;
    for (size_t i = 1; i < taken.size(); ++i) gaps.push_back((taken[i] - taken[i-1]) * 1000);
    std::sort(gaps.begin(), gaps.end());
    double average = 0; for (double gap : gaps) average += gap;
    if (!gaps.empty()) average /= gaps.size();
    double p90 = gaps.empty() ? 0 : gaps[gaps.size() * 9 / 10];
    unsigned real = shown[0].exchange(0), generated = shown[1].exchange(0);
    unsigned lost = dropped[0].exchange(0) + dropped[1].exchange(0) + missing[0].exchange(0) + missing[1].exchange(0);
    unsigned counts[4]; for (int i = 0; i < 4; ++i) counts[i] = methods[i].exchange(0);
    static const char *names[] = {"native", "synced", "minimum", "spaced"};
    int method = int(std::max_element(counts, counts + 4) - counts);
    unsigned presented = real + generated + lost;
    os_log(os_log_create("com.bg3mfx", "frames"),
        "bg3mfx frames: rendered %.1f/s, shown real %.1f/s, generated %.1f/s, dropped %.0f%%, method %{public}s, gap %.1f ms (p90 %.1f ms)",
        rendered.exchange(0) / span, real / span, generated / span, presented ? 100.0 * lost / presented : 0.0,
        counts[method] ? names[method] : "none", average, p90);
}
}

BOOL BG3MFXFrameLogEnabled(void) {
    static BOOL enabled = [] {
        const char *value = getenv("BG3MFX_FRAME_LOG");
        if (!value || strcmp(value, "1")) return NO;
        lastReport = CACurrentMediaTime();
        reportTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(reportTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(reportTimer, ^{ report(); });
        dispatch_resume(reportTimer);
        return YES;
    }();
    return enabled;
}
void BG3MFXFrameLogRendered(void) { if (BG3MFXFrameLogEnabled()) ++rendered; }
void BG3MFXFrameLogShown(BOOL generated, CFTimeInterval time) {
    if (!BG3MFXFrameLogEnabled()) return;
    int kind = generated ? 1 : 0;
    if (time < 0) { ++missing[kind]; return; }
    if (time == 0) { ++dropped[kind]; return; }
    ++shown[kind];
    std::lock_guard<std::mutex> lock(timesLock); times.push_back(time);
}
void BG3MFXFrameLogMethod(BG3MFXPresentMethod method) {
    if (BG3MFXFrameLogEnabled() && method >= 0 && method < 4) ++methods[method];
}
