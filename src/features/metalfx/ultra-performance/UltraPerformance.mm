#include "common/native/SupportedBuild.h"
#import "features/metalfx/ultra-performance/UltraPerformance.h"
#import "features/metalfx/MetalFX.h"
#include "common/native/CodePatch.h"
#import <MetalFX/MetalFX.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>

namespace Native = BG3MFXBuild::RenderScale;

namespace {
// BG3's render scale table, plus quality 4's entry (1.0 while not active). BG3's
// code reaches it through a pointer in the island, so it is changed in place.
static_assert(sizeof(std::atomic<float>) == 4 && std::atomic<float>::is_always_lock_free, "the table is read as floats");
std::atomic<float> table[5] = {1.3f, 1.5f, 1.7f, 2.0f, 1.0f};
std::atomic<bool> installed{false};
float scale = 1;

// ARM64 ADRP x9 at `pc` targeting the page of `target`.
uint32_t adrp(uintptr_t pc, uintptr_t target) {
    int64_t pages = ((int64_t)(target >> 12) - (int64_t)(pc >> 12)) & 0x1fffff;
    return 0x90000009 | (uint32_t)((pages & 3) << 29) | (uint32_t)(((pages >> 2) & 0x7ffff) << 5);
}
bool adrpReaches(uintptr_t pc, uintptr_t target) {
    int64_t pages = ((int64_t)(target >> 12) - (int64_t)(pc >> 12));
    return pages >= -(1 << 20) && pages < (1 << 20);
}
}

BOOL BG3MFXUltraPerformanceInstalled(void) { return installed.load(); }
float BG3MFXUltraPerformanceScale(void) { return scale; }
void BG3MFXUltraPerformanceActive(bool active) {
    if (!installed.load(std::memory_order_relaxed)) return;
    float value = active ? scale : 1.0f;
    if (table[4].load(std::memory_order_relaxed) != value) table[4].store(value, std::memory_order_relaxed);
}

BOOL BG3MFXInstallUltraPerformance(intptr_t slide, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXUltraPerformance" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // Only where the Temporal scaler can reduce the input at all.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    float maximum = device && [MTLFXTemporalScalerDescriptor supportsMetal4FX:device] ?
        [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device] : 0;
    if (!(maximum > 1.5f)) return YES;
    scale = maximum * (1 - 1.0f / 300);

    const uintptr_t tableAddress = Native::Table + slide;
    if (memcmp(reinterpret_cast<const void *>(tableAddress), Native::TableOriginal, sizeof Native::TableOriginal))
        return fail(@"Unsupported render scale table.");
    for (const auto &compare : Native::Compares)
        if (*reinterpret_cast<const uint32_t *>(compare.address + slide) != compare.original)
            return fail(@"Unsupported render scale quality check.");
    const uintptr_t island = BG3MFXBuild::HeaderPadding + slide + BG3MFXBuild::Islands::RenderScale.offset;
    for (size_t i = 0; i < BG3MFXBuild::Islands::RenderScale.bytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(island + i)) return fail(@"Render scale island space is in use.");
    const uintptr_t islandPage = island & ~(uintptr_t)0xfff;
    const size_t slot = island & 0xfff;
    if (slot % 8 || slot / 8 > 0xfff) return fail(@"Render scale island is misaligned.");
    std::vector<std::pair<uintptr_t, size_t>> ranges = {{island, BG3MFXBuild::Islands::RenderScale.bytes}};
    for (const auto &load : Native::Loads) {
        const uintptr_t pc = load.address + slide;
        if (*reinterpret_cast<const uint32_t *>(pc) != load.adrp || *reinterpret_cast<const uint32_t *>(pc + 4) != Native::AddTable)
            return fail(@"Unsupported render scale table load.");
        if (!adrpReaches(pc, island)) return fail(@"Render scale island is out of range.");
        ranges.push_back({pc, 8});
    }
    for (const auto &compare : Native::Compares) ranges.push_back({compare.address + slide, 4});

    auto result = BG3MFXPatchCode(ranges, [&] {
        // The island holds a pointer to the table; each site loads it in place of
        // the table's address: adrp x9, island page; ldr x9, [x9, slot].
        const uintptr_t pointer = reinterpret_cast<uintptr_t>(table);
        memcpy(reinterpret_cast<void *>(island), &pointer, sizeof pointer);
        for (const auto &load : Native::Loads) {
            const uintptr_t pc = load.address + slide;
            uint32_t code[2] = {adrp(pc, islandPage), (uint32_t)(0xf9400129 | ((slot / 8) << 10))};
            memcpy(reinterpret_cast<void *>(pc), code, sizeof code);
        }
        for (const auto &compare : Native::Compares) memcpy(reinterpret_cast<void *>(compare.address + slide), &compare.patched, 4);
    });
    if (result != BG3MFXCodePatchResult::Patched) return fail(@"Could not install Ultra Performance.");
    installed = true;
    return YES;
}
