#import "common/gpu/MetalFXPipeline.h"
#import "common/gpu/GPUResources.h"
#import <QuartzCore/QuartzCore.h>
#include <cmath>
#include <cstdio>

// Several in-flight producer/scaler/consumer chains, followed by immediate
// backend destruction. Private inputs must be produced by GPU work, not CPU
// initialization, so a missing cross-queue dependency cannot silently pass.
int main() { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if (!device) return 1;
    NSError *error=nil;
    BG3MFXPipeline *pipeline=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void Fill(texture2d<float,access::write> c [[texture(0)]],texture2d<float,access::write> d [[texture(1)]],"
        "texture2d<float,access::write> m [[texture(2)]],constant float &v [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {"
        "c.write(float4(v,v*0.5,v*0.25,1),p);d.write(float4(0.5),p);m.write(float4(0),p);}";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> fill=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"Fill"] error:&error];
    if(!fill) return 3;
    id<MTLCommandQueue> queue=[device newCommandQueue];
    BOOL metal4=NO;
    // Pass 0 submits Metal 4 work at once (no runtime commit hook); pass 1
    // defers it until the Metal 3 buffer is committed, as the runtime does.
    for(int deferred=0;deferred<2;++deferred) {
    BG3MFXMetal4CommitHooked=deferred ? [](id<MTLCommandBuffer>)->BOOL { return YES; } : nullptr;
    pipeline=[[BG3MFXPipeline alloc] initWithDevice:device inputWidth:256 inputHeight:128
        outputWidth:512 outputHeight:256 colorFormat:MTLPixelFormatRGBA16Float depthFormat:MTLPixelFormatR32Float
        motionFormat:MTLPixelFormatRG16Float outputFormat:MTLPixelFormatRGBA16Float error:&error];
    if(!pipeline) { fprintf(stderr,"%s\n",error.description.UTF8String);return 2; }
    NSMutableArray *buffers=[NSMutableArray array], *readbacks=[NSMutableArray array];
    metal4=pipeline.usesMetal4;
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
        [blit endEncoding];[buffers addObject:b];[readbacks addObject:pixels];[b commit];BG3MFXMetal4BridgeCommitted(b);
    }}
    pipeline=nil; // Submission ownership must outlive the backend and its cache.
    for(unsigned frame=0;frame<8;++frame) {
        id<MTLCommandBuffer> b=buffers[frame];[b waitUntilCompleted];
        if(b.status!=MTLCommandBufferStatusCompleted) {
            fprintf(stderr,"Frame %u: command buffer status %ld: %s\n",frame,(long)b.status,b.error.description.UTF8String);return 5;
        }
        const __fp16 *data=(const __fp16 *)((id<MTLBuffer>)readbacks[frame]).contents;
        for(unsigned y=32;y<224;y+=29) for(unsigned x=32;x<480;x+=31) {
            float v=data[(y*512+x)*4], expected=0.1f*(frame+1);
            if(!std::isfinite(v) || std::abs(v-expected)>0.02f) {
                fprintf(stderr,"Frame %u: stale/invalid output %g, expected %g\n",frame,v,expected);return 6;
            }
        }
    }
    printf("%s bridge (%s submission): eight in-flight GPU producers, scalers and consumers passed after backend destruction.\n",
        metal4 ? "Metal4" : "Metal3",deferred ? "deferred" : "immediate");
    }
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
        [b commit];BG3MFXMetal4BridgeCommitted(b);[b waitUntilCompleted];return b.status==MTLCommandBufferStatusCompleted;
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
    // A buffer BG3 drops without committing never signals. Its Metal 4 work
    // must not wait on it (stalling every later submission for 4 s), yet must
    // still run before the next submission (MetalFX stalls otherwise), and its
    // slot and references must be released.
    __weak id<MTLTexture> abandoned[3];
    @autoreleasepool {
        NSMutableArray *inputs=[NSMutableArray array]; makeInputs(inputs);
        for(unsigned i=0;i<3;++i) abandoned[i]=inputs[i];
        id<MTLCommandBuffer> b=[queue commandBuffer];
        BG3MFXFrameParameters p={};p.motionScaleX=p.motionScaleY=1;p.depthReversed=YES;
        if(![pipeline encodeColor:inputs[0] depth:inputs[1] motion:inputs[2] parameters:p commandBuffer:b error:nil]) return 11;
    }
    CFTimeInterval started=CACurrentMediaTime();
    for(unsigned frame=0;frame<40;++frame) if(!run(second)) {
        fprintf(stderr,"A submission after an uncommitted buffer failed (stalled Metal 4 queue)\n");return 12;
    }
    double elapsed=CACurrentMediaTime()-started;
    for(unsigned wait=0;wait<100 && (abandoned[0] || abandoned[1] || abandoned[2]);++wait) [NSThread sleepForTimeInterval:0.01];
    if(abandoned[0] || abandoned[1] || abandoned[2]) {
        fprintf(stderr,"An uncommitted buffer's Metal 4 submission kept its inputs alive\n");return 13;
    }
    if(elapsed>2) { fprintf(stderr,"Submissions after an uncommitted buffer took %.1f s\n",elapsed);return 14; }
    printf("Metal4 bridge: an uncommitted buffer's work ran without its wait; 40 later submissions took %.2f s.\n",elapsed);
    return 0;
}}
