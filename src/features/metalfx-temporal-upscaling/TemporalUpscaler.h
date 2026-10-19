#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "common/gpu/MetalFXPipeline.h"

NS_ASSUME_NONNULL_BEGIN

// BG3's sampling displacement uses clip-space Y. MetalFX wants the opposite
// image displacement in framebuffer pixels (Y down).
static inline void BG3MFXApplyTemporalJitter(BG3MFXFrameParameters *p, float x, float y) {
    p->jitterX = -x;
    p->jitterY = y;
}

// Live BG3 integration for one temporal frame. Input color is BG3's compact
// HDR encoding; depth and motion are the real scene buffers discovered at TAA.
@interface BG3MFXTemporalUpscaler : NSObject
@property(nonatomic, readonly) BOOL usesMetal4;
@property(nonatomic, readonly) NSUInteger outputHeight;
@property(nonatomic, copy, nullable) void (^gpuFailureHandler)(NSError *error);
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                              inputWidth:(NSUInteger)width
                             inputHeight:(NSUInteger)height
                            outputWidth:(NSUInteger)outputWidth
                           outputHeight:(NSUInteger)outputHeight
                                  error:(NSError **)error;
- (BOOL)encodeColor:(id<MTLTexture>)color
         deviceDepth:(id<MTLTexture>)deviceDepth
              motion:(id<MTLTexture>)motion
          parameters:(BG3MFXFrameParameters)parameters
         destination:(id<MTLTexture>)destination
       commandBuffer:(id<MTLCommandBuffer>)commandBuffer
               error:(NSError **)error;
- (void)resetHistory;
// Lets go of memory kept for the next frame while this size is not rendered.
- (void)releaseIdleResources;
@end

NS_ASSUME_NONNULL_END
