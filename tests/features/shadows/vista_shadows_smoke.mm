#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <vector>

using Replay = uintptr_t (*)(void *, uintptr_t, void *, uintptr_t (*)(void *, uintptr_t, void *));
struct Fixture {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLTexture> depth;
    id<MTLTexture> fourSliceDepth;
    id<MTLBuffer> counter;
    id<MTLBuffer> indices;
    id<MTLRenderPipelineState> countedPipeline;
    id<MTLRenderPipelineState> depthOnlyPipeline;
    id<MTLRenderPipelineState> clearPipeline;
    id<MTLDepthStencilState> depthState;
    id<MTLDepthStencilState> clearDepthState;
    NSUInteger size;
    NSError *error;
};

static id<MTLLibrary> makeLibrary(id<MTLDevice> device, NSError **error) {
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vistaVS(uint i [[vertex_id]]) {"
        "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};"
        "float z[3]={0.4,0.8,0.4}; return float4(p[i],z[i],1); }\n"
        "vertex float4 seedVS(uint i [[vertex_id]]) {"
        "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0.9,1); }\n"
        "vertex float4 clearVS(uint i [[vertex_id]]) {"
        "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "fragment void vistaCountFS(device atomic_uint *count [[buffer(0)]]) {"
        "atomic_fetch_add_explicit(count,1,memory_order_relaxed); }";
    return [device newLibraryWithSource:source options:nil error:error];
}

static bool makeFixture(Fixture &f) {
    f.device=MTLCreateSystemDefaultDevice();
    if (!f.device) { fprintf(stderr,"No default Metal device\n"); return false; }
    f.size=128;
    f.queue=[f.device newCommandQueue];
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm
        width:f.size height:f.size mipmapped:NO];
    td.textureType=MTLTextureType2DArray; td.arrayLength=2; td.storageMode=MTLStorageModePrivate;
    // The native atlas is sampled when the reduced target is seeded from its
    // load contents, as well as attached as a render target.
    td.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    f.depth=[f.device newTextureWithDescriptor:td];
    td.arrayLength=4;
    f.fourSliceDepth=[f.device newTextureWithDescriptor:td];
    f.counter=[f.device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
    uint16_t indexData[3]={0,1,2};
    f.indices=[f.device newBufferWithBytes:indexData length:sizeof(indexData) options:MTLResourceStorageModeShared];
    if (!f.queue || !f.depth || !f.fourSliceDepth || !f.counter || !f.indices) { fprintf(stderr,"Metal allocation failed (queue=%d depth=%d fourSliceDepth=%d counter=%d indices=%d)\n",!!f.queue,!!f.depth,!!f.fourSliceDepth,!!f.counter,!!f.indices); return false; }
    NSError *error=nil;
    id<MTLLibrary> library=makeLibrary(f.device,&error);
    f.error=error;
    if (!library) { fprintf(stderr,"Metal shader compilation failed: %s\n",error.description.UTF8String ?: "no details"); return false; }
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[library newFunctionWithName:@"vistaVS"];
    pd.fragmentFunction=[library newFunctionWithName:@"vistaCountFS"];
    pd.depthAttachmentPixelFormat=MTLPixelFormatDepth16Unorm;
    f.countedPipeline=[f.device newRenderPipelineStateWithDescriptor:pd error:&error];
    f.error=error;
    if (!f.countedPipeline) { fprintf(stderr,"Counted pipeline failed: %s\n",error.description.UTF8String ?: "no details"); return false; }
    pd.vertexFunction=[library newFunctionWithName:@"seedVS"];
    pd.fragmentFunction=nil;
    f.depthOnlyPipeline=[f.device newRenderPipelineStateWithDescriptor:pd error:&error];
    f.error=error;
    if (!f.depthOnlyPipeline) { fprintf(stderr,"Depth-only pipeline failed: %s\n",error.description.UTF8String ?: "no details"); return false; }
    pd.vertexFunction=[library newFunctionWithName:@"clearVS"];
    f.clearPipeline=[f.device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!f.clearPipeline) { fprintf(stderr,"Clear pipeline failed: %s\n",error.description.UTF8String ?: "no details"); return false; }
    MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new];
    dd.depthCompareFunction=MTLCompareFunctionGreaterEqual; dd.depthWriteEnabled=YES;
    f.depthState=[f.device newDepthStencilStateWithDescriptor:dd];
    if (!f.depthState) fprintf(stderr,"Depth state creation failed\n");
    dd.depthCompareFunction=MTLCompareFunctionAlways;
    f.clearDepthState=[f.device newDepthStencilStateWithDescriptor:dd];
    if (!f.clearDepthState) fprintf(stderr,"Clear depth state creation failed\n");
    return f.countedPipeline && f.depthOnlyPipeline && f.clearPipeline && f.depthState && f.clearDepthState;
}

static MTLRenderPassDescriptor *passFor(Fixture &f, NSUInteger slice, MTLLoadAction load, double clear, id<MTLTexture> target=nil) {
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor new];
    pass.depthAttachment.texture=target ?: f.depth; pass.depthAttachment.slice=slice;
    pass.depthAttachment.loadAction=load; pass.depthAttachment.storeAction=MTLStoreActionStore;
    pass.depthAttachment.clearDepth=clear;
    return pass;
}

static void seedTexture(Fixture &f) {
    id<MTLCommandBuffer> cb=[f.queue commandBuffer];
    for (NSUInteger slice=0;slice<2;++slice) {
        id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:passFor(f,slice,MTLLoadActionClear,0.1+0.1*slice)];
        [e endEncoding];
    }
    // Native depth already contains a larger value over the left half. The
    // vista pass must preserve it while adding its shallower values elsewhere.
    id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:passFor(f,0,MTLLoadActionLoad,0)];
    [e setRenderPipelineState:f.depthOnlyPipeline]; [e setDepthStencilState:f.depthState];
    [e setViewport:(MTLViewport){0,0,(double)f.size/2,(double)f.size,0,1}];
    [e setScissorRect:(MTLScissorRect){0,0,f.size/2,f.size}];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    id<MTLCommandBuffer> fourSliceCB=[f.queue commandBuffer];
    id<MTLRenderCommandEncoder> fourSliceEncoder=[fourSliceCB renderCommandEncoderWithDescriptor:
        passFor(f,0,MTLLoadActionClear,0.1,f.fourSliceDepth)];
    [fourSliceEncoder endEncoding]; [fourSliceCB commit]; [fourSliceCB waitUntilCompleted];
}

struct PassRequest { Fixture *fixture; NSUInteger slice; id<MTLTexture> target; bool clearTileBeforeDraw=false; };
static void encodeCountedPass(PassRequest *request, bool indexed=false) {
    Fixture *f=request->fixture;
    *(uint32_t *)f->counter.contents=0;
    id<MTLCommandBuffer> cb=[f->queue commandBuffer];
    id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:passFor(*f,request->slice,MTLLoadActionLoad,0,request->target)];
    if (!e) { f->error=[NSError errorWithDomain:@"VistaSmoke" code:1 userInfo:nil]; return; }
    if (request->clearTileBeforeDraw) {
        // Clear a tile that initially contains 0.9 while the replay wrapper is
        // active. The following draw must replace the cleared region with its
        // lower depth, rather than max-merging against the old native value.
        [e setRenderPipelineState:f->clearPipeline]; [e setDepthStencilState:f->clearDepthState];
        [e setViewport:(MTLViewport){12,40,4,20,0,1}];
        [e setScissorRect:(MTLScissorRect){12,40,4,20}];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [e setRenderPipelineState:f->countedPipeline]; [e setDepthStencilState:f->depthState];
    MTLViewport viewport={8,12,96,80,0,1};
    MTLScissorRect scissor={8,12,96,80};
    [e setViewports:&viewport count:1];
    [e setScissorRects:&scissor count:1];
    [e setFragmentBuffer:f->counter offset:0 atIndex:0];
    [e setDepthBias:0 slopeScale:4 clamp:0];
    if (indexed) [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:3 indexType:MTLIndexTypeUInt16 indexBuffer:f->indices indexBufferOffset:0];
    else [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status!=MTLCommandBufferStatusCompleted) f->error=cb.error;
}

static uintptr_t replayCallback(void *commands, uintptr_t flags, void *fence) {
    PassRequest *request=(PassRequest *)commands;
    if (flags!=0x1234 || fence!=(void *)0x5678) return 0;
    encodeCountedPass(request);
    return 0xa55a;
}

struct PendingRequest {
    Fixture *fixture;
    NSUInteger slice;
    id<MTLCommandBuffer> buffer;
    id<MTLRenderCommandEncoder> deferredEncoder;
    bool deferEnd;
    bool clearUpdatedViewport;
};
static uintptr_t pendingCallback(void *commands, uintptr_t flags, void *fence) {
    PendingRequest *request=(PendingRequest *)commands;
    if (flags!=0x1234 || fence!=(void *)0x5678) return 0;
    Fixture *f=request->fixture;
    *(uint32_t *)f->counter.contents=0;
    request->buffer=[f->queue commandBuffer];
    id<MTLRenderCommandEncoder> e=[request->buffer renderCommandEncoderWithDescriptor:
        passFor(*f,request->slice,MTLLoadActionLoad,0)];
    if (!e) { f->error=[NSError errorWithDomain:@"VistaSmoke" code:2 userInfo:nil]; return 0; }
    if (request->clearUpdatedViewport) {
        // These redraws reuse already-rendered slices. Clear the updated
        // region first, as the game's tile pass does, so conservative
        // upsampling does not accumulate against the previous replay.
        [e setRenderPipelineState:f->clearPipeline]; [e setDepthStencilState:f->clearDepthState];
        [e setViewport:(MTLViewport){8,12,96,80,0,1}];
        [e setScissorRect:(MTLScissorRect){8,12,96,80}];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [e setRenderPipelineState:f->countedPipeline]; [e setDepthStencilState:f->depthState];
    MTLViewport viewport={8,12,96,80,0,1}; MTLScissorRect scissor={8,12,96,80};
    [e setViewports:&viewport count:1]; [e setScissorRects:&scissor count:1];
    [e setFragmentBuffer:f->counter offset:0 atIndex:0];
    [e setDepthBias:0 slopeScale:4 clamp:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (request->deferEnd) request->deferredEncoder=e;
    else [e endEncoding]; // Merge is encoded now; completion still owns its low texture.
    return request->buffer ? 0xa55a : 0;
}

static bool readSlice(Fixture &f, NSUInteger slice, std::vector<uint16_t> &pixels) {
    NSUInteger rowBytes=((f.size*sizeof(uint16_t)+255)/256)*256;
    id<MTLBuffer> readback=[f.device newBufferWithLength:rowBytes*f.size options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[f.queue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    [blit copyFromTexture:f.depth sourceSlice:slice sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(f.size,f.size,1) toBuffer:readback destinationOffset:0
        destinationBytesPerRow:rowBytes destinationBytesPerImage:rowBytes*f.size];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status!=MTLCommandBufferStatusCompleted) return false;
    pixels.resize(f.size*f.size);
    for (NSUInteger y=0;y<f.size;++y) memcpy(pixels.data()+y*f.size,(const uint8_t *)readback.contents+y*rowBytes,f.size*sizeof(uint16_t));
    return true;
}

static double depthAt(const std::vector<uint16_t> &pixels, NSUInteger size, NSUInteger x, NSUInteger y) {
    return (double)pixels[y*size+x]/65535.0;
}
static bool nearDepth(double actual, double expected) { return std::abs(actual-expected)<0.015; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc!=3) return 2;
        bool expectVista=strcmp(argv[2],"expect-vista")==0;
        bool expectVistaOnly=strcmp(argv[2],"expect-vista-only")==0;
        bool expectVistaOnlyQuiet=strcmp(argv[2],"expect-vista-only-quiet")==0;
        bool expectVistaOnlyNative=strcmp(argv[2],"expect-vista-only-native")==0;
        bool expectCompare=strcmp(argv[2],"expect-compare")==0;
        bool expectNative=strcmp(argv[2],"expect-native")==0;
        bool expectRedirect=expectVista || expectVistaOnly || expectVistaOnlyQuiet;
        bool expectOnly=expectVistaOnly || expectVistaOnlyQuiet || expectVistaOnlyNative;
        bool suppressionExpected=expectVistaOnly || expectVistaOnlyNative;
        if (!expectRedirect && !expectNative && !expectVistaOnlyNative && !expectCompare) return 2;
        setenv("BG3MFX_ENABLE_METALFX","1",1);
        setenv("BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS","1",1);
        setenv("BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA",(expectRedirect || expectCompare) ? "1" : "0",1);
        if (expectCompare) setenv("BG3MFX_VISTA_COMPARE","1",1);
        if (expectVistaOnlyNative) {
            setenv("BG3MFX_TRACE_SHADOW_PIXELS","1",1);
            setenv("BG3MFX_TRACE_SHADOWS","1",1);
        }
        // Leave the new flag alone in the legacy cases so callers can exercise
        // an inherited environment. The dedicated cases always enable it.
        if (expectOnly) setenv("BG3MFX_SHADOWS_VISTA_ONLY","1",1);
        void *runtime=dlopen(argv[1],RTLD_NOW|RTLD_GLOBAL);
        if (!runtime) { fprintf(stderr,"dlopen: %s\n",dlerror()); return 3; }
        auto replay=(Replay)dlsym(runtime,"BG3MFXReplayVista");
        if (!replay) { fprintf(stderr,"BG3MFXReplayVista export missing\n"); return 4; }
        Fixture f={};
        if (!makeFixture(f)) { fprintf(stderr,"Metal fixture setup failed: %s\n",f.error.description.UTF8String ?: "no details"); return 5; }
        seedTexture(f);
        uint16_t adjacentSeedDepth=0;
        if (expectRedirect) {
            std::vector<uint16_t> initial;
            if (!readSlice(f,0,initial)) return 8;
            adjacentSeedDepth=initial[50*f.size+20];
        }
        if (suppressionExpected) {
            // A native replay with a four-slice depth array is not BG3's vista
            // pass. It must leave the vista-only diagnostic unarmed, so both
            // that replay and a following ordinary draw remain native.
            PassRequest unsupported={&f,0,f.fourSliceDepth};
            if (replay(&unsupported,0x1234,(void *)0x5678,replayCallback)!=0xa55a || f.error ||
                *(uint32_t *)f.counter.contents!=96*80) {
                fprintf(stderr,"unsupported four-slice replay did not preserve native draws\n"); return 22;
            }
            PassRequest beforeReady={&f,1,nil};
            encodeCountedPass(&beforeReady);
            if (f.error || *(uint32_t *)f.counter.contents!=96*80) {
                fprintf(stderr,"vista-only suppression armed for an unsupported native pass\n"); return 23;
            }
            id<MTLCommandBuffer> resetBeforeReady=[f.queue commandBuffer];
            id<MTLRenderCommandEncoder> resetBeforeReadyEncoder=[resetBeforeReady renderCommandEncoderWithDescriptor:
                passFor(f,1,MTLLoadActionClear,0.2)];
            [resetBeforeReadyEncoder endEncoding]; [resetBeforeReady commit]; [resetBeforeReady waitUntilCompleted];
        }
        PassRequest scoped={&f,0,nil,expectRedirect};
        uintptr_t result=replay(&scoped,0x1234,(void *)0x5678,replayCallback);
        if (result!=0xa55a || f.error) { fprintf(stderr,"Replay callback failed: %s\n",f.error.description.UTF8String ?: "wrong wrapper result"); return 6; }
        uint32_t fragments=*(uint32_t *)f.counter.contents;
        uint32_t nativeFragments=96*80;
        uint32_t expectedFragments=expectRedirect ? nativeFragments/4 : nativeFragments;
        if (fragments!=expectedFragments) { fprintf(stderr,"fragment invocations %u, expected %u\n",fragments,expectedFragments); return 7; }
        if (expectVistaOnlyNative) {
            using DepthSample = NSDictionary *(*)(void);
            auto depthSample=(DepthSample)dlsym(runtime,"BG3MFXStandaloneShadowDepthSample");
            if (!depthSample) { fprintf(stderr,"BG3MFXStandaloneShadowDepthSample export missing\n"); return 24; }
            NSDictionary *event=nil;
            // The render command buffer is complete here; the diagnostic depth
            // readback has its own completion handler, so allow it up to 1s.
            for (NSUInteger attempt=0;attempt<100;++attempt) {
                event=depthSample();
                if ([event[@"status"] isEqualToString:@"completed"]) break;
                usleep(10000);
            }
            double minimum=[event[@"minimumDepth"] doubleValue];
            double maximum=[event[@"maximumDepth"] doubleValue];
            if (![event[@"status"] isEqualToString:@"completed"] ||
                [event[@"slice"] unsignedIntegerValue]!=0 ||
                [event[@"pixelCount"] unsignedIntegerValue]!=128*128 ||
                [event[@"nonzeroPixels"] unsignedIntegerValue]==0 ||
                !nearDepth(minimum,0.1) || !nearDepth(maximum,0.9)) {
                fprintf(stderr,"shadow depth readback failed: status=%s slice=%lu pixels=%lu nonzero=%lu min=%.4f max=%.4f\n",
                    [event[@"status"] UTF8String] ?: "missing",
                    (unsigned long)[event[@"slice"] unsignedIntegerValue],
                    (unsigned long)[event[@"pixelCount"] unsignedIntegerValue],
                    (unsigned long)[event[@"nonzeroPixels"] unsignedIntegerValue],minimum,maximum);
                return 25;
            }
        }
        std::vector<uint16_t> slice;
        if (!readSlice(f,0,slice)) return 8;
        if (expectRedirect) {
            bool leftOkay=slice[50*f.size+20]==adjacentSeedDepth;
            if (!leftOkay || !nearDepth(depthAt(slice,f.size,14,50),0.4271) ||
                std::abs(depthAt(slice,f.size,90,50)-0.58125)>0.004 || !nearDepth(depthAt(slice,f.size,120,4),0.1)) {
                fprintf(stderr,"vista merge failed: preserved %.4f, added %.4f, outside %.4f\n",depthAt(slice,f.size,20,50),depthAt(slice,f.size,90,50),depthAt(slice,f.size,120,4)); return 9;
            }
        } else if (expectVistaOnlyNative) {
            double leftDepth=depthAt(slice,f.size,20,50);
            if (!nearDepth(leftDepth,0.9) || std::abs(depthAt(slice,f.size,90,50)-0.5802083)>0.004 || !nearDepth(depthAt(slice,f.size,120,4),0.1)) {
                fprintf(stderr,"vista-only native path failed: left %.4f right %.4f outside %.4f\n",leftDepth,depthAt(slice,f.size,90,50),depthAt(slice,f.size,120,4)); return 10;
            }
        } else if (expectCompare) {
            if (!nearDepth(depthAt(slice,f.size,20,50),0.9) || std::abs(depthAt(slice,f.size,90,50)-0.5802083)>0.004 || !nearDepth(depthAt(slice,f.size,120,4),0.1)) {
                fprintf(stderr,"comparison did not begin at full native resolution: left %.4f right %.4f outside %.4f\n",depthAt(slice,f.size,20,50),depthAt(slice,f.size,90,50),depthAt(slice,f.size,120,4)); return 10;
            }
        } else if (!nearDepth(depthAt(slice,f.size,20,50),0.9) || std::abs(depthAt(slice,f.size,90,50)-0.5802083)>0.004 || !nearDepth(depthAt(slice,f.size,120,4),0.1)) {
            fprintf(stderr,"disabled path changed native full-resolution depth\n"); return 10;
        }
        // A matching pass outside the replay wrapper must stay full resolution
        // even when the vista feature is enabled.
        PassRequest outside={&f,1,nil};
        encodeCountedPass(&outside);
        uint32_t outsideFragments=*(uint32_t *)f.counter.contents;
        uint32_t expectedOutsideFragments=suppressionExpected ? 0 : nativeFragments;
        if (outsideFragments!=expectedOutsideFragments || f.error) {
            fprintf(stderr,"outside-scope pass was redirected or failed: %u\n",outsideFragments); return 11;
        }
        double outsideDepth=suppressionExpected ? 0.2 : 0.5802083;
        if (!readSlice(f,1,slice) || !nearDepth(depthAt(slice,f.size,90,50),outsideDepth)) {
            fprintf(stderr,"outside-scope pass changed depth unexpectedly: %.4f\n",depthAt(slice,f.size,90,50)); return 12;
        }
        if (suppressionExpected) {
            encodeCountedPass(&outside,true);
            uint32_t indexedFragments=*(uint32_t *)f.counter.contents;
            if (indexedFragments!=0 || f.error || !readSlice(f,1,slice) || !nearDepth(depthAt(slice,f.size,90,50),0.2)) {
                fprintf(stderr,"outside-scope indexed draw was not suppressed: fragments=%u depth=%.4f\n",indexedFragments,depthAt(slice,f.size,90,50)); return 21;
            }
        }
        for (NSUInteger i=1;i<2;++i) {
            if (!readSlice(f,i,slice) || !nearDepth(depthAt(slice,f.size,120,4),0.2)) {
                fprintf(stderr,"vista pass touched array slice %lu\n",(unsigned long)i); return 13;
            }
        }
        if (expectRedirect) {
            auto allocations=(NSUInteger(*)())dlsym(runtime,"BG3MFXTexturePoolAllocations");
            if (!allocations) return 14;
            NSUInteger before=allocations();
            PendingRequest first={&f,0,nil,nil,false,true}, second={&f,1,nil,nil,false,true};
            if (replay(&first,0x1234,(void *)0x5678,pendingCallback)!=0xa55a ||
                replay(&second,0x1234,(void *)0x5678,pendingCallback)!=0xa55a || f.error) return 15;
            // The first command buffer is still uncommitted, so its reduced
            // depth target cannot be checked out for the second pass.
            if (allocations()!=before+1) {
                fprintf(stderr,"in-flight vista passes allocated %lu reduced targets, expected 1 additional\n",
                    (unsigned long)(allocations()-before)); return 16;
            }
            [first.buffer commit]; [second.buffer commit];
            [first.buffer waitUntilCompleted]; [second.buffer waitUntilCompleted];
            if (first.buffer.status!=MTLCommandBufferStatusCompleted || second.buffer.status!=MTLCommandBufferStatusCompleted) return 17;
            for (NSUInteger i=0;i<2;++i) {
                if (!readSlice(f,i,slice) || std::abs(depthAt(slice,f.size,90,50)-0.58125)>0.004) {
                    fprintf(stderr,"in-flight vista pass failed on slice %lu\n",(unsigned long)i); return 18;
                }
            }

            // Native submission can return while BG3 still owns an open
            // encoder. Keep its prepared vista context until that encoder is
            // ended after the replay scope has unwound.
            id<MTLCommandBuffer> reset=[f.queue commandBuffer];
            id<MTLRenderCommandEncoder> resetEncoder=[reset renderCommandEncoderWithDescriptor:
                passFor(f,1,MTLLoadActionClear,0.2)];
            [resetEncoder endEncoding]; [reset commit]; [reset waitUntilCompleted];
            PendingRequest deferred={&f,1,nil,nil,true,true};
            if (replay(&deferred,0x1234,(void *)0x5678,pendingCallback)!=0xa55a ||
                f.error || !deferred.buffer || !deferred.deferredEncoder || *(uint32_t *)f.counter.contents!=0) return 19;
            [deferred.deferredEncoder endEncoding];
            [deferred.buffer commit]; [deferred.buffer waitUntilCompleted];
            if (deferred.buffer.status!=MTLCommandBufferStatusCompleted ||
                *(uint32_t *)f.counter.contents!=nativeFragments/4 ||
                !readSlice(f,1,slice) || std::abs(depthAt(slice,f.size,90,50)-0.58125)>0.004 ||
                !nearDepth(depthAt(slice,f.size,120,4),0.2)) {
                fprintf(stderr,"deferred vista encoder lost its in-scope setup\n"); return 20;
            }
        }
        if (expectRedirect) puts(expectVistaOnly ? "Vista-only diagnostic suppression and redirect passed" : "Vista shadow redirect, merge and slice isolation passed");
        else if (expectVistaOnlyNative) puts("Vista-only diagnostic suppression preserved native scoped rendering");
        else if (expectCompare) puts("Vista comparison began at full native resolution");
        else puts("Vista disabled path remained full resolution");
    }
}
