#import "SubmitOpcodeProbe.h"
#include "CodePatch.h"
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <sys/syslimits.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <tuple>
#include <vector>

// Read by the opcode wrapper's fast path; written on the render thread.
extern "C" { uint8_t BG3MFXSubmitProbeRecording; }

namespace {
// BG3 4.1.1.7631656, rf::RendererCommandBuffer::Submit(bool, GPUFence *)
// (x0 = command buffer). Its replay loop aligns each record and dispatches on
// the opcode byte with `ldrb w9, [x28]; sub w8, w9, #3`; every record passes
// through that load (handlers return to 0x106429fe4, then 0x10642a02c).
const uintptr_t entrySite = 0x106429f40, opcodeSite = 0x10642a048;
const uint32_t entryInstruction = 0xd106c3ff, opcodeInstruction = 0x39400389, opcodeNext = 0x51000d28;
// Islands in the zero header padding, after the thread idling islands.
const size_t entryIslandOffset = 0xa00, opcodeIslandOffset = 0xa40, islandBytes = 40;
const double recordSeconds = 5;

// Records that begin a pass: compute (16), render subpass (17, pass index at
// +4), blit (19); and the end of a blit pass (20). Draws are 46-48 and compute
// dispatches 49.
bool beginsSegment(uint8_t op) { return op == 16 || op == 17 || op == 19 || op == 20; }
bool isWork(uint8_t op) { return op >= 46 && op <= 49; }

// Per (caller, command buffer, segment) totals over the recording. Phases:
// before the first draw or dispatch, between them, after the last one.
struct Segment {
    uint8_t kind = 0;
    int32_t argument = -1;
    uint64_t calls = 0, work = 0, ticks = 0;
    uint64_t ops[3][256] = {};
};
using Key = std::tuple<uintptr_t, uintptr_t, unsigned>;

// Trace.mm's constructor installs the probe before this file's C++
// initializers run, so globals here must not need dynamic initialization.
char trigger[PATH_MAX];
intptr_t gameSlide;
double ticksToMs;
std::atomic<bool> armed;
// Kept alive for the process; ARC would otherwise release and stop it.
dispatch_source_t triggerTimer;

// Render thread only.
std::map<Key, Segment> *segments;
uint64_t recordStart, submits, otherSubmits, otherOps;
uintptr_t caller, commandBuffer;
unsigned segmentIndex;
Segment *segment;
uint64_t segmentStart;
bool sawWork;
uint32_t tail[256];
uint8_t touched[256];
unsigned touchedCount;

void flushTail(unsigned phase) {
    for (unsigned i = 0; i < touchedCount; ++i) {
        uint8_t op = touched[i];
        if (segment) segment->ops[phase][op] += tail[op];
        tail[op] = 0;
    }
    touchedCount = 0;
}

void endSegment(uint64_t now) {
    if (!segment) return;
    flushTail(2);
    segment->ticks += now - segmentStart;
    segment = nullptr;
}

void beginSegment(uint8_t kind, int32_t argument, uint64_t now) {
    endSegment(now);
    Segment &s = (*segments)[Key(caller, commandBuffer, segmentIndex++)];
    s.kind = kind;
    s.argument = argument;
    ++s.calls;
    segment = &s;
    segmentStart = now;
    sawWork = false;
}

std::string summary(double seconds) {
    std::string out;
    char line[512];
    snprintf(line, sizeof line, "# seconds %.2f render-thread submits %llu other-thread submits %llu other-thread records %llu\n"
        "# ms/call of a Submit's last segment runs until the next Submit\n"
        "caller\tbuffer\tsegment\tkind\targument\tcalls\tms/call\twork/call\tbefore\tbetween\tafter\n",
        seconds, submits, otherSubmits, otherOps);
    out += line;
    for (auto &[key, s] : *segments) {
        snprintf(line, sizeof line, "0x%lx\t0x%lx\t%u\t%u\t%d\t%llu\t%.4f\t%.1f", std::get<0>(key), std::get<1>(key), std::get<2>(key),
            s.kind, s.argument, s.calls, s.ticks * ticksToMs / s.calls, double(s.work) / s.calls);
        out += line;
        for (auto &phase : s.ops) {
            out += '\t';
            bool first = true;
            for (unsigned op = 0; op < 256; ++op) if (phase[op]) {
                snprintf(line, sizeof line, "%s%u:%.1f", first ? "" : " ", op, double(phase[op]) / s.calls);
                out += line;
                first = false;
            }
            if (first) out += '-';
        }
        out += '\n';
    }
    return out;
}

void finish(uint64_t now) {
    endSegment(now);
    BG3MFXSubmitProbeRecording = 0;
    double seconds = (now - recordStart) * ticksToMs / 1000;
    std::string text = summary(seconds), path = std::string(trigger) + ".tsv";
    segments->clear();
    unlink(trigger);
    armed = false;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FILE *file = fopen(path.c_str(), "w");
        if (file) { fwrite(text.data(), 1, text.size(), file); fclose(file); }
        os_log(os_log_create("com.bg3mfx", "submit"), "bg3mfx submit: %{public}s %{public}s",
            file ? "wrote" : "could not write", path.c_str());
    });
}
}

extern "C" void BG3MFXSubmitEntry(uint8_t *buffer, uintptr_t returnAddress) {
    if (!pthread_main_np()) { if (BG3MFXSubmitProbeRecording) ++otherSubmits; return; }
    uint64_t now = mach_absolute_time();
    if (BG3MFXSubmitProbeRecording) {
        endSegment(now);
        if ((now - recordStart) * ticksToMs >= recordSeconds * 1000) { finish(now); return; }
    } else {
        if (!armed.load(std::memory_order_relaxed)) return;
        // The trigger is deleted when a recording ends; the timer may have
        // seen it just before.
        if (access(trigger, F_OK) != 0) { armed = false; return; }
        recordStart = now;
        submits = otherSubmits = otherOps = 0;
        BG3MFXSubmitProbeRecording = 1;
    }
    ++submits;
    caller = returnAddress - gameSlide;
    commandBuffer = reinterpret_cast<uintptr_t>(buffer);
    segmentIndex = 0;
    beginSegment(0, buffer[0x58], now);
}

extern "C" void BG3MFXSubmitOpcode(const uint8_t *record, uint8_t *) {
    if (!pthread_main_np()) { ++otherOps; return; }
    if (!segment) return;
    uint8_t op = record[0];
    if (beginsSegment(op)) {
        int32_t argument = -1;
        if (op == 17) memcpy(&argument, record + 4, 4);
        beginSegment(op, argument, mach_absolute_time());
    }
    if (isWork(op)) {
        flushTail(sawWork ? 1 : 0);
        sawWork = true;
        ++segment->work;
        ++segment->ops[1][op];
        return;
    }
    if (!tail[op]++) touched[touchedCount++] = op;
}

extern "C" void BG3MFXSubmitEntryWrapper(), BG3MFXSubmitOpcodeWrapper();

namespace {
bool zero(uintptr_t address, size_t bytes) {
    for (size_t i = 0; i < bytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(address + i)) return false;
    return true;
}

// stp x16, x17, [sp, #-16]!; adr x17, ret; ldr x16, wrapper; br x16; nop;
// wrapper: .quad; ret: ldp x16, x17, [sp], #16; <displaced>; b resume
void writeIsland(uintptr_t stub, uintptr_t wrapper, uint32_t displaced, uintptr_t resume) {
    uint32_t code[10] = {0xa9bf47f0, 0x100000d1, 0x58000070, 0xd61f0200, 0xd503201f, 0, 0,
        0xa8c147f0, displaced, BG3MFXBranch(stub + 36, resume)};
    memcpy(code + 5, &wrapper, 8);
    memcpy(reinterpret_cast<void *>(stub), code, sizeof code);
}
}

BOOL BG3MFXInstallSubmitOpcodeProbe(intptr_t slide, const char *triggerPath, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXSubmitOpcodeProbe" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    if (!triggerPath || triggerPath[0] != '/') return fail(@"BG3MFX_TRACE_SUBMIT_OPCODES must be an absolute trigger file path.");
    // NativeMenu has already checked the executable UUID; also check every
    // replaced instruction.
    uintptr_t entry = entrySite + slide, opcode = opcodeSite + slide;
    if (*reinterpret_cast<const uint32_t *>(entry) != entryInstruction || *reinterpret_cast<const uint32_t *>(opcode) != opcodeInstruction ||
        *reinterpret_cast<const uint32_t *>(opcode + 4) != opcodeNext)
        return fail(@"Unsupported command buffer replay.");
    uintptr_t entryIsland = 0x100004000 + slide + entryIslandOffset, opcodeIsland = 0x100004000 + slide + opcodeIslandOffset;
    if (!zero(entryIsland, islandBytes) || !zero(opcodeIsland, islandBytes)) return fail(@"Submit probe island space is in use.");
    if (!BG3MFXBranchReaches(entry, entryIsland) || !BG3MFXBranchReaches(opcode, opcodeIsland) ||
        !BG3MFXBranchReaches(entryIsland + 36, entry + 4) || !BG3MFXBranchReaches(opcodeIsland + 36, opcode + 4))
        return fail(@"Submit probe islands are out of range.");
    if (strlen(triggerPath) >= sizeof trigger) return fail(@"The Submit probe trigger path is too long.");
    strlcpy(trigger, triggerPath, sizeof trigger);
    segments = new std::map<Key, Segment>;
    gameSlide = slide;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    ticksToMs = double(timebase.numer) / timebase.denom / 1e6;
    unlink(trigger);
    auto result = BG3MFXPatchCode({{entryIsland, islandBytes}, {opcodeIsland, islandBytes}, {entry, 4}, {opcode, 4}}, [&] {
        writeIsland(entryIsland, reinterpret_cast<uintptr_t>(BG3MFXSubmitEntryWrapper), entryInstruction, entry + 4);
        writeIsland(opcodeIsland, reinterpret_cast<uintptr_t>(BG3MFXSubmitOpcodeWrapper), opcodeInstruction, opcode + 4);
        sys_icache_invalidate(reinterpret_cast<void *>(entryIsland), islandBytes);
        sys_icache_invalidate(reinterpret_cast<void *>(opcodeIsland), islandBytes);
        uint32_t toEntry = BG3MFXBranch(entry, entryIsland), toOpcode = BG3MFXBranch(opcode, opcodeIsland);
        memcpy(reinterpret_cast<void *>(entry), &toEntry, 4);
        memcpy(reinterpret_cast<void *>(opcode), &toOpcode, 4);
    });
    if (result != BG3MFXCodePatchResult::Patched) return fail(@"Could not install the Submit opcode probe.");
    // Arm when the trigger file appears; the render thread starts recording at
    // its next Submit.
    triggerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(triggerTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(triggerTimer, ^{
        if (!armed && access(trigger, F_OK) == 0) armed = true;
    });
    dispatch_resume(triggerTimer);
    os_log(os_log_create("com.bg3mfx", "submit"), "bg3mfx submit: probe installed, trigger %{public}s", trigger);
    return YES;
}
