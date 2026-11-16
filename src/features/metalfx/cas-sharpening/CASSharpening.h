#pragma once
#import <Foundation/Foundation.h>

// Lets BG3's CAS (FidelityFX Contrast Adaptive Sharpening) stage run with
// MetalFX Spatial and Temporal. BG3 turns CAS off for every upscaling type but
// Off, and MetalFX runs on BG3's FSR type underneath. Part of the metalfx
// feature, which installs it; if it cannot install, metalfx reports it and
// CAS stays off with MetalFX.

// Whether the CAS stage renders: the player turned CAS on, and the upscaling
// type is Off (BG3's own rule) or MetalFX Spatial or Temporal is selected
// (`mode`: 0 Off, 1 FSR, 2 Spatial, 3 Temporal).
inline bool BG3MFXCASRenders(bool casEnabled, int nativeUpscalingType, int mode) {
    return casEnabled && (nativeUpscalingType < 1 || mode == 2 || mode == 3);
}
// Whether the CAS options in Video should be available: with MetalFX selected,
// when installed; otherwise BG3 decides.
BOOL BG3MFXCASSharpeningInstalled(void);
BOOL BG3MFXInstallCASSharpening(intptr_t slide, NSError **error);
