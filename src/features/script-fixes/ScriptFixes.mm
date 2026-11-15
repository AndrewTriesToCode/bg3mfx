#include "common/Feature.h"
#import "common/Notice.h"
#include "common/native/CodePatch.h"
#include "common/native/SupportedBuild.h"
#include "features/script-fixes/ScriptFixes.h"
#include <atomic>
#include <mach/mach.h>
#include <mach/mach_vm.h>

// Two entry hooks patch BG3's scripts and AI data as the game reads them
// (ScriptFixes.h): lua_load for Thoth scripts, the FileReader constructor
// for AI archetypes. Nothing on disk changes.
namespace Native = BG3MFXBuild::ScriptFixes;
namespace Layout = BG3MFXBuild::ScriptFixes::Layout;
namespace Fixes = BG3MFXScriptFixes;

namespace {
Fixes::Load originalLoad;
using ReaderInit = void *(*)(void *reader, const void *path, uint32_t type, uint64_t flags);
ReaderInit originalReaderInit;
std::atomic<bool> reported{false};

void skipped(std::string_view path, Fixes::Result result) {
    if (reported.exchange(true)) return;  // one notice per run
    NSString *why = result == Fixes::Result::Unknown
        ? @"its contents are not the version this build ships (a mod may replace it)"
        : result == Fixes::Result::NotWritable ? @"its memory could not be written" : @"an edit did not match";
    BG3MFXFail([NSString stringWithFormat:@"Script fixes left %.*s unpatched: %@.", int(path.size()), path.data(), why],
        nil, nil);
}

int loadHook(void *L, Fixes::Reader reader, void *data, const char *chunk, const char *mode) {
    return Fixes::LoadFixed(originalLoad, L, reader, data, chunk, mode, skipped);
}

// Copies `patched` over `bytes`. Packaged files can be the FileManager's
// read-only copy: those pages are made private (copy-on-write) and writable,
// written, and returned to their protection.
bool writeData(char *bytes, const char *patched, size_t size) {
    const mach_vm_address_t page = mach_vm_trunc_page(reinterpret_cast<mach_vm_address_t>(bytes));
    const mach_vm_size_t length = mach_vm_round_page(reinterpret_cast<mach_vm_address_t>(bytes) + size) - page;
    mach_vm_address_t region = page;
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (mach_vm_region(mach_task_self(), &region, &regionSize, VM_REGION_BASIC_INFO_64,
            reinterpret_cast<vm_region_info_t>(&info), &infoCount, &object) != KERN_SUCCESS ||
        region > page || region + regionSize < page + length)
        return false;
    if (info.protection & VM_PROT_WRITE) {
        memcpy(bytes, patched, size);
        return true;
    }
    if (mach_vm_protect(mach_task_self(), page, length, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        return false;
    memcpy(bytes, patched, size);
    mach_vm_protect(mach_task_self(), page, length, false, info.protection);
    return true;
}

void *readerInitHook(void *reader, const void *path, uint32_t type, uint64_t flags) {
    void *result = originalReaderInit(reader, path, type, flags);
    const auto *string = static_cast<const char *>(path);
    const bool isLong = static_cast<int8_t>(string[Layout::StringLong]) < 0;
    std::string_view name = isLong
        ? std::string_view(*reinterpret_cast<const char *const *>(string),
                           *reinterpret_cast<const uint32_t *>(string + Layout::StringLength))
        : std::string_view(string, static_cast<uint8_t>(string[Layout::StringLong]));
    const auto *fields = static_cast<char *>(reader);
    if (!fields[Layout::ReaderLoaded] || Fixes::Candidate(Fixes::Kind::Data, name).empty()) return result;
    char *data = *reinterpret_cast<char *const *>(fields + Layout::ReaderData);
    const size_t size = *reinterpret_cast<const size_t *>(fields + Layout::ReaderSize);
    Fixes::PatchData(name, data, size, writeData, skipped);
    return result;
}

BOOL installScriptFixes(const BG3MFXFeatureContext &context, NSError **error) {
    auto fail = [&](NSString *what, const char *failure) {
        if (error)
            *error = [NSError errorWithDomain:@"BG3MFXScriptFixes" code:1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not hook BG3's %@: %s.", what, failure]}];
        return NO;
    };
    const uintptr_t islands = BG3MFXBuild::HeaderPadding + context.slide + BG3MFXBuild::Islands::ScriptFixes.offset;
    const uintptr_t loadIsland = islands, readerIsland = islands + BG3MFXEntryIslandBytes;
    originalLoad = reinterpret_cast<Fixes::Load>(loadIsland + BG3MFXEntryOriginalOffset);
    originalReaderInit = reinterpret_cast<ReaderInit>(readerIsland + BG3MFXEntryOriginalOffset);
    // Both entries are checked before either is hooked, so an unsupported
    // build leaves both unhooked.
    if (*reinterpret_cast<const uint32_t *>(Native::FileReaderInit + context.slide) != Native::FileReaderInitFirst)
        return fail(@"file reading", "unsupported first instruction");
    if (*reinterpret_cast<const uint32_t *>(Native::LuaLoad + context.slide) != Native::LuaLoadFirst)
        return fail(@"script loading", "unsupported first instruction");
    if (const char *failure = BG3MFXHookEntry(Native::FileReaderInit + context.slide, Native::FileReaderInitFirst,
                                              readerIsland, reinterpret_cast<void *>(readerInitHook)))
        return fail(@"file reading", failure);
    if (const char *failure = BG3MFXHookEntry(Native::LuaLoad + context.slide, Native::LuaLoadFirst, loadIsland,
                                              reinterpret_cast<void *>(loadHook)))
        return fail(@"script loading", failure);
    return YES;
}
}
BG3MFX_FEATURE(scriptFixes, {"script-fixes", nullptr, true, installScriptFixes, nullptr});
