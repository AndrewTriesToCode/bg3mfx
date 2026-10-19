#import "features/dynamic-worker-prioritization/DynamicWorkers.h"
#import <AppKit/AppKit.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <sys/resource.h>
#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <thread>
#include <unistd.h>

std::atomic<uint64_t> BG3MFXRenderedFrames{0};

// BG3 gives its WT/High worker threads (render and game jobs) and the
// WorkerThreadScheduler hand-set priorities and no QoS, so macOS runs them on
// the top-tier cores. In Darwin background they run on the lower tier at lower
// clocks: in Lower City that cut CPU power from about 11 W to 7.4 W at the same
// frame rate, but where frames were CPU-bound on these workers it cost 6-25%
// (docs/dev/performance.md). So placement is decided live by frame rate trials (below).
//
// Every other thread keeps BG3's placement. The WT/Low workers (streaming,
// loading) used little CPU and, in background, delayed dialogue lines: Darwin
// background also throttles disk reads. The server's sleeping limiter wakes
// late in background and misses ticks.
//
// QoS changes fail with EPERM on these threads and Darwin background can only
// be set by a thread for itself, so each applies the current placement the next
// time it blocks in semaphore_wait or semaphore_timedwait (BG3's WaitEvent and
// the scheduler use them).
namespace {
std::atomic<bool> installed{false}, inBackground{false};
std::atomic<uint32_t> generation{1};
uint64_t msTicks;

void report(const char *format, ...) __attribute__((format(printf, 1, 2)));
void report(const char *format, ...) {
    char text[256];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    static os_log_t log = os_log_create("com.bg3mfx", "threads");
    os_log(log, "bg3mfx dynamic workers: %{public}s", text);
}

void setBackground(bool on) {
    if (inBackground.exchange(on) != on) generation.fetch_add(1);
}

// An unnamed thread may be named later, so it is rechecked, but only once per
// placement change rather than on every wait.
bool managedThread(uint32_t current) {
    thread_local int managed = -1;
    thread_local uint32_t unnamedAt;
    if (managed < 0) {
        if (unnamedAt == current) return false;
        char name[64] = {};
        pthread_getname_np(pthread_self(), name, sizeof name);
        if (!name[0]) { unnamedAt = current; return false; }  // not named yet
        managed = !strncmp(name, "WT/High/", 8) || !strcmp(name, "WorkerThreadScheduler");
    }
    return managed;
}

void applyPlacement() {
    if (!installed.load(std::memory_order_relaxed)) return;
    thread_local uint32_t seen;
    thread_local int placed = -1;
    uint32_t current = generation.load(std::memory_order_relaxed);
    if (current == seen || !managedThread(current)) return;
    seen = current;
    int wanted = inBackground.load(std::memory_order_relaxed);
    if (wanted == placed) return;
    setpriority(PRIO_DARWIN_THREAD, 0, wanted ? PRIO_DARWIN_BG : 0);
    placed = wanted;
}

kern_return_t semaphoreWait(semaphore_t semaphore) {
    applyPlacement();
    return semaphore_wait(semaphore);
}

kern_return_t semaphoreTimedWait(semaphore_t semaphore, mach_timespec_t timeout) {
    applyPlacement();
    return semaphore_timedwait(semaphore, timeout);
}

// Calls from this library reach the originals.
__attribute__((used, section("__DATA,__interpose"))) const struct {
    const void *replacement, *replacee;
} interposers[] = {{(const void *)&semaphoreWait, (const void *)&semaphore_wait},
                   {(const void *)&semaphoreTimedWait, (const void *)&semaphore_timedwait}};

// The frame threads wait on these workers 12-14% of the time even at normal
// priority, so waiting is no signal; frame rate is. A trial alternates normal /
// background / normal / background in 1 s windows (the first 250 ms of each
// ignored) and keeps background if its frame rate is within 5% of normal: trial
// noise is about 2%, the real costs seen were 6-25%, and a few percent of frame
// rate is worth the power. With a frame cap or vsync both sides reach the cap,
// so background wins. Trials repeat after 30 s while background wins and back
// off (to 60 s) while normal wins. In background, a frame rate more
// than 15% below the trial's returns the workers to normal at once, until the
// next trial.
struct {
    bool active;
    unsigned tick, checkTicks;
    uint64_t frames[2], ticks[2], nextTrial, backoffMs = 30000, lastFrames, checkFrames;
    double trialFps;
} trial;

void tick(uint64_t now) {
    uint64_t frames = BG3MFXRenderedFrames.load(std::memory_order_relaxed), delta = frames - trial.lastFrames;
    trial.lastFrames = frames;
    if (!delta) return;  // menus, loading, or not rendering
    // macOS throttles BG3 when it is not the active app; those frame rates say
    // nothing about the workers. Abandon a running trial at normal; otherwise
    // keep the current placement (background saves power while inactive).
    if (!NSRunningApplication.currentApplication.active) {
        if (trial.active) {
            trial.active = false;
            trial.nextTrial = now + 5000 * msTicks;
            setBackground(false);
        }
        trial.checkFrames = trial.checkTicks = 0;
        return;
    }
    if (!trial.active && now >= trial.nextTrial) {
        trial.active = true;
        trial.tick = 0;
        trial.frames[0] = trial.frames[1] = trial.ticks[0] = trial.ticks[1] = 0;
        setBackground(false);
        return;
    }
    if (trial.active) {
        unsigned window = trial.tick / 4;
        bool normal = window % 2 == 0;
        if (trial.tick % 4) {
            trial.frames[!normal] += delta;
            ++trial.ticks[!normal];
        }
        if (++trial.tick % 4 == 0 && trial.tick < 16) setBackground(normal);
        if (trial.tick < 16) return;
        trial.active = false;
        double fpsNormal = trial.frames[0] * 4.0 / std::max<uint64_t>(trial.ticks[0], 1),
               fpsBackground = trial.frames[1] * 4.0 / std::max<uint64_t>(trial.ticks[1], 1);
        bool background = fpsBackground >= fpsNormal * 0.95;
        setBackground(background);
        trial.trialFps = background ? fpsBackground : fpsNormal;
        uint64_t holdMs = background ? 30000 : trial.backoffMs;
        trial.backoffMs = background ? 30000 : std::min<uint64_t>(trial.backoffMs * 2, 60000);
        trial.nextTrial = now + holdMs * msTicks;
        trial.checkFrames = trial.checkTicks = 0;
        report("trial: normal %.1f fps, background %.1f fps; %s for %llu s",
               fpsNormal, fpsBackground, background ? "background" : "normal", holdMs / 1000);
        return;
    }
    if (inBackground.load()) {
        trial.checkFrames += delta;
        if (++trial.checkTicks < 4) return;
        double fps = trial.checkFrames;
        trial.checkFrames = trial.checkTicks = 0;
        if (fps < trial.trialFps * 0.85) {
            setBackground(false);
            trial.nextTrial = now + 30000 * msTicks;
            report("normal: %.0f fps against %.1f fps in its trial; next trial in 30 s", fps, trial.trialFps);
        }
    }
}
}

BOOL BG3MFXInstallDynamicWorkers(void (*reportEvent)(NSDictionary *)) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    msTicks = 1000000ull * timebase.denom / timebase.numer;
    // Start in background; the first trial adjusts it.
    setBackground(true);
    installed = true;
    std::thread([] {
        for (;;) {
            usleep(250000);
            // This thread has no run loop; drain AppKit's autoreleases each tick.
            @autoreleasepool { tick(mach_absolute_time()); }
        }
    }).detach();
    if (reportEvent) reportEvent(@{@"event": @"dynamicWorkersInstalled"});
    return YES;
}
