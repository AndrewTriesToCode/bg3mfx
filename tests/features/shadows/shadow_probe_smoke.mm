#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <unistd.h>
#include <cstring>

// Exercise the real hooks with a shadow-shaped array pass. Constants differ
// between draws: the probe must preserve the first draw, not the final bind.
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc!=3) return 2;
        NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"bg3mfx-shadow-%d.jsonl",getpid()]];
        setenv("BG3MFX_TRACE",path.UTF8String,1);
        setenv("BG3MFX_TRACE_SHADOWS",strcmp(argv[2],"expect-off")==0 ? "0" : "1",1);
        if (!dlopen(argv[1],RTLD_NOW)) { fprintf(stderr,"%s\n",dlerror()); return 3; }
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if (!device) return 4;
        NSError *error=nil;
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct Camera { float4x4 g_ViewMat; float4x4 g_ProjectionMat; float4x4 g_OffsetViewProjectionMat; float g_NearPlane; float g_FarPlane; };\n"
            "vertex float4 shadowVS(uint i [[vertex_id]], constant Camera &c [[buffer(11)]]) {"
            "float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};"
            "return c.g_OffsetViewProjectionMat * float4(p[i],c.g_NearPlane/c.g_FarPlane,1); }";
        id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
        pd.vertexFunction=[library newFunctionWithName:@"shadowVS"];
        pd.depthAttachmentPixelFormat=MTLPixelFormatDepth16Unorm;
        id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) { fprintf(stderr,"%s\n",error.description.UTF8String); return 5; }
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm width:32 height:32 mipmapped:NO];
        td.textureType=MTLTextureType2DArray; td.arrayLength=2;
        td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate;
        id<MTLTexture> depth=[device newTextureWithDescriptor:td];
        id<MTLCommandQueue> queue=[device newCommandQueue];
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        float camera[52]={}; // 208 bytes including struct tail alignment.
        for (unsigned m=0;m<3;++m) for (unsigned i=0;i<4;++i) camera[m*16+i*5]=1;
        camera[48]=1; camera[49]=100;
        id<MTLBuffer> constants=[device newBufferWithLength:512 options:MTLResourceStorageModeShared];
        memcpy((char *)constants.contents+256,camera,sizeof(camera));
        for (unsigned slice=0;slice<2;++slice) {
            MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor new];
            pass.depthAttachment.texture=depth; pass.depthAttachment.slice=slice;
            pass.depthAttachment.loadAction=MTLLoadActionClear; pass.depthAttachment.storeAction=MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:pass];
            [e setRenderPipelineState:pipeline]; [e setViewport:MTLViewport{0,0,32,32,0,1}];
            if (!slice) [e setVertexBytes:camera length:sizeof(camera) atIndex:11];
            else { [e setVertexBuffer:constants offset:0 atIndex:11]; [e setVertexBufferOffset:256 atIndex:11]; }
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            float changed[52]; memcpy(changed,camera,sizeof(camera)); changed[48]=2;
            [e setVertexBytes:changed length:sizeof(changed) atIndex:11];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
        }
        [cb commit]; [cb waitUntilCompleted];
        if (cb.status!=MTLCommandBufferStatusCompleted) return 6;
        NSString *trace=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        unsigned samples=0;
        for (NSString *line in [trace componentsSeparatedByString:@"\n"]) {
            NSDictionary *event=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![event[@"event"] isEqualToString:@"shadowProbeSample"]) continue;
            if ([event[@"slice"] unsignedIntValue]!=samples || [event[@"samples"] count]!=1) return 7;
            NSDictionary *sample=event[@"samples"][0];
            NSData *data=[[NSData alloc] initWithBase64EncodedString:sample[@"base64"] options:0];
            if (data.length<200 || memcmp(data.bytes,camera,200)) return 8;
            ++samples;
        }
        BOOL expected=strcmp(argv[2],"expect-probe")==0;
        if (samples!=(expected ? 2u : 0u)) { fprintf(stderr,"Unexpected probe samples: %u\n",samples); return 9; }
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        puts("Shadow probe: first-draw constants, array slices and quiet isolation passed");
    }
}
