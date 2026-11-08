#import "features/custom-menu/FullscreenFit.h"
#import <AppKit/AppKit.h>

// BG3's Borderless mode is macOS full screen. At startup BindSurface sizes the
// window to the whole screen, notch strip included (1728x1117 pt on a 14-inch
// MacBook Pro), before AppKit's full-screen transition; the transition keeps
// that height but puts the top under the notch, at y = -33, so the bottom 33 pt
// were off screen until a resolution change set the frame again, which AppKit
// fits below the notch (1728x1084). This gives the window that frame once it
// is full screen and its bottom is off the screen. That happens only with the
// app's "Scale to fit below built-in camera" off: with it on, the window is the
// whole screen at y = 0 and macOS scales the whole space below the camera
// (with bars at the sides), so it is left alone.
// Part of custom-menu (the Video settings repairs).

namespace {
bool isGameWindow(NSWindow *window) {
    Class gameWindowClass = NSClassFromString(@"LSWindow");
    return gameWindowClass && [window isKindOfClass:gameWindowClass];
}
// The screen below its notch: the bottom of the areas beside the camera
// housing (auxiliaryTopLeftArea, 1084 pt up on a 14-inch MacBook Pro, in both
// modes), with the full width and bottom. The whole screen without a notch.
// Neither the safe area (no notch with Scale to fit on) nor the visible frame
// (the menu bar, until the full-screen space is shown) says this.
NSRect fullScreenFrame(NSScreen *screen) {
    NSRect frame = screen.frame, beside = screen.auxiliaryTopLeftArea;
    if (!NSIsEmptyRect(beside) && NSMinY(beside) > NSMinY(frame)) frame.size.height = NSMinY(beside) - NSMinY(frame);
    return frame;
}
void fit(NSWindow *window) {
    if (!isGameWindow(window) || !(window.styleMask & NSWindowStyleMaskFullScreen) || !window.screen) return;
    NSRect target = fullScreenFrame(window.screen), frame = window.frame;
    if (NSMinY(frame) >= NSMinY(window.screen.frame) - 0.5 || target.size.height <= 0) return;
    [window setFrame:target display:YES];
}
}

void BG3MFXInstallFullscreenFit() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // After the transition, and again if AppKit moves the window later.
        for (NSNotificationName name in @[NSWindowDidEnterFullScreenNotification, NSWindowDidMoveNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) {
                NSWindow *window = note.object;
                dispatch_async(dispatch_get_main_queue(), ^{ fit(window); });
            }];
    });
}
