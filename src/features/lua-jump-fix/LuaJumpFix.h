#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Points BG3's Lua error handling at _setjmp/_longjmp, which skip the signal
// mask and alternate-stack system calls of setjmp/longjmp. Requires the
// UUID-checked ARM64 executable and the Temporal jitter islands.
BOOL BG3MFXInstallLuaJumpFix(intptr_t slide, void (*report)(NSDictionary *), NSError **error);
