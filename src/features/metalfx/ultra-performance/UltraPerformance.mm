#include "common/native/SupportedBuild.h"
#import "features/metalfx/ultra-performance/UltraPerformance.h"
#import "features/metalfx/MetalFX.h"
#include "common/native/CodePatch.h"
#include <libkern/OSCacheControl.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
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
// MetalFX's supported content scale range for BG3's device; 0 until known.
std::atomic<float> minimumScale{0}, maximumScale{0};
// Read by the SSR valid island as a byte: nonzero makes SSR discard its history.
std::atomic<uint8_t> ssrDiscard{0};
static_assert(sizeof ssrDiscard == 1, "the SSR island loads one byte");

// Render thread only.
int32_t settledSizes[4];
bool settledEligible;
unsigned settledFrames;
// Frames left to discard SSR history after an area change. Two, in case the
// SSR stage of a changed frame runs after the next frame starts recording.
unsigned ssrDiscardFrames;
// Frames recorded with unchanged sizes and upscaler selection before reducing.
constexpr unsigned SettleFrames = 60;
template<class T> T read(const void *p, size_t offset) {
    T value; memcpy(&value, static_cast<const char *>(p) + offset, sizeof value); return value;
}

float targetArea(uint8_t *frame) {
    int32_t sizes[4];
    memcpy(sizes, frame + Layout::RenderSize, 8); memcpy(sizes + 2, frame + Layout::OutputSize, 8);
    const int32_t *render = sizes, *output = sizes + 2;
    void *settings = *reinterpret_cast<void **>(settingsGlobal);
    BG3MFXPublishStartupReducedQuality();
    bool selected = BG3MFXUltraPerformanceSelected();
    float smallest = minimumScale.load(), largest = maximumScale.load();
    bool eligible = selected && largest > smallest && smallest > 0 && BG3MFXSelectedScalingMode() == 3 && !BG3MFXTemporalFailed() &&
        settings && read<uint8_t>(settings, Layout::SettingsUpscaling) == 1 &&
        render[0] > 0 && render[1] > 0 && output[0] > 0 && output[1] > 0;
    // A quality, mode or window change resizes targets over several frames;
    // stay at full size until it has settled.
    if (eligible != settledEligible || memcmp(sizes, settledSizes, sizeof sizes)) {
        settledEligible = eligible;
        memcpy(settledSizes, sizes, sizeof sizes);
        settledFrames = 0;
    }
    if (!eligible || settledFrames < SettleFrames) {
        ++settledFrames;
        return 1;
    }
    // The rendered region is output / the largest scale (plus a pixel of margin)
    // per axis, within the render targets and the range MetalFX accepts.
    float scale = largest;
    float axis = std::max((output[0] / scale + 1) / render[0], (output[1] / scale + 1) / render[1]);
    float top = std::min({1.0f, output[0] / (smallest * render[0]), output[1] / (smallest * render[1])});
    return std::min(top * top, axis * axis);
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

}

BOOL BG3MFXUltraPerformanceInstalled(void) { return installed.load(); }
BOOL BG3MFXUltraPerformanceSelected(void) {
    if (!installed.load()) return NO;
    void *settings = *reinterpret_cast<void **>(settingsGlobal);
    return settings && read<uint8_t>(settings, BG3MFXBuild::Temporal::Layout::SettingsQuality) == BG3MFXUltraPerformanceQuality;
}
float BG3MFXUltraPerformanceArea(void) { return appliedArea.load(); }
void BG3MFXUltraPerformanceSetScaleLimits(float smallest, float largest) {
    minimumScale = std::max(smallest, 1.0f); maximumScale = largest;
}

static BOOL installUltraPerformance(intptr_t slide, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXUltraPerformance" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
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
    if (result != BG3MFXCodePatchResult::Patched) return fail(@"Could not install Ultra Performance.");
    installed = true;
    return YES;
}

BOOL BG3MFXInstallUltraPerformance(intptr_t slide, NSError **error) { return installUltraPerformance(slide, error); }
