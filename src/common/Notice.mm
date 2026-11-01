#import "common/Notice.h"
#import <AppKit/AppKit.h>
#include <cstdlib>
#include <cstring>

void BG3MFXShowNotice(NSString *title, NSString *text) {
    if (getenv("BG3MFX_TEST_ERRORS_STDERR") && strcmp(getenv("BG3MFX_TEST_ERRORS_STDERR"),"1") == 0) return;
    dispatch_async(dispatch_get_main_queue(),^{
        [NSApplication sharedApplication];
        NSAlert *alert=[NSAlert new]; alert.messageText=title; alert.informativeText=text;
        [alert addButtonWithTitle:@"OK"]; [alert runModal];
    });
}
