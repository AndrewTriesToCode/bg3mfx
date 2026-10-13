#pragma once
#import <Foundation/Foundation.h>

// Build-specific native Video menu integration. Must precede menu construction.
BOOL BG3MFXInstallNativeMenu(void (*report)(NSDictionary *), NSError **error);
// 0 Off, 1 FSR, 2 Spatial, 3 Temporal. "MetalFX Temporal + Frame Generation"
// reports Temporal here and enables BG3MFXFrameGenerationEnabled.
int BG3MFXSelectedScalingMode(void);
BOOL BG3MFXFrameGenerationEnabled(void);
