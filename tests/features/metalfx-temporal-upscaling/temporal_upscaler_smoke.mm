#import "features/metalfx-temporal-upscaling/TemporalUpscaler.h"
#include <cmath>
#include <cstdlib>

static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger width, NSUInteger height,
                               MTLPixelFormat format, MTLTextureUsage usage) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:width height:height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = usage;
    return [device newTextureWithDescriptor:desc];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 1;
        NSError *error = nil;
        if (argc != 1 && argc != 5) return 9;
        const NSUInteger inW=argc==5 ? strtoul(argv[1],nullptr,10) : 256;
        const NSUInteger inH=argc==5 ? strtoul(argv[2],nullptr,10) : 256;
        const NSUInteger outW=argc==5 ? strtoul(argv[3],nullptr,10) : 512;
        const NSUInteger outH=argc==5 ? strtoul(argv[4],nullptr,10) : 512;
        if (inW<128 || inH<128 || outW<256 || outH<256 || outW>4096 || outH>4096) return 9;
        BG3MFXTemporalUpscaler *upscaler = [[BG3MFXTemporalUpscaler alloc] initWithDevice:device
            inputWidth:inW inputHeight:inH outputWidth:outW outputHeight:outH error:&error];
        if (!upscaler) { fprintf(stderr,"%s\n",error.description.UTF8String); return 2; }

        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void Fill(texture2d<float,access::write> color [[texture(0)]], "
            "texture2d<float,access::write> motion [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
            "color.write(float4(0.5,0.75,1.0,1),p); motion.write(float4(0,0,0,0),p); }\n"
            "kernel void Read(texture2d<float,access::read> src [[texture(0)]], device float4 *out [[buffer(0)]], "
            "uint2 p [[thread_position_in_grid]]) { out[p.y*src.get_width()+p.x]=src.read(p); }";
        BOOL patterned = getenv("BG3MFX_TEST_PATTERN") != nullptr;
        if (patterned) source = [source stringByReplacingOccurrencesOfString:@"color.write(float4(0.5,0.75,1.0,1),p);"
            withString:@"float v=((p.x/7+p.y/9)%2) ? 0.5 : 1.5; color.write(float4(v*0.5,v*0.75,v,1),p);"];
        BOOL moving = getenv("BG3MFX_TEST_MOTION") != nullptr;
        if (moving) source = [source stringByReplacingOccurrencesOfString:@"motion.write(float4(0,0,0,0),p);"
            withString:@"motion.write(float4(sin(float(p.x)*0.1)*1.5,cos(float(p.y)*0.1),0,0),p);"];
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        id<MTLComputePipelineState> fill = library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"Fill"] error:&error] : nil;
        id<MTLComputePipelineState> read = library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"Read"] error:&error] : nil;
        if (!fill || !read) { fprintf(stderr,"%s\n",error.description.UTF8String); return 3; }

        id<MTLTexture> color = texture(device,inW,inH,MTLPixelFormatRG11B10Float,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
        id<MTLTexture> motion = texture(device,inW,inH,MTLPixelFormatRG16Float,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
        id<MTLTexture> depth = texture(device,inW,inH,MTLPixelFormatDepth32Float_Stencil8,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        // BG3's live destination also allows render-target use, which lets
        // MetalFX write it directly; without it the upscaler copies its output.
        MTLTextureUsage outputUsage = MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        if (getenv("BG3MFX_TEST_DIRECT_OUTPUT")) outputUsage |= MTLTextureUsageRenderTarget;
        id<MTLTexture> output = texture(device,outW,outH,MTLPixelFormatRG11B10Float,outputUsage);
        id<MTLBuffer> pixels = [device newBufferWithLength:outW*outH*sizeof(float)*4 options:MTLResourceStorageModeShared];
        if (!color || !motion || !depth || !output || !pixels) return 4;
        id<MTLCommandQueue> queue = [device newCommandQueue];

        BG3MFXFrameParameters parameters = {};
        parameters.motionScaleX = parameters.motionScaleY = -1;
        parameters.depthReversed = YES;
        const BOOL bg3Jitter = getenv("BG3MFX_TEST_BG3_JITTER") != nullptr;
        const float bg3Samples[8][2] = {{0,-1.0f/6},{-0.25f,1.0f/6},{0.25f,-7.0f/18},{-0.375f,-1.0f/18},
            {0.125f,5.0f/18},{-0.125f,-5.0f/18},{0.375f,1.0f/18},{-0.4375f,7.0f/18}};
        for (int frame=0; frame<(bg3Jitter ? 32 : 3); ++frame) {
            if (moving) { parameters.jitterX=(frame-1)*0.25f; parameters.jitterY=frame==1 ? -0.166667f : 0.166667f; }
            if (bg3Jitter) {
                parameters.jitterX=bg3Samples[frame%8][0];
                parameters.jitterY=-bg3Samples[frame%8][1];
            }
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
            [encoder setComputePipelineState:fill]; [encoder setTexture:color atIndex:0]; [encoder setTexture:motion atIndex:1];
            [encoder dispatchThreads:MTLSizeMake(inW,inH,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [encoder endEncoding];

            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.clearDepth = getenv("BG3MFX_TEST_FAR_DEPTH") ? 0.0 : 0.5;
            id<MTLRenderCommandEncoder> depthEncoder = [buffer renderCommandEncoderWithDescriptor:pass];
            [depthEncoder endEncoding];

            if (![upscaler encodeColor:color deviceDepth:depth motion:motion parameters:parameters
                destination:output commandBuffer:buffer error:&error]) {
                fprintf(stderr,"%s\n",error.description.UTF8String); return 5;
            }
            encoder = [buffer computeCommandEncoder];
            [encoder setComputePipelineState:read]; [encoder setTexture:output atIndex:0]; [encoder setBuffer:pixels offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(outW,outH,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [encoder endEncoding]; [buffer commit]; [buffer waitUntilCompleted];
            if (buffer.status != MTLCommandBufferStatusCompleted) {
                fprintf(stderr,"%s\n",buffer.error.description.UTF8String); return 6;
            }
            float *p = (float *)pixels.contents;
            for (NSUInteger y=64; y<outH-64; y+=47) for (NSUInteger x=64; x<outW-64; x+=53)
                for (int c=0; c<3; ++c) {
                    const float expected[] = {0.5f,0.75f,1.0f};
                    const float actual = p[(y*outW+x)*4+c];
                    if (!std::isfinite(actual) || actual<0 || actual>2 || (!patterned && fabs(actual-expected[c])>0.08f)) {
                        fprintf(stderr,"Temporal HDR mismatch %lu,%lu channel %d: %f != %f\n",x,y,c,actual,expected[c]); return 7;
                    }
                }
            if (frame == 1) [upscaler resetHistory];
        }
        id<MTLCommandBuffer> unretained = [queue commandBufferWithUnretainedReferences];
        // Metal API validation may upgrade unretained command buffers to retained.
        BOOL accepted = [upscaler encodeColor:color deviceDepth:depth motion:motion parameters:parameters
            destination:output commandBuffer:unretained error:&error];
        if (accepted != unretained.retainedReferences) return 8;
        printf("Temporal BG3 HDR/depth conversion and MetalFX history passed %d-frame pixel checks; command-buffer lifetime guard checked.\n", bg3Jitter ? 32 : 3);
    }
}
