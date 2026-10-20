#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <cmath>

static IMP baselineCompute;
// Simulate a later wrapper that bypasses our plain encoder-creation hook.
static id foreignCompute(id self, SEL cmd) { return ((id(*)(id,SEL))baselineCompute)(self,cmd); }
static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger size, MTLPixelFormat format = MTLPixelFormatRG11B10Float) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:size height:size mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    return [device newTextureWithDescriptor:desc];
}
static void drawPass(id<MTLCommandBuffer> buffer, id<MTLTexture> source, id<MTLTexture> target,
                     id<MTLRenderPipelineState> pipeline) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setRenderPipelineState:pipeline];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2 || argc > 3) return 1;
        NSString *mode = argc == 3 ? @(argv[2]) : @"normal";
        if (getenv("BG3MFX_TEST_ERROR_DIALOG")) {
            NSApplication *app = [NSApplication sharedApplication];
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
            [app finishLaunching];
            [app activate];
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;
        id<MTLCommandQueue> earlyQueue = [device newCommandQueue];
        id<MTLCommandBuffer> earlyBuffer = [earlyQueue commandBuffer];
        SEL plain = sel_registerName("computeCommandEncoder");
        Method method = class_getInstanceMethod(object_getClass(earlyBuffer),plain);
        baselineCompute = method_getImplementation(method);
        setenv("BG3MFX_ENABLE_METALFX","1",1);
        void *runtime = dlopen(argv[1],RTLD_NOW | RTLD_LOCAL);
        if (!runtime) { fprintf(stderr,"%s\n",dlerror()); return 3; }
        auto select = (BOOL(*)(int))dlsym(runtime,"BG3MFXSetStandaloneScalingMode");
        if (!select || !select(2)) return 9;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 Fullscreen(uint id [[vertex_id]]) {float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[id],0,1);}\n"
            "fragment float4 PPTAA_PS(float4 p [[position]], texture2d<float> src [[texture(0)]]) {return src.read(uint2(p.xy));}\n"
            "fragment float4 SMAANeighborhoodBlending_PS(float4 p [[position]], texture2d<float> src [[texture(0)]]) {return src.read(uint2(p.xy));}\n"
            "fragment float4 PPBloomUpsampleBlurAndCombine_PS(float4 p [[position]], texture2d<float> src [[texture(0)]]) {return float4(src.read(uint2(p.xy)).rgb+1.0,1);}\n"
            "fragment float4 PPColorGradingApplyLUTPS(float4 p [[position]], texture2d<float> src [[texture(0)]]) {return float4(src.read(uint2(p.xy)).rgb+1.0,1);}\n"
            "fragment float4 FSR_Tonemap(float4 p [[position]], texture2d<float> src [[texture(0)]]) {float3 c=src.read(uint2(p.xy)).rgb;return float4(c/(1+max(c.r,max(c.g,c.b))),1);}\n"
            "kernel void Fill(texture2d<float,access::write> dst [[texture(0)]], uint2 p [[thread_position_in_grid]]) "
            "{ dst.write(float4(1.0,3.0,5.0,1.0),p); }\n"
            "kernel void FSR(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]], "
            "device atomic_uint *count [[buffer(0)]], uint2 p [[thread_position_in_grid]]) "
            "{ if(all(p==uint2(0))) atomic_fetch_add_explicit(count,1,memory_order_relaxed); dst.write(src.read(p/2),p); }\n"
            "kernel void FSR_RCAS(texture2d<float,access::write> dst [[texture(2)]], "
            "device atomic_uint *count [[buffer(0)]], uint2 p [[thread_position_in_grid]]) "
            "{ if(all(p==uint2(0))) atomic_fetch_add_explicit(count,1,memory_order_relaxed); dst.write(float4(0.0),p); }\n"
            "kernel void Read(texture2d<float,access::read> src [[texture(0)]], device float4 *out [[buffer(0)]], "
            "uint2 p [[thread_position_in_grid]]) { out[p.y*src.get_width()+p.x]=src.read(p); }";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        NSMutableArray *pipelines = [NSMutableArray array];
        for (NSString *name in @[@"Fill",@"FSR",@"FSR_RCAS",@"Read"]) {
            id state = [device newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:&error];
            if (!state) { fprintf(stderr,"%s\n",error.description.UTF8String); return 4; } [pipelines addObject:state];
        }
        NSMutableArray *renderPipelines = [NSMutableArray array];
        for (NSString *name in @[@"PPTAA_PS",@"PPBloomUpsampleBlurAndCombine_PS",@"PPColorGradingApplyLUTPS",@"FSR_Tonemap",@"SMAANeighborhoodBlending_PS"]) {
            MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
            desc.vertexFunction = [library newFunctionWithName:@"Fullscreen"];
            desc.fragmentFunction = [library newFunctionWithName:name];
            desc.colorAttachments[0].pixelFormat = MTLPixelFormatRG11B10Float;
            id state = [device newRenderPipelineStateWithDescriptor:desc error:&error];
            if (!state) { fprintf(stderr,"%s\n",error.description.UTF8String); return 10; }
            [renderPipelines addObject:state];
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLTexture> input = texture(device,256), taa = texture(device,256), bloom = texture(device,256);
        id<MTLTexture> graded = texture(device,256), tonemapped = texture(device,256), scaled = texture(device,512);
        id<MTLTexture> destination = texture(device,512,[mode isEqualToString:@"bad-format"] ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRG11B10Float);
        id<MTLBuffer> pixels = [device newBufferWithLength:512*512*4*sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLBuffer> nativeDispatches = [device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
        *(uint32_t *)nativeDispatches.contents = 0;
        auto allocations = (NSUInteger(*)(void))dlsym(runtime,"BG3MFXTexturePoolAllocations");
        if (!allocations) return 13;
        NSUInteger warm = 0;
        for (int frame=0; frame<3; ++frame) {
            id<MTLCommandBuffer> buffer = [queue commandBufferWithUnretainedReferences];
            if (!buffer.retainedReferences) return 5;
            class_replaceMethod(object_getClass(buffer),plain,(IMP)foreignCompute,method_getTypeEncoding(method));
            id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
            [encoder setComputePipelineState:pipelines[0]]; [encoder setTexture:input atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(256,256,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [encoder endEncoding];
            // "no-taa": BG3 with SMAA (or no AA) runs no TAA pass to seed the chain.
            drawPass(buffer,input,taa,renderPipelines[[mode isEqualToString:@"no-taa"] ? 4 : 0]);
            drawPass(buffer,taa,bloom,renderPipelines[1]);
            drawPass(buffer,bloom,graded,renderPipelines[2]);
            drawPass(buffer,graded,tonemapped,renderPipelines[3]);
            encoder = [buffer computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
            [encoder setComputePipelineState:pipelines[1]]; [encoder setTexture:tonemapped atIndex:0]; [encoder setTexture:scaled atIndex:1];
            [encoder setBuffer:nativeDispatches offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(512,512,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            if ([mode isEqualToString:@"unexpected-dispatch"]) {
                [encoder setComputePipelineState:pipelines[0]];
                [encoder dispatchThreads:MTLSizeMake(256,256,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            }
            if (![mode isEqualToString:@"bad-sequence"]) {
                [encoder setComputePipelineState:pipelines[2]]; [encoder setTexture:scaled atIndex:0]; [encoder setTexture:destination atIndex:2];
                [encoder dispatchThreads:MTLSizeMake(512,512,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            }
            [encoder endEncoding];
            encoder = [buffer computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
            [encoder setComputePipelineState:pipelines[3]]; [encoder setTexture:destination atIndex:0]; [encoder setBuffer:pixels offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(512,512,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [encoder endEncoding]; [buffer commit]; [buffer waitUntilCompleted];
            if (buffer.status != MTLCommandBufferStatusCompleted) return 6;
            // "bad-format": MetalFX cannot write BG3's destination. The first
            // frame's failure must turn Spatial off without ending the process,
            // and BG3's own FSR and RCAS must run on every later frame.
            if ([mode isEqualToString:@"bad-format"]) {
                uint32_t native = *(uint32_t *)nativeDispatches.contents;
                if (native != 2u*frame) {
                    fprintf(stderr,"Frame %d after a Spatial failure ran %u native FSR/RCAS dispatches, expected %u\n",frame,native,2u*frame); return 24;
                }
                continue;
            }
            // Steady-state frames must reuse pooled intermediates, not allocate.
            if (frame == 0) warm = allocations();
            else if (allocations() != warm) { fprintf(stderr,"Spatial allocated textures after warmup\n"); return 12; }
            if (*(uint32_t *)nativeDispatches.contents != 0) { fprintf(stderr,"Native FSR work ran despite the MetalFX replacement\n"); return 8; }
            float *p = (float *)pixels.contents;
            for (NSUInteger y=32;y<480;y+=37) for (NSUInteger x=32;x<480;x+=41) for (int c=0;c<3;++c) {
                float actual = p[(y*512+x)*4+c], expected = 3+2*c;
                if (!std::isfinite(actual) || fabs(actual-expected)>expected*0.04f) {
                    fprintf(stderr,"Hook output mismatch: %f != %f\n",actual,expected); return 7;
                }
            }
        }
        if ([mode isEqualToString:@"resize"]) {
            // A window drag gives every frame a new size. Run the chain through
            // many sizes, as BG3 does, then check that the earlier sizes' memory
            // was released: their textures are gone and GPU allocations return.
            auto frameAt = [&](NSUInteger size, __weak id<MTLTexture> *probe) -> int {
                @autoreleasepool {
                    id<MTLTexture> sInput=texture(device,size), sTAA=texture(device,size), sBloom=texture(device,size);
                    id<MTLTexture> sGraded=texture(device,size), sTonemapped=texture(device,size);
                    id<MTLTexture> sScaled=texture(device,size*2), sDestination=texture(device,size*2);
                    if (probe) *probe=sDestination;
                    *(uint32_t *)nativeDispatches.contents=0;
                    id<MTLCommandBuffer> buffer=[queue commandBuffer];
                    id<MTLComputeCommandEncoder> e=[buffer computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
                    [e setComputePipelineState:pipelines[0]]; [e setTexture:sInput atIndex:0];
                    [e dispatchThreads:MTLSizeMake(size,size,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [e endEncoding];
                    drawPass(buffer,sInput,sTAA,renderPipelines[0]);
                    drawPass(buffer,sTAA,sBloom,renderPipelines[1]);
                    drawPass(buffer,sBloom,sGraded,renderPipelines[2]);
                    drawPass(buffer,sGraded,sTonemapped,renderPipelines[3]);
                    e=[buffer computeCommandEncoderWithDispatchType:MTLDispatchTypeSerial];
                    [e setComputePipelineState:pipelines[1]]; [e setTexture:sTonemapped atIndex:0]; [e setTexture:sScaled atIndex:1];
                    [e setBuffer:nativeDispatches offset:0 atIndex:0];
                    [e dispatchThreads:MTLSizeMake(size*2,size*2,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
                    [e setComputePipelineState:pipelines[2]]; [e setTexture:sScaled atIndex:0]; [e setTexture:sDestination atIndex:2];
                    [e dispatchThreads:MTLSizeMake(size*2,size*2,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [e endEncoding];
                    [buffer commit]; [buffer waitUntilCompleted];
                    if (buffer.status!=MTLCommandBufferStatusCompleted) return -1;
                    return *(uint32_t *)nativeDispatches.contents==0;
                }
            };
            // Returns whether MetalFX took over, allowing a new size to settle first.
            auto settledFrameAt = [&](NSUInteger size, __weak id<MTLTexture> *probe) -> int {
                int replaced=0;
                for (int attempt=0; attempt<6 && replaced==0; ++attempt) {
                    if ((replaced=frameAt(size,probe))<0) return -1;
                    if (!replaced) [NSThread sleepForTimeInterval:0.35];
                }
                return replaced;
            };
            const NSUInteger first=192, sizes=24;
            if (settledFrameAt(first,nullptr)!=1) { fprintf(stderr,"Spatial did not replace FSR at %lux%lu\n",first,first); return 20; }
            double baseline=device.currentAllocatedSize/1048576.0;
            __weak id<MTLTexture> earlier[sizes];
            for (NSUInteger i=0;i<sizes;++i)
                if (settledFrameAt(first+8*(i+1),&earlier[i])!=1) { fprintf(stderr,"Spatial did not replace FSR during the sweep\n"); return 21; }
            // Back at the first size: only its own resources should remain.
            if (settledFrameAt(first,nullptr)!=1) return 22;
            double grown=device.currentAllocatedSize/1048576.0-baseline;
            NSUInteger pinned=0; for (auto &texture:earlier) if (texture) ++pinned;
            printf("Spatial resize sweep: %lu sizes, GPU allocations %+.1f MB, %lu earlier destinations still alive\n",
                (unsigned long)sizes,grown,(unsigned long)pinned);
            // At most one other size (the cache keeps two) stays: about 7 MB here,
            // against 170 MB when every size was kept.
            if (grown>24 || pinned) { fprintf(stderr,"Spatial kept resources for earlier sizes\n"); return 23; }
        }
        if ([mode isEqualToString:@"bad-format"]) {
            puts("A MetalFX Spatial failure turned Spatial off without closing; BG3's native FSR/RCAS ran on the following frames.");
            return 0;
        }
        if ([mode isEqualToString:@"no-taa"]) puts("MetalFX Spatial without TAA scaled FSR_Tonemap's linear HDR input across three frames; native FSR/RCAS stayed suppressed.");
        else puts("MetalFX Spatial scaled post-bloom/color-grade linear HDR across three frames; native FSR/RCAS stayed suppressed, including a displaced creation hook.");
    }
}
