#pragma once
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

// Frame-rate log for development and bug reports, enabled with
// BG3MFX_FRAME_LOG=1. Every 2 s it writes one line to the system log
// (subsystem com.bg3mfx, category frames): BG3's rendered rate, the real and
// generated images that reached the display, drops, the presentation method,
// the gaps between shown images, and the latency from BG3 committing a frame
// to the real image being shown. Disabled, each call is one branch.

typedef NS_ENUM(int, BG3MFXPresentMethod) {
    BG3MFXPresentNative = 0,       // Frame Generation off: BG3's own presents
    BG3MFXPresentSynced = 1,       // vsync on: minimum duration, refresh-aligned
    BG3MFXPresentMinimum = 2,      // vsync off, at most half the refresh rate
    BG3MFXPresentSpaced = 3,       // vsync off, faster: generated, wait, real
};

#ifdef __cplusplus
extern "C" {
#endif
BOOL BG3MFXFrameLogEnabled(void);
// BG3 presented a frame, to a real drawable or a stand-in.
void BG3MFXFrameLogRendered(void);
// A presented callback: time > 0 shown, 0 dropped by the display, < 0 no drawable.
void BG3MFXFrameLogShown(BOOL generated, CFTimeInterval time);
void BG3MFXFrameLogMethod(BG3MFXPresentMethod method);
// Scheduled timing for a generated/real pair, in seconds.
void BG3MFXFrameLogPacing(BOOL synced, double refresh, double interval, unsigned refreshes,
                          double generatedMinimum, double realMinimum);
void BG3MFXFrameLogDisplayState(BOOL appActive, NSInteger maximumFPS);
// Time BG3 blocked waiting for a stand-in slot, plus its frame cadence.
void BG3MFXFrameLogBackpressure(double standInWait, double cadence);
// A stand-in slot was still busy after the preferred low-latency wait, so the
// frame borrowed one bounded overflow slot from the stand-in texture pool.
void BG3MFXFrameLogStandInOverflow(void);
// BG3's requested drawable count (2 double-buffered, 3 triple or vsync off) and
// the stand-ins Frame Generation allows it (0 with Frame Generation off).
void BG3MFXFrameLogBuffering(unsigned bg3, unsigned standIns);
// A real frame reached the display this long after BG3 committed it, with this
// many frames in flight at the commit.
void BG3MFXFrameLogLatency(CFTimeInterval seconds, unsigned queued);
// Native command-buffer execution and its surrounding host-side intervals.
// Times are host-clock seconds; GPU execution is end minus start.
void BG3MFXFrameLogGPU(CFTimeInterval start, CFTimeInterval end,
                      CFTimeInterval committed, CFTimeInterval completed);
// Time spent acquiring a native CAMetalLayer drawable.
void BG3MFXFrameLogDrawableWait(CFTimeInterval seconds);
#ifdef __cplusplus
}
#endif
