#pragma once
#import <Foundation/Foundation.h>

// Build-specific native Video menu integration. Must precede menu construction.
BOOL BG3MFXInstallNativeMenu(void (*report)(NSDictionary *), NSError **error);
// 0 Off, 1 FSR, 2 Spatial, 3 Temporal.
int BG3MFXSelectedScalingMode(void);
// The "MetalFX Frame Generation" checkbox, on a device that supports it.
BOOL BG3MFXFrameGenerationEnabled(void);
// After a MetalFX upscaler failure: select AMD FSR 1.0, which BG3 already runs
// underneath, so Video options show it. NO without the native menu (test harnesses).
BOOL BG3MFXFallBackToFSR(void);
// Render thread, before each frame: BG3 starts with its own quality (at most
// Ultra Quality). Until Video options are first built and restore the saved
// Dynamic quality themselves, publish it to the renderer from the main thread
// as the menu does, so BG3 also resizes its render targets.
void BG3MFXPublishStartupDynamicQuality(void);
// The "Upscaler Target Minimum FPS" slider: Dynamic's target in rendered frames
// per second, like Max Frame Rate (10-240, 60 until set).
int BG3MFXDynamicMinimumFrameRate(void);
// The "Dynamic Upscaler Thermal Guard" checkbox (off until set).
BOOL BG3MFXDynamicThermalGuard(void);
