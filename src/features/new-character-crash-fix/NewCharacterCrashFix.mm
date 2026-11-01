#include "common/Feature.h"
#import "features/new-character-crash-fix/NewCharacterCrashFix.h"
#import "features/metal-hooks/MetalHooks.h"
#import <objc/runtime.h>
#include <atomic>
#include <mutex>

// ClusteredAssignmentStage sizes the buffer as ceil(w/72)*ceil(h/72) tiles of
// 46 slices × 16 bytes (736 bytes per tile). 8 MB covers an 8K render (about
// 4.7 MB). Shared storage starts zero-filled, which reads as no lights.
static constexpr NSUInteger standInBytes = 8u << 20;
static std::atomic<void *> standIn{nullptr};

static id<MTLBuffer> standInFor(id<MTLDevice> device) {
    void *existing = standIn.load(std::memory_order_acquire);
    if (existing) {
        id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)existing;
        if (buffer.device == device) return buffer;
        return nil;  // BG3 renders with one device; never mix another's buffer in.
    }
    static std::mutex creating;
    std::lock_guard<std::mutex> lock(creating);
    if ((existing = standIn.load(std::memory_order_acquire)))
        return ((__bridge id<MTLBuffer>)existing).device == device ? (__bridge id<MTLBuffer>)existing : nil;
    // Untracked: bound to every encoder, a tracked buffer that one pass writes
    // would make Metal order all of them after each other.
    id<MTLBuffer> buffer = [device newBufferWithLength:standInBytes
        options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
    if (!buffer) return nil;
    buffer.label = @"BG3MFX cluster stand-in";
    standIn.store((__bridge_retained void *)buffer, std::memory_order_release);  // kept for the process
    return buffer;
}

void BG3MFXBindClusterStandIns(id encoder, BOOL compute) {
    if (!encoder) return;
    id<MTLBuffer> buffer = standInFor([encoder device]);
    if (!buffer) return;
    if (compute) {
        id<MTLComputeCommandEncoder> computeEncoder = encoder;
        [computeEncoder setBuffer:buffer offset:0 atIndex:BG3MFXClusterInfoIndex];
        [computeEncoder setBuffer:buffer offset:0 atIndex:BG3MFXClusterInfoWriteIndex];
    } else {
        [(id<MTLRenderCommandEncoder>)encoder setFragmentBuffer:buffer offset:0 atIndex:BG3MFXClusterInfoIndex];
    }
}

BOOL BG3MFXIsClusterStandIn(id<MTLBuffer> buffer) {
    return buffer && (__bridge void *)buffer == standIn.load(std::memory_order_acquire);
}

namespace {
void (*reportEvent)(NSDictionary *);
void newEncoder(id encoder, BOOL compute) { BG3MFXBindClusterStandIns(encoder, compute); }
#ifndef BG3MFX_NO_TRACE
// Diagnostics: what BG3 left at compute indices 1 and 6, kept on the encoder as
// a tag, so dispatches show whether the stand-in was read.
char slotKeys[2];
NSNumber *const standInTag = @0, *const filledTag = @1;
void computeBind(id encoder, NSUInteger index, id buffer) {
    int slot = index == BG3MFXClusterInfoIndex ? 0 : index == BG3MFXClusterInfoWriteIndex ? 1 : -1;
    if (slot < 0) return;
    NSNumber *tag = !buffer ? nil : BG3MFXIsClusterStandIn(buffer) ? standInTag : filledTag;
    objc_setAssociatedObject(encoder, &slotKeys[slot], tag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// The passes Metal validation reported without ClusterInfoBuffer;
// VolumetricFogGather and the debug views don't declare it.
BOOL clusterPass(NSString *name) {
    return ([name hasPrefix:@"ClusteredLighting_"] && ![name hasPrefix:@"ClusteredLighting_Debug"])
        || [name isEqualToString:@"VolumetricFogInitialize"] || [name isEqualToString:@"VolumetricFogLighting"]
        || [name isEqualToString:@"ClusterAssignment"];
}
// Reports cluster passes that read the stand-in (BG3 left the slot unbound) or
// an explicit nil (which the guard cannot cover): the first few, then every 256th.
void dispatch(id encoder, NSString *name) {
    if (!clusterPass(name)) return;
    int slot = [name isEqualToString:@"ClusterAssignment"] ? 1 : 0;
    NSNumber *tag = objc_getAssociatedObject(encoder, &slotKeys[slot]);
    if (tag == filledTag) return;
    bool standIn = tag == standInTag;
    static std::atomic<unsigned> standIns{0}, nils{0};
    unsigned count = standIn ? ++standIns : ++nils;
    if (reportEvent && (count <= 8 || count % 256 == 0))
        reportEvent(@{@"event":@"clusterBufferGuard", @"pipeline":name, @"bound":standIn ? @"standIn" : @"nil", @"count":@(count)});
}
#endif
BOOL installNewCharacterCrashFix(const BG3MFXFeatureContext &context, NSError **) {
    reportEvent = context.report;
#ifndef BG3MFX_NO_TRACE
    BG3MFXMetalHooksOnComputeBind(computeBind);
    BG3MFXMetalHooksOnDispatch(dispatch);
#endif
    return BG3MFXMetalHooksOnNewEncoder(newEncoder);
}
const char *const newCharacterCrashFixRequires[] = {"metal-hooks", nullptr};
}
BG3MFX_FEATURE(newCharacterCrashFix, {"new-character-crash-fix", newCharacterCrashFixRequires, false, nullptr, installNewCharacterCrashFix, nullptr});
