#import "common/Notice.h"
#import "common/EventLog.h"
#import <AppKit/AppKit.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <os/log.h>

void BG3MFXFail(NSString *message, NSString *title, NSString *text) {
    BG3MFX_EVENT(@{@"event":@"failure", @"message":message ?: @""});
#ifdef BG3MFX_NO_TRACE
    static os_log_t log = os_log_create("com.bg3mfx", "failure");
    os_log_error(log, "%{public}@", message);
#endif
    const char *test = getenv("BG3MFX_TEST_ERRORS_STDERR");
    if (test && strcmp(test, "1") == 0) { fprintf(stderr, "%s\n", message.UTF8String); fflush(stderr); return; }
    if (!title) return;
    dispatch_async(dispatch_get_main_queue(),^{
        [NSApplication sharedApplication];
        NSAlert *alert=[NSAlert new]; alert.messageText=title; alert.informativeText=text;
        [alert addButtonWithTitle:@"OK"]; [alert runModal];
    });
}
