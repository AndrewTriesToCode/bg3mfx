// Synthetic model of BG3's per-frame uniform allocator (MetalRenderer +0x8
// os_unfair_lock guarding a 16-byte-aligned bump offset at +0x2090; see
// docs/dev/performance.md). Worker threads record "draws": each draw spins for
// a set amount of work and allocates its constants. Modes:
//   locked  every allocation takes the shared lock, as BG3's inlined sites do.
//   chunked "hot" allocations come from a per-thread slice reserved through the
//           same lock; a share of "cold" allocations still use the locked path,
//           as BG3's other ~128 sites would.
//   none    no shared allocator (each thread bumps its own counter): the floor
//           for the model's own overhead; its overlap check is skipped.
// Every allocation is recorded and checked for 16-byte alignment and overlap
// at each frame end; the frame's peak offset shows the slices' waste.
// Results are synthetic: they model the pattern, not BG3's real draw mix.
//
// uniform_lock_sim MODE THREADS DRAWS_PER_FRAME WORK_NS [FRAMES] [COLD_PERCENT] [CHUNK_BYTES] [FPS_CAP]
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <time.h>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

namespace {
struct Renderer {
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    uint64_t offset = 0;
};
Renderer renderer;
std::atomic<uint64_t> generation{0}, lockTakes{0}, lockContended{0};

// BG3's inlined sequence: lock; align up to 16; bump; unlock. The trylock
// only counts contention; os_unfair_lock_lock starts with the same attempt.
uint64_t allocLocked(uint64_t size) {
    ++lockTakes;
    if (!os_unfair_lock_trylock(&renderer.lock)) {
        ++lockContended;
        os_unfair_lock_lock(&renderer.lock);
    }
    uint64_t at = (renderer.offset + 15) & ~uint64_t(15);
    renderer.offset = at + size;
    os_unfair_lock_unlock(&renderer.lock);
    return at;
}

uint64_t chunkBytes = 16384;
struct Slice { uint64_t generation = ~0ull, next = 0, end = 0; };
thread_local Slice slice;
std::atomic<uint64_t> sliceRefills{0};

// A per-thread slice of the same buffer, reserved through BG3's protocol and
// dropped when BeginFrame starts a new generation.
uint64_t allocChunked(uint64_t size) {
    uint64_t gen = generation.load(std::memory_order_acquire);
    uint64_t at = (slice.next + 15) & ~uint64_t(15);
    if (slice.generation != gen || at + size > slice.end) {
        uint64_t bytes = std::max(chunkBytes, (size + 15) & ~uint64_t(15));
        at = allocLocked(bytes);
        slice = {gen, at, at + bytes};
        ++sliceRefills;
    }
    slice.next = at + size;
    return at;
}

void work(uint64_t ns, uint64_t ticksPerUs) {
    uint64_t end = mach_absolute_time() + ns * ticksPerUs / 1000;
    while (mach_absolute_time() < end) {}
}

uint64_t threadCpuNs() { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s locked|chunked|none THREADS DRAWS_PER_FRAME WORK_NS [FRAMES] [COLD_PERCENT] [CHUNK_BYTES] [FPS_CAP]\n", argv[0]);
        return 2;
    }
    const bool chunked = strcmp(argv[1], "chunked") == 0, none = strcmp(argv[1], "none") == 0;
    const int threads = atoi(argv[2]);
    const int draws = atoi(argv[3]);
    const uint64_t workNs = strtoull(argv[4], nullptr, 10);
    const int frames = argc > 5 ? atoi(argv[5]) : 300;
    const int coldPercent = argc > 6 ? atoi(argv[6]) : 10;
    if (argc > 7) chunkBytes = strtoull(argv[7], nullptr, 10);
    const double fpsCap = argc > 8 ? atof(argv[8]) : 0;

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    const uint64_t ticksPerUs = 1000ull * timebase.denom / timebase.numer;

    // Constant buffer sizes like a material's cbuffer: 64-512 bytes in 16s,
    // and draw work from 0.25x to 1.75x WORK_NS, fixed per draw so both modes
    // run the same sequence.
    std::vector<uint32_t> sizes(draws), drawNs(draws);
    std::vector<uint8_t> cold(draws);
    uint32_t seed = 12345;
    for (int i = 0; i < draws; ++i) {
        seed = seed * 1664525 + 1013904223;
        sizes[i] = 64 + ((seed >> 8) % 29) * 16;
        cold[i] = static_cast<int>((seed >> 20) % 100) < coldPercent;
        seed = seed * 1664525 + 1013904223;
        drawNs[i] = static_cast<uint32_t>(workNs * (25 + (seed >> 8) % 151) / 100);
    }

    struct Record { uint64_t at, size; };
    std::vector<std::vector<Record>> records(threads);
    std::atomic<int> nextDraw{0};
    std::atomic<bool> quit{false};
    std::atomic<uint64_t> workerCpuNs{0};
    // Workers block between frames, as BG3's sleep once idle.
    dispatch_semaphore_t go = dispatch_semaphore_create(0), finished = dispatch_semaphore_create(0);

    std::vector<std::thread> pool;
    for (int t = 0; t < threads; ++t) {
        pool.emplace_back([&, t] {
            pthread_setname_np("sim-worker");
            for (;;) {
                dispatch_semaphore_wait(go, DISPATCH_TIME_FOREVER);
                if (quit.load()) return;
                uint64_t cpu0 = threadCpuNs();
                for (int i; (i = nextDraw.fetch_add(1)) < draws;) {
                    work(drawNs[i], ticksPerUs);
                    thread_local uint64_t own;
                    uint64_t at = none ? (own += 512) : chunked && !cold[i] ? allocChunked(sizes[i]) : allocLocked(sizes[i]);
                    records[t].push_back({at, sizes[i]});
                }
                workerCpuNs += threadCpuNs() - cpu0;
                dispatch_semaphore_signal(finished);
            }
        });
    }

    uint64_t wall0 = mach_absolute_time(), busyTicks = 0, peakOffset = 0, totalBytes = 0, errors = 0;
    for (int f = 0; f < frames; ++f) {
        uint64_t start = mach_absolute_time();
        // BeginFrame: zero the offset and start a new slice generation.
        renderer.offset = 0;
        generation.fetch_add(1, std::memory_order_release);
        for (auto &r : records) r.clear();
        nextDraw.store(0);
        for (int t = 0; t < threads; ++t) dispatch_semaphore_signal(go);
        for (int t = 0; t < threads; ++t) dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
        uint64_t end = mach_absolute_time();
        busyTicks += end - start;

        std::vector<Record> all;
        for (auto &r : records) all.insert(all.end(), r.begin(), r.end());
        std::sort(all.begin(), all.end(), [](const Record &a, const Record &b) { return a.at < b.at; });
        for (size_t i = 0; i < all.size() && !none; ++i) {
            if (all[i].at % 16) ++errors;
            if (i && all[i - 1].at + all[i - 1].size > all[i].at) ++errors;
            totalBytes += all[i].size;
        }
        if (all.size() != static_cast<size_t>(draws)) ++errors;
        peakOffset = std::max(peakOffset, renderer.offset);
        if (fpsCap > 0) {
            uint64_t target = start + static_cast<uint64_t>(1e6 / fpsCap) * ticksPerUs;
            mach_wait_until(target);
        }
    }
    uint64_t wallTicks = mach_absolute_time() - wall0;
    quit.store(true);
    for (int t = 0; t < threads; ++t) dispatch_semaphore_signal(go);
    for (auto &t : pool) t.join();

    double wall = static_cast<double>(wallTicks) / ticksPerUs / 1e6;
    double frameMs = static_cast<double>(busyTicks) / ticksPerUs / 1000 / frames;
    double cpu = workerCpuNs.load() / 1e9;
    // Lower bound on worker CPU: the draw work alone.
    double workCpu = 0;
    for (uint32_t ns : drawNs) workCpu += ns;
    workCpu *= frames / 1e9;
    printf("%-7s threads %2d draws %5d work %4llu ns cold %2d%%: frame %6.3f ms  workers %4.0f%% cpu (%4.1f%% over work)  "
           "locks/frame %6.0f contended %4.1f%%  peak %7llu B (data %llu)  errors %llu\n",
           argv[1], threads, draws, static_cast<unsigned long long>(workNs), coldPercent, frameMs,
           100 * cpu / wall, 100 * (cpu - workCpu) / cpu, static_cast<double>(lockTakes.load()) / frames,
           lockTakes ? 100.0 * lockContended.load() / lockTakes.load() : 0.0, static_cast<unsigned long long>(peakOffset),
           static_cast<unsigned long long>(totalBytes / frames), static_cast<unsigned long long>(errors));
    return errors ? 1 : 0;
}
