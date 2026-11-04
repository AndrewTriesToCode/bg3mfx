#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Renderer-hook regression for the new-character crash fix: a compute pass
// named like BG3's ClusterAssignment reads ClusterInfoBuffer (compute index 6)
// that the test never binds, as BG3 does entering character creation. With the
// fix, the read hits the zero-filled stand-in, so the pass writes 7.
// Synthetic and offscreen. The unguarded case is not run: it faults the GPU.
// usage: new-character-crash-fix-smoke RUNTIME.dylib
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) return 1;
        setenv("BG3MFX_ENABLE", "1", 1);
        setenv("BG3MFX_FEATURE_NEW_CHARACTER_CRASH_FIX", "1", 1);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 3;
        if (!dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)) { fprintf(stderr, "%s\n", dlerror()); return 4; }
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void ClusterAssignment(device uint *out [[buffer(0)]], device const uint *info [[buffer(6)]])"
            " { out[0] = info[0] + 7; }\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr, "%s\n", error.description.UTF8String); return 5; }
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"ClusterAssignment"] error:&error];
        if (!pipeline) { fprintf(stderr, "%s\n", error.description.UTF8String); return 6; }
        id<MTLBuffer> out = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        memset(out.contents, 0xff, 16);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:out offset:0 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [encoder endEncoding];
        [buffer commit];
        [buffer waitUntilCompleted];
        if (buffer.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "Command buffer failed.\n"); return 7; }
        uint32_t value = *static_cast<uint32_t *>(out.contents);
        if (value != 7) { fprintf(stderr, "ClusterAssignment read %u, not the stand-in's 0 (+7).\n", value - 7); return 8; }
        printf("New-character crash fix: an unbound ClusterAssignment read the zero stand-in (synthetic, offscreen).\n");
    }
    return 0;
}
