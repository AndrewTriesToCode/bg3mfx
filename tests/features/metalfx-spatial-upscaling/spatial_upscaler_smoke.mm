#import "features/metalfx-spatial-upscaling/SpatialUpscaler.h"
#include <cmath>

static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger width, NSUInteger height, MTLPixelFormat format) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    return [device newTextureWithDescriptor:desc];
}
int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        if (!device) return 1;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void Fill(texture2d<float,access::write> dst [[texture(0)]], uint2 p [[thread_position_in_grid]]) "
            "{ dst.write(float4(3.0,5.0,7.0,1.0),p); }\n"
            "kernel void Read(texture2d<float,access::read> src [[texture(0)]], device float4 *out [[buffer(0)]], "
            "uint2 p [[thread_position_in_grid]]) { out[p.y*src.get_width()+p.x]=src.read(p); }";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        id<MTLComputePipelineState> fill = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"Fill"] error:&error];
        id<MTLComputePipelineState> read = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"Read"] error:&error];
        BG3MFXSpatialUpscaler *upscaler = [[BG3MFXSpatialUpscaler alloc] initWithDevice:device
            inputWidth:256 inputHeight:256 outputWidth:512 outputHeight:512 error:&error];
        if (!upscaler || !fill || !read) { fprintf(stderr,"%s\n",error.description.UTF8String); return 2; }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLTexture> input = texture(device,256,256,MTLPixelFormatRG11B10Float);
        id<MTLTexture> destination = texture(device,512,512,MTLPixelFormatRG11B10Float);
        id<MTLBuffer> pixels = [device newBufferWithLength:512*512*4*sizeof(float) options:MTLResourceStorageModeShared];
        for (int frame=0; frame<3; ++frame) {
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
            [encoder setComputePipelineState:fill]; [encoder setTexture:input atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(256,256,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [encoder endEncoding];
            if (![upscaler encodeHDRColor:input destination:destination commandBuffer:buffer error:&error]) {
                fprintf(stderr,"%s\n",error.description.UTF8String); return 3;
            }
            encoder = [buffer computeCommandEncoder];
            [encoder setComputePipelineState:read]; [encoder setTexture:destination atIndex:0];
            [encoder setBuffer:pixels offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(512,512,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [encoder endEncoding]; [buffer commit]; [buffer waitUntilCompleted];
            if (buffer.status != MTLCommandBufferStatusCompleted) { fprintf(stderr,"%s\n",buffer.error.description.UTF8String); return 4; }
            float *p = (float *)pixels.contents;
            for (NSUInteger y=32; y<480; y+=37) for (NSUInteger x=32; x<480; x+=41)
                for (int c=0; c<3; ++c) {
                    float actual = p[(y*512+x)*4+c], expected = (float)(3+2*c);
                    // The source is BG3's linear-HDR pre-FSR_Tonemap image; it
                    // must survive the RGBA16Float conversion and scaling.
                    if (!std::isfinite(actual) || fabs(actual-expected)>expected*0.04f) {
                        fprintf(stderr,"HDR mismatch %lu,%lu channel %d: %f != %f\n",x,y,c,actual,expected); return 5;
                    }
                }
        }
        id<MTLCommandBuffer> unretained = [queue commandBufferWithUnretainedReferences];
        if ([upscaler encodeHDRColor:input destination:destination commandBuffer:unretained error:&error]) return 6;
        id<MTLCommandBuffer> valid = [queue commandBuffer];
        id<MTLTexture> wrong = texture(device,512,512,MTLPixelFormatRGBA8Unorm);
        if ([upscaler encodeHDRColor:input destination:wrong commandBuffer:valid error:&error]) return 7;
        puts("Spatial linear-HDR upscaler passed pixel checks on three frames; unsupported resources refused.");
    }
}
