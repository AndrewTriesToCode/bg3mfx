#pragma once
#import <Foundation/Foundation.h>

// Build-specific native Video menu integration. Must precede menu construction.
BOOL BG3MFXInstallNativeMenu(void (*report)(NSDictionary *), NSError **error);
// 0 Off, 1 FSR, 2 Spatial, 3 Temporal.
int BG3MFXSelectedScalingMode(void);
// The "MetalFX Frame Generation" checkbox, on a device that supports it.
BOOL BG3MFXFrameGenerationEnabled(void);
