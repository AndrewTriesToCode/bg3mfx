#include "common/native/SupportedBuild.h"
#import "features/dynamic-resolution/DynamicResolution.h"
#import "integration/menu/NativeMenu.h"
#include "common/native/CodePatch.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

extern "C" BOOL BG3MFXTemporalFailed(void);

namespace Native = BG3MFXBuild::ViewportReduction;
namespace Layout = BG3MFXBuild::ViewportReduction::Layout;

namespace {
// BG3 4.1.1.7631656, ls::RenderThread::Update records each render frame with
//   mov x0, x22 ; bl rf::RenderFrame::StartRecording()
// at two sites. The hook runs on the render thread before any view records.
const uintptr_t sites[] = {Native::StartRecordingFirst, Native::StartRecordingSecond};
constexpr unsigned Sites = sizeof sites / sizeof sites[0];
const size_t islandOffset = BG3MFXBuild::Islands::ViewportReduction.offset, islandStride = BG3MFXBuild::Islands::ViewportReduction.bytes / Sites;
const size_t ssrIslandOffset = BG3MFXBuild::Islands::SSRHistory.offset, ssrIslandBytes = BG3MFXBuild::Islands::SSRHistory.bytes;
static_assert(sizeof BG3MFXBuild::ViewportReduction::SSRHistoryRender + 4 == BG3MFXBuild::Islands::SSRHistory.bytes, "SSR island holds the render code and a branch back");
const size_t ssrValidOffset = BG3MFXBuild::Islands::SSRValid.offset;
static_assert(sizeof BG3MFXBuild::ViewportReduction::SSRValidRender + 4 + 8 == BG3MFXBuild::Islands::SSRValid.bytes, "SSR valid island holds its code, a branch back and the flag address");

void (*originalStartRecording)(void *);
void (*calculateViewports)(void *);
void (*recalculateViewports)(void *);
uintptr_t metalFrameVTable, settingsGlobal;
std::atomic<bool> installed{false};
std::atomic<float> appliedArea{1};
std::atomic<bool> measuring{false};
// MetalFX's supported content scale range for BG3's device; 0 until known.
std::atomic<float> minimumScale{0}, maximumScale{0};
// Read by the SSR valid island as a byte: nonzero makes SSR discard its history.
std::atomic<uint8_t> ssrDiscard{0};
static_assert(sizeof ssrDiscard == 1, "the SSR island loads one byte");
// One line per controller window (category `controller`): the diagnostic
// runtime, and a quiet-runtime developer build (BG3MFX_RESOLUTION_LOG) for
// measuring without the diagnostic runtime's CPU cost.
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_RESOLUTION_LOG)
#define BG3MFX_CONTROLLER_LOG 1
os_log_t controllerLog;
#endif
#ifndef BG3MFX_NO_TRACE
void (*reportEvent)(NSDictionary *);
os_log_t resolutionLog;
// BG3MFX_DYNAMIC_RESOLUTION_AREA: a fixed area, or a triangle wave between two.
bool overrideArea;
float minimumArea = 1, maximumArea = 1, periodSeconds = 0;
double ticksToSeconds;
uint64_t startTicks;
float logged = -1;
#endif

// GPU execution intervals of BG3's command buffers and our Metal 4
// submissions. Completions from different queues and handler threads arrive
// out of order, so each window sorts its intervals and takes their union.
std::mutex gpuLock;
std::vector<std::pair<double, double>> gpuIntervals, takenIntervals;
// Render thread only: the end of the time already counted, so an interval
// spanning two windows is not counted twice.
double gpuCounted;
#ifndef BG3MFX_NO_TRACE
// Diagnostics: the window's intervals before merging.
struct GPUStats { unsigned count; double raw, first, last; } takenStats;
#endif
double takeGPUBusy() {
    takenIntervals.clear();
    { std::lock_guard<std::mutex> hold(gpuLock); gpuIntervals.swap(takenIntervals); }
    std::sort(takenIntervals.begin(), takenIntervals.end());
    double busy = 0;
#ifndef BG3MFX_NO_TRACE
    takenStats = {unsigned(takenIntervals.size()), 0, takenIntervals.empty() ? 0 : takenIntervals.front().first, 0};
#endif
    for (const auto &interval : takenIntervals) {
#ifndef BG3MFX_NO_TRACE
        takenStats.raw += interval.second - interval.first;
        takenStats.last = std::max(takenStats.last, interval.second);
#endif
        double from = std::max(interval.first, gpuCounted);
        if (interval.second > from) { busy += interval.second - from; gpuCounted = interval.second; }
    }
    return busy;
}

// Render thread only.
int32_t settledSizes[4];
bool settledEligible;
unsigned settledFrames;
// Frames left to discard SSR history after an area change. Two, in case the
// SSR stage of a changed frame runs after the next frame starts recording.
unsigned ssrDiscardFrames;
// Frames recorded with unchanged sizes and upscaler selection before reducing.
constexpr unsigned SettleFrames = 60;
// The controller's area, kept while Dynamic is not reducing.
float controlledArea = 1;
double windowStart;
unsigned windowFrames;
// Utilization averaged over recent windows (half from the latest), so one
// noisy window does not move the area. Negative until the first window.
double smoothed = -1;

// The target frame rate is a minimum. Over each window the controller counts
// the frame rate and compares the GPU's busy time with the time that passed.
// Below the target while the GPU is busier than GPUBound, it shrinks the area
// by the shortfall; otherwise (at or above the target, or with the GPU not the
// limit) it grows back toward full resolution, but for a while not back to an
// area that missed.
constexpr double Window = 0.25;
constexpr double GPUBound = 0.95;
constexpr double MaximumShrink = 0.80, MaximumGrowth = 1.15;
// A frame rate (averaged like utilization) below this fraction of the target
// misses it. A miss shrinks by the shortfall and a margin, to land on the
// target rather than just under it.
constexpr double Missed = 0.98, MissedShrinkMargin = 0.97;
double smoothedFPS = -1;
// After a miss, growth stops short of the missed area for this long.
constexpr double MissedSeconds = 10, MissedMargin = 0.95;
double missedAt = -MissedSeconds;
float missedArea = 1;
// Longer frames are loading screens, menus or hitches, not a GPU load to follow.
constexpr double LongestFrame = 0.1;

template<class T> T read(const void *p, size_t offset) {
    T value; memcpy(&value, static_cast<const char *>(p) + offset, sizeof value); return value;
}

// The rendered frame rate Dynamic aims for: the Upscaler Target Minimum FPS,
// unless BG3's frame cap (when on) or the refresh rate is lower. Like the cap,
// the minimum counts rendered frames; Frame Generation shows two per rendered
// frame, so half the refresh rate is the most it can render to the screen.
double targetFrameRate(const void *settings) {
    namespace Temporal = BG3MFXBuild::Temporal::Layout;
    double target = BG3MFXDynamicMinimumFrameRate();
    int32_t numerator = read<int32_t>(settings, Temporal::SettingsRefreshNumerator);
    int32_t denominator = read<int32_t>(settings, Temporal::SettingsRefreshDenominator);
    if (numerator > 0 && denominator > 0)
        target = std::min(target, double(numerator) / denominator / (BG3MFXFrameGenerationEnabled() ? 2 : 1));
    uint16_t cap = read<uint16_t>(settings, Temporal::SettingsFrameCap);
    if (read<uint8_t>(settings, Temporal::SettingsFrameCapEnabled) && cap) target = std::min(target, double(cap));
    return target;
}

// Thermal Guard: a ceiling on the area. While macOS reports any thermal state
// above nominal, it falls to ThermalCut of the current area every
// ThermalCutSeconds, down to MetalFX's floor; at nominal it rises by
// ThermalRecovery every ThermalRecoverySeconds. Lowering the area only raises
// the frame rate, so the target frame rate still holds.
constexpr double ThermalCut = 0.8, ThermalCutSeconds = 5;
constexpr double ThermalRecovery = 1.1, ThermalRecoverySeconds = 15;
float thermalCeiling = 1;
double thermalSteppedAt = -ThermalRecoverySeconds;

float thermalLimit(float area, float lowest) {
    double now = CACurrentMediaTime();
    NSProcessInfoThermalState state = NSProcessInfo.processInfo.thermalState;
    float ceiling = thermalCeiling;
    if (state > NSProcessInfoThermalStateNominal) {
        if (now - thermalSteppedAt >= ThermalCutSeconds) {
            ceiling = std::max(lowest, float(std::min(ceiling, area) * ThermalCut));
            thermalSteppedAt = now;
        }
    } else if (ceiling < 1 && now - thermalSteppedAt >= ThermalRecoverySeconds) {
        ceiling = std::min(1.0f, float(ceiling * ThermalRecovery));
        thermalSteppedAt = now;
    }
#ifdef BG3MFX_CONTROLLER_LOG
    if (ceiling != thermalCeiling) os_log(controllerLog, "thermal %ld ceiling %.3f", long(state), ceiling);
#endif
    thermalCeiling = ceiling;
    return std::min(area, ceiling);
}

float controllerArea(double target) {
    double now = CACurrentMediaTime();
    if (!measuring.exchange(true) || !windowStart) {
        takeGPUBusy(); windowStart = now; windowFrames = 0; smoothed = smoothedFPS = -1;
        return controlledArea;
    }
    ++windowFrames;
    double elapsed = now - windowStart;
    if (elapsed < Window) return controlledArea;
    double busy = takeGPUBusy(), measured = busy / elapsed;
    unsigned frames = windowFrames;
    windowStart = now; windowFrames = 0;
    // BG3 slows to 30 fps in the background.
    if (frames < 3 || elapsed / frames > LongestFrame || !NSApp.isActive) return controlledArea;
    smoothed = smoothed < 0 ? measured : (smoothed + measured) / 2;
    double fps = frames / elapsed;
    smoothedFPS = smoothedFPS < 0 ? fps : (smoothedFPS + fps) / 2;
    double utilization = smoothed;
    double step = MaximumGrowth;
    if (target > 0 && smoothedFPS < Missed * target && utilization > GPUBound) {
        step = std::max(MaximumShrink, MissedShrinkMargin * smoothedFPS / target);
        missedAt = now; missedArea = controlledArea;
    } else if (now - missedAt < MissedSeconds) {
        step = std::min(step, std::max(1.0, MissedMargin * missedArea / controlledArea));
    }
    controlledArea = std::min(1.0f, float(controlledArea * step));
#ifdef BG3MFX_CONTROLLER_LOG
    os_log(controllerLog, "busy %.3f smoothed %.3f fps %.1f smoothed %.1f target fps %.1f area %.3f",
        measured, utilization, fps, smoothedFPS, target, controlledArea);
#endif
#ifndef BG3MFX_NO_TRACE
    if (reportEvent)
        reportEvent(@{@"event":@"dynamicResolutionStep",@"utilization":@(utilization),@"measured":@(measured),@"frames":@(frames),
            @"seconds":@(elapsed),@"targetFrameRate":@(target),@"area":@(controlledArea),@"intervals":@(takenStats.count),
            @"raw":@(takenStats.raw),@"span":@(takenStats.last - takenStats.first),
            @"lag":@(windowStart - takenStats.last)});
#endif
    return controlledArea;
}

float targetArea(uint8_t *frame) {
    int32_t sizes[4];
    memcpy(sizes, frame + Layout::RenderSize, 8); memcpy(sizes + 2, frame + Layout::OutputSize, 8);
    const int32_t *render = sizes, *output = sizes + 2;
    void *settings = *reinterpret_cast<void **>(settingsGlobal);
    BG3MFXPublishStartupDynamicQuality();
    bool selected = BG3MFXDynamicResolutionSelected();
    float smallest = minimumScale.load(), largest = maximumScale.load();
    bool eligible = selected && largest > smallest && smallest > 0 && BG3MFXSelectedScalingMode() == 3 && !BG3MFXTemporalFailed() &&
        settings && read<uint8_t>(settings, Layout::SettingsUpscaling) == 1 &&
        render[0] > 0 && render[1] > 0 && output[0] > 0 && output[1] > 0;
    // A quality, mode or window change resizes targets over several frames;
    // stay at full size until it has settled.
    if (eligible != settledEligible || memcmp(sizes, settledSizes, sizeof sizes)) {
#ifdef BG3MFX_CONTROLLER_LOG
        os_log(controllerLog, "eligible %d: quality %d limits %.2f-%.2f mode %d temporalFailed %d frameGeneration %d upscaling %d render %dx%d output %dx%d",
            eligible, settings ? read<uint8_t>(settings, BG3MFXBuild::Temporal::Layout::SettingsQuality) : -1, smallest, largest,
            BG3MFXSelectedScalingMode(), BG3MFXTemporalFailed(), BG3MFXFrameGenerationEnabled(),
            settings ? read<uint8_t>(settings, Layout::SettingsUpscaling) : -1, render[0], render[1], output[0], output[1]);
#endif
        settledEligible = eligible;
        memcpy(settledSizes, sizes, sizeof sizes);
        settledFrames = 0;
    }
    if (!eligible || settledFrames < SettleFrames) {
        ++settledFrames;
        measuring = false; windowStart = 0;
        return 1;
    }
    // The rendered region spans output / largest (plus a pixel of margin) to
    // output / smallest per axis, within the render targets.
    float axis = std::max((output[0] / largest + 1) / render[0], (output[1] / largest + 1) / render[1]);
    float top = std::min({1.0f, output[0] / (smallest * render[0]), output[1] / (smallest * render[1])});
    float highest = top * top, lowest = std::min(highest, axis * axis);
#ifndef BG3MFX_NO_TRACE
    if (overrideArea) {
        float area = minimumArea;
        if (periodSeconds > 0) {
            double phase = std::fmod((mach_absolute_time() - startTicks) * ticksToSeconds, periodSeconds) / periodSeconds;
            area = minimumArea + (maximumArea - minimumArea) * float(1 - std::abs(2 * phase - 1));
        }
        return std::min(highest, std::max(area, lowest));
    }
#endif
    controlledArea = std::min(highest, std::max(controllerArea(targetFrameRate(settings)), lowest));
    if (BG3MFXDynamicThermalGuard())
        controlledArea = thermalLimit(controlledArea, lowest);
    return controlledArea;
}

void startRecordingHook(uint8_t *frame) {
    if (frame && read<uintptr_t>(frame, 0) == metalFrameVTable) {
        float area = targetArea(frame);
        appliedArea = area;
        // Compare with the frame itself: a recreated frame starts at 1 again.
        if (area != read<float>(frame, Layout::Reduction)) {
            float reduction[2] = {area, area};
            memcpy(frame + Layout::Reduction, reduction, 8);
            ssrDiscardFrames = 2;
            calculateViewports(frame);
            void **views = read<void **>(frame, Layout::Views);
            uint32_t count = read<uint32_t>(frame, Layout::ViewCount);
            for (uint32_t i = 0; views && i < count && i < 64; ++i)
                if (views[i]) recalculateViewports(views[i]);
#ifndef BG3MFX_NO_TRACE
            if (std::abs(area - logged) >= 0.05f || (area == 1) != (logged == 1)) {
                logged = area;
                int32_t render[2], viewport[2], viewSize[2] = {}, viewRect[2] = {};
                memcpy(render, frame + Layout::RenderSize, 8); memcpy(viewport, frame + Layout::RenderViewport, 8);
                if (views && count && views[0]) {
                    memcpy(viewSize, static_cast<uint8_t *>(views[0]) + BG3MFXBuild::Temporal::Layout::ViewSize, 8);
                    memcpy(viewRect, static_cast<uint8_t *>(views[0]) + Layout::ViewRenderRect, 8);
                }
                os_log(resolutionLog, "bg3mfx resolution: area %.3f | render %dx%d viewport %dx%d | views %u, first view size %dx%d render rect %dx%d",
                    area, render[0], render[1], viewport[0], viewport[1], count, viewSize[0], viewSize[1], viewRect[0], viewRect[1]);
            }
#endif
        }
    }
    // SSR maps its history through the current viewport; after a change that
    // samples the previous frame's region at the wrong scale.
    ssrDiscard.store(ssrDiscardFrames ? 1 : 0, std::memory_order_relaxed);
    if (ssrDiscardFrames) --ssrDiscardFrames;
    originalStartRecording(frame);
}

uintptr_t branchTarget(uintptr_t site, uint32_t word) {
    int32_t imm = (int32_t)(word << 6) >> 6;
    return site + (intptr_t)imm * 4;
}

#ifndef BG3MFX_NO_TRACE
bool parse(const char *value) {
    char *end = nullptr;
    float first = strtof(value, &end);
    if (end == value || !(first > 0) || first > 1) return false;
    minimumArea = maximumArea = first;
    if (!*end) return true;
    if (*end != ',') return false;
    const char *rest = end + 1;
    float second = strtof(rest, &end);
    if (end == rest || !(second > 0) || second > 1 || *end != ',') return false;
    rest = end + 1;
    float seconds = strtof(rest, &end);
    if (end == rest || *end || !(seconds > 0)) return false;
    minimumArea = std::min(first, second); maximumArea = std::max(first, second); periodSeconds = seconds;
    return true;
}
#endif
}

BOOL BG3MFXDynamicResolutionInstalled(void) { return installed.load(); }
BOOL BG3MFXDynamicResolutionSelected(void) {
    if (!installed.load()) return NO;
#ifndef BG3MFX_NO_TRACE
    if (overrideArea) return YES;
#endif
    void *settings = *reinterpret_cast<void **>(settingsGlobal);
    return settings && BG3MFXDynamicQualityValue(read<uint8_t>(settings, BG3MFXBuild::Temporal::Layout::SettingsQuality));
}
float BG3MFXDynamicResolutionArea(void) { return appliedArea.load(); }
void BG3MFXDynamicResolutionSetScaleLimits(float smallest, float largest) {
    minimumScale = std::max(smallest, 1.0f); maximumScale = largest;
}
BOOL BG3MFXDynamicResolutionMeasuring(void) { return measuring.load(std::memory_order_relaxed); }
void BG3MFXDynamicResolutionGPUWork(double start, double end) {
    if (!(end > start)) return;
    std::lock_guard<std::mutex> hold(gpuLock);
    // Bounded if the render thread stops taking them.
    if (gpuIntervals.size() < 4096) gpuIntervals.emplace_back(start, end);
}

BOOL BG3MFXInstallDynamicResolution(intptr_t slide, void (*report)(NSDictionary *), NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXDynamicResolution" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
#ifndef BG3MFX_NO_TRACE
    if (const char *value = getenv("BG3MFX_DYNAMIC_RESOLUTION_AREA")) {
        if (!parse(value)) return fail(@"BG3MFX_DYNAMIC_RESOLUTION_AREA must be an area fraction, or min,max,seconds.");
        overrideArea = true;
    }
    reportEvent = report;
#else
    (void)report;
#endif
    for (unsigned i = 0; i < Sites; ++i) {
        uintptr_t site = sites[i] + slide;
        uint32_t word = *reinterpret_cast<const uint32_t *>(site);
        if ((word & 0xfc000000) != 0x94000000 || branchTarget(site, word) != Native::StartRecording + slide)
            return fail(@"Unsupported render frame recording call site.");
    }
    if (*reinterpret_cast<const uint32_t *>(Native::CalculateViewports + slide) != Native::CalculateViewportsFirst ||
        *reinterpret_cast<const uint32_t *>(Native::RecalculateViewports + slide) != Native::RecalculateViewportsFirst)
        return fail(@"Unsupported native viewport functions.");
    const uintptr_t fogScale = Native::FogPrevScaleLoad + slide, fogOffset = Native::FogPrevOffsetLoad + slide;
    if (*reinterpret_cast<const uint32_t *>(fogScale) != Native::FogPrevScaleOriginal ||
        *reinterpret_cast<const uint32_t *>(fogOffset) != Native::FogPrevOffsetOriginal)
        return fail(@"Unsupported volumetric fog history viewport.");
    const uintptr_t exposureUV = Native::ExposureUVLoad + slide;
    if (memcmp(reinterpret_cast<const void *>(exposureUV), Native::ExposureUVOriginal, sizeof Native::ExposureUVOriginal))
        return fail(@"Unsupported auto-exposure scene UV settings.");
    for (const auto &load : Native::RenderRectLoads)
        if (*reinterpret_cast<const uint32_t *>(load.address + slide) != load.original)
            return fail(@"Unsupported render rectangle load.");
    const uintptr_t ssrStart = Native::SSRHistoryStart + slide, ssrIsland = BG3MFXBuild::HeaderPadding + slide + ssrIslandOffset;
    if (memcmp(reinterpret_cast<const void *>(ssrStart), Native::SSRHistoryOriginal, sizeof Native::SSRHistoryOriginal))
        return fail(@"Unsupported screen-space reflection history viewport.");
    for (size_t i = 0; i < ssrIslandBytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(ssrIsland + i)) return fail(@"Screen-space reflection island space is in use.");
    const uintptr_t ssrValid = Native::SSRValidLoad + slide, ssrValidIsland = BG3MFXBuild::HeaderPadding + slide + ssrValidOffset;
    if (*reinterpret_cast<const uint32_t *>(ssrValid) != Native::SSRValidOriginal)
        return fail(@"Unsupported screen-space reflection history validity.");
    for (size_t i = 0; i < BG3MFXBuild::Islands::SSRValid.bytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(ssrValidIsland + i)) return fail(@"Screen-space reflection validity island space is in use.");
    if (!BG3MFXBranchReaches(ssrValid, ssrValidIsland) ||
        !BG3MFXBranchReaches(ssrValidIsland + sizeof Native::SSRValidRender, Native::SSRValidReturn + slide))
        return fail(@"Screen-space reflection validity island is out of range.");
    if (!BG3MFXBranchReaches(ssrStart, ssrIsland) || !BG3MFXBranchReaches(ssrIsland + sizeof Native::SSRHistoryRender, Native::SSRHistoryReturn + slide))
        return fail(@"Screen-space reflection island is out of range.");
    uintptr_t island = BG3MFXBuild::HeaderPadding + slide + islandOffset;
    for (size_t i = 0; i < Sites * islandStride; ++i)
        if (*reinterpret_cast<const uint8_t *>(island + i)) return fail(@"Viewport reduction island space is in use.");
    std::vector<std::pair<uintptr_t, size_t>> ranges = {{island, Sites * islandStride}};
    for (unsigned i = 0; i < Sites; ++i) {
        if (!BG3MFXBranchReaches(sites[i] + slide, island + i * islandStride)) return fail(@"Viewport reduction islands are out of range.");
        ranges.push_back({sites[i] + slide, 4});
    }
    ranges.push_back({fogScale, 4});
    ranges.push_back({fogOffset, 4});
    ranges.push_back({exposureUV, sizeof Native::ExposureUVOriginal});
    ranges.push_back({ssrIsland, ssrIslandBytes});
    ranges.push_back({ssrStart, 4});
    ranges.push_back({ssrValidIsland, BG3MFXBuild::Islands::SSRValid.bytes});
    ranges.push_back({ssrValid, 4});
    for (const auto &load : Native::RenderRectLoads) ranges.push_back({load.address + slide, 4});
#ifndef BG3MFX_NO_TRACE
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    ticksToSeconds = (double)timebase.numer / timebase.denom / 1e9;
    startTicks = mach_absolute_time();
    resolutionLog = os_log_create("com.bg3mfx", "resolution");
#endif
#ifdef BG3MFX_CONTROLLER_LOG
    controllerLog = os_log_create("com.bg3mfx", "controller");
#endif
    originalStartRecording = reinterpret_cast<void (*)(void *)>(Native::StartRecording + slide);
    calculateViewports = reinterpret_cast<void (*)(void *)>(Native::CalculateViewports + slide);
    recalculateViewports = reinterpret_cast<void (*)(void *)>(Native::RecalculateViewports + slide);
    metalFrameVTable = Native::MetalRenderFrameVTable + slide;
    settingsGlobal = BG3MFXBuild::Temporal::Settings + slide;
    const uintptr_t hook = reinterpret_cast<uintptr_t>(startRecordingHook);
    auto result = BG3MFXPatchCode(ranges, [&] {
        for (unsigned i = 0; i < Sites; ++i) {
            // x0 already holds the frame: nop; ldr x16, #12; br x16; nop; .quad hook
            uint32_t code[6] = {0xd503201f, 0x58000070, 0xd61f0200, 0xd503201f, 0, 0};
            memcpy(code + 4, &hook, 8);
            memcpy(reinterpret_cast<void *>(island + i * islandStride), code, sizeof code);
        }
        sys_icache_invalidate(reinterpret_cast<void *>(island), Sites * islandStride);
        for (unsigned i = 0; i < Sites; ++i) {
            uintptr_t site = sites[i] + slide;
            uint32_t call = 0x94000000 | (BG3MFXBranch(site, island + i * islandStride) & 0x03ffffff);
            memcpy(reinterpret_cast<void *>(site), &call, 4);
        }
        // Save the composed render viewport as the fog history's previous viewport.
        memcpy(reinterpret_cast<void *>(fogScale), &Native::FogPrevScaleRender, 4);
        memcpy(reinterpret_cast<void *>(fogOffset), &Native::FogPrevOffsetRender, 4);
        // Average auto-exposure over the composed render viewport.
        memcpy(reinterpret_cast<void *>(exposureUV), Native::ExposureUVRender, sizeof Native::ExposureUVRender);
        // Size forward lighting clamps, bloom and DOF radii and the projection jitter from the composed render rectangle.
        for (const auto &load : Native::RenderRectLoads)
            memcpy(reinterpret_cast<void *>(load.address + slide), &load.render, 4);
        // Save the composed render viewport, and UV clamps inside it, as the SSR history's previous viewport.
        uint32_t ssr[ssrIslandBytes / 4];
        memcpy(ssr, Native::SSRHistoryRender, sizeof Native::SSRHistoryRender);
        const uintptr_t ssrBack = ssrIsland + sizeof Native::SSRHistoryRender;
        ssr[sizeof Native::SSRHistoryRender / 4] = 0x14000000 | (BG3MFXBranch(ssrBack, Native::SSRHistoryReturn + slide) & 0x03ffffff);
        memcpy(reinterpret_cast<void *>(ssrIsland), ssr, sizeof ssr);
        sys_icache_invalidate(reinterpret_cast<void *>(ssrIsland), sizeof ssr);
        const uint32_t toIsland = 0x14000000 | (BG3MFXBranch(ssrStart, ssrIsland) & 0x03ffffff);
        memcpy(reinterpret_cast<void *>(ssrStart), &toIsland, 4);
        // Load SSR's history-valid byte as 0 while an area change is flagged.
        uint32_t valid[BG3MFXBuild::Islands::SSRValid.bytes / 4];
        constexpr size_t validWords = sizeof Native::SSRValidRender / 4;
        memcpy(valid, Native::SSRValidRender, sizeof Native::SSRValidRender);
        valid[validWords] = 0x14000000 | (BG3MFXBranch(ssrValidIsland + validWords * 4, Native::SSRValidReturn + slide) & 0x03ffffff);
        const uintptr_t flag = reinterpret_cast<uintptr_t>(&ssrDiscard);
        memcpy(valid + validWords + 1, &flag, 8);
        memcpy(reinterpret_cast<void *>(ssrValidIsland), valid, sizeof valid);
        sys_icache_invalidate(reinterpret_cast<void *>(ssrValidIsland), sizeof valid);
        const uint32_t toValidIsland = 0x14000000 | (BG3MFXBranch(ssrValid, ssrValidIsland) & 0x03ffffff);
        memcpy(reinterpret_cast<void *>(ssrValid), &toValidIsland, 4);
    });
    if (result != BG3MFXCodePatchResult::Patched) return fail(@"Could not install dynamic resolution.");
    installed = true;
#ifndef BG3MFX_NO_TRACE
    if (overrideArea)
        os_log(resolutionLog, "bg3mfx resolution: area override %.3f-%.3f, period %.1f s", minimumArea, maximumArea, periodSeconds);
#endif
    if (report) report(@{@"event":@"dynamicResolutionInstalled"});
    return YES;
}
