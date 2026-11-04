#import "features/metalfx/frame-generation/FrameLog.h"
#import "common/EventLog.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

namespace {
std::atomic<unsigned> rendered{0}, shown[2], dropped[2], missing[2], methods[4];
std::atomic<unsigned> bg3Buffers{0}, standInLimit{0};  // latest values
std::atomic<int> appActive{-1}, screenMaximumFPS{0};
std::mutex timesLock;
std::vector<double> times;  // presented times of shown images since the last report
std::vector<double> realTimes, generatedTimes;
std::vector<double> latencies;  // commit-to-display latencies of real frames
std::vector<unsigned> queues;   // frames in flight at each of those commits
std::vector<double> gpuTimes, gpuQueueTimes, gpuCompletionTailTimes, drawableWaitTimes;
struct PacingSample { double refresh, interval, generatedMinimum, realMinimum; unsigned refreshes; };
std::vector<PacingSample> pacing;
std::atomic<unsigned> syncedSamples{0}, pacingSamples{0};
std::atomic<unsigned> standInOverflows{0};
struct BackpressureSample { double wait, cadence; };
std::vector<BackpressureSample> backpressure;
dispatch_source_t reportTimer;  // keeps the 2 s report timer alive
double lastReport;              // start of the current report window

void report() {
    double now = CACurrentMediaTime(), span = now - lastReport; lastReport = now;
    if (span <= 0) return;
    std::vector<double> taken, realTaken, generatedTaken, latency; std::vector<unsigned> queued;
    std::vector<PacingSample> schedules;
    std::vector<BackpressureSample> waits;
    std::vector<double> gpu, gpuQueue, gpuTail, drawableWait;
    { std::lock_guard<std::mutex> lock(timesLock); taken.swap(times); realTaken.swap(realTimes);
      generatedTaken.swap(generatedTimes); latency.swap(latencies); queued.swap(queues);
      schedules.swap(pacing); waits.swap(backpressure); gpu.swap(gpuTimes);
      gpuQueue.swap(gpuQueueTimes); gpuTail.swap(gpuCompletionTailTimes);
      drawableWait.swap(drawableWaitTimes); }
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
    auto meanGapMs=[](std::vector<double> &values) {
        std::sort(values.begin(),values.end()); double sum=0;
        for (size_t i=1;i<values.size();++i) sum+=(values[i]-values[i-1])*1000;
        return values.size()>1 ? sum/(values.size()-1) : 0.0;
    };
    double realGap=meanGapMs(realTaken), generatedGap=meanGapMs(generatedTaken);
    double standInWait=0, work=0;
    for (const auto &s:waits) { standInWait+=s.wait; work+=fmax(s.cadence-s.wait,0); }
    if (!waits.empty()) { standInWait/=waits.size(); work/=waits.size(); }
    double refresh=0, interval=0, generatedMinimum=0, realMinimum=0, refreshes=0;
    for (const auto &s:schedules) { refresh+=s.refresh; interval+=s.interval;
        generatedMinimum+=s.generatedMinimum; realMinimum+=s.realMinimum; refreshes+=s.refreshes; }
    if (!schedules.empty()) { double n=schedules.size(); refresh/=n; interval/=n;
        generatedMinimum/=n; realMinimum/=n; refreshes/=n; }
    unsigned real = shown[0].exchange(0), generated = shown[1].exchange(0);
    unsigned lost = dropped[0].exchange(0) + dropped[1].exchange(0) + missing[0].exchange(0) + missing[1].exchange(0);
    unsigned counts[4]; for (int i = 0; i < 4; ++i) counts[i] = methods[i].exchange(0);
    static const char *names[] = {"native", "synced", "minimum", "spaced"};
    int method = int(std::max_element(counts, counts + 4) - counts);
    unsigned presented = real + generated + lost;
    auto timing=[](std::vector<double> &values) {
        std::sort(values.begin(),values.end());
        if (values.empty()) return std::array<double,3>{0,0,0};
        double mean=0; for(double value:values) mean+=value;
        mean/=values.size();
        return std::array<double,3>{mean,values[values.size()*9/10],values.back()};
    };
    auto gpuStat=timing(gpu), queueStat=timing(gpuQueue), tailStat=timing(gpuTail), waitStat=timing(drawableWait);
    auto stats=[](const std::array<double,3> &s) { return @{@"meanMs":@(s[0]),@"p90Ms":@(s[1]),@"maxMs":@(s[2])}; };
    BG3MFX_EVENT(@{@"event":@"frameStats",@"seconds":@(span),
        @"renderedPerSecond":@(rendered.exchange(0)/span),@"realPerSecond":@(real/span),@"generatedPerSecond":@(generated/span),
        @"droppedPercent":@(presented ? 100.0*lost/presented : 0.0),@"method":@(counts[method] ? names[method] : "none"),
        @"gapMs":@(average),@"gapP90Ms":@(p90),@"realCadenceMs":@(realGap),@"generatedCadenceMs":@(generatedGap),
        @"syncedSamples":@(syncedSamples.exchange(0)),@"pacingSamples":@(pacingSamples.exchange(0)),
        @"refreshHz":@(refresh>0 ? 1.0/refresh : 0),@"intervalMs":@(interval*1000),@"refreshes":@(llround(refreshes)),
        @"generatedMinimumMs":@(generatedMinimum*1000),@"realMinimumMs":@(realMinimum*1000),
        @"appActive":@(appActive.load()),@"screenMaximumHz":@(screenMaximumFPS.load()),
        @"standInWaitMs":@(standInWait*1000),@"standInWorkMs":@(work*1000),@"standInOverflows":@(standInOverflows.exchange(0)),
        @"latencyMs":@(latencyAverage),@"latencyP90Ms":@(latencyP90),@"inFlight":@(queueAverage),
        @"bg3Buffers":@(bg3Buffers.load()),@"standIns":@(standInLimit.load()),
        @"nativeGPUCount":@(gpu.size()),@"nativeGPU":stats(gpuStat),@"gpuQueue":stats(queueStat),
        @"completionTail":stats(tailStat),@"drawableWait":stats(waitStat)});
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
    (generated ? generatedTimes : realTimes).push_back(time);
}
void BG3MFXFrameLogPacing(BOOL synced, double refresh, double interval, unsigned refreshes,
                          double generatedMinimum, double realMinimum) {
    if (!BG3MFXFrameLogEnabled()) return;
    if (synced) ++syncedSamples;
    ++pacingSamples;
    std::lock_guard<std::mutex> lock(timesLock);
    pacing.push_back({refresh,interval,generatedMinimum,realMinimum,refreshes});
}
void BG3MFXFrameLogDisplayState(BOOL active, NSInteger maximumFPS) {
    if (!BG3MFXFrameLogEnabled()) return;
    appActive=active ? 1 : 0; screenMaximumFPS=(int)maximumFPS;
}
void BG3MFXFrameLogBackpressure(double standInWait, double cadence) {
    if (!BG3MFXFrameLogEnabled()) return;
    std::lock_guard<std::mutex> lock(timesLock);
    backpressure.push_back({standInWait,cadence});
}
void BG3MFXFrameLogStandInOverflow(void) {
    if (BG3MFXFrameLogEnabled()) ++standInOverflows;
}
void BG3MFXFrameLogBuffering(unsigned bg3, unsigned standIns) {
    if (!BG3MFXFrameLogEnabled()) return;
    bg3Buffers = bg3; standInLimit = standIns;
}
void BG3MFXFrameLogLatency(CFTimeInterval seconds, unsigned queued) {
    if (!BG3MFXFrameLogEnabled() || seconds <= 0) return;
    std::lock_guard<std::mutex> lock(timesLock); latencies.push_back(seconds); queues.push_back(queued);
}
void BG3MFXFrameLogGPU(CFTimeInterval start, CFTimeInterval end,
                       CFTimeInterval committed, CFTimeInterval completed) {
    if (!BG3MFXFrameLogEnabled() || start <= 0 || end < start) return;
    std::lock_guard<std::mutex> lock(timesLock);
    gpuTimes.push_back((end-start)*1000);
    if (committed > 0 && start >= committed) gpuQueueTimes.push_back((start-committed)*1000);
    if (completed > end) gpuCompletionTailTimes.push_back((completed-end)*1000);
}
void BG3MFXFrameLogDrawableWait(CFTimeInterval seconds) {
    if (!BG3MFXFrameLogEnabled() || seconds < 0) return;
    std::lock_guard<std::mutex> lock(timesLock); drawableWaitTimes.push_back(seconds*1000);
}
void BG3MFXFrameLogMethod(BG3MFXPresentMethod method) {
    if (BG3MFXFrameLogEnabled() && method >= 0 && method < 4) ++methods[method];
}
