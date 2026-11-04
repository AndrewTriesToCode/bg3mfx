#import "features/metalfx/temporal-upscaling/TemporalUpscaler.h"
#import "common/gpu/GPUResources.h"
#include <algorithm>

#include <cmath>

@implementation BG3MFXTemporalUpscaler {
    id<MTLDevice> _device;
    id<MTLComputePipelineState> _copyColor;
    BG3MFXPipeline *_scaler;
    NSUInteger _inputWidth, _inputHeight, _outputWidth, _outputHeight;
    NSLock *_lock;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device inputWidth:(NSUInteger)width
                    inputHeight:(NSUInteger)height outputWidth:(NSUInteger)outputWidth
                   outputHeight:(NSUInteger)outputHeight error:(NSError **)error {
    return [self initWithDevice:device inputWidth:width inputHeight:height outputWidth:outputWidth
        outputHeight:outputHeight dynamicResolution:NO error:error];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device inputWidth:(NSUInteger)width
                    inputHeight:(NSUInteger)height outputWidth:(NSUInteger)outputWidth
                   outputHeight:(NSUInteger)outputHeight dynamicResolution:(BOOL)dynamicResolution
                          error:(NSError **)error {
    if (!(self = [super init])) return nil;
    // A dynamic-resolution scaler may take full-size inputs (the Dynamic
    // qualities render at native size and shrink a region of it per frame).
    bool smaller = dynamicResolution ? outputWidth >= width && outputHeight >= height : outputWidth > width && outputHeight > height;
    if (!device || !width || !height || !smaller ||
        (double)outputWidth / width > 3.0 || (double)outputHeight / height > 3.0) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXTemporalUpscaler" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Unsupported temporal input or output dimensions."}];
        return nil;
    }
    _device = device; _inputWidth = width; _inputHeight = height;
    _outputWidth = outputWidth; _outputHeight = outputHeight; _lock = [NSLock new];

    // PPTAA's Current input is linear HDR. FSR_Tonemap compresses it later,
    // before native FSR; both MetalFX modes take color before it. Preserve
    // HDR at both ends of Temporal for native tone mapping and UI composition.
    // MetalFX reads BG3's RG11B10 color and D32S8 depth directly and writes
    // RG11B10. This kernel copies the output when BG3's destination lacks
    // MetalFX's output usage.
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void BG3MFXCopyTemporalColor(texture2d<float,access::read> src [[texture(0)]], "
        "texture2d<float,access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
        "if(any(p>=uint2(dst.get_width(),dst.get_height()))) return;"
        "float3 c=max(src.read(p).rgb,0.0);"
        "dst.write(float4(c,1.0),p);}\n";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:error];
    if (!library) return nil;
    _copyColor = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"BG3MFXCopyTemporalColor"] error:error];
    if (!_copyColor) return nil;
    _scaler = [[BG3MFXPipeline alloc] initWithDevice:device mode:BG3MFXScalingModeTemporal
        colorProcessingMode:MTLFXSpatialScalerColorProcessingModeHDR inputWidth:width inputHeight:height
        outputWidth:outputWidth outputHeight:outputHeight colorFormat:MTLPixelFormatRG11B10Float
        depthFormat:MTLPixelFormatDepth32Float_Stencil8 motionFormat:MTLPixelFormatRG16Float
        outputFormat:MTLPixelFormatRG11B10Float dynamicResolution:dynamicResolution error:error];
    return _scaler ? self : nil;
}

- (BOOL)usesMetal4 { return _scaler.usesMetal4; }
- (NSUInteger)outputHeight { return _outputHeight; }
- (void (^)(NSError *))gpuFailureHandler { return _scaler.gpuFailureHandler; }
- (void)setGpuFailureHandler:(void (^)(NSError *))handler { _scaler.gpuFailureHandler=handler; }

- (BOOL)encodeColor:(id<MTLTexture>)color deviceDepth:(id<MTLTexture>)deviceDepth
             motion:(id<MTLTexture>)motion parameters:(BG3MFXFrameParameters)parameters
        destination:(id<MTLTexture>)destination commandBuffer:(id<MTLCommandBuffer>)buffer
              error:(NSError **)error {
    BOOL valid = color && deviceDepth && motion && destination && buffer &&
        buffer.device == _device && buffer.status == MTLCommandBufferStatusNotEnqueued && buffer.retainedReferences &&
        color.device == _device && deviceDepth.device == _device && motion.device == _device && destination.device == _device &&
        color.width == _inputWidth && color.height == _inputHeight && color.pixelFormat == MTLPixelFormatRG11B10Float &&
        deviceDepth.width == _inputWidth && deviceDepth.height == _inputHeight &&
        deviceDepth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 &&
        motion.width == _inputWidth && motion.height == _inputHeight && motion.pixelFormat == MTLPixelFormatRG16Float &&
        destination.width == _outputWidth && destination.height == _outputHeight &&
        destination.pixelFormat == MTLPixelFormatRG11B10Float &&
        color.textureType == MTLTextureType2D && deviceDepth.textureType == MTLTextureType2D &&
        motion.textureType == MTLTextureType2D && destination.textureType == MTLTextureType2D &&
        color.sampleCount == 1 && deviceDepth.sampleCount == 1 && motion.sampleCount == 1 && destination.sampleCount == 1 &&
        (color.usage & MTLTextureUsageShaderRead) && (deviceDepth.usage & MTLTextureUsageShaderRead) &&
        (motion.usage & MTLTextureUsageShaderRead) && (destination.usage & MTLTextureUsageShaderWrite) &&
        !color.framebufferOnly && !deviceDepth.framebufferOnly && !motion.framebufferOnly && !destination.framebufferOnly &&
        color.storageMode != MTLStorageModeMemoryless && deviceDepth.storageMode != MTLStorageModeMemoryless &&
        motion.storageMode != MTLStorageModeMemoryless && destination.storageMode != MTLStorageModeMemoryless &&
        color.hazardTrackingMode != MTLHazardTrackingModeUntracked &&
        deviceDepth.hazardTrackingMode != MTLHazardTrackingModeUntracked &&
        motion.hazardTrackingMode != MTLHazardTrackingModeUntracked &&
        destination.hazardTrackingMode != MTLHazardTrackingModeUntracked &&
        std::isfinite(parameters.jitterX) && std::isfinite(parameters.jitterY) &&
        std::isfinite(parameters.motionScaleX) && std::isfinite(parameters.motionScaleY) &&
        parameters.motionScaleX != 0 && parameters.motionScaleY != 0;
    if (!valid) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXTemporalUpscaler" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"BG3 temporal color, depth, motion, or output resources do not match the validated MetalFX path."}];
        [_scaler resetHistory];
        return NO;
    }

    [_lock lock];
    id<MTLComputeCommandEncoder> encoder = nil;
    {
        // Write straight into BG3's destination when it allows MetalFX's output
        // usage; otherwise use a pooled output and one copy.
        MTLTextureUsage required = _scaler.outputTextureUsage;
        BOOL direct = (destination.usage & required) == required;
        BG3MFXFrame *frame = [_scaler encodeColor:color depth:deviceDepth motion:motion parameters:parameters
            output:direct ? destination : nil commandBuffer:buffer error:error];
        if (!frame) { [_lock unlock]; return NO; }
        if (!direct) {
            encoder = [buffer computeCommandEncoder];
            if (!encoder) goto encoderFailure;
            [encoder setComputePipelineState:_copyColor];
            [encoder setTexture:frame.rendered atIndex:0]; [encoder setTexture:destination atIndex:1];
            [encoder dispatchThreads:MTLSizeMake(_outputWidth,_outputHeight,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [encoder endEncoding];
        }
        BG3MFXTemporalUpscaler *keepAlive = self;
        [buffer addCompletedHandler:^(id<MTLCommandBuffer>) { (void)keepAlive; (void)frame; }];
    }
    [_lock unlock];
    return YES;

encoderFailure:
    if (error) *error = [NSError errorWithDomain:@"BG3MFXTemporalUpscaler" code:4
        userInfo:@{NSLocalizedDescriptionKey:@"Could not create a Metal encoder for temporal upscaling."}];
    [_scaler resetHistory];
    [_lock unlock];
    return NO;
}

- (void)resetHistory {
    [_lock lock];
    [_scaler resetHistory];
    [_lock unlock];
}

- (void)releaseIdleResources {
    [_lock lock];
    [_scaler releaseIdleResources];
    [_lock unlock];
}
@end
