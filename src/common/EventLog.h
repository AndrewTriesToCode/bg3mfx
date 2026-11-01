#pragma once
#import <Foundation/Foundation.h>

// The diagnostic runtime's JSONL event log, at BG3MFX_TRACE or
// $TMPDIR/bg3mfx-trace.jsonl. Player-runtime calls compile away.
#ifndef BG3MFX_NO_TRACE
void BG3MFXEventLogOpen(void);
// Writes one event as a JSON line with the process id. An important event is
// timestamped and always written. Any other is written once per distinct
// content, and only until the log holds 20,000 of them.
void BG3MFXEventLogWrite(NSDictionary *event, bool important);
#else
static inline void BG3MFXEventLogOpen(void) {}
static inline void BG3MFXEventLogWrite(NSDictionary *, bool) {}
#endif
