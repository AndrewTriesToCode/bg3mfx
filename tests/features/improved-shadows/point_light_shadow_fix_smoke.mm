// Synthetic, offscreen: the point-light shadow fix's face layout and
// compositing LinearizeDepth on the system device, with the four tetrahedron
// face projections and viewports BG3 4.1.1 uses (a 7.5 m torch, 1024² tile).
#import "features/improved-shadows/PointLightShadowFix.mm"
#include <cmath>
#include <cstdio>
#include <vector>

// BG3-style pipelines: a depth-only caster that covers its viewport at a
// depth naming the face (without the clip distances, as BG3's), and the atlas
// LinearizeDepth (written from BG3's AIR).
static const char *const bg3Source = R"METAL(
#include <metal_stdlib>
using namespace metal;
vertex float4 CasterVS(uint id [[vertex_id]], constant float &depth [[buffer(0)]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * 2.0f - 1.0f, depth, 1.0f);
}
struct Lineralization { float2 constants; float2 viewportOffset; uint isOrtho; float pad; };
vertex float4 PassPosVS(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
}
fragment float LinearizeDepth(float4 position [[position]], texture2d<float> sceneDepth [[texture(0)]],
                              constant Lineralization &l [[buffer(0)]]) {
    float depth = sceneDepth.read(uint2(position.xy - l.viewportOffset)).x;
    if (depth == 0.0f) return 1.0f;
    return l.isOrtho != 0 ? (depth - l.constants.y) / l.constants.x : l.constants.y / (depth - l.constants.x);
}
)METAL";

void BG3MFXFail(NSString *message, NSString *, NSString *) { fprintf(stderr, "failure: %s\n", message.UTF8String); }
BOOL BG3MFXMetalHooksReplaceDraws(BG3MFXDrawReplacement) { return YES; }
BOOL BG3MFXMetalHooksOnRenderPass(void (*)(MTLRenderPassDescriptor *)) { return YES; }

static void *create(id device, SEL, MTLRenderPipelineDescriptor *desc, NSError **error) {
    return (__bridge_retained void *)[device newRenderPipelineStateWithDescriptor:desc error:error];
}
static int failures;
static void check(bool ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); ++failures; }
}

// offsetViewProjection of faces 0-3, column-major, and BG3's face viewports
// for a tile at the target's origin.
static const float faces[4][16] = {
    {0.2946f, 0, 0, 0,  0, 0.4166f, 0.0006f, -0.4597f,  0, 0.2157f, -0.0012f, 0.8881f,  0, 0, 0.01f, 0},
    {0, -0.2946f, 0, 0,  -0.4166f, 0, 0.0006f, -0.4597f,  0.2157f, 0, 0.0012f, -0.8881f,  0, 0, 0.01f, 0},
    {0, 0.2157f, 0.0012f, -0.8881f,  0, 0.4166f, -0.0006f, 0.4597f,  0.2946f, 0, 0, 0,  0, 0, 0.01f, 0},
    {0.2157f, 0, -0.0012f, 0.8881f,  -0.4166f, 0, -0.0006f, 0.4597f,  0, -0.2946f, 0, 0,  0, 0, 0.01f, 0},
};
static const float normals[4][3] = {{0, -0.57735f, 0.81650f}, {0, -0.57735f, -0.81650f}, {-0.81650f, 0.57735f, 0}, {0.81650f, 0.57735f, 0}};
static const NSUInteger tileSize = 256;
static MTLViewport faceViewport(int face) {
    const double s = tileSize, h = s / 2;
    const MTLViewport viewports[4] = {{0, h, s, h, 0, 1}, {h, 0, h, s, 0, 1}, {0, 0, s, h, 0, 1}, {0, 0, h, s, 0, 1}};
    return viewports[face];
}

// Draws the four faces (moved, or as BG3 does) and copies the tile into an
// R16Unorm atlas tile; returns each atlas texel as the face whose depth it
// holds, -1 for none.
// The depth target is `targetSize` square (twice the tile, or the tile alone
// as BG3 uses for a close light).
static std::vector<int> render(id<MTLDevice> device, id<MTLRenderPipelineState> caster, id<MTLRenderPipelineState> atlas, bool moved,
                               NSUInteger targetSize) {
    MTLDepthStencilDescriptor *always = [MTLDepthStencilDescriptor new];
    always.depthCompareFunction = MTLCompareFunctionGreater;  // reversed Z, as BG3's shadow passes
    always.depthWriteEnabled = YES;
    id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:always];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                  width:targetSize height:targetSize mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [device newTextureWithDescriptor:td];
    MTLTextureDescriptor *ad = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Unorm
                                                                                  width:tileSize height:tileSize mipmapped:NO];
    ad.usage = MTLTextureUsageRenderTarget;
    ad.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:ad];
    id<MTLBuffer> readback = [device newBufferWithLength:tileSize * tileSize * 2 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 0.0;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:caster];
    [encoder setDepthStencilState:depthState];
    BG3MFXShadowTile tile = {};
    for (int face = 0; face < 4; ++face) {
        MTLViewport viewport = faceViewport(face);
        check(BG3MFXShadowFaceTile(face, viewport, targetSize, targetSize, &tile) && tile.x == 0 && tile.y == 0 &&
              tile.size == tileSize && tile.region == (targetSize >= 2 * tileSize ? tileSize : targetSize / 2),
              "BG3's face viewport gives the light's tile, and a region that fits");
        [encoder setViewport:moved ? BG3MFXShadowFaceViewport(face, viewport, tile) : viewport];
        // Every face covers its whole viewport in front of the others; only
        // the face that owns a texel may be left there.
        float faceDepth = 0.2f * (face + 1);
        [encoder setVertexBytes:&faceDepth length:sizeof faceDepth atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [encoder endEncoding];

    MTLRenderPassDescriptor *copy = [MTLRenderPassDescriptor new];
    copy.colorAttachments[0].texture = target;
    copy.colorAttachments[0].loadAction = MTLLoadActionClear;
    copy.colorAttachments[0].storeAction = MTLStoreActionStore;
    encoder = [buffer renderCommandEncoderWithDescriptor:copy];
    [encoder setRenderPipelineState:atlas];
    [encoder setFragmentTexture:depth atIndex:0];
    // Orthographic constants, so the atlas holds 1 - depth.
    struct { float constants[2], viewportOffset[2]; uint32_t isOrtho; float pad; } l = {{-1.0f, 1.0f}, {0, 0}, 1, 0};
    [encoder setFragmentBytes:&l length:sizeof l atIndex:0];
    [encoder setFragmentBytes:&tile length:sizeof tile atIndex:BG3MFXShadowTileIndex];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(tileSize, tileSize, 1)
                 toBuffer:readback destinationOffset:0 destinationBytesPerRow:tileSize * 2 destinationBytesPerImage:tileSize * tileSize * 2];
    [blit endEncoding];
    [buffer commit];
    [buffer waitUntilCompleted];
    std::vector<int> owners(tileSize * tileSize);
    const uint16_t *texels = static_cast<const uint16_t *>(readback.contents);
    for (NSUInteger i = 0; i < owners.size(); ++i) {
        float d = 1.0f - texels[i] / 65535.0f;
        int face = (int)lroundf(d / 0.2f) - 1;
        owners[i] = face >= 0 && face < 4 && std::fabs(d - 0.2f * (face + 1)) < 1e-3f ? face : -1;
    }
    return owners;
}

// ClusteredLighting looks a direction up in the face whose normal is closest,
// at that face's projection into its viewport: the fraction of lookups whose
// texel holds another face's depth.
static double wrongLookups(const std::vector<int> &owners) {
    int lookups = 0, wrong = 0;
    for (int i = 0; i < 64; ++i)
        for (int j = 0; j < 128; ++j) {
            float theta = (float)M_PI * (i + 0.5f) / 64, phi = 2.0f * (float)M_PI * (j + 0.5f) / 128;
            float d[3] = {sinf(theta) * cosf(phi), cosf(theta), sinf(theta) * sinf(phi)};
            int face = 0;
            float best = -2.0f;
            for (int f = 0; f < 4; ++f) {
                float dot = normals[f][0] * d[0] + normals[f][1] * d[1] + normals[f][2] * d[2];
                if (dot > best) { best = dot; face = f; }
            }
            const float *m = faces[face];
            MTLViewport rect = faceViewport(face);
            float cx = m[0] * d[0] + m[4] * d[1] + m[8] * d[2], cy = m[1] * d[0] + m[5] * d[1] + m[9] * d[2];
            float cw = m[3] * d[0] + m[7] * d[1] + m[11] * d[2];
            float x = rect.originX + (cx / cw * 0.5f + 0.5f) * rect.width, y = rect.originY + (0.5f - cy / cw * 0.5f) * rect.height;
            ++lookups;
            if (BG3MFXShadowTileFace(x, y, tileSize) != face) ++wrong;  // the diagonals match the lighting
            if (owners[(NSUInteger)y * tileSize + (NSUInteger)x] != face) ++wrong;
        }
    return (double)wrong / lookups;
}

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "SKIP: no Metal device\n"); return 0; }
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@(bg3Source) options:nil error:&error];
        if (!library) { fprintf(stderr, "FAIL: %s\n", error.localizedDescription.UTF8String); return 1; }

        MTLRenderPipelineDescriptor *casterDesc = [MTLRenderPipelineDescriptor new];
        casterDesc.vertexFunction = [library newFunctionWithName:@"CasterVS"];
        casterDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        check(BG3MFXShadowCasterPipeline(casterDesc), "a depth-only caster is claimed");
        casterDesc.fragmentFunction = [library newFunctionWithName:@"LinearizeDepth"];
        check(BG3MFXShadowCasterPipeline(casterDesc), "a caster with a fragment function (alpha test) is claimed");
        casterDesc.fragmentFunction = nil;
        casterDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        casterDesc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        check(!BG3MFXShadowCasterPipeline(casterDesc), "a main-view depth pipeline is left alone");
        casterDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        casterDesc.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
        id<MTLRenderPipelineState> caster = [device newRenderPipelineStateWithDescriptor:casterDesc error:&error];

        MTLRenderPipelineDescriptor *atlasDesc = [MTLRenderPipelineDescriptor new];
        atlasDesc.vertexFunction = [library newFunctionWithName:@"PassPosVS"];
        atlasDesc.fragmentFunction = [library newFunctionWithName:@"LinearizeDepth"];
        atlasDesc.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        check(!BG3MFXShadowAtlasPipeline(atlasDesc) && !BG3MFXShadowCasterPipeline(atlasDesc), "the main-depth LinearizeDepth is left alone");
        atlasDesc.colorAttachments[0].pixelFormat = MTLPixelFormatR16Unorm;
        check(BG3MFXShadowAtlasPipeline(atlasDesc) && !BG3MFXShadowCasterPipeline(atlasDesc), "the atlas LinearizeDepth is claimed");
        id<MTLRenderPipelineState> bg3Atlas = [device newRenderPipelineStateWithDescriptor:atlasDesc error:&error];
        id<MTLRenderPipelineState> clone = BG3MFXPointLightShadowPipeline(device, atlasDesc, create, &error);
        if (!caster || !bg3Atlas || !clone) { fprintf(stderr, "FAIL: %s\n", error.localizedDescription.UTF8String); return 1; }

        BG3MFXShadowTile tile;
        check(!BG3MFXShadowFaceTile(-1, faceViewport(0), 2048, 2048, &tile), "a spot or orthographic view (face -1) is left alone");
        check(!BG3MFXShadowFaceTile(0, (MTLViewport){0, 0, 256, 256, 0, 1}, 2048, 2048, &tile), "a square viewport is not a face");
        check(BG3MFXShadowFaceTile(1, (MTLViewport){640, 512, 128, 256, 0, 1}, 2048, 2048, &tile) && tile.x == 512 &&
              tile.y == 512 && tile.size == 256 && tile.region == 256, "face 1's viewport is the tile's right half");
        check(BG3MFXShadowFaceTile(1, (MTLViewport){1024, 0, 1024, 2048, 0, 1}, 2048, 2048, &tile) && tile.size == 2048 &&
              tile.region == 1024, "a tile that fills the target gets half-resolution regions");
        check(!BG3MFXShadowFaceTile(1, (MTLViewport){1024, 0, 1024, 2048, 0, 1}, 2048, 512, &tile), "a tile whose faces would drop below a quarter of their resolution is left alone");
        BG3MFXShadowFaceTile(3, faceViewport(3), 2 * tileSize, 2 * tileSize, &tile);
        MTLViewport movedFace3 = BG3MFXShadowFaceViewport(3, faceViewport(3), tile);
        check(movedFace3.originX == tileSize && movedFace3.originY == tileSize, "face 3 is drawn one tile right and down");

        double bg3 = wrongLookups(render(device, caster, bg3Atlas, false, 2 * tileSize));
        double fixed = wrongLookups(render(device, caster, clone, true, 2 * tileSize));
        double close = wrongLookups(render(device, caster, clone, true, tileSize));
        check(bg3 > 0.2, "BG3's overlapping faces leave lookups reading another face");
        check(fixed < 0.01, "moved faces and the compositing copy give each lookup its own face");
        check(close < 0.01, "half-resolution faces in a full target give each lookup its own face");
        printf("lookups reading another face: BG3 %.1f%%, fixed %.2f%%, fixed in a full target %.2f%%\n", bg3 * 100, fixed * 100, close * 100);
    }
    if (failures) return 1;
    printf("point-light-shadow-fix-smoke: ok\n");
    return 0;
}
