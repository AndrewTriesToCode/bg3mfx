#pragma once
#import <Foundation/Foundation.h>

// Failures never close the game: the player may have unsaved progress. Each
// turns off the part that failed and tells the player once, on the main run
// loop (never from a hook or from dyld's constructor). With
// BG3MFX_TEST_ERRORS_STDERR=1, noninteractive regressions read stderr instead.
void BG3MFXShowNotice(NSString *title, NSString *text);
