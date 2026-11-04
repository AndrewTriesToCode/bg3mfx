#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Dynamic resolution: the "Dynamic" Upscaling Quality (BG3 quality 4, which
// BG3 renders at scale 1.0) with MetalFX Temporal. It keeps a minimum frame
// rate (metalfx's Upscaler Target Minimum FPS slider), at native resolution when it can; with
// metalfx's Thermal Guard checkbox it also lowers the area while macOS
// reports a thermal state above nominal (NSProcessInfo thermalState). Before each on-screen frame
// records, BG3's own render-viewport reduction (RenderFrame +0x4368, otherwise
// unused) is set from a GPU-time controller and its viewports are recalculated,
// so every render-resolution pass draws a sub-rectangle of unchanged targets
// while output-resolution passes do not; MetalFX Temporal upscales just that
// region. The area spans the device's MetalFX Temporal input content scale
// range (supportedInputContentMin/MaxScaleForDevice; 1x to 3x per axis on
// M-series GPUs), and stays at 1 until the Temporal integration reports it.
// Reduces only with MetalFX Temporal and BG3's FSR stage on; otherwise the
// reduction returns to 1. Frame Generation stretches the reduced region. Requires the UUID-checked ARM64
// executable. The dynamic-resolution feature, wanted with metalfx; if it
// cannot install, root reports it skipped and MetalFX does not offer Dynamic.
BOOL BG3MFXDynamicResolutionInstalled(void);
// BG3's settings select a Dynamic quality, so Temporal scalers need dynamic
// input content.
BOOL BG3MFXDynamicResolutionSelected(void);
// The area most recently applied to a render frame; 1 when not reducing.
float BG3MFXDynamicResolutionArea(void);
// The Temporal scaler device's supported input content scale range (output
// size / rendered content size, per axis).
void BG3MFXDynamicResolutionSetScaleLimits(float minimumScale, float maximumScale);
// One BG3 command buffer's GPU execution (Metal media time, seconds), while
// the controller measures.
BOOL BG3MFXDynamicResolutionMeasuring(void);
void BG3MFXDynamicResolutionGPUWork(double start, double end);

// The Upscaling Quality value of Dynamic.
inline constexpr int BG3MFXDynamicQuality = 4;
inline bool BG3MFXDynamicQualityValue(int quality) {
    return quality == BG3MFXDynamicQuality;
}
