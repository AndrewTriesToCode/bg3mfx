#include "common/native/SupportedBuild.h"
#import "features/thread-idling/ThreadIdling.h"
#include "common/native/CodePatch.h"
#include <libkern/OSCacheControl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <vector>

// BG3 spends most of its idle CPU time spinning rather than sleeping. In Lower
// City at the same frame rate and a steady 30 server ticks/s, removing these
// spins cut CPU power from 23.7 W to about 11 W (docs/dev/performance.md):
// - An idle worker polls the job queues for 500 us before it sleeps.
// - The WorkerThreadScheduler thread yield-spins for 101 us after every wake,
//   which with frequent wakes kept a top-tier core 88% busy.
// - GameClock::CapFrame (the server's 30 Hz tick limiter and the client's frame
//   cap) fills each wait by running queued worker jobs and yield-spinning; the
//   server's tick needs about 9 ms of its 33 ms.
// Workers and the scheduler now sleep at once: in an uncapped CPU-bound sweep,
// 50 us worker or 101 us scheduler polls cost CPU without measurable fps. The
// poll, CapFrame step and margin are tunable for measurement
// (BG3MFX_WORKER_POLL_US, BG3MFX_SCHEDULER_POLL_US, BG3MFX_CAPFRAME_POLL_US,
// BG3MFX_CAPFRAME_MARGIN_US).
namespace Native = BG3MFXBuild::ThreadIdling;

namespace {
// BG3 4.1.1.7631656.
// WorkerThreadWorker::DoWork, after a scan finds no job: `ldr x9, [x19, #0x28]`
// loads the spin budget in us (500 with more than 3 cores) compared with the
// time since the worker woke. Replaced by `mov x9, #budget` (0: sleep at once).
const uintptr_t workerBudget = Native::WorkerBudget;
const uint32_t workerBudgetLoad = 0xf9401669, workerBudgetMov = 0xd2800009;
// WorkerThreadScheduler::DoWork, twice: `mov w9, #0x8a87; movk w9, #0x1, lsl
// #16`, the 100999 ns yield window. Replaced by the chosen window (0: `mov w9,
// #0; nop`).
const uintptr_t schedulerWindows[2] = {Native::SchedulerWindowFirst, Native::SchedulerWindowSecond};
const uint32_t schedulerWindow[2] = {0x529150e9, 0x72a00029}, schedulerWindowMov = 0x52800009,
    schedulerWindowMovk = 0x72a00009, nop = 0xd503201f;
// CapFrame, with more than 1 ms left, steals and runs a queued job or, when
// none is queued, `bl pthread_yield_np`; it re-checks the time every 0.5 ms and
// spins the last 1 ms. The yield becomes a 250 us sleep, so job stealing (which
// matters on Macs with few workers) continues between steps, until the next
// step would land in that tail; then it sleeps until 200 us before the
// deadline, so the tail spins only that margin. A poll of 0 sleeps there at
// once. The wait target is the `csel x27, x8, xzr, gt` result (us from the
// clock's start).
const uintptr_t capIdleYield = Native::CapIdleYield, capTargetSelect = Native::CapTargetSelect;
const uint32_t capIdleYieldCall = 0x944bed7f, capTargetSelectWord = 0x9a9fc11b;
const uint64_t capTailUs = 1000;
// WorkerThreadBatch::WaitForCompletion stays BG3's: its completion event holds
// one semaphore that each blocking waiter resets, so sending helpers to its
// blocking path could strand a waiter or leak the semaphore.
// The idle island is in the zero header padding, after the Temporal jitter
// islands.
const size_t idleIslandOffset = BG3MFXBuild::Islands::ThreadIdle.offset, idleIslandBytes = BG3MFXBuild::Islands::ThreadIdle.bytes;

uint64_t usTicks;
// CapFrame poll step and margin in ticks.
uint64_t capPollTicks, capMarginTicks;
#ifndef BG3MFX_NO_TRACE
void (*reportEvent)(NSDictionary *);
// How late CapFrame's deadline sleeps wake, to choose the margin: counts per
// bucket (<25, <50, <100, <200, <500, >=500 us) and the maximum.
std::atomic<uint64_t> lateBuckets[6], lateMaxUs{0}, capSleeps{0};
void noteWake(uint64_t lateTicks) {
    uint64_t us = lateTicks / usTicks;
    const uint64_t limits[5] = {25, 50, 100, 200, 500};
    unsigned bucket = 0;
    while (bucket < 5 && us >= limits[bucket]) ++bucket;
    ++lateBuckets[bucket];
    for (uint64_t max = lateMaxUs.load(); us > max && !lateMaxUs.compare_exchange_weak(max, us);) {}
    uint64_t sleeps = ++capSleeps;
    if (reportEvent && !(sleeps & (sleeps - 1)) && sleeps >= 1024) {
        @autoreleasepool {
            reportEvent(@{@"event": @"capFrameWakeLateness", @"sleeps": @(sleeps), @"maxUs": @(lateMaxUs.load()),
                          @"under25": @(lateBuckets[0].load()), @"under50": @(lateBuckets[1].load()),
                          @"under100": @(lateBuckets[2].load()), @"under200": @(lateBuckets[3].load()),
                          @"under500": @(lateBuckets[4].load()), @"over500": @(lateBuckets[5].load())});
        }
    }
}
#endif

// Called in place of CapFrame's idle yield with the clock and its wait target.
void capIdle(const char *clock, int64_t targetUs) {
    uint64_t now = mach_absolute_time();
    if (!*reinterpret_cast<const uint8_t *>(clock + Native::Layout::ClockStarted)) {
        if (capPollTicks) mach_wait_until(now + capPollTicks);
        else pthread_yield_np();
        return;
    }
    uint64_t deadline = *reinterpret_cast<const uint64_t *>(clock + Native::Layout::ClockStart) +
        static_cast<uint64_t>(targetUs) * usTicks;
    // Another poll step, while CapFrame would still check for jobs after it.
    if (capPollTicks && static_cast<int64_t>(deadline - now) > static_cast<int64_t>((capTailUs * usTicks) + capPollTicks)) {
        mach_wait_until(now + capPollTicks);
        return;
    }
    uint64_t wake = deadline - capMarginTicks;
    // Within the margin already (only reachable with a margin above 1 ms):
    // keep BG3's yield until its tail takes over.
    if (static_cast<int64_t>(wake - now) <= 0) {
        pthread_yield_np();
        return;
    }
    mach_wait_until(wake);
#ifndef BG3MFX_NO_TRACE
    noteWake(mach_absolute_time() - wake);
#endif
}

bool zero(uintptr_t address, size_t bytes) {
    for (size_t i = 0; i < bytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(address + i)) return false;
    return true;
}

// A whole-number setting in us, or the fallback when unset or out of range.
uint64_t setting(const char *name, uint64_t fallback, uint64_t maximum) {
    const char *value = getenv(name);
    if (!value || !*value) return fallback;
    char *end = nullptr;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (*end || parsed > maximum) return fallback;
    return parsed;
}
}

BOOL BG3MFXInstallThreadIdling(intptr_t slide, void (*report)(NSDictionary *), NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXThreadIdling" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // The worker budget is a 16-bit immediate; the scheduler window is in ns
    // and is kept under 1 ms; the CapFrame margin is kept under 1 s.
    const uint64_t workerPollUs = setting("BG3MFX_WORKER_POLL_US", 0, 0xffff);
    const uint64_t schedulerPollUs = setting("BG3MFX_SCHEDULER_POLL_US", 0, 1000);
    const uint64_t capMarginUs = setting("BG3MFX_CAPFRAME_MARGIN_US", 200, 1000000);
    // A step must leave CapFrame inside its 1 ms job-check window or past it.
    const uint64_t capPollUs = setting("BG3MFX_CAPFRAME_POLL_US", 250, 1000);
    // NativeMenu has already checked the executable UUID; also check every
    // instruction replaced or branched to.
    uintptr_t worker = workerBudget + slide, idle = capIdleYield + slide;
    if (*reinterpret_cast<const uint32_t *>(worker) != workerBudgetLoad) return fail(@"Unsupported worker idle loop.");
    for (uintptr_t site : schedulerWindows)
        if (memcmp(reinterpret_cast<const void *>(site + slide), schedulerWindow, sizeof schedulerWindow) != 0)
            return fail(@"Unsupported scheduler idle loop.");
    if (*reinterpret_cast<const uint32_t *>(idle) != capIdleYieldCall ||
        *reinterpret_cast<const uint32_t *>(capTargetSelect + slide) != capTargetSelectWord)
        return fail(@"Unsupported frame limiter.");
    uintptr_t idleIsland = BG3MFXBuild::HeaderPadding + slide + idleIslandOffset;
    if (!zero(idleIsland, idleIslandBytes)) return fail(@"Thread idling island space is in use.");
    if (!BG3MFXBranchReaches(idle, idleIsland)) return fail(@"Thread idling island is out of range.");
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    usTicks = 1000ull * timebase.denom / timebase.numer;
    capMarginTicks = capMarginUs * usTicks;
    capPollTicks = capPollUs * usTicks;
#ifndef BG3MFX_NO_TRACE
    reportEvent = report;
#endif
    std::vector<std::pair<uintptr_t, size_t>> ranges = {{idleIsland, idleIslandBytes}, {worker, 4},
        {schedulerWindows[0] + slide, 8}, {schedulerWindows[1] + slide, 8}, {idle, 4}};
    auto result = BG3MFXPatchCode(ranges, [&] {
        // mov x0, x19 (the clock); mov x1, x27 (the wait target);
        // ldr x16, #8; br x16; .quad capIdle (CapFrame's BL returns past it)
        uint32_t idleCode[6] = {0xaa1303e0, 0xaa1b03e1, 0x58000050, 0xd61f0200, 0, 0};
        uintptr_t idleHook = reinterpret_cast<uintptr_t>(capIdle);
        memcpy(idleCode + 4, &idleHook, 8);
        memcpy(reinterpret_cast<void *>(idleIsland), idleCode, sizeof idleCode);
        sys_icache_invalidate(reinterpret_cast<void *>(idleIsland), idleIslandBytes);
        uint32_t budget = workerBudgetMov | static_cast<uint32_t>(workerPollUs) << 5;
        memcpy(reinterpret_cast<void *>(worker), &budget, 4);
        uint32_t windowNs = static_cast<uint32_t>(schedulerPollUs * 1000);
        uint32_t window[2] = {schedulerWindowMov | (windowNs & 0xffff) << 5,
                              windowNs >> 16 ? schedulerWindowMovk | (windowNs >> 16) << 5 : nop};
        for (uintptr_t site : schedulerWindows) memcpy(reinterpret_cast<void *>(site + slide), window, sizeof window);
        uint32_t toIdle = 0x94000000 | (BG3MFXBranch(idle, idleIsland) & 0x03ffffff);
        memcpy(reinterpret_cast<void *>(idle), &toIdle, 4);
    });
    if (result == BG3MFXCodePatchResult::NotWritable) return fail(@"Could not make the idle loops writable.");
    // Written but not executable again: report it as installed, not skipped.
    if (report) report(@{@"event": @"threadIdlingInstalled", @"protectionRestored": @(result == BG3MFXCodePatchResult::Patched),
                         @"workerPollUs": @(workerPollUs), @"schedulerPollUs": @(schedulerPollUs),
                         @"capFramePollUs": @(capPollUs), @"capFrameMarginUs": @(capMarginUs)});
    return YES;
}
