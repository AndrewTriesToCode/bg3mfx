#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Uniform allocation slices: the hottest draw-recording sites take their
// uniform space from a per-thread slice instead of BG3's shared lock for every
// allocation. Requires the UUID-checked ARM64 executable.
BOOL BG3MFXInstallUniformSlices(intptr_t slide, void (*report)(NSDictionary *), NSError **error);
