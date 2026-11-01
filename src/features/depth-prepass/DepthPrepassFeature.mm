#include "common/Feature.h"
#import "features/depth-prepass/DepthPrepass.h"

// The depth-prepass feature: DepthPrepass.h's rules through metal-hooks' draw
// filter. Only the draws of pipelines it tags call into it.

namespace {
void (*reportEvent)(NSDictionary *);
uint8_t renderPass(MTLRenderPassDescriptor *desc) {
    const TrimRole role = BG3MFXPrepassRole(desc);
    // Diagnostics: report the previous frame's counts at each trimmed prepass.
    if (reportEvent && role == RolePrepass) {
        static unsigned prepasses;
        const BG3MFXPrepassCounts counts = BG3MFXDrainPrepassCounts();
        reportEvent(@{@"event":@"prepassTrim", @"prepass":@(++prepasses), @"skipped":@(counts.skipped), @"swapped":@(counts.swapped)});
    }
    return role;
}
BOOL installDepthPrepass(const BG3MFXFeatureContext &context, NSError **error) {
    reportEvent = context.report;
    if (BG3MFXMetalHooksFilterDraws({BG3MFXClassifyPrepass, renderPass, BG3MFXPreparePrepassDepth, BG3MFXPrepassDraw})) return YES;
    if (error) *error = [NSError errorWithDomain:@"BG3MFXDepthPrepass" code:1
                                        userInfo:@{NSLocalizedDescriptionKey:@"metal-hooks' draw filter is already taken."}];
    return NO;
}
const char *const depthPrepassRequires[] = {"metal-hooks", nullptr};
}
BG3MFX_FEATURE(depthPrepass, {"depth-prepass", depthPrepassRequires, false, nullptr, installDepthPrepass, nullptr});
