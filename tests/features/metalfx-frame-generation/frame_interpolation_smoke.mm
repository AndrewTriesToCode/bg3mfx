#import "features/metalfx-frame-generation/FrameInterpolation.h"
#include <cmath>
static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger size, MTLPixelFormat format, MTLTextureUsage usage) {
    auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:size height:size mipmapped:NO];
    d.storageMode=MTLStorageModePrivate; d.usage=usage; return [device newTextureWithDescriptor:d];
}
int main() { @autoreleasepool {
    auto device=MTLCreateSystemDefaultDevice(); if(!device)return 1;
    if (![MTLFXFrameInterpolatorDescriptor supportsDevice:device]) { puts("Frame interpolation unsupported: skipped."); return 0; }
    NSError *error=nil;
    // BG3MFX_TEST_DIRECT_INPUTS uses BG3's live formats, read in place.
    const bool direct=getenv("BG3MFX_TEST_DIRECT_INPUTS");
    auto scene=texture(device,256,direct ? MTLPixelFormatRGB10A2Unorm : MTLPixelFormatRGBA16Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
    auto depth=texture(device,128,direct ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatDepth32Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
    auto motion=texture(device,128,MTLPixelFormatRG16Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
    auto effect=direct ? [[BG3MFXFrameInterpolation alloc] initWithDevice:device scene:scene depth:depth motion:motion error:&error]
        : [[BG3MFXFrameInterpolation alloc] initWithDevice:device width:128 height:128 outputWidth:256 outputHeight:256 error:&error];
    if (!effect) { fprintf(stderr,"%s\n",error.description.UTF8String);return 2; }
    if (direct) {
        BOOL sceneExpected=NO; if (@available(macOS 27.0, *)) sceneExpected=YES;
        if (effect.directColor!=sceneExpected || !effect.directDepth || !effect.directMotion) {
            fprintf(stderr,"direct inputs not used: color %d depth %d motion %d\n",effect.directColor,effect.directDepth,effect.directMotion);return 8;
        }
    } else if (effect.directColor || effect.directDepth || effect.directMotion) return 9;
    float camera[56]={}; camera[21]=1.7;camera[48]=0.1;camera[49]=100;
    NSData *c=[NSData dataWithBytes:camera length:sizeof(camera)];
    auto queue=[device newCommandQueue];
    auto read=[device newBufferWithLength:256*256*8 options:MTLResourceStorageModeShared];
    for (int frame=0;frame<3;++frame) {
        auto cb=[queue commandBuffer]; auto pass=[MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture=scene;pass.colorAttachments[0].clearColor=MTLClearColorMake(.3,.5,.7,1);
        pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        auto e=[cb renderCommandEncoderWithDescriptor:pass];[e endEncoding];
        pass=[MTLRenderPassDescriptor new];pass.depthAttachment.texture=depth;pass.depthAttachment.clearDepth=.5;
        pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;
        if (direct) {pass.stencilAttachment.texture=depth;pass.stencilAttachment.loadAction=MTLLoadActionClear;pass.stencilAttachment.storeAction=MTLStoreActionStore;}
        e=[cb renderCommandEncoderWithDescriptor:pass];[e endEncoding];
        pass=[MTLRenderPassDescriptor new];pass.colorAttachments[0].texture=motion;
        pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        e=[cb renderCommandEncoderWithDescriptor:pass];[e endEncoding];
        BG3MFXFrameParameters p={};p.depthReversed=YES;p.motionScaleX=p.motionScaleY=-1;
        auto out=[effect encodeScene:scene depth:depth motion:motion camera:c parameters:p deltaTime:1.0f/60 commandBuffer:cb error:&error];
        if(!out){fprintf(stderr,"%s\n",error.description.UTF8String);return 3;}
        auto b=[cb blitCommandEncoder];[b copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(256,256,1) toBuffer:read destinationOffset:0 destinationBytesPerRow:256*8 destinationBytesPerImage:256*256*8];[b endEncoding];
        [cb commit];[cb waitUntilCompleted];if(cb.error){fprintf(stderr,"%s\n",cb.error.description.UTF8String);return 4;}
        if(frame) {const __fp16 *v=(const __fp16 *)read.contents;for(int i=0;i<256*256*4;++i) if(!std::isfinite(float(v[i])))return 5;
            const float expected[]={.3,.5,.7};for(int j=0;j<3;++j)if(fabs(float(v[(128*256+128)*4+j])-expected[j])>.04)return 6;}
    }
    [effect resetHistory];
    auto cb=[queue commandBuffer]; BG3MFXFrameParameters p={};
    if([effect encodeScene:scene depth:depth motion:scene camera:c parameters:p deltaTime:.016 commandBuffer:cb error:&error] || !error)return 7;
    printf("Frame interpolation %s%s: real GPU producer/consumer, preserved history, finite pixels and invalid-input checks passed.\n",effect.usesMetal4 ? "Metal 4" : "Metal 3",direct ? " (BG3 formats, direct inputs)" : "");
    return 0;
}}
