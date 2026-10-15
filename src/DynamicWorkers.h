#pragma once
#import <Foundation/Foundation.h>
#include <atomic>
#include <cstdint>

// Dynamic worker core prioritization: keeps BG3's WT/High worker threads and
// its job scheduler on the lower-tier cores (Darwin background) while that
// costs no frame rate, and returns them to normal priority while it would.
// Changes no BG3 code; call once BG3's executable has been checked.
BOOL BG3MFXInstallDynamicWorkers(void (*report)(NSDictionary *));

// BG3's rendered frames, counted by the present hooks in Trace.mm.
extern std::atomic<uint64_t> BG3MFXRenderedFrames;
