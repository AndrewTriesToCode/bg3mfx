#import "features/improved-shadows/PointLightShadowFix.h"
#include "common/Notice.h"
#import <objc/runtime.h>
#include <atomic>
#include <cmath>
#include <mutex>

bool BG3MFXShadowFaceTile(int face, MTLViewport viewport, NSUInteger width, NSUInteger height, BG3MFXShadowTile *tile) {
    if (face < 0 || face > 3) return false;
    bool wide = face == 0 || face == 2;
    double size = wide ? viewport.width : viewport.height;
    if (size < 4.0 || size != std::floor(size) || (wide ? viewport.height : viewport.width) * 2.0 != size) return false;
    double x = viewport.originX - (face == 1 ? size / 2 : 0.0), y = viewport.originY - (face == 0 ? size / 2 : 0.0);
    if (x < 0.0 || y < 0.0 || x != std::floor(x) || y != std::floor(y)) return false;
    uint32_t region = (uint32_t)size;
    while (x + 2.0 * region > width || y + 2.0 * region > height) {
        if (region * 4 <= (uint32_t)size || region % 2) return false;
        region /= 2;
    }
    *tile = {(uint32_t)x, (uint32_t)y, (uint32_t)size, region};
    return true;
}

MTLViewport BG3MFXShadowFaceViewport(int face, MTLViewport viewport, const BG3MFXShadowTile &tile) {
    double scale = (double)tile.region / tile.size;
    viewport.originX = tile.x + (viewport.originX - tile.x) * scale + (face & 1) * (double)tile.region;
    viewport.originY = tile.y + (viewport.originY - tile.y) * scale + (face >> 1) * (double)tile.region;
    viewport.width *= scale;
    viewport.height *= scale;
    return viewport;
}

bool BG3MFXShadowCasterPipeline(MTLRenderPipelineDescriptor *desc) {
    if (!desc.vertexFunction || desc.depthAttachmentPixelFormat != MTLPixelFormatDepth32Float || !desc.rasterizationEnabled)
        return false;
    for (NSUInteger i = 0; i < 8; ++i)
        if (desc.colorAttachments[i].pixelFormat != MTLPixelFormatInvalid) return false;
    return true;
}

bool BG3MFXShadowAtlasPipeline(MTLRenderPipelineDescriptor *desc) {
    return [desc.fragmentFunction.name isEqualToString:@"LinearizeDepth"] &&
           desc.colorAttachments[0].pixelFormat == MTLPixelFormatR16Unorm;
}

id<MTLRenderPipelineState> BG3MFXPointLightShadowPipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor *desc,
                                                          BG3MFXCreateRenderPipeline create, NSError **error) {
    static std::mutex lock;
    static id<MTLDevice> cachedDevice;
    static id<MTLFunction> cachedFunction;
    id<MTLFunction> function;
    {
        std::lock_guard<std::mutex> guard(lock);
        if (cachedDevice != device) {
            id<MTLLibrary> library = [device newLibraryWithSource:@(BG3MFXPointLightShadowSource) options:nil error:error];
            id<MTLFunction> made = [library newFunctionWithName:@"LinearizeDepthTetrahedron"];
            if (!made) return nil;
            cachedDevice = device; cachedFunction = made;
        }
        function = cachedFunction;
    }
    MTLRenderPipelineDescriptor *clone = [desc copy];
    clone.fragmentFunction = function;
    static SEL selector = @selector(newRenderPipelineStateWithDescriptor:error:);
    return (__bridge_transfer id<MTLRenderPipelineState>)create(device, selector, clone, error);
}

namespace {
// What a claimed pipeline is.
enum : uintptr_t { Caster = 1, Atlas = 2 };
char kindKey, cloneKey;
std::atomic<bool> failed;

// A pending tile may cross render passes, but never command buffers or
// source textures. Weak identities do not retain obsolete scene resources.
struct ThreadState {
    __weak id<MTLCommandBuffer> buffer;
    __weak id<MTLTexture> depth;
    uint64_t generation = 0;
    bool moved = false;
    BG3MFXShadowTile tile = {};
};
thread_local ThreadState thread;

bool claim(id device, MTLRenderPipelineDescriptor *desc, id state, BG3MFXCreateRenderPipeline create) {
    if (failed.load(std::memory_order_relaxed)) return false;
    uintptr_t kind = BG3MFXShadowCasterPipeline(desc) ? Caster : BG3MFXShadowAtlasPipeline(desc) ? Atlas : 0;
    if (!kind) return false;
    if (kind == Atlas) {
        NSError *error = nil;
        id<MTLRenderPipelineState> clone = BG3MFXPointLightShadowPipeline(device, desc, create, &error);
        if (!clone) {
            if (!failed.exchange(true))
                BG3MFXFail([@"Point-light shadow fix kept BG3's shadows: " stringByAppendingString:error.localizedDescription ?: @"unknown error"], nil, nil);
            return false;
        }
        objc_setAssociatedObject(state, &cloneKey, clone, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(state, &kindKey, (__bridge id)(void *)kind, OBJC_ASSOCIATION_ASSIGN);
    return true;
}

// A shadow caster draw for a point light's face: drawn in its own region.
bool casterDraw(__unsafe_unretained id encoder, const BG3MFXEncoderCalls &calls, void (^call)(void)) {
    // Every incompatible caster invalidates the previous sequence, including
    // missing CPU constants and unsupported viewports.
    thread.moved = false; thread.buffer = nil; thread.depth = nil;
    id<MTLCommandBuffer> buffer = calls.commandBuffer ? calls.commandBuffer(encoder) : nil;
    id<MTLTexture> depth = calls.depthTarget ? calls.depthTarget(encoder) : nil;
    uint64_t generation = calls.commandBufferGeneration ? calls.commandBufferGeneration(encoder) : 0;
    if (!buffer || buffer.status != MTLCommandBufferStatusNotEnqueued || !depth || !generation) return false;
    auto *camera = static_cast<const BG3MFXShadowCamera *>(calls.fragmentConstants(encoder, BG3MFXShadowCameraIndex, sizeof(BG3MFXShadowCamera)));
    if (!camera) return false;
    int face = camera->tetrahedronFaceIndex;
    MTLViewport viewport;
    BG3MFXShadowTile tile;
    MTLScissorRect scissor;
    if (!calls.viewport(encoder, &viewport) ||
        !BG3MFXShadowFaceTile(face, viewport, depth.width, depth.height, &tile) || calls.scissor(encoder, &scissor))
        return false;
    thread.moved = true;
    thread.buffer = buffer; thread.depth = depth;
    thread.generation = generation;
    thread.tile = tile;
    if (face == 0 && tile.region == tile.size) return false;
    calls.setViewport(encoder, BG3MFXShadowFaceViewport(face, viewport, tile));
    call();
    calls.setViewport(encoder, viewport);
    return true;
}

// BG3's atlas copy after a moved point light: the compositing clone instead.
bool atlasDraw(__unsafe_unretained id encoder, __unsafe_unretained id state, __unsafe_unretained id<MTLTexture> source,
               const BG3MFXEncoderCalls &calls, void (^call)(void)) {
    if (!thread.moved) return false;
    thread.moved = false;
    id<MTLCommandBuffer> buffer = thread.buffer;
    id<MTLTexture> depth = thread.depth;
    thread.buffer = nil; thread.depth = nil;
    if (!buffer || buffer.status != MTLCommandBufferStatusNotEnqueued || !depth || depth != source ||
        !calls.commandBuffer || calls.commandBuffer(encoder) != buffer || !calls.commandBufferGeneration ||
        calls.commandBufferGeneration(encoder) != thread.generation) return false;
    id clone = objc_getAssociatedObject(state, &cloneKey);
    if (!clone) return false;
    calls.setPipeline(encoder, clone);
    calls.setFragmentBytes(encoder, &thread.tile, sizeof thread.tile, BG3MFXShadowTileIndex);
    call();
    calls.setPipeline(encoder, state);
    return true;
}

bool draw(__unsafe_unretained id encoder, __unsafe_unretained id state, __unsafe_unretained id<MTLTexture> source,
          __unsafe_unretained id<MTLTexture>, const BG3MFXEncoderCalls &calls, void (^call)(void)) {
    uintptr_t kind = (uintptr_t)(__bridge void *)objc_getAssociatedObject(state, &kindKey);
    if (kind == Caster) return casterDraw(encoder, calls, call);
    if (kind == Atlas) return atlasDraw(encoder, state, source, calls, call);
    return false;
}

}

BOOL BG3MFXInstallPointLightShadowFix(NSError **error) {
    if (BG3MFXMetalHooksReplaceDraws({claim, draw, 1u << BG3MFXShadowCameraIndex})) return YES;
    if (error) *error = [NSError errorWithDomain:@"BG3MFX" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"Another feature already replaces draws."}];
    return NO;
}
