#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Removes BG3's duplicate cascaded-shadow stage from the game view. Requires
// the UUID-checked ARM64 executable; call before BG3 creates its render views.
BOOL BG3MFXInstallShadowDuplicateFix(intptr_t slide, void (*report)(NSDictionary *), NSError **error);
