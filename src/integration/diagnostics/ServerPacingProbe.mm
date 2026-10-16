#include "common/native/SupportedBuild.h"
#import "integration/diagnostics/ServerPacingProbe.h"
#include "common/native/CodePatch.h"
#include <libkern/OSCacheControl.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <sys/time.h>
#include <time.h>
#include <algorithm>
#include <cstring>
#include <vector>

namespace Native = BG3MFXBuild::ServerPacing;
namespace Layout = BG3MFXBuild::ServerPacing::Layout;

namespace {
// BG3 4.1.1.7631656, ServerWorker::DoWork's tick (x19 = ServerWorker):
//   bl ls::Dispatcher::Process()             tick start
//   bl ecs::EntityWorld::Update(GameTime&)   entity systems
//   bl gettimeofday                          tick end: time stored at +0xc0
//   bl ls::GameClock::CapFrame(elapsed us)   limiter, at +0x80; target +0x98
// The limiter is also reached from the top of the loop when a tick is due
// later (no tick runs on that pass).
enum Site { TickStart, World, TickEnd, Cap, Sites };
const uintptr_t sites[Sites] = {Native::TickStart, Native::World, Native::TickEnd, Native::Cap};
const uintptr_t targets[Sites] = {Native::ProcessTarget, Native::WorldTarget, Native::GettimeofdayTarget, Native::CapTarget};
const size_t islandOffset = BG3MFXBuild::Islands::ServerPacing.offset, islandStride = BG3MFXBuild::Islands::ServerPacing.bytes / Sites;

void (*originalProcess)(void *);
void (*originalWorld)(void *, const void *);
int (*originalGettimeofday)(timeval *, void *);
void (*originalCap)(void *, uint64_t);
double ticksToMs;

// Server thread only.
uint8_t *worker;
uint64_t windowStart, tickStart, lastTickStart, cpuStart;
bool inTick;
struct Window {
    unsigned ticks, capAfterTick, capEarly, buckets[6];
    double workMs, workMax, workMin = 1e9, cpuMs, worldMs, periodMs, periodMax, capMs, capElapsedMs, capRemainingMs;
} window;

double nowMs() { return mach_absolute_time() * ticksToMs; }

void flush(uint64_t now) {
    Window &w = window;
    double seconds = (now - windowStart) * ticksToMs / 1000;
    unsigned caps = w.capAfterTick + w.capEarly;
    os_log(os_log_create("com.bg3mfx", "pacing"),
        "bg3mfx pacing: %.1f ticks/s | period %.2f max %.2f ms | work %.2f (min %.2f max %.2f) ms, cpu %.2f ms, world %.2f ms | "
        "cap after-tick %u early %u, %.3f ms/tick inside, elapsed arg %.2f ms, remaining %.2f ms | "
        "work <25:%u 25-30:%u 30-32:%u 32-33:%u 33-33.4:%u >33.4:%u | target %lld us debt %lld us",
        w.ticks / seconds, w.periodMs / std::max(1u, w.ticks - 1), w.periodMax,
        w.workMs / w.ticks, w.workMin, w.workMax, w.cpuMs / w.ticks, w.worldMs / w.ticks,
        w.capAfterTick, w.capEarly, w.capMs / w.ticks, caps ? w.capElapsedMs / caps : 0, caps ? w.capRemainingMs / caps : 0,
        w.buckets[0], w.buckets[1], w.buckets[2], w.buckets[3], w.buckets[4], w.buckets[5],
        *reinterpret_cast<int64_t *>(worker + Layout::WorkerTarget), *reinterpret_cast<int64_t *>(worker + Layout::WorkerDebt));
    window = Window();
    windowStart = now;
}

void tickStartHook(void *dispatcher, uint8_t *serverWorker) {
    uint64_t now = mach_absolute_time();
    worker = serverWorker;
    if (!windowStart) windowStart = now;
    if (lastTickStart) {
        double period = (now - lastTickStart) * ticksToMs;
        window.periodMs += period;
        window.periodMax = std::max(window.periodMax, period);
    }
    if (window.ticks && (now - windowStart) * ticksToMs >= 2000) flush(now);
    lastTickStart = tickStart = now;
    cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    inTick = true;
    originalProcess(dispatcher);
}

void worldHook(void *world, const void *time) {
    double start = nowMs();
    originalWorld(world, time);
    window.worldMs += nowMs() - start;
}

int tickEndHook(timeval *tv, void *tz) {
    uint64_t now = mach_absolute_time();
    if (inTick) {
        double work = (now - tickStart) * ticksToMs;
        window.workMs += work;
        window.workMin = std::min(window.workMin, work);
        window.workMax = std::max(window.workMax, work);
        window.cpuMs += (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6;
        static const double edges[] = {25, 30, 32, 33, 33.4};
        unsigned bucket = 0;
        while (bucket < 5 && work >= edges[bucket]) ++bucket;
        ++window.buckets[bucket];
        ++window.ticks;
    }
    return originalGettimeofday(tv, tz);
}

void capHook(uint8_t *clock, uint64_t elapsedUs) {
    // CapFrame waits target(+0x18) - (debt(+0x28) + elapsed).
    int64_t remaining = *reinterpret_cast<int64_t *>(clock + Layout::Target) - (*reinterpret_cast<int64_t *>(clock + Layout::Debt) + (int64_t)elapsedUs);
    (inTick ? window.capAfterTick : window.capEarly)++;
    inTick = false;
    window.capElapsedMs += elapsedUs / 1000.0;
    window.capRemainingMs += remaining / 1000.0;
    double start = nowMs();
    originalCap(clock, elapsedUs);
    window.capMs += nowMs() - start;
}

uintptr_t branchTarget(uintptr_t site, uint32_t word) {
    int32_t imm = (int32_t)(word << 6) >> 6;
    return site + (intptr_t)imm * 4;
}
}

BOOL BG3MFXInstallServerPacingProbe(intptr_t slide, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXServerPacingProbe" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    for (unsigned i = 0; i < Sites; ++i) {
        uintptr_t site = sites[i] + slide;
        uint32_t word = *reinterpret_cast<const uint32_t *>(site);
        if ((word & 0xfc000000) != 0x94000000 || branchTarget(site, word) != targets[i] + slide)
            return fail(@"Unsupported server tick call site.");
    }
    uintptr_t island = BG3MFXBuild::HeaderPadding + slide + islandOffset;
    for (size_t i = 0; i < Sites * islandStride; ++i)
        if (*reinterpret_cast<const uint8_t *>(island + i)) return fail(@"Server pacing island space is in use.");
    std::vector<std::pair<uintptr_t, size_t>> ranges = {{island, Sites * islandStride}};
    for (unsigned i = 0; i < Sites; ++i) {
        if (!BG3MFXBranchReaches(sites[i] + slide, island + i * islandStride)) return fail(@"Server pacing islands are out of range.");
        ranges.push_back({sites[i] + slide, 4});
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    ticksToMs = (double)timebase.numer / timebase.denom / 1e6;
    originalProcess = reinterpret_cast<void (*)(void *)>(targets[TickStart] + slide);
    originalWorld = reinterpret_cast<void (*)(void *, const void *)>(targets[World] + slide);
    originalGettimeofday = &gettimeofday;
    originalCap = reinterpret_cast<void (*)(void *, uint64_t)>(targets[Cap] + slide);
    const uintptr_t hooks[Sites] = {reinterpret_cast<uintptr_t>(tickStartHook), reinterpret_cast<uintptr_t>(worldHook),
        reinterpret_cast<uintptr_t>(tickEndHook), reinterpret_cast<uintptr_t>(capHook)};
    auto result = BG3MFXPatchCode(ranges, [&] {
        for (unsigned i = 0; i < Sites; ++i) {
            // TickStart passes the ServerWorker: mov x1, x19. Then
            // ldr x16, #12; br x16; nop; .quad hook
            uint32_t code[6] = {i == TickStart ? 0xaa1303e1u : 0xd503201fu, 0x58000070, 0xd61f0200, 0xd503201f, 0, 0};
            memcpy(code + 4, &hooks[i], 8);
            memcpy(reinterpret_cast<void *>(island + i * islandStride), code, sizeof code);
        }
        sys_icache_invalidate(reinterpret_cast<void *>(island), Sites * islandStride);
        for (unsigned i = 0; i < Sites; ++i) {
            uintptr_t site = sites[i] + slide;
            uint32_t call = 0x94000000 | (BG3MFXBranch(site, island + i * islandStride) & 0x03ffffff);
            memcpy(reinterpret_cast<void *>(site), &call, 4);
        }
    });
    if (result != BG3MFXCodePatchResult::Patched) return fail(@"Could not install the server pacing probe.");
    os_log(os_log_create("com.bg3mfx", "pacing"), "bg3mfx pacing: probe installed");
    return YES;
}
