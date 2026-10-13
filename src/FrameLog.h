#pragma once
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

// Frame-rate log for development and bug reports, enabled with
// BG3MFX_FRAME_LOG=1. Every 2 s it writes one line to the system log
// (subsystem com.bg3mfx, category frames): BG3's rendered rate, the real and
// generated images that reached the display, drops, the presentation method,
// and the gaps between shown images. Disabled, each call is one branch.

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
#ifdef __cplusplus
}
#endif
