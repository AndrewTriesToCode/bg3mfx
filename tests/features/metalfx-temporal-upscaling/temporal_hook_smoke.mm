#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <cmath>

static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger size, MTLPixelFormat format, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:size height:size mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = usage;
    return [device newTextureWithDescriptor:d];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 1;
        setenv("BG3MFX_ENABLE_METALFX","1",1);
        void *runtime = dlopen(argv[1],RTLD_NOW | RTLD_LOCAL);
        if (!runtime) { fprintf(stderr,"%s\n",dlerror()); return 2; }
        auto select = (BOOL(*)(int))dlsym(runtime,"BG3MFXSetStandaloneScalingMode");
        if (!select || !select(2)) return 3;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 4;
        NSError *error = nil;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 Fullscreen(uint id [[vertex_id]]) {float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[id],0,1);}\n"
            "fragment float LinearizeDepth(float4 p [[position]], depth2d<float> src [[texture(0)]]) {"
            "constexpr sampler s(coord::pixel,filter::nearest);return src.sample(s,p.xy);}\n"
            "fragment float2 VelocityBufferCamera_PS() {return float2(0);}\n"
            "fragment float4 PPTAA_PS(float4 p [[position]], texture2d<float> src [[texture(0)]]) {return float4(src.read(uint2(p.xy)).rgb+0.25,1);}\n"
            "fragment float4 PPBloomUpsampleBlurAndCombine_PS(float4 p [[position]], texture2d<float> src [[texture(0)]]) {return float4(src.read(uint2(p.xy)).rgb+0.125,1);}\n"
            "fragment float4 FSR_Tonemap(float4 p [[position]], texture2d<float> src [[texture(0)]]) {float3 c=src.read(uint2(p.xy)).rgb;return float4(c/(1+max(c.r,max(c.g,c.b))),1);}\n"
            "kernel void Fill(texture2d<float,access::write> color [[texture(0)]], texture2d<float,access::write> motion [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
            "color.write(float4(0.5,0.75,1.0,1),p);motion.write(float4(0),p);}\n"
            "kernel void FSR(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]], device atomic_uint *count [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {"
            "if(all(p==uint2(0))) atomic_fetch_add_explicit(count,1,memory_order_relaxed);dst.write(src.read(p/2),p);}\n"
            "kernel void FSR_RCAS(texture2d<float,access::write> dst [[texture(2)]], device atomic_uint *count [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {"
            "if(all(p==uint2(0))) atomic_fetch_add_explicit(count,1,memory_order_relaxed);dst.write(float4(0),p);}\n"
            "kernel void Read(texture2d<float,access::read> src [[texture(0)]], device float4 *out [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {out[p.y*src.get_width()+p.x]=src.read(p);}";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr,"%s\n",error.description.UTF8String); return 5; }
        NSMutableArray *compute = [NSMutableArray array];
        for (NSString *name in @[@"Fill",@"FSR",@"FSR_RCAS",@"Read"]) {
            id state = [device newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:&error];
            if (!state) return 6; [compute addObject:state];
        }
        NSMutableArray *render = [NSMutableArray array];
        for (NSString *name in @[@"LinearizeDepth",@"PPTAA_PS",@"VelocityBufferCamera_PS",@"FSR_Tonemap",@"PPBloomUpsampleBlurAndCombine_PS"]) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [library newFunctionWithName:@"Fullscreen"]; d.fragmentFunction = [library newFunctionWithName:name];
            d.colorAttachments[0].pixelFormat = [name isEqualToString:@"LinearizeDepth"] ? MTLPixelFormatR32Float : [name isEqualToString:@"VelocityBufferCamera_PS"] ? MTLPixelFormatRG16Float : MTLPixelFormatRG11B10Float;
            id state = [device newRenderPipelineStateWithDescriptor:d error:&error];
            if (!state) { fprintf(stderr,"%s\n",error.description.UTF8String); return 7; } [render addObject:state];
        }
        MTLTextureUsage rw = MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        id<MTLTexture> color = texture(device,256,MTLPixelFormatRG11B10Float,rw);
        id<MTLTexture> motion = texture(device,256,MTLPixelFormatRG16Float,rw|MTLTextureUsageRenderTarget);
        id<MTLTexture> placeholder = texture(device,16,MTLPixelFormatRGBA8Unorm,MTLTextureUsageShaderRead);
        id<MTLTexture> depth = texture(device,256,MTLPixelFormatDepth32Float_Stencil8,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        id<MTLTexture> linearDepth = texture(device,256,MTLPixelFormatR32Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        id<MTLTexture> taa = texture(device,256,MTLPixelFormatRG11B10Float,rw|MTLTextureUsageRenderTarget);
        id<MTLTexture> auxiliaryTAA = texture(device,256,MTLPixelFormatRG11B10Float,rw|MTLTextureUsageRenderTarget);
        id<MTLTexture> postColor = texture(device,256,MTLPixelFormatRG11B10Float,rw|MTLTextureUsageRenderTarget);
        id<MTLTexture> scaled = texture(device,512,MTLPixelFormatRG11B10Float,rw);
        id<MTLTexture> output = texture(device,512,MTLPixelFormatRG11B10Float,rw);
        id<MTLBuffer> pixels = [device newBufferWithLength:512*512*sizeof(float)*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> previewPixels = [device newBufferWithLength:256*256*sizeof(float)*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> count = [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
        *(uint32_t *)count.contents=0;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        float camera[56]={}, temporal[56]={}, viewport[42]={};
        camera[21]=1.7320508; camera[48]=0.1; camera[49]=1000;
        camera[26]=-camera[48]/(camera[49]-camera[48]); camera[30]=camera[48]*camera[49]/(camera[49]-camera[48]);
        viewport[0]=viewport[1]=1;
        uint32_t dimensions[2]={256,256}; memcpy((char *)viewport+16,dimensions,8);
        for (int frame=0; frame<4; ++frame) {
            // A newly allocated scene target must discover its FSR dependency
            // without prematurely stripping native AA or reusing old history.
            if (frame == 3) taa = texture(device,256,MTLPixelFormatRG11B10Float,rw|MTLTextureUsageRenderTarget);
            if (!select(frame==0 ? 2 : 3)) return 8;
            id<MTLCommandBuffer> b = [queue commandBufferWithUnretainedReferences];
            id<MTLComputeCommandEncoder> c = [b computeCommandEncoder];
            [c setComputePipelineState:compute[0]]; [c setTexture:color atIndex:0]; [c setTexture:motion atIndex:1];
            [c dispatchThreads:MTLSizeMake(256,256,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
            pass.depthAttachment.texture=depth; pass.depthAttachment.loadAction=MTLLoadActionClear;
            pass.depthAttachment.storeAction=MTLStoreActionStore; pass.depthAttachment.clearDepth=0.5;
            id<MTLRenderCommandEncoder> r = [b renderCommandEncoderWithDescriptor:pass]; [r endEncoding];
            pass=[MTLRenderPassDescriptor new]; pass.colorAttachments[0].texture=linearDepth;
            pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            r=[b renderCommandEncoderWithDescriptor:pass];
            // Resource bindings before pipeline state are legal Metal usage.
            [r setFragmentTexture:depth atIndex:0]; [r setRenderPipelineState:render[0]];
            [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [r endEncoding];
            if (frame != 1) {
            pass=[MTLRenderPassDescriptor new]; pass.colorAttachments[0].texture=motion;
            pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            r=[b renderCommandEncoderWithDescriptor:pass];
            [r setFragmentBytes:camera length:sizeof(camera) atIndex:11];
            [r setRenderPipelineState:render[2]];
            [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [r endEncoding];
            }
            pass=[MTLRenderPassDescriptor new]; pass.colorAttachments[0].texture=taa;
            pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            r=[b renderCommandEncoderWithDescriptor:pass];
            [r setFragmentTexture:color atIndex:0]; [r setFragmentTexture:frame == 1 ? placeholder : motion atIndex:2];
            [r setFragmentBytes:temporal length:sizeof(temporal) atIndex:8];
            [r setFragmentBytes:viewport length:sizeof(viewport) atIndex:9];
            [r setRenderPipelineState:render[1]];
            [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [r endEncoding];
            // Mid-frame changes must not mix Spatial's TAA with Temporal's FSR.
            if (frame == 2) {
                // A second view must not overwrite the first view's TAA inputs.
                pass.colorAttachments[0].texture=auxiliaryTAA;
                r=[b renderCommandEncoderWithDescriptor:pass];
                [r setFragmentTexture:color atIndex:0]; [r setFragmentTexture:motion atIndex:2];
                [r setFragmentBytes:temporal length:sizeof(temporal) atIndex:8];
                [r setFragmentBytes:viewport length:sizeof(viewport) atIndex:9];
                [r setRenderPipelineState:render[1]];
                [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [r endEncoding];
                // This view never feeds FSR: its native AA must remain intact.
                c=[b computeCommandEncoder]; [c setComputePipelineState:compute[3]];
                [c setTexture:auxiliaryTAA atIndex:0]; [c setBuffer:previewPixels offset:0 atIndex:0];
                [c dispatchThreads:MTLSizeMake(256,256,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            }
            if (!select(frame==1 ? 2 : 3)) return 9;
            id<MTLTexture> finalHDR = taa;
            if (frame == 2) {
                pass.colorAttachments[0].texture=postColor;
                r=[b renderCommandEncoderWithDescriptor:pass];
                [r setFragmentTexture:taa atIndex:0]; [r setRenderPipelineState:render[4]];
                [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [r endEncoding];
                finalHDR=postColor;
            }
            pass.colorAttachments[0].texture=auxiliaryTAA;
            r=[b renderCommandEncoderWithDescriptor:pass];
            [r setFragmentTexture:finalHDR atIndex:0]; [r setRenderPipelineState:render[3]];
            [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [r endEncoding];
            c=[b computeCommandEncoder];
            [c setTexture:auxiliaryTAA atIndex:0]; [c setTexture:scaled atIndex:1]; [c setComputePipelineState:compute[1]];
            [c setBuffer:count offset:0 atIndex:0];
            [c dispatchThreads:MTLSizeMake(512,512,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [c setTexture:scaled atIndex:0]; [c setTexture:output atIndex:2]; [c setComputePipelineState:compute[2]];
            [c dispatchThreads:MTLSizeMake(512,512,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            c=[b computeCommandEncoder]; [c setComputePipelineState:compute[3]];
            [c setTexture:output atIndex:0]; [c setBuffer:pixels offset:0 atIndex:0];
            [c dispatchThreads:MTLSizeMake(512,512,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            [b commit]; [b waitUntilCompleted];
            if (b.status!=MTLCommandBufferStatusCompleted || *(uint32_t *)count.contents) return 10;
            if (frame == 2) {
                const float *preview=(const float *)previewPixels.contents;
                const float expectedPreview[]={0.75f,1.0f,1.25f};
                for (int ch=0;ch<3;++ch) if (fabs(preview[(128*256+128)*4+ch]-expectedPreview[ch])>0.08) {
                    fprintf(stderr,"Unscaled preview lost native AA: %f != %f\n",preview[(128*256+128)*4+ch],expectedPreview[ch]); return 12;
                }
            }
            const float added=(frame==0 || frame==3) ? 0.25f : frame==2 ? 0.125f : 0;
            const float expected[]={0.5f+added,0.75f+added,1.0f+added}; float *p=(float *)pixels.contents;
            for (NSUInteger y=64;y<448;y+=47) for (NSUInteger x=64;x<448;x+=53) for (int ch=0;ch<3;++ch)
                if (!std::isfinite(p[(y*512+x)*4+ch]) || fabs(p[(y*512+x)*4+ch]-expected[ch])>0.08) {
                    fprintf(stderr,"Temporal hook mismatch frame %d: %f != %f\n",frame,p[(y*512+x)*4+ch],expected[ch]);return 11;
                }
        }
        // A window resized through more sizes than any cache bound must keep
        // one scaler per size: on macOS 27 scalers leak, and recreating one
        // every frame exhausted the ANE and hung BG3.
        auto created = (NSUInteger(*)(void))dlsym(runtime,"BG3MFXStandaloneTemporalScalersCreated");
        if (!created) return 13;
        // Returns whether MetalFX replaced BG3's native FSR for the frame.
        // `probe` receives weak references to BG3's color, depth, motion and output.
        auto resizedFrame = [&](NSUInteger size, __weak id<MTLTexture> *probe = nullptr) -> int { @autoreleasepool {
            id<MTLTexture> sColor=texture(device,size,MTLPixelFormatRG11B10Float,rw);
            id<MTLTexture> sMotion=texture(device,size,MTLPixelFormatRG16Float,rw|MTLTextureUsageRenderTarget);
            id<MTLTexture> sDepth=texture(device,size,MTLPixelFormatDepth32Float_Stencil8,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
            id<MTLTexture> sLinear=texture(device,size,MTLPixelFormatR32Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
            id<MTLTexture> sTAA=texture(device,size,MTLPixelFormatRG11B10Float,rw|MTLTextureUsageRenderTarget);
            id<MTLTexture> sTonemapped=texture(device,size,MTLPixelFormatRG11B10Float,rw|MTLTextureUsageRenderTarget);
            id<MTLTexture> sScaled=texture(device,size*2,MTLPixelFormatRG11B10Float,rw);
            id<MTLTexture> sOutput=texture(device,size*2,MTLPixelFormatRG11B10Float,rw);
            if (probe) { probe[0]=sTAA; probe[1]=sDepth; probe[2]=sMotion; probe[3]=sOutput; }
            uint32_t sDimensions[2]={uint32_t(size),uint32_t(size)}; memcpy((char *)viewport+16,sDimensions,8);
            *(uint32_t *)count.contents=0;
            if (!select(3)) return -1;
            id<MTLCommandBuffer> b=[queue commandBufferWithUnretainedReferences];
            id<MTLComputeCommandEncoder> c=[b computeCommandEncoder];
            [c setComputePipelineState:compute[0]]; [c setTexture:sColor atIndex:0]; [c setTexture:sMotion atIndex:1];
            [c dispatchThreads:MTLSizeMake(size,size,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor new];
            pass.depthAttachment.texture=sDepth; pass.depthAttachment.loadAction=MTLLoadActionClear;
            pass.depthAttachment.storeAction=MTLStoreActionStore; pass.depthAttachment.clearDepth=0.5;
            id<MTLRenderCommandEncoder> r=[b renderCommandEncoderWithDescriptor:pass]; [r endEncoding];
            auto draw=[&](id<MTLTexture> target, id<MTLRenderPipelineState> state, NSArray *sources, BOOL constants) {
                MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor new]; p.colorAttachments[0].texture=target;
                p.colorAttachments[0].loadAction=MTLLoadActionClear; p.colorAttachments[0].storeAction=MTLStoreActionStore;
                id<MTLRenderCommandEncoder> e=[b renderCommandEncoderWithDescriptor:p];
                for (NSUInteger i=0;i<sources.count;++i) if (sources[i]!=NSNull.null) [e setFragmentTexture:sources[i] atIndex:i];
                if (constants) {
                    [e setFragmentBytes:camera length:sizeof(camera) atIndex:11];
                    [e setFragmentBytes:temporal length:sizeof(temporal) atIndex:8];
                    [e setFragmentBytes:viewport length:sizeof(viewport) atIndex:9];
                }
                [e setRenderPipelineState:state]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
            };
            draw(sLinear,render[0],@[sDepth],NO);
            draw(sMotion,render[2],@[],YES);
            draw(sTAA,render[1],@[sColor,NSNull.null,sMotion],YES);
            draw(sTonemapped,render[3],@[sTAA],NO);
            c=[b computeCommandEncoder];
            [c setTexture:sTonemapped atIndex:0]; [c setTexture:sScaled atIndex:1]; [c setComputePipelineState:compute[1]];
            [c setBuffer:count offset:0 atIndex:0];
            [c dispatchThreads:MTLSizeMake(size*2,size*2,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [c setTexture:sScaled atIndex:0]; [c setTexture:sOutput atIndex:2]; [c setComputePipelineState:compute[2]];
            [c dispatchThreads:MTLSizeMake(size*2,size*2,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            [b commit]; [b waitUntilCompleted];
            if (b.status!=MTLCommandBufferStatusCompleted) return -1;
            return *(uint32_t *)count.contents==0;
        }};
        const NSUInteger sizes[]={160,176,192,208,224,240,272,288,304};
        for (NSUInteger size : sizes) {
            NSUInteger before=created(); int replaced=0;
            // A new size runs natively until it has held long enough to settle.
            for (int attempt=0; attempt<6 && created()==before; ++attempt) {
                if ((replaced=resizedFrame(size))<0) return 14;
                if (created()==before) [NSThread sleepForTimeInterval:0.35];
            }
            if (created()!=before+1 || !replaced) { fprintf(stderr,"No Temporal scaler for %lux%lu\n",size,size); return 15; }
            for (int frame=0; frame<3; ++frame) if (resizedFrame(size)!=1) return 16;
            if (created()!=before+1) { fprintf(stderr,"Temporal scaler recreated at a steady %lux%lu\n",size,size); return 17; }
        }
        // Returning to any earlier size reuses its scaler on the first frame.
        NSUInteger total=created();
        for (NSUInteger size : sizes) if (resizedFrame(size)!=1 || created()!=total) {
            fprintf(stderr,"Temporal scaler recreated when returning to %lux%lu\n",size,size); return 18;
        }
        // Cached scalers must not keep the textures of sizes no longer rendered:
        // BG3 frees its render targets on resize. Render each size once more,
        // then end on a different size and check that none of them survives.
        __weak id<MTLTexture> earlier[9][4];
        for (NSUInteger i=0;i<9;++i) if (resizedFrame(sizes[i],earlier[i])!=1) return 19;
        if (resizedFrame(sizes[0])!=1) return 19;
        NSUInteger pinned=0;
        for (NSUInteger i=1;i<9;++i) for (int k=0;k<4;++k) if (earlier[i][k]) { ++pinned; if (getenv("BG3MFX_TEST_VERBOSE")) fprintf(stderr,"size %lu kind %d alive\n",(unsigned long)sizes[i],k); }
        printf("Temporal resize: %lu textures of 32 from earlier sizes still alive\n",(unsigned long)pinned);
        if (pinned) { fprintf(stderr,"Cached Temporal scalers kept earlier sizes' textures alive\n"); return 20; }
        puts("Spatial/Temporal switching, retained native AA on an unscaled preview, new-target warmup, and HDR postprocessing passed four-frame pixel checks; native FSR dispatch count zero.");
        printf("Nine settled resizes created one Temporal scaler each and reused all of them on return.\n");
    }
}
