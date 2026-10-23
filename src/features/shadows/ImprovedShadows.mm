#import "features/shadows/ImprovedShadows.h"
#include "features/shadows/ImprovedShadowsShader.h"
#import <objc/runtime.h>
#include <os/log.h>
#include <atomic>
#include <cstdio>
#include <cstring>

static os_log_t shadowLog() {
    static os_log_t log = os_log_create("com.bg3mfx", "shadow");
    return log;
}

bool BG3MFXImprovedShadowsEnabled(void) {
    static bool enabled = [] {
        const char *value = getenv("BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS");
        return !(value && strcmp(value, "0") == 0);
    }();
    return enabled;
}

static char replacementKey, gbufferNormalKey;

bool BG3MFXPrepareImprovedShadows(id device, MTLRenderPipelineDescriptor *desc, id state, BG3MFXCreateRenderPipeline create) {
    NSString *name = desc.fragmentFunction.name;
    if (!state || ![name hasPrefix:@"DirLight_Cascaded_"]) return false;
    int cascades = 0, size = 0;
    bool pcss = [name hasPrefix:@"DirLight_Cascaded_PCSS_"];
    if (!(pcss || [name hasPrefix:@"DirLight_Cascaded_PCF_"])) return false;
    if (sscanf(name.UTF8String, pcss ? "DirLight_Cascaded_PCSS_%dx%d" : "DirLight_Cascaded_PCF_%dx%d", &cascades, &size) != 2 ||
        cascades < 1 || cascades > 4 || (size != 1024 && size != 2048)) {
        os_log(shadowLog(), "improved shadows: unknown variant %{public}@", name);
        return false;
    }
    static id<MTLLibrary> library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *error = nil;
        library = [device newLibraryWithSource:@(BG3MFXImprovedShadowsSource) options:nil error:&error];
        if (!library) os_log(shadowLog(), "improved shadows: library failed: %{public}@", error.description);
    });
    if (!library) return false;
    MTLFunctionConstantValues *values = [MTLFunctionConstantValues new];
    float mapSize = float(size);
    [values setConstantValue:&cascades type:MTLDataTypeInt atIndex:0];
    [values setConstantValue:&mapSize type:MTLDataTypeFloat atIndex:1];
    [values setConstantValue:&pcss type:MTLDataTypeBool atIndex:2];
    NSError *error = nil;
    id<MTLFunction> fragment = [library newFunctionWithName:@"BG3MFXImprovedShadows" constantValues:values error:&error];
    id pipeline = nil;
    if (fragment) {
        MTLRenderPipelineDescriptor *copy = [desc copy];
        copy.fragmentFunction = fragment;
        static SEL selector = @selector(newRenderPipelineStateWithDescriptor:error:);
        pipeline = (__bridge_transfer id)create(device, selector, copy, &error);
    }
    os_log(shadowLog(), "improved shadows: %{public}@ %{public}s %{public}@", name,
        pipeline ? "ready" : "failed", error ? error.description : @"");
    if (!pipeline) return false;
    objc_setAssociatedObject(state, &replacementKey, pipeline, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return true;
}

// BG3's G-buffer pass writes the view-space normal (RG16Float) to color 0 and
// the material bits the shadow mask reads to color 2. Remember color 0 on
// color 2's texture, so the shadow draw finds it from its own binding.
void BG3MFXNoteImprovedShadowsPass(MTLRenderPassDescriptor *desc) {
    id<MTLTexture> normal = desc.colorAttachments[0].texture, material = desc.colorAttachments[2].texture;
    if (!normal || !material || !desc.colorAttachments[3].texture || normal.pixelFormat != MTLPixelFormatRG16Float ||
        normal.width != material.width || normal.height != material.height) return;
    if (objc_getAssociatedObject(material, &gbufferNormalKey) != normal)
        objc_setAssociatedObject(material, &gbufferNormalKey, normal, OBJC_ASSOCIATION_RETAIN);
}

static void reportFallback(const char *reason) {
    static std::atomic<int> reported{0};
    if (reported.fetch_add(1) < 8) os_log(shadowLog(), "improved shadows: BG3's draw kept (%{public}s)", reason);
}

bool BG3MFXImprovedShadowsDraw(__unsafe_unretained id encoder, __unsafe_unretained id state,
    __unsafe_unretained id<MTLTexture> linearDepth, __unsafe_unretained id<MTLTexture> gbuffer2,
    const BG3MFXImprovedShadowsCalls &calls, void (^draw)(void)) {
    __unsafe_unretained id pipeline = objc_getAssociatedObject(state, &replacementKey);
    if (!pipeline) return false;
    __unsafe_unretained id<MTLTexture> normal = gbuffer2 ? objc_getAssociatedObject(gbuffer2, &gbufferNormalKey) : nil;
    if (!normal || !linearDepth) { reportFallback("no G-buffer normal"); return false; }
    if (normal.width != linearDepth.width || normal.height != linearDepth.height) { reportFallback("size mismatch"); return false; }
    calls.setPipeline(encoder, pipeline);
    calls.setFragmentTexture(encoder, normal, 40);
    draw();
    calls.setPipeline(encoder, state);
    return true;
}
