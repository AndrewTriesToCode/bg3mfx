#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

// CPU cost of the renderer hooks on BG3's hottest encoder calls, shaped like
// its G-buffer pass: per draw, rebind 8 fragment textures (two of them
// changed) and a pipeline, then draw. Encoding time only; the GPU work is
// trivial. Synthetic and offscreen: compare runtimes on one machine, never
// against frame times.
// usage: hook-overhead [RUNTIME.dylib [scaling-mode]] (no runtime: Metal alone)
// Features come from the environment (BG3MFX_FEATURE_*); BG3MFX_ENABLE is set.
// scaling-mode needs the standalone test runtime (libBG3MetalFXTest.dylib).
int main(int argc, char **argv) {
    @autoreleasepool {
        setenv("BG3MFX_ENABLE", "1", 1);
        void *runtime = nullptr;
        if (argc > 1 && !(runtime = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL))) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        if (argc > 2) {
            auto select = runtime ? (BOOL (*)(int))dlsym(runtime, "BG3MFXSetStandaloneScalingMode") : nullptr;
            if (!select || !select(atoi(argv[2]))) { fprintf(stderr, "Scaling modes need the standalone test runtime.\n"); return 2; }
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 3;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 HookOverhead_vertexMain(uint id [[vertex_id]]) { return float4(0,0,0,1); }\n"
            "fragment float4 HookOverhead_fragmentMain(texture2d<float> t0 [[texture(0)]]) { return t0.read(uint2(0,0)); }\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr, "%s\n", error.description.UTF8String); return 4; }
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"HookOverhead_vertexMain"];
        desc.fragmentFunction = [library newFunctionWithName:@"HookOverhead_fragmentMain"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pipelines[2] = {
            [device newRenderPipelineStateWithDescriptor:desc error:&error],
            [device newRenderPipelineStateWithDescriptor:desc error:&error]};
        if (!pipelines[0] || !pipelines[1]) return 5;
        MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                width:16 height:16 mipmapped:NO];
        textureDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        textureDesc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> textures[16];
        for (auto &t : textures) t = [device newTextureWithDescriptor:textureDesc];
        id<MTLTexture> target = [device newTextureWithDescriptor:textureDesc];
        id<MTLCommandQueue> queue = [device newCommandQueue];

        constexpr int draws = 20000, trials = 9;
        std::vector<double> perDraw;
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        for (int trial = 0; trial <= trials; ++trial) @autoreleasepool {
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            uint64_t start = mach_absolute_time();
            id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
            for (int i = 0; i < draws; ++i) {
                id<MTLTexture> bound[8];
                for (int s = 0; s < 8; ++s) bound[s] = textures[s];
                bound[2] = textures[8 + (i & 7)];
                bound[5] = textures[8 + ((i >> 1) & 7)];
                [encoder setRenderPipelineState:pipelines[(i >> 4) & 1]];
                [encoder setFragmentTextures:bound withRange:NSMakeRange(0, 8)];
                [encoder setFragmentTexture:textures[i & 15] atIndex:9];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
            [encoder endEncoding];
            uint64_t end = mach_absolute_time();
            [buffer commit];
            [buffer waitUntilCompleted];
            // The first trial warms caches and the hooks' per-class setup.
            if (trial) perDraw.push_back(double(end - start) * timebase.numer / timebase.denom / draws);
        }
        std::sort(perDraw.begin(), perDraw.end());
        printf("%s%s%s: median %.1f ns per draw (min %.1f, max %.1f; %d draws x %d trials)\n",
               argc > 1 ? argv[1] : "Metal alone", argc > 2 ? ", scaling mode " : "", argc > 2 ? argv[2] : "",
               perDraw[perDraw.size() / 2], perDraw.front(), perDraw.back(), draws, trials);
    }
    return 0;
}
