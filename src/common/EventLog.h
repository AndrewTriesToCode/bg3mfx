#pragma once
#import <Foundation/Foundation.h>

// The diagnostic runtime's one log: JSONL at BG3MFX_TRACE or
// $TMPDIR/bg3mfx-trace.jsonl. Everything that reports for development goes
// through these two macros; analyze it with tools/analysis or `tail -f`.
//
// BG3MFX_EVENT is for rare events: each is timestamped and always written.
// BG3MFX_TRACE_EVENT is for frequent ones (per frame or per call): each is
// written once per distinct content, and only until the log holds 20,000 lines.
//
// In the quiet runtime neither evaluates its argument and no strings remain,
// but the argument still compiles, so it cannot go stale.
void BG3MFXEventLogOpen(void);
void BG3MFXEventLogWrite(NSDictionary *event, bool important);
#ifndef BG3MFX_NO_TRACE
#define BG3MFX_EVENT(...) BG3MFXEventLogWrite((__VA_ARGS__), true)
#define BG3MFX_TRACE_EVENT(...) BG3MFXEventLogWrite((__VA_ARGS__), false)
#else
#define BG3MFX_EVENT(...) do { if (0) BG3MFXEventLogWrite((__VA_ARGS__), true); } while (0)
#define BG3MFX_TRACE_EVENT(...) do { if (0) BG3MFXEventLogWrite((__VA_ARGS__), false); } while (0)
#endif
