#pragma once
#import <Foundation/Foundation.h>

// Improved shadows' single sun shadow pass: registers BG3's stage lists for the game, player and offscreen views with
// custom-render-stages (features/custom-render-stages/CustomRenderStages.h),
// without the second Shadow pack, so the sun shadow cascades render once per
// frame instead of twice. custom-render-stages installs them afterwards.
BOOL BG3MFXInstallDuplicateShadowFix(NSError **error);
