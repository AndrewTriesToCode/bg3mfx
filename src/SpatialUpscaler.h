#import "MetalFXPipeline.h"
NS_ASSUME_NONNULL_BEGIN

// BG3 replacement at the native FSR boundary. Input is linear HDR
// scene color captured before FSR_Tonemap; output replaces the FSR result.
@interface BG3MFXSpatialUpscaler : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            inputWidth:(NSUInteger)width inputHeight:(NSUInteger)height
                           outputWidth:(NSUInteger)outputWidth outputHeight:(NSUInteger)outputHeight
                                 error:(NSError **)error;
- (BOOL)encodeHDRColor:(id<MTLTexture>)input destination:(id<MTLTexture>)destination
      commandBuffer:(id<MTLCommandBuffer>)buffer error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
