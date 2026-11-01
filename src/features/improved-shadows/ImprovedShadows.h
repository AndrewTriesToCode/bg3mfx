#pragma once
#import <Foundation/Foundation.h>
#include "common/Feature.h"

// Improved shadows (requires custom-render-stages and custom-pipeline-bundles):
// bg3mfx's own sun shadow mask shader replaces BG3's (DirLight_Cascaded_PCSS_* for Medium and High,
// DirLight_Cascaded_PCF_* for Low). It takes the surface normal from the
// G-buffer instead of each 2x2 quad's depth slope. The shadow mask stage's
// Load override puts clones of BG3's programs, with bg3mfx's fragment
// function, in place of BG3's, and its StartRecording override records the
// G-buffer normal's bind at the head of the stage's list. The shader source
// is ImprovedShadowsShader.h.
BOOL BG3MFXInstallImprovedShadows(const BG3MFXFeatureContext &context, NSError **error);
