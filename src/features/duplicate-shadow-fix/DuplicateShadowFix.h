#pragma once
#import <Foundation/Foundation.h>

// Registers BG3's stage lists for the game, player and offscreen views with
// custom-render-stages (features/custom-render-stages/CustomRenderStages.h),
// without the second Shadow pack, so the sun shadow cascades render once per
// frame instead of twice. custom-render-stages installs them afterwards.
BOOL BG3MFXInstallDuplicateShadowFix(void (*report)(NSDictionary *), NSError **error);
