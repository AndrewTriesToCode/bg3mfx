#include "common/native/SupportedBuild.h"
#import "features/thread-idling/ThreadIdling.h"
#include "common/native/CodePatch.h"
#include <libkern/OSCacheControl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <atomic>
#include <cstring>

// BG3 spends most of its idle CPU time spinning rather than sleeping. In Lower
// City at the same frame rate and a steady 30 server ticks/s, removing these
// spins cut CPU power from 23.7 W to about 11 W (docs/dev/performance.md):
// - An idle worker polls the job queues for 500 us before it sleeps.
// - The WorkerThreadScheduler thread yield-spins for 101 us after every wake,
//   which with frequent wakes kept a top-tier core 88% busy.
// - GameClock::CapFrame (the server's 30 Hz tick limiter and the client's frame
//   cap) fills each wait by running queued worker jobs and yield-spinning; the
//   server's tick needs about 9 ms of its 33 ms.
// - WorkerThreadBatch::WaitForCompletion yield-spins while another thread
//   finishes the batch.
namespace Native = BG3MFXBuild::ThreadIdling;

namespace {
// BG3 4.1.1.7631656.
// WorkerThreadWorker::DoWork, after a scan finds no job: `ldr x9, [x19, #0x28]`
// loads the spin budget in us (500 with more than 3 cores) compared with the
// time since the worker woke. Replaced by `mov x9, #0`: sleep at once.
const uintptr_t workerBudget = Native::WorkerBudget;
const uint32_t workerBudgetLoad = 0xf9401669, workerNoBudget = 0xd2800009;
// WorkerThreadScheduler::DoWork, twice: `mov w9, #0x8a87; movk w9, #0x1, lsl
// #16`, the 100999 ns yield window. Replaced by `mov w9, #0; nop`.
const uintptr_t schedulerWindows[2] = {Native::SchedulerWindowFirst, Native::SchedulerWindowSecond};
const uint32_t schedulerWindow[2] = {0x529150e9, 0x72a00029}, schedulerNoWindow[2] = {0x52800009, 0xd503201f};
// CapFrame, with more than 1 ms left, steals and runs a queued job or, when
// none is queued, `bl pthread_yield_np`; it re-checks the time every 0.5 ms and
// spins the last 1 ms. The yield becomes a 250 us sleep: the job stealing (which
// matters on Macs with few cores) and the precise 1 ms spin tail stay.
const uintptr_t capIdleYield = Native::CapIdleYield;
const uint32_t capIdleYieldCall = 0x944bed7f;
const uint64_t capIdleSleepUs = 250;
// WaitForCompletion(help), while the batch has jobs (x19 = batch): runs its own
// and stolen jobs, and when there is none `bl pthread_yield_np`, then re-checks.
// Waiters without help take its blocking path instead, which flags a waiter and
// sleeps on the batch's completion event (signalled by the last job). The yield
// now continues for at most 50 us of a wait, then takes the blocking path.
const uintptr_t waitYield = Native::WaitYield, waitResume = Native::WaitResume, waitBlock = Native::WaitBlock;
const uint32_t waitYieldCall = 0x9449f05a, waitBlockEntry = 0xb9400668;
const uint64_t waitSpinUs = 50;
// Islands in the zero header padding, after the Temporal jitter islands.
const size_t waitIslandOffset = BG3MFXBuild::Islands::ThreadWait.offset, waitIslandBytes = BG3MFXBuild::Islands::ThreadWait.bytes,
    idleIslandOffset = BG3MFXBuild::Islands::ThreadIdle.offset, idleIslandBytes = BG3MFXBuild::Islands::ThreadIdle.bytes;

uint64_t usTicks;
#ifndef BG3MFX_NO_TRACE
// Diagnostics: the batch's completion event holds one semaphore handle, which
// each blocking waiter resets. A second waiter on the same batch would strand
// the first. BG3's own helpers rarely block; count the cases this patch adds.
void (*reportEvent)(NSDictionary *);
std::atomic<uint64_t> helperBlocks{0}, sharedBlocks{0};
void noteBlock(void *batch) {
    auto *flags = reinterpret_cast<std::atomic<uint32_t> *>(static_cast<char *>(batch) + Native::Layout::BatchFlags);
    uint32_t value = flags->load(std::memory_order_acquire);
    uint64_t blocks = ++helperBlocks;
    bool shared = (value & Native::Layout::BatchWaiter) && !(value & Native::Layout::BatchDone);
    uint64_t sharedCount = shared ? ++sharedBlocks : sharedBlocks.load();
    // Rare after the first few; report the first and then at powers of two.
    if (reportEvent && (shared ? !(sharedCount & (sharedCount - 1)) : !(blocks & (blocks - 1)))) {
        @autoreleasepool {
            reportEvent(@{@"event": @"threadIdlingBlock", @"helperBlocks": @(blocks),
                          @"sharedWaiterBlocks": @(sharedCount), @"shared": @(shared)});
        }
    }
}
#endif

void capIdle() {
    mach_wait_until(mach_absolute_time() + capIdleSleepUs * usTicks);
}

// Returns 1 to take the blocking path. One wait is a run of calls for the same
// batch less than 1 ms apart.
int waitOrYield(void *batch) {
    thread_local void *current;
    thread_local uint64_t first, previous;
    uint64_t now = mach_absolute_time();
    if (batch != current || now - previous > 1000 * usTicks) {
        current = batch;
        first = now;
    }
    previous = now;
    if (now - first >= waitSpinUs * usTicks) {
        current = nullptr;
#ifndef BG3MFX_NO_TRACE
        noteBlock(batch);
#endif
        return 1;
    }
    pthread_yield_np();
    return 0;
}

bool zero(uintptr_t address, size_t bytes) {
    for (size_t i = 0; i < bytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(address + i)) return false;
    return true;
}
}

BOOL BG3MFXInstallThreadIdling(intptr_t slide, void (*report)(NSDictionary *), NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXThreadIdling" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // NativeMenu has already checked the executable UUID; also check every
    // instruction replaced or branched to.
    uintptr_t worker = workerBudget + slide, idle = capIdleYield + slide, wait = waitYield + slide;
    if (*reinterpret_cast<const uint32_t *>(worker) != workerBudgetLoad) return fail(@"Unsupported worker idle loop.");
    for (uintptr_t site : schedulerWindows)
        if (memcmp(reinterpret_cast<const void *>(site + slide), schedulerWindow, sizeof schedulerWindow) != 0)
            return fail(@"Unsupported scheduler idle loop.");
    if (*reinterpret_cast<const uint32_t *>(idle) != capIdleYieldCall) return fail(@"Unsupported frame limiter.");
    if (*reinterpret_cast<const uint32_t *>(wait) != waitYieldCall || *reinterpret_cast<const uint32_t *>(waitBlock + slide) != waitBlockEntry)
        return fail(@"Unsupported batch wait.");
    uintptr_t waitIsland = BG3MFXBuild::HeaderPadding + slide + waitIslandOffset, idleIsland = BG3MFXBuild::HeaderPadding + slide + idleIslandOffset;
    if (!zero(waitIsland, waitIslandBytes) || !zero(idleIsland, idleIslandBytes)) return fail(@"Thread idling island space is in use.");
    if (!BG3MFXBranchReaches(idle, idleIsland) || !BG3MFXBranchReaches(wait, waitIsland) ||
        !BG3MFXBranchReaches(waitIsland + 16, waitBlock + slide) || !BG3MFXBranchReaches(waitIsland + 20, waitResume + slide))
        return fail(@"Thread idling islands are out of range.");
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    usTicks = 1000ull * timebase.denom / timebase.numer;
#ifndef BG3MFX_NO_TRACE
    reportEvent = report;
#endif
    auto result = BG3MFXPatchCode({{waitIsland, waitIslandBytes}, {idleIsland, idleIslandBytes}, {worker, 4},
                                   {schedulerWindows[0] + slide, 8}, {schedulerWindows[1] + slide, 8}, {idle, 4}, {wait, 4}}, [&] {
        // ldr x16, #8; br x16; .quad capIdle (CapFrame's BL returns past it)
        uint32_t idleCode[4] = {0x58000050, 0xd61f0200, 0, 0};
        uintptr_t idleHook = reinterpret_cast<uintptr_t>(capIdle);
        memcpy(idleCode + 2, &idleHook, 8);
        memcpy(reinterpret_cast<void *>(idleIsland), idleCode, sizeof idleCode);
        // mov x0, x19; ldr x16, #20 (the literal at +24, from this +4);
        // blr x16; cbz w0, #8; b <block>; b <resume>; .quad waitOrYield
        uint32_t waitCode[8] = {0xaa1303e0, 0x580000b0, 0xd63f0200, 0x34000040,
            BG3MFXBranch(waitIsland + 16, waitBlock + slide), BG3MFXBranch(waitIsland + 20, waitResume + slide), 0, 0};
        uintptr_t waitHook = reinterpret_cast<uintptr_t>(waitOrYield);
        memcpy(waitCode + 6, &waitHook, 8);
        memcpy(reinterpret_cast<void *>(waitIsland), waitCode, sizeof waitCode);
        sys_icache_invalidate(reinterpret_cast<void *>(waitIsland), waitIslandBytes);
        sys_icache_invalidate(reinterpret_cast<void *>(idleIsland), idleIslandBytes);
        memcpy(reinterpret_cast<void *>(worker), &workerNoBudget, 4);
        for (uintptr_t site : schedulerWindows) memcpy(reinterpret_cast<void *>(site + slide), schedulerNoWindow, sizeof schedulerNoWindow);
        uint32_t toIdle = 0x94000000 | (BG3MFXBranch(idle, idleIsland) & 0x03ffffff), toWait = BG3MFXBranch(wait, waitIsland);
        memcpy(reinterpret_cast<void *>(idle), &toIdle, 4);
        memcpy(reinterpret_cast<void *>(wait), &toWait, 4);
    });
    if (result == BG3MFXCodePatchResult::NotWritable) return fail(@"Could not make the idle loops writable.");
    // Written but not executable again: report it as installed, not skipped.
    if (report) report(@{@"event": @"threadIdlingInstalled", @"protectionRestored": @(result == BG3MFXCodePatchResult::Patched)});
    return YES;
}
