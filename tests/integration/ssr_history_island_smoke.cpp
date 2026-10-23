#include "common/native/SupportedBuild.h"
#include <arm_neon.h>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <sys/mman.h>

// Runs BG3's original SSR history save and the reduction probe's island on
// this CPU and compares the previous-viewport values they store, then runs the
// history-valid island with its discard flag clear and set.
namespace Native = BG3MFXBuild::ViewportReduction;

extern "C" void BG3MFXTestSSRHistory(void *view, void *state, const void *code, float32x2_t size);
extern "C" uint32_t BG3MFXTestSSRValid(const void *base, const void *code);

namespace {
constexpr size_t ViewBytes = 0x2210, StateBytes = 0x2490;
constexpr size_t RectSize = 0x2180, RectOffset = 0x2188, FullScale = 0x2170, FullOffset = 0x2178;
constexpr size_t RenderScale = 0x21f8, RenderOffset = 0x2200, Saved = 0x2470;
constexpr uint32_t Ret = 0xd65f03c0;

struct Region { int32_t size[2], offset[2]; };
struct Saved4 { float minimum[2], maximum[2], scale[2], offset[2]; };


void load(uint32_t *at, const uint32_t *words, size_t count) {
    memcpy(at, words, count * 4);
    at[count] = Ret;
}

// `view` fills the integer rectangle and the +0x2170 pair, `render` the
// composed render viewport at +0x21f8.
Saved4 run(const uint32_t *code, const Region &view, const Region &render, const float target[2]) {
    alignas(16) static uint8_t viewBytes[ViewBytes], stateBytes[StateBytes];
    memset(viewBytes, 0, sizeof viewBytes);
    memset(stateBytes, 0xa5, sizeof stateBytes);
    float scale[2] = {view.size[0] / target[0], view.size[1] / target[1]};
    float offset[2] = {view.offset[0] / target[0], view.offset[1] / target[1]};
    float renderScale[2] = {render.size[0] / target[0], render.size[1] / target[1]};
    float renderOffset[2] = {render.offset[0] / target[0], render.offset[1] / target[1]};
    memcpy(viewBytes + RectSize, view.size, 8);
    memcpy(viewBytes + RectOffset, view.offset, 8);
    memcpy(viewBytes + FullScale, scale, 8);
    memcpy(viewBytes + FullOffset, offset, 8);
    memcpy(viewBytes + RenderScale, renderScale, 8);
    memcpy(viewBytes + RenderOffset, renderOffset, 8);
    BG3MFXTestSSRHistory(viewBytes, stateBytes, code, vld1_f32(target));
    Saved4 saved;
    memcpy(&saved, stateBytes + Saved, sizeof saved);
    return saved;
}

bool close(const Saved4 &a, const Saved4 &b) {
    const float *x = &a.minimum[0], *y = &b.minimum[0];
    for (int i = 0; i < 8; ++i)
        if (!(std::fabs(x[i] - y[i]) <= 1e-6f)) return false;
    return true;
}

void print(const char *name, const Saved4 &s) {
    std::printf("  %s min (%.6f, %.6f) max (%.6f, %.6f) scale (%.6f, %.6f) offset (%.6f, %.6f)\n", name, s.minimum[0], s.minimum[1],
                s.maximum[0], s.maximum[1], s.scale[0], s.scale[1], s.offset[0], s.offset[1]);
}
}

int main() {
    constexpr size_t OriginalWords = sizeof Native::SSRHistoryOriginal / 4, IslandWords = sizeof Native::SSRHistoryRender / 4;
    uint32_t *jit = static_cast<uint32_t *>(mmap(nullptr, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0));
    if (jit == MAP_FAILED) { std::fprintf(stderr, "Could not map executable memory.\n"); return 1; }
    pthread_jit_write_protect_np(0);
    load(jit, Native::SSRHistoryOriginal, OriginalWords);
    load(jit + 64, Native::SSRHistoryRender, IslandWords);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(jit, 0x4000);
    const uint32_t *original = jit, *island = jit + 64;
    // The validity island as the probe writes it, returning where it branches back.
    constexpr size_t ValidWords = sizeof Native::SSRValidRender / 4;
    static_assert(ValidWords + 1 + 2 == BG3MFXBuild::Islands::SSRValid.bytes / 4, "island layout");
    static uint8_t discard = 0;
    const uintptr_t flag = reinterpret_cast<uintptr_t>(&discard);
    uint32_t *validOriginal = jit + 128, *validIsland = jit + 136;
    pthread_jit_write_protect_np(0);
    load(validOriginal, &Native::SSRValidOriginal, 1);
    load(validIsland, Native::SSRValidRender, ValidWords);
    memcpy(validIsland + ValidWords + 1, &flag, 8);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(jit, 0x4000);

    const float target[2] = {1728, 1080};
    struct Case { const char *name; Region full, render; } cases[] = {
        {"full size", {{1728, 1080}, {0, 0}}, {{1728, 1080}, {0, 0}}},
        {"area 0.5", {{1728, 1080}, {0, 0}}, {{1222, 764}, {0, 0}}},
        {"offset region", {{1728, 1080}, {0, 0}}, {{864, 540}, {432, 270}}},
    };
    int failures = 0;
    for (const Case &c : cases) {
        // While reducing, BG3 leaves the integer rectangle and +0x2170 at full
        // size; the reference is BG3's own code given the composed region.
        Saved4 reference = run(original, c.render, c.render, target);
        Saved4 patched = run(island, c.full, c.render, target);
        // Unpatched, BG3 saves the full-size viewport: it must differ whenever
        // the region is reduced, or this comparison proves nothing.
        bool reduced = memcmp(&c.full, &c.render, sizeof c.full) != 0;
        if (reduced == close(reference, run(original, c.full, c.render, target))) {
            std::printf("Unpatched SSR history unexpectedly %s for %s.\n", reduced ? "matches" : "differs", c.name);
            ++failures;
        }
        if (!close(reference, patched)) {
            std::printf("SSR history island differs for %s:\n", c.name);
            print("BG3", reference);
            print("island", patched);
            ++failures;
        }
    }
    for (uint8_t valid = 0; valid < 2; ++valid) {
        alignas(16) uint8_t base[0x40] = {};
        base[0x20] = valid;
        for (uint8_t set = 0; set < 2; ++set) {
            discard = set;
            uint32_t bg3 = BG3MFXTestSSRValid(base, validOriginal), patched = BG3MFXTestSSRValid(base, validIsland);
            uint32_t expected = set ? 0 : valid;
            if (bg3 != valid || patched != expected) {
                std::printf("SSR valid island: byte %u, discard %u gave BG3 %u, island %u (want %u).\n", valid, set, bg3, patched, expected);
                ++failures;
            }
        }
    }
    if (failures) return 1;
    std::puts("SSR valid island: loads BG3's history-valid byte, or 0 while the probe's discard flag is set.");
    std::puts("SSR history island: full size, area 0.5 and an offset region match BG3's own history viewport for the composed region; unpatched code saves the full target.");
}
