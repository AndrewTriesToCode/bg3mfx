#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Diagnostic-runtime measurement (BG3MFX_TRACE_SERVER_PACING=1): times each
// BG3 server tick's work, its thread CPU time, the entity world update, and the
// tick limiter (GameClock::CapFrame), and logs a summary every 2 s to the system
// log (subsystem com.bg3mfx, category pacing). Requires the UUID-checked ARM64
// executable and the Temporal jitter islands.
BOOL BG3MFXInstallServerPacingProbe(intptr_t slide, NSError **error);
