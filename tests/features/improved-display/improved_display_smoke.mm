// Synthetic: bg3mfx's CombineUI_HDR and CombineUINo_UI_HDR replacements,
// drawn into RGBA16Float from a PQ scene and an sRGB UI, against the expected
// extended-linear BT.2020 values (1.0 = SDR white, 100 nits), and the sRGB
// variant's gamut compression of a P3 primary.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "features/improved-display/ImprovedDisplayShader.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

static int failures;
static void check(bool ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); ++failures; }
}
static float pq(float nits) {
    const float y = powf(nits / 10000.0f, 0.1593017578125f);
    return powf((0.8359375f + 18.8515625f * y) / (1.0f + 18.6875f * y), 78.84375f);
}
static float srgbToLinear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "SKIP: no Metal device\n"); return 0; }
        // BG3's DefaultVS: a full-screen triangle with texCoord.
        const std::string source = std::string(BG3MFXImprovedDisplaySource) +
            "vertex In DefaultVS(uint i [[vertex_id]]) { float2 u = float2((i << 1) & 2, i & 2);"
            " In o; o.position = float4(u * float2(2, -2) + float2(-1, 1), 0, 1); o.texCoord = u; return o; }\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@(source.c_str()) options:nil error:&error];
        check(library != nil, "the shader source compiles");
        if (!library) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }

        // Five columns of scene and UI: no UI, opaque UI, half-covered, a
        // 1000-nit scene highlight with no UI, and P3's green primary at
        // 100 nits (BT.2020 coordinates) with no UI.
        const int w = 5, h = 1;
        const float sceneNits[w][3] = {{100, 100, 100}, {100, 100, 100}, {400, 400, 400}, {1000, 1000, 1000},
                                       {19.8597f, 94.1777f, 1.7602f}};
        uint32_t scene[w];
        for (int x = 0; x < w; ++x) {
            uint32_t v[3];
            for (int c = 0; c < 3; ++c) v[c] = (uint32_t)lrintf(pq(sceneNits[x][c]) * 1023.0f);
            scene[x] = v[0] | (v[1] << 10) | (v[2] << 20) | (3u << 30);
        }
        const uint8_t ui[w * 4] = {0, 0, 0, 0, 255, 255, 255, 255, 64, 64, 64, 128, 0, 0, 0, 0, 0, 0, 0, 0};
        auto texture = [&](MTLPixelFormat format, const void *bytes, NSUInteger row) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
            id<MTLTexture> t = [device newTextureWithDescriptor:d];
            [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:bytes bytesPerRow:row];
            return t;
        };
        id<MTLTexture> sceneTexture = texture(MTLPixelFormatRGB10A2Unorm, scene, w * 4);
        id<MTLTexture> uiTexture = texture(MTLPixelFormatRGBA8Unorm, ui, w * 4);
        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
        od.usage = MTLTextureUsageRenderTarget;
        od.storageMode = MTLStorageModeShared;
        id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
        // UIPaperWhite, SDRGamma, HDRGamma, HDRPaperWhite as BG3 set them in a capture.
        const float combine[4] = {300.0f, 1.0f, 1.0f, 100.0f};
        id<MTLCommandQueue> queue = [device newCommandQueue];

        auto draw = [&](NSString *fragment, bool srgb, float out[w][4]) {
            MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
            [constants setConstantValue:&srgb type:MTLDataTypeBool atIndex:0];
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [library newFunctionWithName:@"DefaultVS"];
            pd.fragmentFunction = [library newFunctionWithName:fragment constantValues:constants error:nil];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
            MTLRenderPipelineReflection *reflection = nil;
            NSError *pipelineError = nil;
            id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd
                options:MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo reflection:&reflection error:&pipelineError];
            check(pipeline != nil, "the composition pipeline builds");
            if (!pipeline) return;
            // Frame Generation replays the composition with constants of the
            // size the shader declares at fragment buffer 0.
            bool sized = false;
            for (id<MTLBinding> binding in reflection.fragmentBindings)
                if (binding.type == MTLBindingTypeBuffer && binding.index == 0)
                    sized = ((id<MTLBufferBinding>)binding).bufferDataSize == 16;
            check(sized, "fragment buffer 0 declares BG3's 16-byte constants");
            id<MTLTexture> target = [device newTextureWithDescriptor:od];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
            [encoder setRenderPipelineState:pipeline];
            [encoder setFragmentTexture:sceneTexture atIndex:0];
            [encoder setFragmentTexture:uiTexture atIndex:1];
            [encoder setFragmentSamplerState:sampler atIndex:0];
            [encoder setFragmentBytes:combine length:sizeof combine atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding];
            [buffer commit];
            [buffer waitUntilCompleted];
            __fp16 half[w * 4];
            [target getBytes:half bytesPerRow:w * 8 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
            for (int i = 0; i < w * 4; ++i) out[i / 4][i % 4] = (float)half[i];
        };
        auto near = [](float a, float b) { return fabsf(a - b) <= 0.02f * fmaxf(1.0f, fabsf(b)); };

        float out[w][4] = {};
        draw(@"CombineUI_HDR", false, out);
        check(near(out[0][0], 1.0f) && near(out[0][1], 1.0f) && near(out[0][2], 1.0f), "no UI: a 100-nit scene is SDR white");
        check(near(out[1][0], 1.0f) && near(out[1][1], 1.0f) && near(out[1][2], 1.0f), "opaque white UI is SDR white");
        const float keep = 1.0f - 128.0f / 255.0f, uiGrey = srgbToLinear(64.0f / 255.0f);
        check(near(out[2][1], 4.0f * keep * keep + uiGrey), "half-covered: BG3's blend, in linear");
        check(near(out[3][0], 10.0f), "a 1000-nit highlight is 10x SDR white");
        for (int x = 0; x < w; ++x) check(out[x][3] == 1.0f, "opaque output");

        float noUI[w][4] = {};
        draw(@"CombineUINo_UI_HDR", false, noUI);
        check(near(noUI[2][0], 4.0f) && near(noUI[3][2], 10.0f), "no-UI variant passes the scene through");

        // BT.2020 to BT.709 (linear): a value inside sRGB has no channel below 0.
        auto red709 = [](const float c[4]) { return 1.660491f * c[0] - 0.587641f * c[1] - 0.072850f * c[2]; };
        check(red709(out[4]) < -0.1f, "without compression P3 green is outside sRGB");
        float srgb[w][4] = {};
        draw(@"CombineUI_HDR", true, srgb);
        check(red709(srgb[4]) > -0.005f, "the sRGB variant brings P3 green inside sRGB");
        check(srgb[4][1] > 0.8f, "and keeps it bright and green");
        check(near(srgb[0][0], 1.0f) && near(srgb[0][2], 1.0f) && near(srgb[3][1], 10.0f), "and leaves neutral colors alone");
        float srgbNoUI[w][4] = {};
        draw(@"CombineUINo_UI_HDR", true, srgbNoUI);
        check(red709(srgbNoUI[4]) > -0.005f, "the no-UI sRGB variant compresses too");
    }
    if (failures) return 1;
    printf("improved-display smoke: ok\n");
    return 0;
}
