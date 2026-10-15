#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Opt-in measurement (BG3MFX_TRACE_SUBMIT_OPCODES=/path/to/trigger, both
// runtimes): counts the commands rf::RendererCommandBuffer::Submit replays on
// the render thread, per caller and per compute, render or blit pass. It stays
// idle until the trigger file exists, records 5 s, logs a summary to the system
// log (subsystem com.bg3mfx, category submit) and deletes the trigger. Requires
// the UUID-checked ARM64 executable and the Temporal jitter islands.
BOOL BG3MFXInstallSubmitOpcodeProbe(intptr_t slide, const char *trigger, NSError **error);
