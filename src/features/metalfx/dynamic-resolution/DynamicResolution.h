#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Reduced resolution: the "Ultra Performance" Upscaling Quality (BG3 quality 4,
// which BG3 renders at scale 1.0) with MetalFX Temporal. It renders the smallest
// region MetalFX Temporal accepts on this Mac
// (supportedInputContentMin/MaxScaleForDevice; 3x per axis, 1/9 of the pixels,
// on the M5 Pro). Before each on-screen frame records, BG3's own
// render-viewport reduction (RenderFrame +0x4368, otherwise unused) is set to the
// fixed area and its viewports are recalculated, so every render-resolution pass
// draws a sub-rectangle of unchanged targets while output-resolution passes do
// not; MetalFX Temporal upscales just that region. The area stays at 1 until the
// Temporal integration reports the device's range, and returns to 1 unless
// MetalFX Temporal and BG3's FSR stage are on. Frame Generation stretches the
// reduced region. Requires the UUID-checked ARM64 executable. Part of the
// metalfx feature, which installs it; if it cannot install, metalfx reports it
// and does not offer these qualities.
BOOL BG3MFXInstallDynamicResolution(intptr_t slide, NSError **error);
BOOL BG3MFXDynamicResolutionInstalled(void);
// BG3's settings select a reduced quality, so Temporal scalers need dynamic
// input content.
BOOL BG3MFXDynamicResolutionSelected(void);
// The area most recently applied to a render frame; 1 when not reducing.
float BG3MFXDynamicResolutionArea(void);
// The Temporal scaler device's supported input content scale range (output
// size / rendered content size, per axis).
void BG3MFXDynamicResolutionSetScaleLimits(float minimumScale, float maximumScale);

// The Upscaling Quality value of Ultra Performance.
inline constexpr int BG3MFXUltraPerformanceQuality = 4;
inline bool BG3MFXReducedQualityValue(int quality) {
    return quality == BG3MFXUltraPerformanceQuality;
}
