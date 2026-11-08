#pragma once
#import <Foundation/Foundation.h>

// The metalfx feature: MetalFX Spatial and Temporal upscaling (with
// Temporal's jitter and Dynamic resolution), Frame Generation and the
// FSR_Tonemap skip, with their Video options (MetalFXOptions.mm). Requires
// custom-menu and metal-hooks; its renderer work (renderer/MetalFXRenderer.mm)
// is metal-hooks' renderer extension.

// The Upscaling Type: 0 Off, 1 FSR, 2 Spatial, 3 Temporal.
int BG3MFXSelectedScalingMode(void);
// The "MetalFX Frame Generation" checkbox, on a device that supports it.
BOOL BG3MFXFrameGenerationEnabled(void);
// After a MetalFX upscaler failure: select AMD FSR 1.0, which BG3 already runs
// underneath, so Video options show it. NO without the menu (test harnesses).
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
// The parts the feature's install puts in. Temporal's native jitter
// (temporal-upscaling/TemporalJitter.mm); NO with `error` when it cannot.
BOOL BG3MFXInstallTemporalJitter(intptr_t slide, NSError **error);
// renderer/MetalFXRenderer.mm: registers the renderer extension with
// metal-hooks (from install) and hooks CAMetalLayer for Frame Generation's
// stand-in drawables (from activation).
BOOL BG3MFXInstallMetalFXRenderer(NSError **error);
void BG3MFXActivateMetalFXRenderer(void);
// MetalFXOptions.mm: registers the options with custom-menu (from the
// feature's install) and restores the saved choices (from its activation).
void BG3MFXInstallMetalFXOptions(intptr_t slide);
void BG3MFXRestoreMetalFXChoices(void);
// The options changed the Upscaling Type or Frame Generation: retry a failed
// upscaler after a type change, and reset Frame Generation and Temporal history.
void BG3MFXMetalFXSelectionChanged(bool upscalingTypeChanged);
