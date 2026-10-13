#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <dlfcn.h>
#include <cmath>
#include <algorithm>
#include <initializer_list>
static id<MTLTexture> texture(id<MTLDevice> d, NSUInteger size, MTLPixelFormat f, MTLTextureUsage usage) {
    auto t=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:size height:size mipmapped:NO];
    t.storageMode=MTLStorageModePrivate;t.usage=usage;return [d newTextureWithDescriptor:t];
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2 && !(argc==3 && (!strcmp(argv[2],"hdr") || !strcmp(argv[2],"scaled"))))return 1;
    // "hdr": BG3 with HDR output composes with CombineUI_HDR into a BGR10A2Unorm layer.
    // "scaled": BG3 letterboxes the scene into a larger output (windowed or a
    // display whose size or aspect differs from the render resolution).
    bool hdrOutput=argc==3 && !strcmp(argv[2],"hdr"),scaledOutput=argc==3 && !strcmp(argv[2],"scaled");setenv("BG3MFX_ENABLE_METALFX","1",1);
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
    auto setMode=(BOOL(*)(int))dlsym(lib,"BG3MFXSetStandaloneScalingMode");
    auto setFrameGeneration=(BOOL(*)(BOOL))dlsym(lib,"BG3MFXSetStandaloneFrameGeneration");
    // Choices 0-3 are Off, FSR, Spatial and Temporal with the Frame Generation
    // checkbox clear; 4-7 are Temporal, Spatial, Off and FSR with it checked.
    auto modeFor=[](int choice){ static const int modes[]={3,2,0,1}; return choice<4 ? choice : modes[choice-4]; };
    auto select=[&](int choice)->BOOL{ return setMode && setFrameGeneration && setMode(modeFor(choice)) && setFrameGeneration(choice>=4); };
    auto pair=(NSDictionary *(*)(id<MTLCommandBuffer>))dlsym(lib,"BG3MFXStandaloneGeneratedPair");
    auto presented=(NSUInteger(*)(void))dlsym(lib,"BG3MFXStandalonePresentedPairs");
    auto allocations=(NSUInteger(*)(void))dlsym(lib,"BG3MFXTexturePoolAllocations");
    if(!setMode || !setFrameGeneration || !pair || !presented || !allocations)return 3;
    Class standIn=NSClassFromString(@"BG3MFXStandInDrawable");NSUInteger warm=0;int fgFrames=0;
    auto device=MTLCreateSystemDefaultDevice();NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 V(uint i [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0,1);}\n"
        "fragment float LinearizeDepth(float4 p [[position]],depth2d<float> s [[texture(0)]]){constexpr sampler q(coord::pixel,filter::nearest);return s.sample(q,p.xy);}\n"
        "fragment float2 VelocityBufferCamera_PS(){return float2(0);}\n"
        "fragment float4 PPTAA_PS(float4 p [[position]],texture2d<float> t [[texture(0)]]){return t.read(uint2(p.xy));}\n"
        "fragment float4 FSR_Tonemap(float4 p [[position]],texture2d<float> t [[texture(0)]]){float3 c=t.read(uint2(p.xy)).rgb;return float4(c/(1+max(c.r,max(c.g,c.b))),1);}\n"
        "fragment float4 PPToneMap_LUT(float4 p [[position]],texture2d<float> t [[texture(0)]]){return t.read(uint2(p.xy));}\n"
        // Like BG3's DefaultVS: a quad strip with texture coordinates, so the scene maps onto the viewport at any size.
        "struct Q{float4 p [[position]];float2 uv;};vertex Q Quad(uint i [[vertex_id]]){float2 c=float2(i&1,i>>1);return {float4(c*2-1,0,1),float2(c.x,1-c.y)};}\n"
        "struct C{float4 tint;};float4 combine(Q q,texture2d<float> scene,texture2d<float> ui,constant C &c,sampler s){return float4(scene.sample(s,q.uv).rgb*.5+ui.sample(s,q.uv).rgb*.5,1)*c.tint;}\n"
        "fragment float4 CombineUI(Q q [[stage_in]],texture2d<float> scene [[texture(0)]],texture2d<float> ui [[texture(1)]],constant C &c [[buffer(0)]],sampler s [[sampler(0)]]){return combine(q,scene,ui,c,s);}\n"
        "fragment float4 CombineUI_HDR(Q q [[stage_in]],texture2d<float> scene [[texture(0)]],texture2d<float> ui [[texture(1)]],constant C &c [[buffer(0)]],sampler s [[sampler(0)]]){return combine(q,scene,ui,c,s);}\n"
        "kernel void CAS(texture2d<float,access::read> s [[texture(0)]],texture2d<float,access::write> d [[texture(1)]],uint2 p [[thread_position_in_grid]]){d.write(s.read(p),p);}\n"
        "kernel void FSR(texture2d<float,access::read> s [[texture(0)]],texture2d<float,access::write> d [[texture(1)]],device atomic_uint *count [[buffer(0)]],uint2 p [[thread_position_in_grid]]){if(all(p==uint2(0)))atomic_fetch_add_explicit(count,1,memory_order_relaxed);d.write(s.read(p/2),p);}\n"
        "kernel void FSR_RCAS(texture2d<float,access::read> s [[texture(0)]],texture2d<float,access::write> d [[texture(2)]],device atomic_uint *count [[buffer(0)]],uint2 p [[thread_position_in_grid]]){if(all(p==uint2(0)))atomic_fetch_add_explicit(count,1,memory_order_relaxed);float3 c=s.read(p).rgb;d.write(float4(c/(1-max(c.r,max(c.g,c.b))),1),p);}";
    auto library=[device newLibraryWithSource:source options:nil error:&error];if(!library)return 4;
    NSMutableArray *render=[NSMutableArray array];
    NSArray *names=@[@"LinearizeDepth",@"VelocityBufferCamera_PS",@"PPTAA_PS",@"FSR_Tonemap",@"PPToneMap_LUT",hdrOutput ? @"CombineUI_HDR" : @"CombineUI"];
    MTLPixelFormat outputFormat=hdrOutput ? MTLPixelFormatBGR10A2Unorm : MTLPixelFormatBGRA8Unorm;
    for(NSUInteger i=0;i<names.count;++i){auto d=[MTLRenderPipelineDescriptor new];d.vertexFunction=[library newFunctionWithName:i==5 ? @"Quad" : @"V"];
        d.fragmentFunction=[library newFunctionWithName:names[i]];
        d.colorAttachments[0].pixelFormat=i==0 ? MTLPixelFormatR32Float : i==1 ? MTLPixelFormatRG16Float : i==4 ? MTLPixelFormatRGB10A2Unorm : i==5 ? outputFormat : MTLPixelFormatRG11B10Float;
        auto p=[device newRenderPipelineStateWithDescriptor:d error:&error];if(!p){fprintf(stderr,"%s\n",error.description.UTF8String);return 5;}[render addObject:p];}
    auto fsr=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"FSR"] error:&error];
    auto rcas=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"FSR_RCAS"] error:&error];
    auto cas=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"CAS"] error:&error];
    auto q=[device newCommandQueue];auto vertices=[device newBufferWithLength:80 options:MTLResourceStorageModeShared];
    auto count=[device newBufferWithLength:4 options:MTLResourceStorageModeShared];auto sample=[device newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
    float camera[56]={};camera[21]=1.7;camera[26]=-.001001;camera[30]=.1001001;camera[48]=.1;camera[49]=100;
    float temporal[56]={},viewport[42]={};viewport[0]=viewport[1]=1;((uint32_t *)viewport)[4]=((uint32_t *)viewport)[5]=128;
    // Unattached layer: nothing is shown. Without Frame Generation BG3 gets real
    // CAMetalDrawables; with it, stand-ins that the presenter copies to real ones.
    auto layer=[CAMetalLayer layer];layer.device=device;layer.pixelFormat=outputFormat;layer.framebufferOnly=NO;
    // BG3's double-buffered vsync; Frame Generation must lift it to three and restore it.
    layer.maximumDrawableCount=2;
    // Off/FSR/Spatial/Temporal, three Temporal + Frame Generation frames, back
    // to Temporal (releases the effect), then Temporal + Frame Generation again.
    // One BG3 frame for a menu choice. "decline" composes without a sampler,
    // which Frame Generation cannot replay: it must turn itself off, not stop.
    // "size" overrides the output size; "unsettled" expects BG3's native FSR
    // because that size has no Temporal scaler yet and has not held long enough.
    // "noTAA" renders a world frame without BG3's TAA pass (another
    // anti-aliasing setting): there is no depth, motion or camera to pair with.
    auto frame=[&](int choice,bool decline,NSUInteger size=0,bool unsettled=false,bool noTAA=false)->int{if(!select(choice))return 6;int mode=modeFor(choice);bool fg=choice>=4 && !decline;NSUInteger out=size ?: mode ? 256 : 128;
        NSUInteger width=scaledOutput ? out+64 : out,height=scaledOutput ? out+32 : out;
        auto color=texture(device,128,MTLPixelFormatRG11B10Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        auto taa=texture(device,128,MTLPixelFormatRG11B10Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        auto z=texture(device,128,MTLPixelFormatDepth32Float_Stencil8,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        auto linear=texture(device,128,MTLPixelFormatR32Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        auto motion=texture(device,128,MTLPixelFormatRG16Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        auto bounded=texture(device,128,MTLPixelFormatRG11B10Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        auto scaled=texture(device,out,MTLPixelFormatRG11B10Float,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
        auto hdr=texture(device,out,MTLPixelFormatRG11B10Float,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
        auto scene=texture(device,out,MTLPixelFormatRGB10A2Unorm,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        auto ui=texture(device,out,MTLPixelFormatRGBA8Unorm,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        // Without an upscaler, BG3 sharpens the tone-mapped scene with CAS.
        auto sharpened=texture(device,out,MTLPixelFormatRGB10A2Unorm,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
        // Later Frame Generation frames use BG3's vsync-off setting, whose
        // presenter path presents each image after a minimum on-screen duration.
        layer.displaySyncEnabled=!(fg && fgFrames>=2);
        layer.drawableSize=CGSizeMake(width,height);auto drawable=[layer nextDrawable];if(!drawable)return 10;
        if([drawable isKindOfClass:standIn]!=(choice>=4)){fprintf(stderr,"Menu choice %d got the wrong drawable kind\n",choice);return 13;}
        if(layer.maximumDrawableCount!=(choice>=4 ? 3u : 2u)){fprintf(stderr,"Menu choice %d left %lu drawables\n",choice,(unsigned long)layer.maximumDrawableCount);return 15;}
        auto final=drawable.texture;NSUInteger before=presented();
        auto b=[q commandBuffer];
        // BG3 schedules its present before it encodes CombineUI.
        [b presentDrawable:drawable];auto pass=[MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(.2,.4,.6,1);
        auto e=[b renderCommandEncoderWithDescriptor:pass];[e endEncoding];
        pass=[MTLRenderPassDescriptor new];pass.depthAttachment.texture=z;pass.depthAttachment.clearDepth=.5;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;e=[b renderCommandEncoderWithDescriptor:pass];[e endEncoding];
        for(int i=0;i<(noTAA ? 2 : 3);++i){pass=[MTLRenderPassDescriptor new];pass.colorAttachments[0].texture=i==0 ? linear : i==1 ? motion : taa;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            e=[b renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:render[i]];[e setFragmentTexture:i==0 ? z : color atIndex:0];
            if(i==1)[e setFragmentBytes:camera length:sizeof(camera) atIndex:11];
            if(i==2){[e setFragmentTexture:motion atIndex:2];[e setFragmentBytes:temporal length:sizeof(temporal) atIndex:8];[e setFragmentBytes:viewport length:sizeof(viewport) atIndex:9];}
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];}
        *(uint32_t *)count.contents=0;
        if(mode){pass=[MTLRenderPassDescriptor new];pass.colorAttachments[0].texture=bounded;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;e=[b renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:render[3]];[e setFragmentTexture:taa atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];
            auto c=[b computeCommandEncoder];[c setComputePipelineState:fsr];[c setTexture:bounded atIndex:0];[c setTexture:scaled atIndex:1];[c setBuffer:count offset:0 atIndex:0];[c dispatchThreads:MTLSizeMake(out,out,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
            [c setComputePipelineState:rcas];[c setTexture:scaled atIndex:0];[c setTexture:hdr atIndex:2];[c dispatchThreads:MTLSizeMake(out,out,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[c endEncoding];}
        pass=[MTLRenderPassDescriptor new];pass.colorAttachments[0].texture=scene;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;e=[b renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:render[4]];[e setFragmentTexture:mode ? hdr : taa atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];
        if(!mode){auto c=[b computeCommandEncoder];[c setComputePipelineState:cas];[c setTexture:scene atIndex:0];[c setTexture:sharpened atIndex:1];
            [c dispatchThreads:MTLSizeMake(out,out,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[c endEncoding];}
        pass=[MTLRenderPassDescriptor new];pass.colorAttachments[0].texture=ui;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(.8,.2,.4,1);e=[b renderCommandEncoderWithDescriptor:pass];[e endEncoding];
        // Scaled output clears to a bar color and draws the scene into a centered viewport.
        pass.colorAttachments[0].texture=final;pass.colorAttachments[0].loadAction=scaledOutput ? MTLLoadActionClear : MTLLoadActionDontCare;pass.colorAttachments[0].clearColor=MTLClearColorMake(.1,.7,.3,1);
        e=[b renderCommandEncoderWithDescriptor:pass];[e setRenderPipelineState:render[5]];if(scaledOutput)[e setViewport:(MTLViewport){double(width-out)/2,double(height-out)/2,double(out),double(out),0,1}];
        [e setVertexBuffer:vertices offset:0 atIndex:0];float tint[4]={1,1,1,1};[e setFragmentBytes:tint length:sizeof(tint) atIndex:0];if(!decline)[e setFragmentSamplerState:sample atIndex:0];[e setFragmentTexture:mode ? scene : sharpened atIndex:0];[e setFragmentTexture:ui atIndex:1];[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];[e endEncoding];
        NSDictionary *outputs=pair(b);
        if(!fg){
            // Frame Generation requires Temporal and the checkbox; otherwise native presentation.
            if(outputs){fprintf(stderr,"Frame generation ran for menu choice %d\n",choice);return 7;}
            [b commit];[b waitUntilCompleted];
            if(b.error || *(uint32_t *)count.contents!=(mode==1 || unsettled ? 2u : 0u)){fprintf(stderr,"Native FSR dispatch/completion mismatch %d: %s\n",mode,b.error.description.UTF8String);return 8;}
            [NSThread sleepForTimeInterval:.1];
            if(size){printf("%s %lux%lu output used %s for menu choice %d.\n",unsettled ? "Unsettled" : "Settled",(unsigned long)out,(unsigned long)out,
                unsettled ? "native FSR" : "MetalFX Temporal",choice);return 0;}
            if(noTAA)return 0;
            if(decline){printf("Unsupported composition presented unpaired for menu choice %d; Frame Generation turned off.\n",choice);return 0;}
            if(presented()!=0){fprintf(stderr,"Presentation worker used or retained for menu choice %d\n",choice);return 11;}
            printf("Native presentation for menu choice %d; no frame-generation worker.\n",choice);return 0;
        }
        if(!outputs){fprintf(stderr,"No generated pair for mode %d\n",mode);return 7;}
        NSMutableArray *reads=[NSMutableArray array];auto blit=[b blitCommandEncoder];
        for(id<MTLTexture> t in @[final,outputs[@"generated"]]){auto r=[device newBufferWithLength:width*height*4 options:MTLResourceStorageModeShared];[reads addObject:r];[blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toBuffer:r destinationOffset:0 destinationBytesPerRow:width*4 destinationBytesPerImage:width*height*4];}[blit endEncoding];[b commit];[b waitUntilCompleted];
        if(b.error || *(uint32_t *)count.contents!=(mode==1 ? 2u : 0u)){fprintf(stderr,"Native FSR dispatch/completion mismatch %d: %s\n",mode,b.error.description.UTF8String);return 8;}
        // BG3's CombineUI composes the real frame into the stand-in itself. The
        // generated frame reuses its pipeline, constants and UI; for this static
        // scene it must match the real composite within interpolation rounding.
        auto real=(const uint8_t *)((id<MTLBuffer>)reads[0]).contents,generated=(const uint8_t *)((id<MTLBuffer>)reads[1]).contents;
        int worst=0;for(NSUInteger i=0;i<width*height;++i)for(int c=0;c<(hdrOutput ? 3 : 4);++c){
            // Compare channels on the 8-bit scale; BGR10A2 packs three 10-bit channels.
            int a=hdrOutput ? int(((const uint32_t *)real)[i]>>(10*c)&1023)/4 : real[i*4+c];
            int g=hdrOutput ? int(((const uint32_t *)generated)[i]>>(10*c)&1023)/4 : generated[i*4+c];
            worst=std::max(worst,abs(a-g));}
        if(worst>8){fprintf(stderr,"Generated composition differs from the real frame by %d\n",worst);return 9;}
        for(int i=0;i<200 && presented()==before;++i)[NSThread sleepForTimeInterval:.01];
        if(presented()!=before+1){fprintf(stderr,"Present scheduled before CombineUI did not reach the presentation worker\n");return 12;}
        // Pools warm on the first two consecutive frames; the third must reuse.
        if(++fgFrames==2)warm=allocations();
        else if(fgFrames==3 && allocations()!=warm){fprintf(stderr,"Frame generation allocated textures after warmup\n");return 14;}
        printf("Stand-in frame and generated pair (max difference %d, %lux%lu scene in %lux%lu output) presented for menu choice %d, vsync %s.\n",
            worst,(unsigned long)out,(unsigned long)out,(unsigned long)width,(unsigned long)height,choice,layer.displaySyncEnabled ? "on" : "off");
        return 0;
    };
    // Frame Generation with every Upscaling Type. Spatial (5), Off (6) and FSR
    // (7) keep native TAA, whose depth, motion and camera feed the interpolator;
    // the scene is followed through MetalFX Spatial, no upscale, or BG3's FSR.
    for(int choice:{0,1,2,3,4,4,4,3,4,5,5,2,5,4,6,6,0,6,7,7,1,7,5,4})if(int status=frame(choice,false))return status;
    // A window being resized: each new output size uses native FSR, and a size
    // that holds gets its scaler, so a drag creates one scaler instead of one per frame.
    for(NSUInteger size:{240u,248u,248u})if(int status=frame(3,false,size,true))return status;
    [NSThread sleepForTimeInterval:.35];
    if(int status=frame(3,false,248))return status;
    if(int status=frame(4,false))return status;
    // The last choice left Frame Generation active with BG3 double-buffered:
    // only two stand-ins may be in flight. Switching BG3 to triple allows three
    // while the real layer stays at three throughout.
    @autoreleasepool {
        id d0=[layer nextDrawable],d1=[layer nextDrawable];
        CFTimeInterval start=CACurrentMediaTime();id d2=[layer nextDrawable];
        if(!d0 || !d1 || d2 || CACurrentMediaTime()-start<0.9){fprintf(stderr,"Double buffering allowed a third stand-in\n");return 16;}
        layer.maximumDrawableCount=3;
        if(layer.maximumDrawableCount!=3 || !(d2=[layer nextDrawable])){fprintf(stderr,"Triple buffering did not allow a third stand-in\n");return 17;}
        layer.maximumDrawableCount=2;
    }
    if(!select(3))return 6;
    @autoreleasepool { if(![layer nextDrawable] || layer.maximumDrawableCount!=2){fprintf(stderr,"BG3's latest buffering was not restored\n");return 18;} }
    // A composition Frame Generation cannot replay turns it off for the rest of
    // the selection: the game keeps running on real drawables. Reselecting retries.
    if(int status=frame(4,true))return status;
    @autoreleasepool { id d=[layer nextDrawable];
        if(!d || [d isKindOfClass:standIn] || layer.maximumDrawableCount!=2){fprintf(stderr,"Declined Frame Generation kept stand-ins\n");return 20;} }
    for(int choice:{3,4,4})if(int status=frame(choice,false)){fprintf(stderr,"Reselected Frame Generation did not resume\n");return status;}
    // Frames without TAA inputs (menus, loading screens) are presented unpaired
    // while Frame Generation stays on; pairing resumes with the next TAA frame.
    for(int i=0;i<3;++i)if(int status=frame(6,true,0,false,true))return status;
    @autoreleasepool { id d=[layer nextDrawable]; if(![d isKindOfClass:standIn]){fprintf(stderr,"Frames without TAA inputs turned Frame Generation off\n");return 21;} }
    if(int status=frame(6,false)){fprintf(stderr,"Frame Generation did not resume once TAA returned\n");return status;}
    puts("Frames without TAA inputs presented unpaired; Frame Generation resumed with the next TAA frame.");

    // A Temporal frame whose FSR input matches no captured scene (a loading or
    // view transition) must fall back to BG3's own FSR + RCAS, not stop the game.
    if(!select(3))return 6;
    {   auto source=texture(device,128,MTLPixelFormatRG11B10Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        auto scaled=texture(device,256,MTLPixelFormatRG11B10Float,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
        auto sharpened=texture(device,256,MTLPixelFormatRG11B10Float,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
        *(uint32_t *)count.contents=0;auto b=[q commandBuffer];auto c=[b computeCommandEncoder];
        [c setComputePipelineState:fsr];[c setTexture:source atIndex:0];[c setTexture:scaled atIndex:1];[c setBuffer:count offset:0 atIndex:0];[c dispatchThreads:MTLSizeMake(256,256,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
        [c setComputePipelineState:rcas];[c setTexture:scaled atIndex:0];[c setTexture:sharpened atIndex:2];[c dispatchThreads:MTLSizeMake(256,256,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[c endEncoding];
        [b commit];[b waitUntilCompleted];
        if(b.error || *(uint32_t *)count.contents!=2u){fprintf(stderr,"Unmatched Temporal frame did not fall back to native FSR (%u dispatches)\n",*(uint32_t *)count.contents);return 19;}
        puts("Unmatched Temporal frame fell back to native FSR and RCAS.");
    }
    puts("Frame-generation hook checks passed: Frame Generation with Off, FSR, Spatial and Temporal renders into stand-in drawables, pairs and presents from an early-scheduled present, follows BG3's double/triple buffering for stand-ins, reuses pooled resources, and releases on reselection; Off/FSR/Spatial/Temporal keep real drawables (unattached layer; no display or pacing acceptance).");return 0;
}}
