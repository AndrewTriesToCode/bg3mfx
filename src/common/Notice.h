#pragma once
#import <Foundation/Foundation.h>

// The one way to report a failure, in every runtime. Failures never close the
// game: the player may have unsaved progress. Each turns off the part that
// failed, then calls this.
//
// `message` goes to the event log as a `failure` event in the diagnostic
// runtime, and to the system log (subsystem com.bg3mfx, category failure) in the
// quiet one. With a `title`, the player also sees `title` and `text` in a dialog
// on the main run loop (never from a hook or from dyld's constructor).
// With BG3MFX_TEST_ERRORS_STDERR=1, noninteractive regressions get `message`
// on stderr and no dialog.
void BG3MFXFail(NSString *message, NSString *title, NSString *text);
