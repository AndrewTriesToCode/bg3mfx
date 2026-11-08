#import "common/ScreenTiming.h"
#import <AppKit/AppKit.h>
#include <atomic>

namespace {
std::atomic<double> minimumInterval{0}, maximumInterval{0}, granularity{0};
// AppKit is read on the main thread; other threads read the copies.
void update() {
    NSScreen *screen = NSApp.mainWindow.screen ?: NSApp.keyWindow.screen ?: NSScreen.mainScreen;
    minimumInterval.store(screen ? screen.minimumRefreshInterval : 0);
    maximumInterval.store(screen ? screen.maximumRefreshInterval : 0);
    granularity.store(screen ? screen.displayUpdateGranularity : 0);
}
}

void BG3MFXScreenTimingStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSNotificationName name in @[NSApplicationDidChangeScreenParametersNotification,
                                          NSWindowDidChangeScreenNotification, NSWindowDidBecomeMainNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *) { update(); }];
        dispatch_async(dispatch_get_main_queue(), ^{ update(); });
    });
}

BG3MFXScreenTiming BG3MFXScreenTimingCurrent(void) {
    return {minimumInterval.load(std::memory_order_relaxed), maximumInterval.load(std::memory_order_relaxed),
            granularity.load(std::memory_order_relaxed)};
}
