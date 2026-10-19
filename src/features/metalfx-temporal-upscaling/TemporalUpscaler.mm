#import "features/metalfx-temporal-upscaling/TemporalUpscaler.h"
#import "common/gpu/GPUResources.h"
#include <atomic>
#include <algorithm>
#include <cstdlib>

#ifndef BG3MFX_NO_TRACE
// Opt-in local capture for replay and reconstruction-quality investigation.
static void captureInputs(id<MTLCommandBuffer> buffer, id<MTLTexture> color,
                          id<MTLTexture> depth, id<MTLTexture> motion,
                          BG3MFXFrameParameters p, NSUInteger outW, NSUInteger outH) {
    const char *directory = getenv("BG3MFX_CAPTURE_TEMPORAL");
    static std::atomic<unsigned> frames{0};
    if (!directory) return;
    // A marker permits capturing the loaded scene rather than startup frames.
    const char *arm = getenv("BG3MFX_CAPTURE_TEMPORAL_ARM");
    if (arm && ![NSFileManager.defaultManager fileExistsAtPath:@(arm)]) return;
    const char *count = getenv("BG3MFX_CAPTURE_TEMPORAL_FRAMES");
    unsigned limit = count ? (unsigned)std::max(1, std::min(16, atoi(count))) : 3;
    if (frames.load() >= limit) return;
    unsigned frame = frames.fetch_add(1);
    if (frame >= limit) return;
    NSString *root = @(directory);
    NSMutableDictionary *buffers = [NSMutableDictionary dictionary], *rows = [NSMutableDictionary dictionary];
    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
    NSArray *textures = @[color,depth,motion], *names = @[@"color",@"depth",@"motion"];
    for (NSUInteger i=0;i<3;++i) {
        id<MTLTexture> t = textures[i];
        NSUInteger row = (t.width*(i==0 ? 8 : 4)+255)&~NSUInteger(255);
        id<MTLBuffer> data = [buffer.device newBufferWithLength:row*t.height options:MTLResourceStorageModeShared];
        if (!data) { [encoder endEncoding]; return; }
        buffers[names[i]] = data; rows[names[i]] = @(row);
        [encoder copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(t.width,t.height,1) toBuffer:data destinationOffset:0
            destinationBytesPerRow:row destinationBytesPerImage:row*t.height];
    }
    [encoder endEncoding];
    NSDictionary *metadata = @{@"width":@(color.width),@"height":@(color.height),@"outputWidth":@(outW),@"outputHeight":@(outH),
        @"rows":rows,@"jitterX":@(p.jitterX),@"jitterY":@(p.jitterY),@"motionScaleX":@(p.motionScaleX),
        @"motionScaleY":@(p.motionScaleY),@"depthReversed":@(p.depthReversed),@"reset":@(p.reset)};
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status != MTLCommandBufferStatusCompleted) return;
        [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *prefix = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%u",frame]];
        for (NSString *name in names) {
            id<MTLBuffer> data = buffers[name];
            [[NSData dataWithBytes:data.contents length:data.length] writeToFile:[prefix stringByAppendingFormat:@"-%@.bin",name] atomically:YES];
        }
        [[NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:[prefix stringByAppendingString:@".json"] atomically:YES];
    }];
}
#endif
#include <cmath>

@implementation BG3MFXTemporalUpscaler {
    id<MTLDevice> _device;
    id<MTLComputePipelineState> _copyDepth, _copyColor;
    BG3MFXPipeline *_scaler;
    BG3MFXTexturePool *_colors, *_depths;
    NSUInteger _inputWidth, _inputHeight, _outputWidth, _outputHeight;
    NSLock *_lock;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device inputWidth:(NSUInteger)width
                    inputHeight:(NSUInteger)height outputWidth:(NSUInteger)outputWidth
                   outputHeight:(NSUInteger)outputHeight error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (!device || !width || !height || outputWidth <= width || outputHeight <= height ||
        (double)outputWidth / width > 3.0 || (double)outputHeight / height > 3.0) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXTemporalUpscaler" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Unsupported temporal input or output dimensions."}];
        return nil;
    }
    _device = device; _inputWidth = width; _inputHeight = height;
    _outputWidth = outputWidth; _outputHeight = outputHeight; _lock = [NSLock new];

    // PPTAA's Current input is linear HDR. FSR_Tonemap compresses it later,
    // before native FSR; only Spatial captures that bounded texture. Preserve
    // HDR at both ends of Temporal for native tone mapping and UI composition.
    // MetalFX reads BG3's RG11B10 color and D32S8 depth directly and writes
    // RG11B10. These kernels only convert for diagnostic input capture, and
    // copy the output when BG3's destination lacks MetalFX's output usage.
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void BG3MFXCopyTemporalDepth(depth2d<float> src [[texture(0)]], "
        "texture2d<float,access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
        "if(any(p>=uint2(dst.get_width(),dst.get_height()))) return;"
        "constexpr sampler s(coord::pixel,filter::nearest,address::clamp_to_edge);"
        "dst.write(src.sample(s,float2(p)+0.5),p);}\n"
        "kernel void BG3MFXCopyTemporalColor(texture2d<float,access::read> src [[texture(0)]], "
        "texture2d<float,access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
        "if(any(p>=uint2(dst.get_width(),dst.get_height()))) return;"
        "float3 c=max(src.read(p).rgb,0.0);"
        "dst.write(float4(c,1.0),p);}\n";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:error];
    if (!library) return nil;
    _copyDepth = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"BG3MFXCopyTemporalDepth"] error:error];
    _copyColor = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"BG3MFXCopyTemporalColor"] error:error];
    if (!_copyDepth || !_copyColor) return nil;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
        width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _colors = [[BG3MFXTexturePool alloc] initWithDevice:device descriptor:desc];
    desc.pixelFormat = MTLPixelFormatR32Float;
    _depths = [[BG3MFXTexturePool alloc] initWithDevice:device descriptor:desc];
    _scaler = [[BG3MFXPipeline alloc] initWithDevice:device mode:BG3MFXScalingModeTemporal
        colorProcessingMode:MTLFXSpatialScalerColorProcessingModeHDR inputWidth:width inputHeight:height
        outputWidth:outputWidth outputHeight:outputHeight colorFormat:MTLPixelFormatRG11B10Float
        depthFormat:MTLPixelFormatDepth32Float_Stencil8 motionFormat:MTLPixelFormatRG16Float
        outputFormat:MTLPixelFormatRG11B10Float error:error];
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
#ifndef BG3MFX_NO_TRACE
    // Input capture files keep the earlier RGBA16F/R32F layout for replay tools.
    if (getenv("BG3MFX_CAPTURE_TEMPORAL")) {
        id<MTLTexture> hdrColor = [_colors acquire], depthCopy = [_depths acquire];
        if (hdrColor && depthCopy && (encoder = [buffer computeCommandEncoder])) {
            [_colors relinquish:hdrColor afterCommandBuffer:buffer]; [_depths relinquish:depthCopy afterCommandBuffer:buffer];
            [encoder setComputePipelineState:_copyColor];
            [encoder setTexture:color atIndex:0]; [encoder setTexture:hdrColor atIndex:1];
            [encoder dispatchThreads:MTLSizeMake(_inputWidth,_inputHeight,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [encoder setComputePipelineState:_copyDepth];
            [encoder setTexture:deviceDepth atIndex:0]; [encoder setTexture:depthCopy atIndex:1];
            [encoder dispatchThreads:MTLSizeMake(_inputWidth,_inputHeight,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [encoder endEncoding];
            captureInputs(buffer,hdrColor,depthCopy,motion,parameters,_outputWidth,_outputHeight);
        }
    }
#endif
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
