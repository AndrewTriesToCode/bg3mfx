#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Replaces hot functions of BG3's unoptimized Granny animation runtime with
// optimized versions that give bit-identical results (GrannyKernels.h).
// Requires the UUID-checked ARM64 executable.
BOOL BG3MFXInstallAnimationOptimizations(intptr_t slide, NSError **error);
