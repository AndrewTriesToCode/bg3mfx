#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, BG3MFXScalingMode) {
    BG3MFXScalingModeTemporal,
    BG3MFXScalingModeSpatial,
};

// These values must come from the game's camera and motion-vector convention.
// Do not infer them from the display resolution or invent zero motion vectors.
typedef struct {
    float jitterX, jitterY;
    float motionScaleX, motionScaleY;
    BOOL depthReversed, reset;
} BG3MFXFrameParameters;

@interface BG3MFXFrame : NSObject
@property(nonatomic, readonly) id<MTLTexture> rendered;
@end

// Encoding backend only. BG3 buffer discovery, HUD composition, menu integration,
// and presentation pacing are separate and are not implemented by this class.
@interface BG3MFXPipeline : NSObject
@property(nonatomic, readonly) BOOL usesMetal4;
// Metal 4 queue errors arrive independently of the game's Metal 3 completion.
@property(nonatomic, copy, nullable) void (^gpuFailureHandler)(NSError *error);
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            inputWidth:(NSUInteger)width
                           inputHeight:(NSUInteger)height
                           outputWidth:(NSUInteger)outputWidth
                          outputHeight:(NSUInteger)outputHeight
                           colorFormat:(MTLPixelFormat)colorFormat
                           depthFormat:(MTLPixelFormat)depthFormat
                          motionFormat:(MTLPixelFormat)motionFormat
                          outputFormat:(MTLPixelFormat)outputFormat
                                 error:(NSError **)error;
// Spatial scaling takes an already anti-aliased image. Color processing must
// match that image's actual encoding; it is not inferred from its pixel format.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  mode:(BG3MFXScalingMode)mode
                   colorProcessingMode:(MTLFXSpatialScalerColorProcessingMode)colorProcessingMode
                            inputWidth:(NSUInteger)width
                           inputHeight:(NSUInteger)height
                           outputWidth:(NSUInteger)outputWidth
                          outputHeight:(NSUInteger)outputHeight
                           colorFormat:(MTLPixelFormat)colorFormat
                           depthFormat:(MTLPixelFormat)depthFormat
                          motionFormat:(MTLPixelFormat)motionFormat
                          outputFormat:(MTLPixelFormat)outputFormat
                                 error:(NSError **)error;
- (nullable BG3MFXFrame *)encodeColor:(id<MTLTexture>)color
                               depth:(nullable id<MTLTexture>)depth
                              motion:(nullable id<MTLTexture>)motion
                          parameters:(BG3MFXFrameParameters)parameters
                       commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                               error:(NSError **)error;
// Encodes into `output` instead of a pooled texture. It must match the output
// format and size and include the scaler's required output usage.
- (nullable BG3MFXFrame *)encodeColor:(id<MTLTexture>)color
                               depth:(nullable id<MTLTexture>)depth
                              motion:(nullable id<MTLTexture>)motion
                          parameters:(BG3MFXFrameParameters)parameters
                              output:(nullable id<MTLTexture>)output
                       commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                               error:(NSError **)error;
// Required usage for an explicit output texture.
@property(nonatomic, readonly) MTLTextureUsage outputTextureUsage;
- (void)resetHistory;
// Drops the Metal 4 residency set, which keeps every input it has seen alive.
- (void)releaseIdleResources;
@end

NS_ASSUME_NONNULL_END
