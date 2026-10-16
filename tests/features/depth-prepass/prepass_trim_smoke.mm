#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Renderer-hook regression for the depth prepass trim and redundant bind
// filtering, shaped like BG3's prepass and four-target G-buffer:
//   Opaque: a vertex-only `_DEP` prepass pipeline (trimmed) and its `_DEF`
//           G-buffer pipeline (switched to a depth-writing state).
//   Cutout: a `_DEP` prepass that discards its left half; its `_DEF` pipeline
//           does not discard and relies on the Equal test (left untouched).
// Reversed Z: the cutout (0.8) is nearer than the opaque (0.5).
// Expected G-buffer color0: left half opaque (A), right half cutout (B).
// usage: prepass-trim-smoke RUNTIME.dylib [expect-trim|expect-full]
static const NSUInteger size = 32;

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 1;
        bool expectTrim = !strcmp(argv[2], "expect-trim");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;
        setenv("BG3MFX_ENABLE_METALFX", "1", 1);
        void *runtime = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!runtime) { fprintf(stderr, "%s\n", dlerror()); return 3; }

        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 position [[position]]; float2 uv; };\n"
            "static V square(uint id, float z) { float2 p[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,-1),float2(1,1),float2(-1,1)};"
            " V v; v.position=float4(p[id],z,1); v.uv=p[id]*0.5+0.5; return v; }\n"
            "vertex V Test_Opaque_DEP_vertexMain(uint id [[vertex_id]]) { return square(id,0.5); }\n"
            // Vertex-only and non-rasterizing, so its writes are well defined: it
            // counts how often the prepass actually runs a trimmable draw.
            "vertex void Test_Counter_DEP_vertexMain(device atomic_uint *count [[buffer(1)]])"
            " { atomic_fetch_add_explicit(count,1,memory_order_relaxed); }\n"
            "vertex V Test_Opaque_DEF_vertexMain(uint id [[vertex_id]]) { return square(id,0.5); }\n"
            "vertex V Test_Cutout_DEP_vertexMain(uint id [[vertex_id]]) { return square(id,0.8); }\n"
            "vertex V Test_Cutout_DEF_vertexMain(uint id [[vertex_id]]) { return square(id,0.8); }\n"
            "fragment void Test_Cutout_DEP_fragmentMain(V v [[stage_in]]) { if (v.uv.x < 0.5) discard_fragment(); }\n"
            "struct G { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; float4 c2 [[color(2)]]; float4 c3 [[color(3)]]; };\n"
            // Color comes from texture slot 3, which only changes between the draws.
            "fragment G Test_DEF_fragmentMain(V v [[stage_in]], texture2d<float> t3 [[texture(3)]]) {"
            " float4 c=t3.read(uint2(0,0)); G g; g.c0=c; g.c1=c; g.c2=c; g.c3=c; return g; }\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr, "%s\n", error.description.UTF8String); return 4; }

        auto pipeline = [&](NSString *vertex, NSString *fragment, bool gbuffer, bool rasterize = true) -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
            desc.rasterizationEnabled = rasterize;
            desc.vertexFunction = [library newFunctionWithName:vertex];
            if (fragment) desc.fragmentFunction = [library newFunctionWithName:fragment];
            if (gbuffer) for (NSUInteger i = 0; i < 4; ++i) desc.colorAttachments[i].pixelFormat = MTLPixelFormatRGBA8Unorm;
            desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            NSError *e = nil;
            id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:desc error:&e];
            if (!state) fprintf(stderr, "%s\n", e.description.UTF8String);
            return state;
        };
        id<MTLRenderPipelineState> opaqueDEP = pipeline(@"Test_Opaque_DEP_vertexMain", nil, false);
        id<MTLRenderPipelineState> counterDEP = pipeline(@"Test_Counter_DEP_vertexMain", nil, false, false);
        id<MTLRenderPipelineState> cutoutDEP = pipeline(@"Test_Cutout_DEP_vertexMain", @"Test_Cutout_DEP_fragmentMain", false);
        id<MTLRenderPipelineState> opaqueDEF = pipeline(@"Test_Opaque_DEF_vertexMain", @"Test_DEF_fragmentMain", true);
        id<MTLRenderPipelineState> cutoutDEF = pipeline(@"Test_Cutout_DEF_vertexMain", @"Test_DEF_fragmentMain", true);
        if (!opaqueDEP || !counterDEP || !cutoutDEP || !opaqueDEF || !cutoutDEF) return 5;

        MTLDepthStencilDescriptor *prepassDepth = [MTLDepthStencilDescriptor new];
        prepassDepth.depthCompareFunction = MTLCompareFunctionGreaterEqual;
        prepassDepth.depthWriteEnabled = YES;
        MTLDepthStencilDescriptor *gbufferDepth = [MTLDepthStencilDescriptor new];
        gbufferDepth.depthCompareFunction = MTLCompareFunctionEqual;
        gbufferDepth.depthWriteEnabled = NO;
        id<MTLDepthStencilState> prepassState = [device newDepthStencilStateWithDescriptor:prepassDepth];
        id<MTLDepthStencilState> gbufferState = [device newDepthStencilStateWithDescriptor:gbufferDepth];

        auto target = [&](MTLPixelFormat format, MTLStorageMode storage) {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:size height:size mipmapped:NO];
            desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            desc.storageMode = storage;
            return [device newTextureWithDescriptor:desc];
        };
        id<MTLTexture> depth = target(MTLPixelFormatDepth32Float_Stencil8, MTLStorageModePrivate);
        id<MTLTexture> colors[4];
        for (auto &c : colors) c = target(MTLPixelFormatRGBA8Unorm, MTLStorageModeShared);
        auto solid = [&](uint32_t rgba) {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
            desc.storageMode = MTLStorageModeShared;
            id<MTLTexture> t = [device newTextureWithDescriptor:desc];
            [t replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&rgba bytesPerRow:4];
            return t;
        };
        const uint32_t colorA = 0xff0000ffu, colorB = 0xff00ff00u, other = 0xffff0000u;  // ABGR in memory
        id<MTLTexture> textureA = solid(colorA), textureB = solid(colorB), filler = solid(other);
        id<MTLBuffer> counter = [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];

        // Frame 1 teaches the runtime which depth target feeds the G-buffer; the
        // trim applies from frame 2 on.
        for (int frame = 1; frame <= 2; ++frame) {
            *(uint32_t *)counter.contents = 0;
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            MTLRenderPassDescriptor *prepass = [MTLRenderPassDescriptor new];
            prepass.depthAttachment.texture = depth;
            prepass.depthAttachment.loadAction = MTLLoadActionClear;
            prepass.depthAttachment.clearDepth = 0.0;
            prepass.depthAttachment.storeAction = MTLStoreActionStore;
            prepass.stencilAttachment.texture = depth;
            id<MTLRenderCommandEncoder> e = [buffer renderCommandEncoderWithDescriptor:prepass];
            [e setDepthStencilState:prepassState];
            [e setRenderPipelineState:opaqueDEP];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e setRenderPipelineState:counterDEP];
            [e setVertexBuffer:counter offset:0 atIndex:1];
            [e drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:6];
            [e setRenderPipelineState:cutoutDEP];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];

            MTLRenderPassDescriptor *gbuffer = [MTLRenderPassDescriptor new];
            for (NSUInteger i = 0; i < 4; ++i) {
                gbuffer.colorAttachments[i].texture = colors[i];
                gbuffer.colorAttachments[i].loadAction = MTLLoadActionClear;
                gbuffer.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, 0);
                gbuffer.colorAttachments[i].storeAction = MTLStoreActionStore;
            }
            gbuffer.depthAttachment.texture = depth;
            gbuffer.depthAttachment.loadAction = MTLLoadActionLoad;
            gbuffer.depthAttachment.storeAction = MTLStoreActionStore;
            gbuffer.stencilAttachment.texture = depth;
            gbuffer.stencilAttachment.loadAction = MTLLoadActionLoad;
            e = [buffer renderCommandEncoderWithDescriptor:gbuffer];
            [e setDepthStencilState:gbufferState];
            // Slots 0-5 bound as one range, as BG3 does; only slot 3 differs
            // between the two draws.
            id<MTLTexture> first[6] = {filler, filler, filler, textureA, filler, filler};
            id<MTLTexture> second[6] = {filler, filler, filler, textureB, filler, filler};
            [e setFragmentTextures:first withRange:NSMakeRange(0, 6)];
            [e setRenderPipelineState:opaqueDEF];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e setFragmentTextures:second withRange:NSMakeRange(0, 6)];
            [e setRenderPipelineState:cutoutDEF];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            [buffer commit];
            [buffer waitUntilCompleted];
            if (buffer.error) { fprintf(stderr, "%s\n", buffer.error.description.UTF8String); return 6; }

            uint32_t prepassVertices = *(uint32_t *)counter.contents;
            uint32_t pixels[size * size];
            [colors[0] getBytes:pixels bytesPerRow:size * 4 fromRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0];
            for (NSUInteger y = 0; y < size; ++y)
                for (NSUInteger x = 0; x < size; ++x) {
                    uint32_t want = x < size / 2 ? colorA : colorB;
                    if (pixels[y * size + x] != want) {
                        fprintf(stderr, "frame %d pixel (%lu,%lu) = %08x, expected %08x\n", frame,
                                (unsigned long)x, (unsigned long)y, pixels[y * size + x], want);
                        return 7;
                    }
                }
            bool trimmed = prepassVertices == 0;
            if (frame == 1 && trimmed) { fprintf(stderr, "frame 1 skipped the prepass before learning its target\n"); return 8; }
            if (frame == 2 && trimmed != expectTrim) {
                fprintf(stderr, "frame 2 trimmable prepass vertices %u; expected %s\n", prepassVertices, expectTrim ? "none" : "some");
                return 9;
            }
        }
        printf("Prepass trim %s: cutout and opaque G-buffer pixels correct on both frames; texture slot change forwarded.\n",
               expectTrim ? "on" : "off");
        return 0;
    }
}
