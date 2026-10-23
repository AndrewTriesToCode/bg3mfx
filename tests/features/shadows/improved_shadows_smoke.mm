// Synthetic (offscreen) checks for the improved shadows shader:
// - every cascade count and filter (PCSS 1024/2048, PCF 1024) compiles;
// - on a flat ground plane under a checkerboard of blockers, pixels well
//   inside a blocker square are shadowed and pixels well inside an open square
//   are lit, for both filters, at a normal and a low render size; the sky
//   stays lit.
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <cmath>
#include <cstdio>
#include <vector>
#include "features/shadows/ImprovedShadowsShader.h"

static constexpr int MapSize = 1024, Square = 64, Margin = 12;

// Layouts of the shader's constant buffers.
struct PerFrame { float f0, f1, time, timeScale; };
struct PerCamera { simd_float4x4 m0, m1, m2; float nearDepth, depthScale; };
struct PerView { float light[3], pad0, v1[3], pad1, v2[3], pad2; simd_float4x4 viewToWorld; };
struct ShadowMaskParams { int materials, vista, vistaSlice; float vistaDistance; simd_float4x4 vistaMatrix, vistaDetailedMatrix; };
struct Object { simd_float4 a, b, c, d; };
struct Lighting {
    float f0, f1, f2, f3, softness, f5, edgeFade;
    simd_float4 depthRange, texelWorld;
    simd_float4x4 cascade[4];
    simd_float4 depthFade, constantBias, minimumRadius;
};
static_assert(sizeof(PerView) == 112 && offsetof(PerView, viewToWorld) == 48, "PerView layout");
static_assert(sizeof(ShadowMaskParams) == 144, "ShadowMaskParams layout");
static_assert(offsetof(Lighting, depthRange) == 32 && offsetof(Lighting, cascade) == 64 && sizeof(Lighting) == 368, "Lighting layout");

static const char *vertexSource = R"METAL(
#include <metal_stdlib>
using namespace metal;
struct Out { float4 position [[position]]; float3 frustumOffset; };
vertex Out TestVS(uint id [[vertex_id]], constant float3 &frustum [[buffer(0)]]) {
    float2 ndc = float2((id << 1) & 2, id & 2) * 2 - 1;
    return { float4(ndc, 0, 1), float3(ndc * frustum.xy, 1) * frustum.z };
}
)METAL";

static int failures;
static void check(bool ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) ++failures;
}

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@(BG3MFXImprovedShadowsSource) options:nil error:&error];
        check(library != nil, "shader library compiles");
        if (!library) { printf("%s\n", error.description.UTF8String); return 1; }
        auto function = [&](int cascades, float mapSize, bool pcss) {
            MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
            [values setConstantValue:&cascades type:MTLDataTypeInt atIndex:0];
            [values setConstantValue:&mapSize type:MTLDataTypeFloat atIndex:1];
            [values setConstantValue:&pcss type:MTLDataTypeBool atIndex:2];
            NSError *e = nil;
            id<MTLFunction> f = [library newFunctionWithName:@"BG3MFXImprovedShadows" constantValues:values error:&e];
            if (!f) printf("%d %g %d: %s\n", cascades, mapSize, pcss, e.description.UTF8String);
            return f;
        };
        bool all = true;
        for (int cascades = 1; cascades <= 4; ++cascades) {
            all &= function(cascades, 1024, true) != nil;
            all &= function(cascades, 2048, true) != nil;
            all &= function(cascades, 1024, false) != nil;
        }
        check(all, "all 12 variants specialize (PCSS 1024/2048, PCF 1024)");

        auto texture = [&](MTLPixelFormat format, int width, int height, const void *bytes, NSUInteger row, MTLTextureUsage usage) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
            d.usage = usage; d.storageMode = MTLStorageModeShared;
            id<MTLTexture> t = [device newTextureWithDescriptor:d];
            if (bytes) [t replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:bytes bytesPerRow:row];
            return t;
        };
        std::vector<uint8_t> noiseBytes(64 * 64);
        for (int i = 0; i < 64 * 64; ++i) noiseBytes[i] = uint8_t((i * 7919u) % 251);
        id<MTLTexture> noise = texture(MTLPixelFormatR8Unorm, 64, 64, noiseBytes.data(), 64, MTLTextureUsageShaderRead);

        // Shadow map: blockers (0.9) on a checkerboard of Square-texel squares over empty (0).
        MTLTextureDescriptor *shadowDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:MapSize height:MapSize mipmapped:NO];
        shadowDesc.textureType = MTLTextureType2DArray; shadowDesc.arrayLength = 1;
        shadowDesc.usage = MTLTextureUsageShaderRead; shadowDesc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> shadow = [device newTextureWithDescriptor:shadowDesc];
        std::vector<float> map(MapSize * MapSize);
        for (int y = 0; y < MapSize; ++y) for (int x = 0; x < MapSize; ++x) map[y * MapSize + x] = ((x / Square + y / Square) & 1) ? 0.9f : 0;
        id<MTLBuffer> mapBuffer = [device newBufferWithBytes:map.data() length:map.size() * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        {
            id<MTLCommandBuffer> upload = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [upload blitCommandEncoder];
            [blit copyFromBuffer:mapBuffer sourceOffset:0 sourceBytesPerRow:MapSize * 4 sourceBytesPerImage:MapSize * MapSize * 4
                      sourceSize:MTLSizeMake(MapSize, MapSize, 1) toTexture:shadow destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding]; [upload commit]; [upload waitUntilCompleted];
        }
        MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
        id<MTLSamplerState> pointSampler = [device newSamplerStateWithDescriptor:samplerDesc];
        samplerDesc.minFilter = samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.compareFunction = MTLCompareFunctionGreaterEqual;
        id<MTLSamplerState> shadowSampler = [device newSamplerStateWithDescriptor:samplerDesc];

        // Camera at the origin looking along +z (view space = world space),
        // ground plane y = -1, sun straight overhead.
        const float tanHalf = 0.7f, far = 100;
        PerFrame frame = {0, 0, 0, 0};
        PerCamera camera = {}; camera.nearDepth = 1; camera.depthScale = far;
        PerView view = {}; view.light[1] = 1; view.viewToWorld = matrix_identity_float4x4;
        ShadowMaskParams params = {};
        Object object = {};
        Lighting lighting = {};
        lighting.softness = 0.1f; lighting.edgeFade = 20;
        lighting.depthRange = simd_make_float4(10, 10, 10, 10);
        lighting.texelWorld = simd_make_float4(8.0f / MapSize, 0, 0, 0);
        // Shadow-map u from world x, v from depth, z from height.
        lighting.cascade[0] = simd_matrix(simd_make_float4(1.0f / 8, 0, 0, 0), simd_make_float4(0, 0, 0.01f, 0),
            simd_make_float4(0, 1.0f / 16, 0, 0), simd_make_float4(0.5f, 0, 0.51f, 1));
        lighting.depthFade = simd_make_float4(100, 100, 100, 100);
        lighting.constantBias = simd_make_float4(0.01f, 0.01f, 0.01f, 0.01f);
        lighting.minimumRadius = simd_make_float4(0.0005f, 0.0005f, 0.0005f, 0.0005f);
        simd_float3 frustum = simd_make_float3(tanHalf, tanHalf, far);

        id<MTLLibrary> vertexLibrary = [device newLibraryWithSource:@(vertexSource) options:nil error:&error];
        id<MTLFunction> vertex = [vertexLibrary newFunctionWithName:@"TestVS"];
        // Renders the plane at size x size and checks each pixel against the checkerboard.
        auto run = [&](int size, bool pcss) {
            std::vector<float> depth(size * size);
            for (int y = 0; y < size; ++y) for (int x = 0; x < size; ++x) {
                float ny = 1 - (y + 0.5f) / size * 2;
                depth[y * size + x] = ny < 0 ? -1 / (ny * tanHalf * far) : 1;
            }
            id<MTLTexture> linearDepth = texture(MTLPixelFormatR32Float, size, size, depth.data(), size * 4, MTLTextureUsageShaderRead);
            // BG3's stereographic encoding of the view-space up normal.
            std::vector<float> normals(size * size * 2);
            for (int i = 0; i < size * size; ++i) { normals[i * 2] = 1.7777778f / 3.5555556f; normals[i * 2 + 1] = 2.7777778f / 3.5555556f; }
            id<MTLTexture> gbuffer0 = texture(MTLPixelFormatRG32Float, size, size, normals.data(), size * 8, MTLTextureUsageShaderRead);
            std::vector<uint32_t> zeros(size * size);
            id<MTLTexture> gbuffer2 = texture(MTLPixelFormatRGBA8Unorm, size, size, zeros.data(), size * 4, MTLTextureUsageShaderRead);
            id<MTLTexture> gbuffer3 = texture(MTLPixelFormatRGBA8Unorm, size, size, zeros.data(), size * 4, MTLTextureUsageShaderRead);
            id<MTLTexture> target = texture(MTLPixelFormatR32Float, size, size, nullptr, 0, MTLTextureUsageRenderTarget);

            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = vertex; d.fragmentFunction = function(1, MapSize, pcss);
            d.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
            id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:d error:&error];
            if (!state) { printf("pipeline: %s\n", error.description.UTF8String); return false; }
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
            [encoder setRenderPipelineState:state];
            [encoder setVertexBytes:&frustum length:sizeof frustum atIndex:0];
            [encoder setFragmentTexture:linearDepth atIndex:0];
            [encoder setFragmentTexture:gbuffer2 atIndex:1];
            [encoder setFragmentTexture:noise atIndex:4];
            [encoder setFragmentTexture:gbuffer3 atIndex:5];
            [encoder setFragmentTexture:shadow atIndex:36];
            [encoder setFragmentTexture:gbuffer0 atIndex:40];
            [encoder setFragmentSamplerState:pointSampler atIndex:0];
            [encoder setFragmentSamplerState:shadowSampler atIndex:9];
            [encoder setFragmentBytes:&params length:sizeof params atIndex:0];
            [encoder setFragmentBytes:&lighting length:sizeof lighting atIndex:7];
            [encoder setFragmentBytes:&camera length:sizeof camera atIndex:11];
            [encoder setFragmentBytes:&view length:sizeof view atIndex:12];
            [encoder setFragmentBytes:&frame length:sizeof frame atIndex:13];
            [encoder setFragmentBytes:&object length:sizeof object atIndex:14];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [encoder endEncoding]; [commands commit]; [commands waitUntilCompleted];
            std::vector<float> out(size * size);
            [target getBytes:out.data() bytesPerRow:size * 4 fromRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0];

            int shadowed = 0, lit = 0, wrong = 0, skyWrong = 0;
            for (int y = 0; y < size; ++y) for (int x = 0; x < size; ++x) {
                float value = out[y * size + x], z = depth[y * size + x];
                if (z == 1) { skyWrong += value != 1; continue; }
                float nx = (x + 0.5f) / size * 2 - 1, ny = 1 - (y + 0.5f) / size * 2;
                simd_float3 p = simd_make_float3(nx * tanHalf, ny * tanHalf, 1) * (far * z);
                float u = (p.x / 8 + 0.5f) * MapSize, v = p.z / 16 * MapSize;
                if (u < Margin || v < Margin || u > MapSize - Margin || v > MapSize - Margin) continue;
                float du = std::fmod(u, float(Square)), dv = std::fmod(v, float(Square));
                if (std::min(du, Square - du) < Margin || std::min(dv, Square - dv) < Margin) continue;
                bool blocked = ((int(u) / Square + int(v) / Square) & 1) != 0;
                if (blocked) { shadowed += value < 0.1f; wrong += value >= 0.1f; }
                else { lit += value > 0.9f; wrong += value <= 0.9f; }
            }
            printf("%s %dx%d: %d shadowed, %d lit, %d wrong, %d sky wrong\n", pcss ? "PCSS" : "PCF", size, size, shadowed, lit, wrong, skyWrong);
            return shadowed > 0 && lit > 0 && wrong == 0 && skyWrong == 0;
        };
        check(run(64, true), "PCSS matches the checkerboard at 64x64");
        check(run(16, true), "PCSS matches the checkerboard at 16x16");
        check(run(64, false), "PCF matches the checkerboard at 64x64");
        check(run(16, false), "PCF matches the checkerboard at 16x16");
    }
    printf(failures ? "FAILED\n" : "PASSED\n");
    return failures ? 1 : 0;
}
