#import "features/cluster-buffer-guard/ClusterBufferGuard.h"
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
