#import "common/gpu/MetalFXPipeline.h"
#include <cmath>
#include <cstdio>

// Several in-flight producer/scaler/consumer chains, followed by immediate
// backend destruction. Private inputs must be produced by GPU work, not CPU
// initialization, so a missing cross-queue dependency cannot silently pass.
int main() { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if (!device) return 1;
    NSError *error=nil;
    BG3MFXPipeline *pipeline=[[BG3MFXPipeline alloc] initWithDevice:device inputWidth:256 inputHeight:128
        outputWidth:512 outputHeight:256 colorFormat:MTLPixelFormatRGBA16Float depthFormat:MTLPixelFormatR32Float
        motionFormat:MTLPixelFormatRG16Float outputFormat:MTLPixelFormatRGBA16Float error:&error];
    if(!pipeline) { fprintf(stderr,"%s\n",error.description.UTF8String);return 2; }
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void Fill(texture2d<float,access::write> c [[texture(0)]],texture2d<float,access::write> d [[texture(1)]],"
        "texture2d<float,access::write> m [[texture(2)]],constant float &v [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {"
        "c.write(float4(v,v*0.5,v*0.25,1),p);d.write(float4(0.5),p);m.write(float4(0),p);}";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> fill=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"Fill"] error:&error];
    if(!fill) return 3;
    id<MTLCommandQueue> queue=[device newCommandQueue];
    NSMutableArray *buffers=[NSMutableArray array], *readbacks=[NSMutableArray array];
    BOOL metal4=pipeline.usesMetal4;
    for(unsigned frame=0;frame<8;++frame) { @autoreleasepool {
        id<MTLTexture> inputs[3];
        MTLPixelFormat formats[]={MTLPixelFormatRGBA16Float,MTLPixelFormatR32Float,MTLPixelFormatRG16Float};
        for(unsigned i=0;i<3;++i) {
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[i] width:256 height:128 mipmapped:NO];
            d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
            inputs[i]=[device newTextureWithDescriptor:d];
        }
        id<MTLCommandBuffer> b=[queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[b computeCommandEncoder];
        float value=0.1f*(frame+1);
        [encoder setComputePipelineState:fill];
        for(unsigned i=0;i<3;++i) [encoder setTexture:inputs[i] atIndex:i];
        [encoder setBytes:&value length:sizeof(value) atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(256,128,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[encoder endEncoding];
        BG3MFXFrameParameters p={};p.motionScaleX=p.motionScaleY=1;p.reset=YES;p.depthReversed=YES;
        BG3MFXFrame *result=[pipeline encodeColor:inputs[0] depth:inputs[1] motion:inputs[2] parameters:p commandBuffer:b error:&error];
        if(!result) { fprintf(stderr,"%s\n",error.description.UTF8String);return 4; }
        id<MTLBuffer> pixels=[device newBufferWithLength:512*256*8 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit=[b blitCommandEncoder];
        [blit copyFromTexture:result.rendered sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(512,256,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:4096 destinationBytesPerImage:pixels.length];
        [blit endEncoding];[buffers addObject:b];[readbacks addObject:pixels];[b commit];
    }}
    pipeline=nil; // Submission ownership must outlive the backend and its cache.
    for(unsigned frame=0;frame<8;++frame) {
        id<MTLCommandBuffer> b=buffers[frame];[b waitUntilCompleted];
        if(b.status!=MTLCommandBufferStatusCompleted) return 5;
        const __fp16 *data=(const __fp16 *)[readbacks[frame] contents];
        for(unsigned y=32;y<224;y+=29) for(unsigned x=32;x<480;x+=31) {
            float v=data[(y*512+x)*4], expected=0.1f*(frame+1);
            if(!std::isfinite(v) || std::abs(v-expected)>0.02f) {
                fprintf(stderr,"Frame %u: stale/invalid output %g, expected %g\n",frame,v,expected);return 6;
            }
        }
    }
    printf("%s bridge: eight in-flight GPU producers, scalers and consumers passed after backend destruction.\n",metal4 ? "Metal4" : "Metal3");
    if(!metal4) return 0;
    // BG3 can replace its render targets at the same size (live: save loads).
    // The Metal 4 residency set must not keep the replaced inputs allocated.
    pipeline=[[BG3MFXPipeline alloc] initWithDevice:device inputWidth:256 inputHeight:128
        outputWidth:512 outputHeight:256 colorFormat:MTLPixelFormatRGBA16Float depthFormat:MTLPixelFormatR32Float
        motionFormat:MTLPixelFormatRG16Float outputFormat:MTLPixelFormatRGBA16Float error:&error];
    if(!pipeline) return 7;
    auto makeInputs=[&](NSMutableArray *into){
        MTLPixelFormat formats[]={MTLPixelFormatRGBA16Float,MTLPixelFormatR32Float,MTLPixelFormatRG16Float};
        for(unsigned i=0;i<3;++i) {
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[i] width:256 height:128 mipmapped:NO];
            d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
            [into addObject:[device newTextureWithDescriptor:d]];
        }
    };
    auto run=[&](NSArray<id<MTLTexture>> *inputs)->BOOL{ @autoreleasepool {
        id<MTLCommandBuffer> b=[queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[b computeCommandEncoder];
        float value=0.5f;[encoder setComputePipelineState:fill];
        for(unsigned i=0;i<3;++i) [encoder setTexture:inputs[i] atIndex:i];
        [encoder setBytes:&value length:sizeof(value) atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(256,128,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[encoder endEncoding];
        BG3MFXFrameParameters p={};p.motionScaleX=p.motionScaleY=1;p.depthReversed=YES;
        if(![pipeline encodeColor:inputs[0] depth:inputs[1] motion:inputs[2] parameters:p commandBuffer:b error:nil]) return NO;
        [b commit];[b waitUntilCompleted];return b.status==MTLCommandBufferStatusCompleted;
    }};
    __weak id<MTLTexture> replaced[3];
    { NSMutableArray *first=[NSMutableArray array]; makeInputs(first);
      for(unsigned i=0;i<3;++i) replaced[i]=first[i];
      for(unsigned frame=0;frame<4;++frame) if(!run(first)) return 8; }
    NSMutableArray *second=[NSMutableArray array]; makeInputs(second);
    for(unsigned frame=0;frame<40;++frame) if(!run(second)) return 9;
    // GPU feedback releases each submission's references shortly after completion.
    for(unsigned wait=0;wait<100 && (replaced[0] || replaced[1] || replaced[2]);++wait) [NSThread sleepForTimeInterval:0.01];
    if(replaced[0] || replaced[1] || replaced[2]) {
        fprintf(stderr,"The Metal 4 residency set kept replaced same-size inputs alive\n");return 10;
    }
    puts("Metal4 bridge: inputs replaced at the same size were released after 40 submissions.");
    return 0;
}}
