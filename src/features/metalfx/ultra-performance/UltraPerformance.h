#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Ultra Performance: the Upscaling Quality (BG3 quality 4) that renders about 3x
// less per axis (1/9 of the pixels) with MetalFX Temporal. BG3's FSR resolution
// code reads a table of four render scales, one per native quality; this adds a
// fifth for quality 4 so BG3 sizes its own render targets as it does for any
// other quality, and no other system needs to know. The scale is derived from the
// Temporal scaler's supported input content scale on this device, just under its
// maximum (BG3 truncates the render size, and a scale of exactly the maximum
// would give a ratio the scaler rejects at some output sizes). It applies only
// while MetalFX Temporal is selected and has not failed; otherwise BG3's FSR
// would stretch the small image, so quality 4 renders at full size. Requires the
// UUID-checked ARM64 executable. Part of the metalfx feature, which installs it;
// if it cannot install, metalfx reports it and does not offer Ultra Performance.
BOOL BG3MFXInstallUltraPerformance(intptr_t slide, NSError **error);
// Whether the render scale table was extended (false on a device whose Temporal
// scaler cannot reduce).
BOOL BG3MFXUltraPerformanceInstalled(void);
// The render scale (output / render size, per axis) quality 4 uses while active.
float BG3MFXUltraPerformanceScale(void);
// Whether quality 4 renders reduced: MetalFX Temporal is selected and working.
// Called every frame from the renderer; takes effect when BG3 next resizes.
void BG3MFXUltraPerformanceActive(bool active);

// The Upscaling Quality value of Ultra Performance.
inline constexpr int BG3MFXUltraPerformanceQuality = 4;
