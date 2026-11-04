#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Makes each SSAO blur pass bind the constant-buffer ring slot written for
// it, so the horizontal pass is horizontal again. Requires the UUID-checked
// ARM64 executable and the SSAOBlur island.
BOOL BG3MFXInstallSSAOBlurFix(intptr_t slide, NSError **error);
