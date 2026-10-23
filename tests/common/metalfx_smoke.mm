#import "common/gpu/MetalFXPipeline.h"
#include <vector>
#include <cmath>
#include <cstdlib>
#include <cstring>

static id<MTLTexture> input(id<MTLDevice> device, MTLPixelFormat format, NSUInteger width, NSUInteger height) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    return [device newTextureWithDescriptor:desc];
}
static id<MTLBuffer> readback(id<MTLCommandBuffer> buffer, id<MTLTexture> texture) {
    NSUInteger row = texture.width * 4;
    id<MTLBuffer> result = [buffer.device newBufferWithLength:row * texture.height options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
    [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(texture.width,texture.height,1) toBuffer:result destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:row*texture.height];
    [encoder endEncoding];
    return result;
}
static bool check(id<MTLBuffer> buffer) {
    uint8_t *pixels = (uint8_t *)buffer.contents;
    // Skip borders; check several interior samples rather than a single pixel.
    for (NSUInteger y=64; y<448; y+=37) for (NSUInteger x=64; x<448; x+=41) {
        uint8_t *p = pixels + (y*512+x)*4;
        if (abs((int)p[0]-64)>10 || abs((int)p[1]-128)>10 || abs((int)p[2]-192)>10) {
            fprintf(stderr,"Unexpected output at %lu,%lu: %u,%u,%u\n",x,y,p[0],p[1],p[2]); return false;
        }
    }
    return true;
}
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 1;
        NSError *error = nil;
        BG3MFXPipeline *pipeline = [[BG3MFXPipeline alloc] initWithDevice:device inputWidth:256 inputHeight:256
            outputWidth:512 outputHeight:512 colorFormat:MTLPixelFormatRGBA8Unorm depthFormat:MTLPixelFormatR32Float
            motionFormat:MTLPixelFormatRG16Float outputFormat:MTLPixelFormatRGBA8Unorm error:&error];
        if (!pipeline) { fprintf(stderr,"%s\n",error.description.UTF8String); return 2; }
        BOOL expected4=[MTLFXTemporalScalerDescriptor supportsMetal4FX:device];
        const char *api=getenv("BG3MFX_TEMPORAL_API");
        if(api && !strcmp(api,"metal3")) expected4=NO;
        if(pipeline.usesMetal4!=expected4) return 20;
        printf("Temporal selected %s.\n",pipeline.usesMetal4 ? "Metal4" : "Metal3");
        id<MTLTexture> color = input(device,MTLPixelFormatRGBA8Unorm,256,256);
        id<MTLTexture> depth = input(device,MTLPixelFormatR32Float,256,256);
        id<MTLTexture> motion = input(device,MTLPixelFormatRG16Float,256,256);
        std::vector<uint8_t> colors(256*256*4);
        for (size_t i=0;i<colors.size();i+=4) { colors[i]=64;colors[i+1]=128;colors[i+2]=192;colors[i+3]=255; }
        std::vector<float> depths(256*256,0.5f);
        std::vector<uint16_t> motions(256*256*2,0);
        [color replaceRegion:MTLRegionMake2D(0,0,256,256) mipmapLevel:0 withBytes:colors.data() bytesPerRow:1024];
        [depth replaceRegion:MTLRegionMake2D(0,0,256,256) mipmapLevel:0 withBytes:depths.data() bytesPerRow:1024];
        [motion replaceRegion:MTLRegionMake2D(0,0,256,256) mipmapLevel:0 withBytes:motions.data() bytesPerRow:1024];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        BG3MFXFrameParameters parameters = {};
        parameters.motionScaleX = parameters.motionScaleY = 1;
        for (int frameIndex=0; frameIndex<4; ++frameIndex) {
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            BG3MFXFrame *frame = [pipeline encodeColor:color depth:depth motion:motion parameters:parameters
                commandBuffer:buffer error:&error];
            if (!frame) { fprintf(stderr,"%s\n",error.description.UTF8String); return 3; }
            id<MTLBuffer> actual = readback(buffer,frame.rendered);
            [buffer commit]; [buffer waitUntilCompleted];
            if (buffer.status != MTLCommandBufferStatusCompleted) { fprintf(stderr,"%s\n",buffer.error.description.UTF8String); return 5; }
            if (!check(actual)) return 6;
        }
        [pipeline resetHistory];
        id<MTLCommandBuffer> buffer = [queue commandBuffer];
        BG3MFXFrame *reset = [pipeline encodeColor:color depth:depth motion:motion parameters:parameters
            commandBuffer:buffer error:&error];
        if (!reset) return 7;
        [buffer commit]; [buffer waitUntilCompleted];
        if (buffer.status != MTLCommandBufferStatusCompleted) return 8;
        // A mismatched depth texture must be refused before encoding GPU work.
        id<MTLTexture> wrongDepth = input(device,MTLPixelFormatR32Float,128,128);
        buffer = [queue commandBuffer];
        if ([pipeline encodeColor:color depth:wrongDepth motion:motion parameters:parameters commandBuffer:buffer error:&error]) return 9;
        // Dynamic resolution: a 384² input scaler renders 256² or the whole
        // input per frame. Red outside the 256² region must never be read.
        {
            // A scaler without dynamic resolution refuses a smaller region.
            BG3MFXFrameParameters region = parameters; region.contentWidth = region.contentHeight = 128;
            buffer = [queue commandBuffer];
            if ([pipeline encodeColor:color depth:depth motion:motion parameters:region commandBuffer:buffer error:&error]) return 13;
            BG3MFXPipeline *dynamic = [[BG3MFXPipeline alloc] initWithDevice:device mode:BG3MFXScalingModeTemporal
                colorProcessingMode:MTLFXSpatialScalerColorProcessingModeHDR inputWidth:384 inputHeight:384
                outputWidth:512 outputHeight:512 colorFormat:MTLPixelFormatRGBA8Unorm depthFormat:MTLPixelFormatR32Float
                motionFormat:MTLPixelFormatRG16Float outputFormat:MTLPixelFormatRGBA8Unorm dynamicResolution:YES error:&error];
            if (!dynamic) { fprintf(stderr,"%s\n",error.description.UTF8String); return 14; }
            id<MTLTexture> full = input(device,MTLPixelFormatRGBA8Unorm,384,384), partial = input(device,MTLPixelFormatRGBA8Unorm,384,384);
            id<MTLTexture> bigDepth = input(device,MTLPixelFormatR32Float,384,384), bigMotion = input(device,MTLPixelFormatRG16Float,384,384);
            std::vector<uint8_t> uniform(384*384*4), outside(384*384*4);
            for (size_t y=0;y<384;++y) for (size_t x=0;x<384;++x) {
                uint8_t *u=&uniform[(y*384+x)*4], *o=&outside[(y*384+x)*4];
                u[0]=64;u[1]=128;u[2]=192;u[3]=255;
                bool inside = x<256 && y<256;
                o[0]=inside?64:255;o[1]=inside?128:0;o[2]=inside?192:0;o[3]=255;
            }
            std::vector<float> bigDepths(384*384,0.5f);
            std::vector<uint16_t> bigMotions(384*384*2,0);
            [full replaceRegion:MTLRegionMake2D(0,0,384,384) mipmapLevel:0 withBytes:uniform.data() bytesPerRow:384*4];
            [partial replaceRegion:MTLRegionMake2D(0,0,384,384) mipmapLevel:0 withBytes:outside.data() bytesPerRow:384*4];
            [bigDepth replaceRegion:MTLRegionMake2D(0,0,384,384) mipmapLevel:0 withBytes:bigDepths.data() bytesPerRow:384*4];
            [bigMotion replaceRegion:MTLRegionMake2D(0,0,384,384) mipmapLevel:0 withBytes:bigMotions.data() bytesPerRow:384*4];
            const NSUInteger sizes[] = {256,256,384,384,256,256};
            for (NSUInteger size : sizes) {
                BG3MFXFrameParameters p = parameters; p.contentWidth = p.contentHeight = size;
                buffer = [queue commandBuffer];
                BG3MFXFrame *frame = [dynamic encodeColor:size==384 ? full : partial depth:bigDepth motion:bigMotion
                    parameters:p commandBuffer:buffer error:&error];
                if (!frame) { fprintf(stderr,"%s\n",error.description.UTF8String); return 15; }
                id<MTLBuffer> actual = readback(buffer,frame.rendered);
                [buffer commit]; [buffer waitUntilCompleted];
                if (buffer.status != MTLCommandBufferStatusCompleted) { fprintf(stderr,"%s\n",buffer.error.description.UTF8String); return 16; }
                if (!check(actual)) { fprintf(stderr,"Dynamic region %lu\n",(unsigned long)size); return 17; }
            }
            // A region beyond the device's largest scale is refused.
            BG3MFXFrameParameters tiny = parameters; tiny.contentWidth = tiny.contentHeight = 32;
            buffer = [queue commandBuffer];
            if ([dynamic encodeColor:partial depth:bigDepth motion:bigMotion parameters:tiny commandBuffer:buffer error:&error]) return 18;
            printf("Dynamic resolution: 384² inputs scaled 256²/384² regions to 512² (max scale %.2f).\n",
                [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device]);
        }
        // Spatial scaling neither requires nor consumes motion, depth, or jitter.
        // Verify all explicit color-processing modes independently of temporal AA.
        for (NSInteger mode = MTLFXSpatialScalerColorProcessingModePerceptual;
             mode <= MTLFXSpatialScalerColorProcessingModeHDR; ++mode) {
            BG3MFXPipeline *spatial = [[BG3MFXPipeline alloc] initWithDevice:device mode:BG3MFXScalingModeSpatial
                colorProcessingMode:(MTLFXSpatialScalerColorProcessingMode)mode inputWidth:256 inputHeight:256
                outputWidth:512 outputHeight:512 colorFormat:MTLPixelFormatRGBA8Unorm depthFormat:MTLPixelFormatR32Float
                motionFormat:MTLPixelFormatRG16Float outputFormat:MTLPixelFormatRGBA8Unorm error:&error];
            if (!spatial) { fprintf(stderr,"%s\n",error.description.UTF8String); return 10; }
            BG3MFXFrameParameters unused = {};
            unused.jitterX = NAN;
            buffer = [queue commandBuffer];
            BG3MFXFrame *scaled = [spatial encodeColor:color depth:nil motion:nil parameters:unused
                commandBuffer:buffer error:&error];
            if (!scaled) return 11;
            id<MTLBuffer> pixels = readback(buffer,scaled.rendered);
            [buffer commit]; [buffer waitUntilCompleted];
            if (buffer.status != MTLCommandBufferStatusCompleted || !check(pixels)) return 12;
        }
        puts("MetalFX 256→512 spatial/temporal upscaling passed pixel checks; history reset and invalid inputs checked");
    }
    return 0;
}
