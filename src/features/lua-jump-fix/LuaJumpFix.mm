#include "common/native/SupportedBuild.h"
#import "features/lua-jump-fix/LuaJumpFix.h"
#include "common/native/CodePatch.h"
#include <libkern/OSCacheControl.h>
#include <setjmp.h>
#include <cstring>

// BG3's Lua 5.4 was built without LUA_USE_POSIX, so every protected call
// (luaD_rawrunprotected) uses setjmp and every error (luaD_throw) longjmp. On
// macOS these also save and restore the signal mask and alternate signal stack:
// two system calls per protected call, about 3.5% of the server thread in Lower
// City (docs/dev/performance.md). POSIX Lua uses _setjmp/_longjmp, which skip them; Lua
// never changes either, so behavior is unchanged. Each call is redirected
// through a tail-jump island, so the stub's caller and return address match.
namespace Native = BG3MFXBuild::Lua;

namespace {
// BG3 4.1.1.7631656: `bl _longjmp` in luaD_throw and `bl _setjmp` in
// luaD_rawrunprotected.
const uintptr_t longjmpSite = Native::LongjmpCall, setjmpSite = Native::SetjmpCall;
const uint32_t longjmpCall = 0x95c18c28, setjmpCall = 0x95c18dab;
// Sequences around each call: `add x0, x8, #0x8; mov w1, #0x1` and
// `add x0, x8, #0x8`.
const uint32_t longjmpBefore[] = {0x91002100, 0x52800021}, setjmpBefore = 0x91002100;
const size_t islandOffset = BG3MFXBuild::Islands::Lua.offset, islandBytes = BG3MFXBuild::Islands::Lua.bytes;
}

BOOL BG3MFXInstallLuaJumpFix(intptr_t slide, void (*report)(NSDictionary *), NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXLuaJumpFix" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // NativeMenu has already checked the executable UUID; also check both calls.
    uintptr_t throwCall = longjmpSite + slide, protectCall = setjmpSite + slide;
    const auto *throwWords = reinterpret_cast<const uint32_t *>(throwCall - 8);
    const auto *protectWords = reinterpret_cast<const uint32_t *>(protectCall - 4);
    if (memcmp(throwWords, longjmpBefore, sizeof longjmpBefore) != 0 || throwWords[2] != longjmpCall ||
        protectWords[0] != setjmpBefore || protectWords[1] != setjmpCall)
        return fail(@"Unsupported Lua error handling.");
    // The islands follow the Temporal jitter islands in the zero header padding.
    uintptr_t island = BG3MFXBuild::HeaderPadding + slide + islandOffset;
    for (size_t i = 0; i < islandBytes; ++i)
        if (*reinterpret_cast<const uint8_t *>(island + i)) return fail(@"Lua jump island space is in use.");
    if (!BG3MFXBranchReaches(throwCall, island) || !BG3MFXBranchReaches(protectCall, island + 16))
        return fail(@"The Lua jump islands are out of range.");
    auto result = BG3MFXPatchCode({{island, islandBytes}, {throwCall, 4}, {protectCall, 4}}, [&] {
        const uintptr_t targets[2] = {reinterpret_cast<uintptr_t>(&_longjmp), reinterpret_cast<uintptr_t>(&_setjmp)};
        for (unsigned i = 0; i < 2; ++i) {
            // ldr x16, #8; br x16; .quad target
            uint32_t code[4] = {0x58000050, 0xd61f0200, 0, 0};
            memcpy(code + 2, &targets[i], 8);
            memcpy(reinterpret_cast<void *>(island + i * 16), code, sizeof code);
        }
        sys_icache_invalidate(reinterpret_cast<void *>(island), islandBytes);
        // _longjmp also unwinds setjmp buffers, so redirect the throw first: no
        // _setjmp buffer can ever reach the original longjmp.
        uint32_t call = 0x94000000 | (BG3MFXBranch(throwCall, island) & 0x03ffffff);
        memcpy(reinterpret_cast<void *>(throwCall), &call, 4);
        call = 0x94000000 | (BG3MFXBranch(protectCall, island + 16) & 0x03ffffff);
        memcpy(reinterpret_cast<void *>(protectCall), &call, 4);
    });
    if (result == BG3MFXCodePatchResult::NotWritable) return fail(@"Could not make Lua error handling writable.");
    // Written but not executable again: report it as installed, not skipped.
    if (report) report(@{@"event": @"luaJumpFixInstalled", @"protectionRestored": @(result == BG3MFXCodePatchResult::Patched)});
    return YES;
}
