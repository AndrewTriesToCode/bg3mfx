#import "features/metalfx-frame-generation/FrameLog.h"
#include <os/log.h>
#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

namespace {
std::atomic<unsigned> rendered{0}, shown[2], dropped[2], missing[2], methods[4];
std::atomic<unsigned> bg3Buffers{0}, standInLimit{0};  // latest values
std::mutex timesLock;
std::vector<double> times;  // presented times of shown images since the last report
std::vector<double> latencies;  // commit-to-display latencies of real frames
std::vector<unsigned> queues;   // frames in flight at each of those commits
dispatch_source_t reportTimer;  // keeps the 2 s report timer alive
double lastReport;              // start of the current report window

void report() {
    double now = CACurrentMediaTime(), span = now - lastReport; lastReport = now;
    if (span <= 0) return;
    std::vector<double> taken, latency; std::vector<unsigned> queued;
    { std::lock_guard<std::mutex> lock(timesLock); taken.swap(times); latency.swap(latencies); queued.swap(queues); }
    std::sort(latency.begin(), latency.end());
    double latencyAverage = 0; for (double value : latency) latencyAverage += value;
    if (!latency.empty()) latencyAverage = latencyAverage * 1000 / latency.size();
    double latencyP90 = latency.empty() ? 0 : latency[latency.size() * 9 / 10] * 1000;
    double queueAverage = 0; for (unsigned value : queued) queueAverage += value;
    if (!queued.empty()) queueAverage /= queued.size();
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
        "bg3mfx frames: rendered %.1f/s, shown real %.1f/s, generated %.1f/s, dropped %.0f%%, method %{public}s, gap %.1f ms (p90 %.1f ms), latency %.1f ms (p90 %.1f ms), in flight %.1f, BG3 buffers %u, stand-ins %u",
        rendered.exchange(0) / span, real / span, generated / span, presented ? 100.0 * lost / presented : 0.0,
        counts[method] ? names[method] : "none", average, p90, latencyAverage, latencyP90, queueAverage, bg3Buffers.load(), standInLimit.load());
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
void BG3MFXFrameLogBuffering(unsigned bg3, unsigned standIns) {
    if (!BG3MFXFrameLogEnabled()) return;
    bg3Buffers = bg3; standInLimit = standIns;
}
void BG3MFXFrameLogLatency(CFTimeInterval seconds, unsigned queued) {
    if (!BG3MFXFrameLogEnabled() || seconds <= 0) return;
    std::lock_guard<std::mutex> lock(timesLock); latencies.push_back(seconds); queues.push_back(queued);
}
void BG3MFXFrameLogMethod(BG3MFXPresentMethod method) {
    if (BG3MFXFrameLogEnabled() && method >= 0 && method < 4) ++methods[method];
}
