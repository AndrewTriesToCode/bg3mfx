#include "common/native/SupportedBuild.h"
#import "features/reduce-locking/UniformSlices.h"
#include "common/native/CodePatch.h"
#include <libkern/OSCacheControl.h>
#include <os/lock.h>
#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <vector>

// BG3 allocates each draw's uniforms from one bump offset per frame, guarded
// by one os_unfair_lock on the MetalRenderer; the lock-and-bump is inlined at
// about 130 sites. Draw-recording jobs on every worker queue on it: in
// thread-state traces about 0.65 cores at a 60 fps cap and 0.9 uncapped
// (docs/dev/performance.md). The two hottest sites now take their allocation
// from a per-thread slice of the same buffer. A slice is reserved through
// BG3's own lock and bump, so every other site still sees BG3's protocol, and
// BeginFrame's reset retires all slices.
namespace Native = BG3MFXBuild::UniformSlices;

namespace {
// BG3 4.1.1.7631656. BindMaterialParameters: `ldr x25, [x1, #0x38]` (the
// renderer); `add x20, x25, #8`; lock; align and bump by x21 into x24; unlock;
// `ldr x1, [sp, #0xd8]`; `b BindResume`.
const uint32_t bindOriginal[14] = {0xf9401c39, 0x91002334, 0xaa1403e0, 0x946b1509, 0xf9504b28, 0x4b0803e9, 0x92400d29,
    0x8b080138, 0x8b150308, 0xf9104b28, 0xaa1403e0, 0x946b1504, 0xf9406fe1, 0x14000082};
// SetupEngineParameters: `ldr x23, [x19, #0x2000]`; the lock at x23 + 0x1f8;
// align and bump by x24 into x28; `mov x23, x19`; unlock.
const uint32_t setupOriginal[13] = {0xf9500277, 0x9107e2fb, 0xaa1b03e0, 0x945bb41c, 0xf95142e8, 0x4b0803e9, 0x92400d29,
    0x8b08013c, 0x8b180388, 0xf91142e8, 0xaa1303f7, 0xaa1b03e0, 0x945bb416};
// BeginFrame, under its own lock: `str q0, [x20, #0x2090]` zeroes the offset.
const uint32_t frameResetOriginal = 0x3d882680;
const size_t islandOffset = BG3MFXBuild::Islands::UniformSlices.offset, islandBytes = BG3MFXBuild::Islands::UniformSlices.bytes;

// Written by the BeginFrame island: the slice generation and the offset the
// previous frame ended at.
struct alignas(64) FrameState {
    std::atomic<uint64_t> generation;
    std::atomic<uint64_t> lastOffset;
} frameState;
static_assert(sizeof(std::atomic<uint64_t>) == 8 && offsetof(FrameState, lastOffset) == 8, "BeginFrame island layout");

uint64_t sliceBytes = 16384;
struct Slice { const char *renderer; uint64_t generation, next, end; };
thread_local Slice slice;

#ifndef BG3MFX_NO_TRACE
void (*reportEvent)(NSDictionary *);
std::atomic<uint64_t> refills{0}, peakOffset{0};
void noteRefill() {
    uint64_t last = frameState.lastOffset.load(std::memory_order_relaxed);
    for (uint64_t peak = peakOffset.load(); last > peak && !peakOffset.compare_exchange_weak(peak, last);) {}
    uint64_t count = ++refills;
    // Peak is the largest offset a finished frame reached, against the
    // buffer's size: the slices' headroom.
    if (reportEvent && count >= 1024 && !(count & (count - 1))) {
        @autoreleasepool {
            reportEvent(@{@"event": @"uniformSlicesUsage", @"slices": @(count), @"peakOffsetBytes": @(peakOffset.load()),
                          @"bufferBytes": @(Native::Layout::BufferBytes), @"sliceBytes": @(sliceBytes)});
        }
    }
}
#endif

// Called from both sites with the renderer and the allocation's size; returns
// its offset, 16-byte aligned like BG3's.
uint64_t allocate(const char *renderer, uint64_t size) {
    uint64_t generation = frameState.generation.load(std::memory_order_acquire);
    uint64_t at = (slice.next + 15) & ~uint64_t(15);
    if (slice.renderer != renderer || slice.generation != generation || at + size > slice.end) {
        uint64_t bytes = std::max(sliceBytes, (size + 15) & ~uint64_t(15));
        auto *lock = reinterpret_cast<os_unfair_lock *>(const_cast<char *>(renderer) + Native::Layout::Lock);
        auto *offset = reinterpret_cast<uint64_t *>(const_cast<char *>(renderer) + Native::Layout::Offset);
        os_unfair_lock_lock(lock);
        at = (*offset + 15) & ~uint64_t(15);
        *offset = at + bytes;
        os_unfair_lock_unlock(lock);
        slice = {renderer, generation, at, at + bytes};
#ifndef BG3MFX_NO_TRACE
        noteRefill();
#endif
    }
    slice.next = at + size;
    return at;
}

bool zero(uintptr_t address, size_t bytes) {
    for (size_t i = 0; i < bytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(address + i)) return false;
    return true;
}

uint32_t call(uintptr_t from, uintptr_t to) { return 0x94000000 | (BG3MFXBranch(from, to) & 0x03ffffff); }
}

BOOL BG3MFXInstallUniformSlices(intptr_t slide, void (*report)(NSDictionary *), NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXUniformSlices" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // A slice size for measurement, in bytes: a multiple of 16 up to 1 MB.
    if (const char *value = getenv("BG3MFX_UNIFORM_SLICE_BYTES")) {
        char *end = nullptr;
        unsigned long long parsed = strtoull(value, &end, 10);
        if (*value && !*end && parsed >= 256 && parsed <= (1u << 20) && !(parsed % 16)) sliceBytes = parsed;
    }
    // NativeMenu has already checked the executable UUID; also check every
    // instruction replaced.
    uintptr_t bind = Native::BindAlloc + slide, setup = Native::SetupAlloc + slide, reset = Native::FrameReset + slide;
    if (memcmp(reinterpret_cast<const void *>(bind), bindOriginal, sizeof bindOriginal) != 0 ||
        memcmp(reinterpret_cast<const void *>(setup), setupOriginal, sizeof setupOriginal) != 0)
        return fail(@"Unsupported uniform allocation sites.");
    if (*reinterpret_cast<const uint32_t *>(reset) != frameResetOriginal) return fail(@"Unsupported frame reset.");
    uintptr_t island = BG3MFXBuild::HeaderPadding + slide + islandOffset, allocIsland = island, resetIsland = island + 16;
    if (!zero(island, islandBytes)) return fail(@"Uniform slice island space is in use.");
    if (!BG3MFXBranchReaches(bind + 16, allocIsland) || !BG3MFXBranchReaches(setup + 12, allocIsland) ||
        !BG3MFXBranchReaches(reset, resetIsland) || !BG3MFXBranchReaches(bind + 28, Native::BindResume + slide) ||
        !BG3MFXBranchReaches(setup + 24, Native::SetupResume + slide))
        return fail(@"Uniform slice island is out of range.");
#ifndef BG3MFX_NO_TRACE
    reportEvent = report;
#endif
    auto result = BG3MFXPatchCode({{island, islandBytes}, {bind, 32}, {setup, 28}, {reset, 4}}, [&] {
        // Allocation: ldr x16, #8; br x16; .quad allocate (returns to the site).
        uint32_t allocCode[4] = {0x58000050, 0xd61f0200, 0, 0};
        uintptr_t allocHook = reinterpret_cast<uintptr_t>(allocate);
        memcpy(allocCode + 2, &allocHook, 8);
        // Frame reset: ldr x17, [x20, #0x2090] (the frame's end); str q0,
        // [x20, #0x2090] (BG3's reset); ldr x16, <state>; str x17, [x16, #8];
        // ldr x17, [x16]; add x17, x17, #1; stlr x17, [x16]; ret; .quad state
        uint32_t resetCode[10] = {0xf9504a91, 0x3d882680, 0x580000d0, 0xf9000611, 0xf9400211, 0x91000631, 0xc89ffe11,
                                  0xd65f03c0, 0, 0};
        uintptr_t state = reinterpret_cast<uintptr_t>(&frameState);
        memcpy(resetCode + 8, &state, 8);
        memcpy(reinterpret_cast<void *>(allocIsland), allocCode, sizeof allocCode);
        memcpy(reinterpret_cast<void *>(resetIsland), resetCode, sizeof resetCode);
        sys_icache_invalidate(reinterpret_cast<void *>(island), islandBytes);
        // ldr x25, [x1, #0x38]; add x20, x25, #8; mov x0, x25; mov x1, x21;
        // bl <alloc>; mov x24, x0; ldr x1, [sp, #0xd8]; b BindResume
        uint32_t bindCode[8] = {0xf9401c39, 0x91002334, 0xaa1903e0, 0xaa1503e1, call(bind + 16, allocIsland), 0xaa0003f8,
                                0xf9406fe1, BG3MFXBranch(bind + 28, Native::BindResume + slide)};
        // ldr x8, [x19, #0x2000]; add x0, x8, #0x1f0; mov x1, x24; bl <alloc>;
        // mov x28, x0; mov x23, x19; b SetupResume
        uint32_t setupCode[7] = {0xf9500268, 0x9107c100, 0xaa1803e1, call(setup + 12, allocIsland), 0xaa0003fc, 0xaa1303f7,
                                 BG3MFXBranch(setup + 24, Native::SetupResume + slide)};
        memcpy(reinterpret_cast<void *>(bind), bindCode, sizeof bindCode);
        memcpy(reinterpret_cast<void *>(setup), setupCode, sizeof setupCode);
        uint32_t toReset = call(reset, resetIsland);
        memcpy(reinterpret_cast<void *>(reset), &toReset, 4);
    });
    if (result == BG3MFXCodePatchResult::NotWritable) return fail(@"Could not make the uniform allocation sites writable.");
    if (report) report(@{@"event": @"uniformSlicesInstalled", @"sliceBytes": @(sliceBytes),
                         @"protectionRestored": @(result == BG3MFXCodePatchResult::Patched)});
    return YES;
}
