#import "features/metalfx-spatial-upscaling/SpatialUpscaler.h"
#import "common/gpu/GPUResources.h"

@implementation BG3MFXSpatialUpscaler {
    id<MTLDevice> _device;
    id<MTLComputePipelineState> _copyHDRInput, _copyOutput;
    BG3MFXPipeline *_scaler;
    BG3MFXTexturePool *_inputs;
    NSUInteger _width, _height, _outputWidth, _outputHeight;
    NSLock *_lock;
}
static BOOL upscalerFailure(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"BG3MFXSpatialUpscaler" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device inputWidth:(NSUInteger)width
                   inputHeight:(NSUInteger)height outputWidth:(NSUInteger)outputWidth
                  outputHeight:(NSUInteger)outputHeight error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _device = device; _width = width; _height = height;
    _outputWidth = outputWidth; _outputHeight = outputHeight;
    _lock = [NSLock new];
    // Convert BG3's linear HDR scene color to MetalFX's RGBA16Float input.
    // No FSR decode is needed because this input is captured before FSR_Tonemap.
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void BG3MFXCopyHDRInput(texture2d<float,access::read> src [[texture(0)]], "
        "texture2d<float,access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
        "if(any(p>=uint2(dst.get_width(),dst.get_height()))) return;"
        "dst.write(float4(src.read(p).rgb,1.0),p);}\n"
        "kernel void BG3MFXCopySpatialOutput(texture2d<float,access::read> src [[texture(0)]], "
        "texture2d<float,access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
        "if(any(p>=uint2(dst.get_width(),dst.get_height()))) return; dst.write(src.read(p),p);}\n";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:error];
    if (!library) return nil;
    _copyHDRInput = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"BG3MFXCopyHDRInput"] error:error];
    if (!_copyHDRInput) return nil;
    _copyOutput = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"BG3MFXCopySpatialOutput"] error:error];
    if (!_copyOutput) return nil;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
        width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _inputs = [[BG3MFXTexturePool alloc] initWithDevice:device descriptor:desc];
    _scaler = [[BG3MFXPipeline alloc] initWithDevice:device mode:BG3MFXScalingModeSpatial
        colorProcessingMode:MTLFXSpatialScalerColorProcessingModeHDR inputWidth:width inputHeight:height
        outputWidth:outputWidth outputHeight:outputHeight colorFormat:MTLPixelFormatRGBA16Float
        depthFormat:MTLPixelFormatR32Float motionFormat:MTLPixelFormatRG16Float
        outputFormat:MTLPixelFormatRGBA16Float error:error];
    return _scaler ? self : nil;
}
- (BOOL)encodeHDRColor:(id<MTLTexture>)input destination:(id<MTLTexture>)destination
      commandBuffer:(id<MTLCommandBuffer>)buffer error:(NSError **)error {
    if (!input || !destination || input == destination || input.device != _device ||
        destination.device != _device || buffer.device != _device || !buffer.retainedReferences ||
        buffer.status != MTLCommandBufferStatusNotEnqueued || input.width != _width || input.height != _height ||
        destination.width != _outputWidth || destination.height != _outputHeight ||
        input.textureType != MTLTextureType2D || destination.textureType != MTLTextureType2D ||
        input.sampleCount != 1 || destination.sampleCount != 1 ||
        input.pixelFormat != MTLPixelFormatRG11B10Float || destination.pixelFormat != MTLPixelFormatRG11B10Float ||
        !(input.usage & MTLTextureUsageShaderRead) || !(destination.usage & MTLTextureUsageShaderWrite) ||
        input.framebufferOnly || destination.framebufferOnly ||
        input.storageMode == MTLStorageModeMemoryless || destination.storageMode == MTLStorageModeMemoryless ||
        input.hazardTrackingMode == MTLHazardTrackingModeUntracked ||
        destination.hazardTrackingMode == MTLHazardTrackingModeUntracked)
        return upscalerFailure(error,@"Unsupported BG3 Spatial resources or command-buffer lifetime.");
    id<MTLTexture> hdrInput = [_inputs acquire];
    if (!hdrInput) return upscalerFailure(error,@"Could not allocate the HDR input.");
    [_inputs relinquish:hdrInput afterCommandBuffer:buffer];
    [_lock lock];
    id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
    if (!encoder) { [_lock unlock]; return upscalerFailure(error,@"Could not create the HDR input encoder."); }
    [encoder setComputePipelineState:_copyHDRInput];
    [encoder setTexture:input atIndex:0]; [encoder setTexture:hdrInput atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(_width,_height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [encoder endEncoding];
    BG3MFXFrameParameters unused = {};
    BG3MFXFrame *frame = [_scaler encodeColor:hdrInput depth:nil motion:nil parameters:unused
        commandBuffer:buffer error:error];
    if (!frame) { [_lock unlock]; return NO; }
    encoder = [buffer computeCommandEncoder];
    if (!encoder) { [_lock unlock]; return upscalerFailure(error,@"Could not create the output encoder."); }
    [encoder setComputePipelineState:_copyOutput];
    [encoder setTexture:frame.rendered atIndex:0]; [encoder setTexture:destination atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(_outputWidth,_outputHeight,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [encoder endEncoding];
    // Keep the scaler instance alive through GPU completion as well as textures
    // retained by the command buffer. Intermediates come from pools.
    BG3MFXSpatialUpscaler *keepAlive = self;
    [buffer addCompletedHandler:^(id<MTLCommandBuffer>) { (void)keepAlive; (void)frame; }];
    [_lock unlock];
    return YES;
}
@end
