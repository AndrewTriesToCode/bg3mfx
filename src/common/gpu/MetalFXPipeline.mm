#import "common/gpu/MetalFXPipeline.h"
#import "common/gpu/GPUResources.h"
#import <MetalFX/MetalFX.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

@interface BG3MFXFrame ()
@property(nonatomic, readwrite) id<MTLTexture> rendered;
@end

@implementation BG3MFXFrame
@end

static void failure(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"BG3MetalFX" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation BG3MFXPipeline {
    id<MTLDevice> _device;
    id<MTL4FXTemporalScaler> _temporal;
    BG3MFXMetal4Bridge *_bridge;
    BG3MFXTexturePool *_outputs;
    id<MTL4FXSpatialScaler> _spatial;
    NSUInteger _inputWidth, _inputHeight, _outputWidth, _outputHeight;
    // Smallest content region a reduced-content Temporal scaler accepts;
    // 0 when every frame must render the whole input.
    NSUInteger _minimumContentWidth, _minimumContentHeight;
    MTLPixelFormat _outputFormat;
    BOOL _reset;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device inputWidth:(NSUInteger)width inputHeight:(NSUInteger)height
                   outputWidth:(NSUInteger)outputWidth outputHeight:(NSUInteger)outputHeight
                   colorFormat:(MTLPixelFormat)colorFormat depthFormat:(MTLPixelFormat)depthFormat
                  motionFormat:(MTLPixelFormat)motionFormat outputFormat:(MTLPixelFormat)outputFormat error:(NSError **)error {
    return [self initWithDevice:device mode:BG3MFXScalingModeTemporal
        colorProcessingMode:MTLFXSpatialScalerColorProcessingModeHDR inputWidth:width inputHeight:height
        outputWidth:outputWidth outputHeight:outputHeight colorFormat:colorFormat depthFormat:depthFormat
        motionFormat:motionFormat outputFormat:outputFormat error:error];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device mode:(BG3MFXScalingMode)mode
           colorProcessingMode:(MTLFXSpatialScalerColorProcessingMode)colorProcessingMode
                    inputWidth:(NSUInteger)width inputHeight:(NSUInteger)height
                   outputWidth:(NSUInteger)outputWidth outputHeight:(NSUInteger)outputHeight
                   colorFormat:(MTLPixelFormat)colorFormat depthFormat:(MTLPixelFormat)depthFormat
                  motionFormat:(MTLPixelFormat)motionFormat outputFormat:(MTLPixelFormat)outputFormat error:(NSError **)error {
    return [self initWithDevice:device mode:mode colorProcessingMode:colorProcessingMode inputWidth:width
        inputHeight:height outputWidth:outputWidth outputHeight:outputHeight colorFormat:colorFormat
        depthFormat:depthFormat motionFormat:motionFormat outputFormat:outputFormat reducedContent:NO error:error];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device mode:(BG3MFXScalingMode)mode
           colorProcessingMode:(MTLFXSpatialScalerColorProcessingMode)colorProcessingMode
                    inputWidth:(NSUInteger)width inputHeight:(NSUInteger)height
                   outputWidth:(NSUInteger)outputWidth outputHeight:(NSUInteger)outputHeight
                   colorFormat:(MTLPixelFormat)colorFormat depthFormat:(MTLPixelFormat)depthFormat
                  motionFormat:(MTLPixelFormat)motionFormat outputFormat:(MTLPixelFormat)outputFormat
             reducedContent:(BOOL)reducedContent error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    if (!device || (mode != BG3MFXScalingModeTemporal && mode != BG3MFXScalingModeSpatial)) {
        failure(error, @"Unknown MetalFX scaler or device"); return nil;
    }
    if (!width || !height || width > outputWidth || height > outputHeight ||
        (double)outputWidth / width > 3 || (double)outputHeight / height > 3) {
        failure(error, @"Unsupported input/output dimensions"); return nil;
    }
    NSError *compilerError=nil;
    id<MTL4Compiler> compiler=[device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&compilerError];
    if (!compiler) { failure(error,compilerError.localizedDescription ?: @"Could not create the Metal 4 compiler"); return nil; }

    if (mode == BG3MFXScalingModeSpatial) {
        if (![MTLFXSpatialScalerDescriptor supportsMetal4FX:device]) {
            failure(error, @"This GPU does not support Metal 4 MetalFX spatial upscaling"); return nil;
        }
        if (colorProcessingMode < MTLFXSpatialScalerColorProcessingModePerceptual ||
            colorProcessingMode > MTLFXSpatialScalerColorProcessingModeHDR) {
            failure(error, @"Unknown spatial color processing mode"); return nil;
        }
        MTLFXSpatialScalerDescriptor *descriptor = [MTLFXSpatialScalerDescriptor new];
        descriptor.inputWidth = width; descriptor.inputHeight = height;
        descriptor.outputWidth = outputWidth; descriptor.outputHeight = outputHeight;
        descriptor.colorTextureFormat = colorFormat; descriptor.outputTextureFormat = outputFormat;
        descriptor.colorProcessingMode = colorProcessingMode;
        _spatial = [descriptor newSpatialScalerWithDevice:device compiler:compiler];
        if (!_spatial) { failure(error, @"MetalFX could not create the spatial scaler for these formats"); return nil; }
    } else {
        if (![MTLFXTemporalScalerDescriptor supportsMetal4FX:device]) {
            failure(error, @"This GPU does not support Metal 4 MetalFX temporal upscaling"); return nil;
        }
        MTLFXTemporalScalerDescriptor *descriptor = [MTLFXTemporalScalerDescriptor new];
        descriptor.inputWidth = width; descriptor.inputHeight = height;
        descriptor.outputWidth = outputWidth; descriptor.outputHeight = outputHeight;
        descriptor.colorTextureFormat = colorFormat; descriptor.depthTextureFormat = depthFormat;
        descriptor.motionTextureFormat = motionFormat; descriptor.outputTextureFormat = outputFormat;
        descriptor.autoExposureEnabled = NO;
        descriptor.requiresSynchronousInitialization = YES;
        if (reducedContent) {
            // Scale is output / rendered content: the full input is the
            // smallest, the device limit the largest.
            float fullScale = (float)std::max((double)outputWidth / width, (double)outputHeight / height);
            float maximum = [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device];
            if (!(maximum > fullScale)) { failure(error, @"This GPU cannot scale a smaller region of these inputs"); return nil; }
            descriptor.inputContentPropertiesEnabled = YES;
            descriptor.inputContentMinScale = std::max(fullScale, [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device]);
            descriptor.inputContentMaxScale = maximum;
            _minimumContentWidth = (NSUInteger)std::ceil(outputWidth / maximum);
            _minimumContentHeight = (NSUInteger)std::ceil(outputHeight / maximum);
        }
        _temporal = [descriptor newTemporalScalerWithDevice:device compiler:compiler];
        if (!_temporal) { failure(error, @"MetalFX could not create the temporal scaler for these formats"); return nil; }
    }
    _bridge = [[BG3MFXMetal4Bridge alloc] initWithDevice:device label:@"BG3MFX upscaling" error:&compilerError];
    if (!_bridge) { failure(error,@"Could not create the Metal 4 upscaling queue"); return nil; }

    _device = device;
    _inputWidth = width; _inputHeight = height;
    _outputWidth = outputWidth; _outputHeight = outputHeight;
    _outputFormat = outputFormat;
    MTLTextureDescriptor *output = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:outputFormat
        width:outputWidth height:outputHeight mipmapped:NO];
    output.storageMode = MTLStorageModePrivate;
    output.usage = (_spatial ? _spatial.outputTextureUsage : _temporal.outputTextureUsage) | MTLTextureUsageShaderRead;
    _outputs = [[BG3MFXTexturePool alloc] initWithDevice:device descriptor:output];
    _reset = YES;
    return self;
}

- (BOOL)usesMetal4 { return YES; }
- (void)resetHistory { _reset = YES; }
- (void)releaseIdleResources { [_bridge releaseResidency]; }

- (BOOL)validTexture:(id<MTLTexture>)texture format:(MTLPixelFormat)format usage:(MTLTextureUsage)usage {
    return texture.device == _device && texture.textureType == MTLTextureType2D && texture.sampleCount == 1 &&
        texture.width == _inputWidth && texture.height == _inputHeight && texture.pixelFormat == format &&
        (texture.usage & usage) == usage && texture.storageMode != MTLStorageModeMemoryless && !texture.framebufferOnly &&
        texture.hazardTrackingMode != MTLHazardTrackingModeUntracked;
}

- (MTLTextureUsage)outputTextureUsage { return _spatial ? _spatial.outputTextureUsage : _temporal.outputTextureUsage; }
- (BG3MFXFrame *)encodeColor:(id<MTLTexture>)color depth:(id<MTLTexture>)depth motion:(id<MTLTexture>)motion
                 parameters:(BG3MFXFrameParameters)parameters
              commandBuffer:(id<MTLCommandBuffer>)buffer error:(NSError **)error {
    return [self encodeColor:color depth:depth motion:motion parameters:parameters output:nil commandBuffer:buffer error:error];
}
- (BG3MFXFrame *)encodeColor:(id<MTLTexture>)color depth:(id<MTLTexture>)depth motion:(id<MTLTexture>)motion
                 parameters:(BG3MFXFrameParameters)parameters output:(id<MTLTexture>)explicitOutput
              commandBuffer:(id<MTLCommandBuffer>)buffer error:(NSError **)error {
    if (buffer.device != _device || buffer.status != MTLCommandBufferStatusNotEnqueued || !buffer.retainedReferences) {
        failure(error, @"Expected an uncommitted command buffer with retained resources on the same device"); return nil;
    }
    if (![self validTexture:color format:(_spatial ? _spatial.colorTextureFormat : _temporal.colorTextureFormat)
        usage:(_spatial ? _spatial.colorTextureUsage : _temporal.colorTextureUsage)] ||
        (_temporal && (![self validTexture:depth format:_temporal.depthTextureFormat usage:_temporal.depthTextureUsage] ||
                       ![self validTexture:motion format:_temporal.motionTextureFormat usage:_temporal.motionTextureUsage]))) {
        [self resetHistory];
        failure(error, @"Input textures do not match MetalFX dimensions, formats, usage, or hazard tracking requirements");
        return nil;
    }
    if (_temporal && (!std::isfinite(parameters.jitterX) || !std::isfinite(parameters.jitterY) ||
        !std::isfinite(parameters.motionScaleX) || !std::isfinite(parameters.motionScaleY) ||
        parameters.motionScaleX == 0 || parameters.motionScaleY == 0)) {
        failure(error, @"Invalid jitter or motion-vector scale"); return nil;
    }
    NSUInteger contentWidth = parameters.contentWidth ?: color.width;
    NSUInteger contentHeight = parameters.contentHeight ?: color.height;
    BOOL wholeInput = contentWidth == color.width && contentHeight == color.height;
    if (contentWidth > color.width || contentHeight > color.height || !contentWidth || !contentHeight ||
        (_temporal && !wholeInput && (!_minimumContentWidth || contentWidth < _minimumContentWidth || contentHeight < _minimumContentHeight))) {
        failure(error, @"The rendered region is outside the range this MetalFX scaler accepts"); return nil;
    }

    id<MTLTexture> output = explicitOutput;
    if (output) {
        MTLTextureUsage required = self.outputTextureUsage;
        if (output.device != _device || output.width != _outputWidth || output.height != _outputHeight ||
            output.pixelFormat != _outputFormat || (output.usage & required) != required || output.framebufferOnly ||
            output.storageMode == MTLStorageModeMemoryless || output.hazardTrackingMode == MTLHazardTrackingModeUntracked) {
            failure(error, @"The output texture does not match the MetalFX output format, size, or usage"); return nil;
        }
    } else {
        // The output is valid until `buffer` completes; consumers encode into it.
        output = [_outputs acquire];
        if (!output) { failure(error, @"Output texture allocation failed"); return nil; }
        [_outputs relinquish:output afterCommandBuffer:buffer];
    }

    BG3MFXFrame *frame = [BG3MFXFrame new];
    frame.rendered = output;
    if (_spatial) {
        _spatial.colorTexture = color;
        _spatial.outputTexture = output;
        _spatial.inputContentWidth = contentWidth;
        _spatial.inputContentHeight = contentHeight;
        id<MTL4FXSpatialScaler> scaler=_spatial;
        BOOL encoded=[_bridge encodeIntoBuffer:buffer allocations:@[color,output] retained:@[scaler]
                encode:^(id<MTL4CommandBuffer> commands) {
                    commands.label=@"BG3 Metal 4 Spatial upscale"; [scaler encodeToCommandBuffer:commands];
                } failure:self.gpuFailureHandler error:error];
        // The scaler retains its textures; the command buffer keeps them for the GPU.
        _spatial.colorTexture = nil; _spatial.outputTexture = nil;
        if (!encoded) return nil;
    } else {
        _temporal.colorTexture = color;
        _temporal.depthTexture = depth;
        _temporal.motionTexture = motion;
        _temporal.outputTexture = output;
        _temporal.inputContentWidth = contentWidth;
        _temporal.inputContentHeight = contentHeight;
        _temporal.jitterOffsetX = parameters.jitterX;
        _temporal.jitterOffsetY = parameters.jitterY;
        _temporal.motionVectorScaleX = parameters.motionScaleX;
        _temporal.motionVectorScaleY = parameters.motionScaleY;
        _temporal.depthReversed = parameters.depthReversed;
        _temporal.preExposure = 1.0f;
        _temporal.reset = _reset || parameters.reset;
        // GPU-only bridge: producer passes -> Metal 4 FX -> native consumers.
        id<MTL4FXTemporalScaler> scaler=_temporal;
        BOOL encoded=[_bridge encodeIntoBuffer:buffer allocations:@[color,depth,motion,output] retained:@[scaler]
                encode:^(id<MTL4CommandBuffer> commands) {
                    commands.label=@"BG3 Metal 4 Temporal upscale"; [scaler encodeToCommandBuffer:commands];
                } failure:self.gpuFailureHandler error:error];
        // The scaler retains its textures, which would keep a cached size's last
        // BG3 render targets alive after a resize. Encoding is done, and the
        // command buffer (or the Metal 4 bridge) keeps them until the GPU finishes.
        _temporal.colorTexture = nil; _temporal.depthTexture = nil;
        _temporal.motionTexture = nil; _temporal.outputTexture = nil;
        if (!encoded) { [self resetHistory]; return nil; }
    }
    _reset = NO;
    return frame;
}
@end
