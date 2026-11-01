#include "common/native/SupportedBuild.h"
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <sys/mman.h>

// Runs the SSAO blur fix's island on this CPU against a modelled DynamicCB,
// recording the two blur passes as BG3 does: a write to the next ring slot,
// then a bind record. BG3's op 0x08 record resolves the slot at replay, so
// both passes get the second write; the island's op 0x07 record keeps the
// slot of its own write. Also checks the patched words against the original
// branch. Synthetic, CPU only.
namespace Native = BG3MFXBuild::SSAOBlur;

extern "C" void *BG3MFXTestSSAOBlurIsland(void *cb, void *record, const void *code);

namespace {
constexpr uint32_t Ret = 0xd65f03c0;
// rf::DynamicCB: ring slots at +0x00, the counter at +0x28.
struct alignas(16) DynamicCB {
    void *slots[4];
    void *gpuBuffer;
    uint32_t counter, padding;
    void *cached;
};
static_assert(offsetof(DynamicCB, counter) == 0x28, "DynamicCB layout");
// A 0x28-byte bind record: op at +0x00, buffer at +0x08.
struct Record { uint8_t bytes[0x28]; };

struct Slot { float delta[4]; };
Slot ring[4];

// BG3's write: the next slot, as SetDynamicConstantBufferData's memcpy.
void write(DynamicCB &cb, const Slot &value) {
    ++cb.counter;
    *static_cast<Slot *>(cb.slots[cb.counter & 3]) = value;
}
void *recordBuffer(const Record &record) {
    void *buffer;
    memcpy(&buffer, record.bytes + 8, 8);
    return buffer;
}
}

int main() {
    int failures = 0;
    // The patch changes only the op and the record's buffer store.
    if (Native::BindOriginal[Native::OpWord] != 0x52800115 || Native::BindOriginal[Native::BufferWord] != 0xf9000414 ||
        Native::BindOriginal[11] != 0x39000015 || Native::OpPatched != (0x52800015u | 7u << 5)) {
        std::printf("SSAO blur patch words don't match the branch they patch.\n");
        ++failures;
    }
    uint32_t *jit = static_cast<uint32_t *>(mmap(nullptr, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0));
    if (jit == MAP_FAILED) { std::fprintf(stderr, "Could not map executable memory.\n"); return 1; }
    constexpr size_t IslandWords = sizeof Native::BindIsland / 4;
    pthread_jit_write_protect_np(0);
    memcpy(jit, Native::BindIsland, sizeof Native::BindIsland);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(jit, 0x4000);
    if (jit[IslandWords - 1] != Ret) { std::printf("SSAO blur island doesn't return.\n"); ++failures; }

    // Every counter value, including wrap-around: the record gets slot counter & 3.
    DynamicCB cb = {};
    for (int i = 0; i < 4; ++i) cb.slots[i] = &ring[i];
    const uint32_t counters[] = {0, 1, 2, 3, 4, 5, 6, 7, 0x7fffffff, 0xfffffffe, 0xffffffff};
    for (uint32_t counter : counters) {
        cb.counter = counter;
        Record record;
        memset(&record, 0xa5, sizeof record);
        void *x20 = BG3MFXTestSSAOBlurIsland(&cb, &record, jit);
        bool othersKept = true;
        for (size_t b = 0; b < sizeof record.bytes; ++b)
            if ((b < 8 || b >= 16) && record.bytes[b] != 0xa5) othersKept = false;
        if (x20 != &cb || recordBuffer(record) != cb.slots[counter & 3] || !othersKept || cb.counter != counter) {
            std::printf("SSAO blur island stored the wrong slot for counter %u.\n", counter);
            ++failures;
        }
    }

    // A frame's two blur passes, as BG3 records them.
    const Slot horizontal = {{1 / 1728.0f, 0, 0, 0}}, vertical = {{0, 1 / 1080.0f, 0, 0}};
    cb.counter = 5;
    Record first, second;
    write(cb, horizontal);
    BG3MFXTestSSAOBlurIsland(&cb, &first, jit);
    write(cb, vertical);
    BG3MFXTestSSAOBlurIsland(&cb, &second, jit);
    // BG3's op 0x08 replay: both records resolve the slot through the counter now.
    const Slot *unpatched = static_cast<const Slot *>(cb.slots[cb.counter & 3]);
    if (memcmp(unpatched, &vertical, sizeof vertical)) { std::printf("The model's unpatched replay isn't vertical.\n"); ++failures; }
    const Slot *a = static_cast<const Slot *>(recordBuffer(first)), *b = static_cast<const Slot *>(recordBuffer(second));
    if (memcmp(a, &horizontal, sizeof horizontal) || memcmp(b, &vertical, sizeof vertical)) {
        std::printf("Patched blur passes don't replay horizontal, then vertical.\n");
        ++failures;
    }
    if (failures) return 1;
    std::printf("SSAO blur fix: the island records each pass's own ring slot; BG3's replay gave both the vertical one (synthetic, CPU).\n");
    return 0;
}
