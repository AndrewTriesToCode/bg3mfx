#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Optimized thread idling: BG3's job system and frame limiter sleep instead of
// spinning while they wait. Requires the UUID-checked ARM64 executable and the
// Temporal jitter islands.
BOOL BG3MFXInstallThreadIdling(intptr_t slide, void (*report)(NSDictionary *), NSError **error);
