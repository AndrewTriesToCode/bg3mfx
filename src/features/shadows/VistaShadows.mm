#include "common/native/SupportedBuild.h"
#import "features/shadows/VistaShadows.h"
#import "common/gpu/GPUResources.h"
#import <objc/runtime.h>
#include "common/native/CodePatch.h"
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>
#include <algorithm>

namespace Native = BG3MFXBuild::Shadows;

namespace {
thread_local unsigned vistaReplayDepth;
thread_local unsigned internalEncoding;
BG3MFXNativeSubmit nativeSubmit;
struct CountScope {
    unsigned &count;
    CountScope(unsigned &value):count(value) { ++count; }
    ~CountScope() { --count; }
};
uintptr_t vistaSubmit(void *commands, uintptr_t flags, void *fence) {
    return BG3MFXReplayVista(commands,flags,fence,nativeSubmit);
}
}
bool BG3MFXVistaReplayActive() { return vistaReplayDepth && !internalEncoding; }
bool BG3MFXVistaInternalEncoding() { return internalEncoding!=0; }
extern "C" uintptr_t BG3MFXReplayVista(void *commands, uintptr_t flags, void *fence, BG3MFXNativeSubmit submit) {
    CountScope scope(vistaReplayDepth);
    return submit(commands,flags,fence);
}

BOOL BG3MFXInstallVistaContext(intptr_t slide, NSError **error) {
    auto fail=[&](NSString *message) {
        if (error) *error=[NSError errorWithDomain:@"BG3MFXVistaShadows" code:1
            userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // CascadedShadowBufferStage::Submit: the distinct stage+0x21a0 job,
    // gated by the vista flag, submits synchronously through the native replay.
    // Check the complete context, not just one BL with the right destination.
    static const uint32_t expected[]={0xf9400668,0xf9400508,0xb9403908,0x35000088,
        0xf950d268,0x9100c100,0x941ba37b};
    uintptr_t site=Native::VistaSubmitCall+slide, target=Native::VistaSubmitTarget+slide;
    uintptr_t island=BG3MFXBuild::HeaderPadding+BG3MFXBuild::Islands::Vista.offset+slide;
    if (memcmp(reinterpret_cast<void *>(site-24),expected,sizeof expected) ||
        *reinterpret_cast<const uint32_t *>(target)!=0xd106c3ff)
        return fail(@"Unsupported native vista submission.");
    for (unsigned i=0;i<BG3MFXBuild::Islands::Vista.bytes;++i) if (*reinterpret_cast<const uint8_t *>(island+i))
        return fail(@"Vista branch island is in use.");
    if (!BG3MFXBranchReaches(site,island)) return fail(@"Vista branch island is out of range.");
    nativeSubmit=reinterpret_cast<BG3MFXNativeSubmit>(target);
    auto result=BG3MFXPatchCode({{island,BG3MFXBuild::Islands::Vista.bytes},{site,4}},[&] {
        uint32_t code[4]={0x58000050,0xd61f0200,0,0}; // ldr x16, #8; br x16; .quad hook
        uintptr_t hook=reinterpret_cast<uintptr_t>(vistaSubmit);
        memcpy(code+2,&hook,8);
        memcpy(reinterpret_cast<void *>(island),code,sizeof code);
        uint32_t call=0x94000000|(BG3MFXBranch(site,island)&0x03ffffff);
        memcpy(reinterpret_cast<void *>(site),&call,4);
    });
    if (result!=BG3MFXCodePatchResult::Patched) return fail(@"Could not install vista submission context.");
    return YES;
}

@interface BG3MFXVistaBackend : NSObject
@property(nonatomic) id<MTLRenderPipelineState> pipeline;
@property(nonatomic) id<MTLRenderPipelineState> seedPipeline;
@property(nonatomic) id<MTLDepthStencilState> depth;
@property(nonatomic) NSMutableDictionary<NSString *, BG3MFXTexturePool *> *pools;
@end
@implementation BG3MFXVistaBackend
@end

static BG3MFXVistaBackend *vistaBackend(id<MTLDevice> device) {
    // Constructors install hooks before C++ global initialization; use only
    // function-local C++ state and Objective-C associated objects here.
    static std::recursive_mutex mutex;
    static char key;
    std::lock_guard<std::recursive_mutex> lock(mutex);
    BG3MFXVistaBackend *backend=objc_getAssociatedObject(device,&key);
    if (backend) return backend;
    CountScope scope(internalEncoding);
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vistaMergeVS(uint i [[vertex_id]]) {"
        "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "struct VistaDepth { float z [[depth(any)]]; };\n"
        "fragment VistaDepth vistaSeedPS(float4 p [[position]], depth2d_array<float,access::read> src [[texture(0)]], constant uint &slice [[buffer(0)]]) {"
        "uint2 q=uint2(p.xy)*2; float z=0; for(uint y=0;y<2;++y) for(uint x=0;x<2;++x) z=max(z,src.read(q+uint2(x,y),slice)); return VistaDepth{z}; }\n"
        "fragment VistaDepth vistaMergePS(float4 p [[position]], depth2d<float,access::read> src [[texture(0)]], constant uint4 &bounds [[buffer(0)]]) {"
        "int2 q=int2(floor(p.xy*0.5-0.5)); float z=0; for(int y=0;y<2;++y) for(int x=0;x<2;++x)"
        "z=max(z,src.read(uint2(clamp(q+int2(x,y),int2(bounds.xy),int2(bounds.zw))))); return VistaDepth{z}; }";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    if (!library) return nil;
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[library newFunctionWithName:@"vistaMergeVS"];
    pd.fragmentFunction=[library newFunctionWithName:@"vistaMergePS"];
    pd.depthAttachmentPixelFormat=MTLPixelFormatDepth16Unorm;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];
    pd.fragmentFunction=[library newFunctionWithName:@"vistaSeedPS"];
    id<MTLRenderPipelineState> seed=[device newRenderPipelineStateWithDescriptor:pd error:&error];
    MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new];
    dd.depthCompareFunction=MTLCompareFunctionAlways; dd.depthWriteEnabled=YES;
    id<MTLDepthStencilState> depth=[device newDepthStencilStateWithDescriptor:dd];
    if (!pipeline || !seed || !depth) return nil;
    backend=[BG3MFXVistaBackend new]; backend.pipeline=pipeline; backend.seedPipeline=seed; backend.depth=depth;
    backend.pools=[NSMutableDictionary dictionary];
    objc_setAssociatedObject(device,&key,backend,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return backend;
}

@implementation BG3MFXVistaPass {
    MTLRenderPassDescriptor *_descriptor, *_destination;
    BG3MFXVistaBackend *_backend;
    BG3MFXTexturePool *_pool;
    id<MTLTexture> _low;
    std::vector<MTLViewport> _viewports;
    std::vector<MTLScissorRect> _scissors, _regions;
}
+ (BOOL)supportsDescriptor:(MTLRenderPassDescriptor *)native device:(id<MTLDevice>)device {
    id<MTLTexture> target=native.depthAttachment.texture;
    if (!target || target.device!=device || target.pixelFormat!=MTLPixelFormatDepth16Unorm ||
        target.textureType!=MTLTextureType2DArray || target.arrayLength!=2 || target.sampleCount!=1 ||
        (target.usage!=MTLTextureUsageUnknown && !(target.usage&MTLTextureUsageShaderRead)) ||
        target.width!=target.height || target.width<128 || (target.width&1) ||
        target.storageMode!=MTLStorageModePrivate || target.hazardTrackingMode!=MTLHazardTrackingModeTracked ||
        native.depthAttachment.level || native.depthAttachment.slice>=target.arrayLength ||
        (native.depthAttachment.loadAction!=MTLLoadActionLoad && native.depthAttachment.loadAction!=MTLLoadActionClear) || native.depthAttachment.storeAction!=MTLStoreActionStore ||
        native.depthAttachment.resolveTexture || native.stencilAttachment.texture || native.visibilityResultBuffer ||
        native.renderTargetArrayLength>1 || native.rasterizationRateMap || native.tileWidth || native.tileHeight ||
        (native.renderTargetWidth && native.renderTargetWidth!=target.width) ||
        (native.renderTargetHeight && native.renderTargetHeight!=target.height)) return NO;
    for (unsigned i=0;i<8;++i) if (native.colorAttachments[i].texture) return NO;
    return YES;
}
+ (instancetype)prepare:(MTLRenderPassDescriptor *)native buffer:(id<MTLCommandBuffer>)buffer {
    id<MTLDevice> device=buffer.device;
    if (![self supportsDescriptor:native device:device]) return nil;
    id<MTLTexture> target=native.depthAttachment.texture;
    BG3MFXVistaBackend *backend=vistaBackend(device);
    if (!backend) return nil;
    BG3MFXVistaPass *pass=[BG3MFXVistaPass new];
    pass->_backend=backend;
    NSString *key=[NSString stringWithFormat:@"%lux%lu",(unsigned long)target.width/2,(unsigned long)target.height/2];
    @synchronized (backend) {
        pass->_pool=backend.pools[key];
        if (!pass->_pool) {
            MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm
                width:target.width/2 height:target.height/2 mipmapped:NO];
            td.storageMode=MTLStorageModePrivate; td.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
            pass->_pool=[[BG3MFXTexturePool alloc] initWithDevice:device descriptor:td];
            backend.pools[key]=pass->_pool;
        }
    }
    pass->_low=[pass->_pool acquire];
    if (!pass->_low) return nil;
    pass->_descriptor=[native copy];
    pass->_descriptor.depthAttachment.texture=pass->_low;
    pass->_descriptor.depthAttachment.slice=0;
    if (native.depthAttachment.loadAction==MTLLoadActionLoad) {
        CountScope scope(internalEncoding);
        MTLRenderPassDescriptor *seed=[MTLRenderPassDescriptor renderPassDescriptor];
        seed.depthAttachment.texture=pass->_low;
        seed.depthAttachment.loadAction=MTLLoadActionDontCare;
        seed.depthAttachment.storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder=[buffer renderCommandEncoderWithDescriptor:seed];
        if (!encoder) return nil;
        encoder.label=@"BG3 vista atlas seed";
        [encoder setRenderPipelineState:backend.seedPipeline];
        [encoder setDepthStencilState:backend.depth];
        [encoder setFragmentTexture:target atIndex:0];
        uint32_t slice=(uint32_t)native.depthAttachment.slice;
        [encoder setFragmentBytes:&slice length:sizeof slice atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
    }
    pass->_descriptor.renderTargetWidth=target.width/2;
    pass->_descriptor.renderTargetHeight=target.height/2;
    pass->_destination=[native copy];
    pass->_viewports.push_back({0,0,(double)target.width,(double)target.height,0,1});
    pass->_scissors.push_back({0,0,target.width,target.height});
    return pass;
}
- (void)dealloc { if (_low) [_pool relinquish:_low]; }
- (MTLRenderPassDescriptor *)descriptor { return _descriptor; }
- (MTLViewport)scaleViewport:(MTLViewport)v {
    v.originX*=0.5; v.originY*=0.5; v.width*=0.5; v.height*=0.5; return v;
}
- (MTLScissorRect)scaleScissor:(MTLScissorRect)r {
    NSUInteger right=(r.x+r.width+1)/2, bottom=(r.y+r.height+1)/2;
    r.x/=2; r.y/=2; r.width=right-r.x; r.height=bottom-r.y; return r;
}
- (void)setNativeViewports:(const MTLViewport *)values count:(NSUInteger)count {
    _viewports.assign(values,values+count);
}
- (void)setNativeScissors:(const MTLScissorRect *)values count:(NSUInteger)count {
    _scissors.assign(values,values+count);
}
- (void)noteDraw {
    double width=_destination.depthAttachment.texture.width, height=_destination.depthAttachment.texture.height;
    for (auto v:_viewports) for (auto r:_scissors) {
        double left=std::max({0.0,std::floor(v.originX),(double)r.x});
        double top=std::max({0.0,std::floor(v.originY),(double)r.y});
        double right=std::min({width,std::ceil(v.originX+v.width),(double)r.x+r.width});
        double bottom=std::min({height,std::ceil(v.originY+v.height),(double)r.y+r.height});
        if (right<=left || bottom<=top) continue;
        MTLScissorRect region={(NSUInteger)left,(NSUInteger)top,(NSUInteger)(right-left),(NSUInteger)(bottom-top)};
        bool found=false;
        for (auto old:_regions) if (old.x==region.x && old.y==region.y && old.width==region.width && old.height==region.height) found=true;
        if (!found) _regions.push_back(region);
    }
}
- (BOOL)finishInBuffer:(id<MTLCommandBuffer>)buffer {
    if (!_low || !buffer) return NO;
    CountScope scope(internalEncoding);
    id<MTLRenderCommandEncoder> encoder=[buffer renderCommandEncoderWithDescriptor:_destination];
    if (!encoder) return NO;
    encoder.label=@"BG3 Smart Shadows vista atlas replacement";
    [encoder setRenderPipelineState:_backend.pipeline];
    [encoder setDepthStencilState:_backend.depth];
    [encoder setFragmentTexture:_low atIndex:0];
    for (auto r:_regions) {
        uint32_t bounds[4]={(uint32_t)(r.x/2),(uint32_t)(r.y/2),
            (uint32_t)((r.x+r.width-1)/2),(uint32_t)((r.y+r.height-1)/2)};
        [encoder setScissorRect:r];
        [encoder setFragmentBytes:bounds length:sizeof bounds atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [encoder endEncoding];
    [_pool relinquish:_low afterCommandBuffer:buffer]; _low=nil;
    return YES;
}
@end
