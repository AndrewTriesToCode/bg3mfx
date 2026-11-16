#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "features/metal-hooks/MetalHooks.h"

// Improved shadows' point-light fix: keeps each tetrahedron face of a point light's shadow views to its own
// triangle of the light's atlas tile. See README.md.
//
// BG3 renders a point light's four faces into one size² tile of its shadow
// depth target, each face over half of it (face 0 the bottom, 1 the right,
// 2 the top, 3 the left half), and relies on the TetrahedronClipDistances
// vertex output to keep a face inside its triangle. None of its shadow vertex
// shaders computes that output, so faces overwrite each other's triangles.
// The fix draws each face into its own quarter-sized region (one tile further
// right, down, or both; scaled down when two tiles don't fit in the target),
// where faces cannot overlap, and composites the four as the tile is copied
// into the atlas, each texel from the face whose triangle holds it.

// BG3's _PerCamera, bound at vertex and fragment buffer 11 in shadow passes.
struct BG3MFXShadowCamera {
    float view[16], projection[16], offsetViewProjection[16];
    float nearPlane, farPlane, padding[2];
    float cameraWorldPos[3];
    int32_t tetrahedronFaceIndex;  // 0-3 for a point light's face, -1 otherwise
};
static_assert(sizeof(BG3MFXShadowCamera) == 224, "BG3's _PerCamera is 224 bytes");
constexpr NSUInteger BG3MFXShadowCameraIndex = 11;
// Fragment buffer the compositing LinearizeDepth reads its tile from (BG3's
// LinearizeDepth uses buffer 0 only).
constexpr NSUInteger BG3MFXShadowTileIndex = 30;

// A point light's tile in the shadow depth target, and the side of the region
// each face is drawn into instead (the tile's size, or a power-of-two
// fraction of it when two tiles don't fit in the target).
struct BG3MFXShadowTile { uint32_t x, y, size, region; };

// The tile a face viewport belongs to, if it is one of BG3's half-tile face
// viewports with the tile at whole-pixel coordinates, and whose faces fit in
// a width × height target at no less than a quarter of their resolution.
bool BG3MFXShadowFaceTile(int face, MTLViewport viewport, NSUInteger width, NSUInteger height, BG3MFXShadowTile *tile);
// Where the fix draws a face: its viewport scaled by region / size about the
// tile's corner and moved by (face & 1, face >> 1) regions.
MTLViewport BG3MFXShadowFaceViewport(int face, MTLViewport viewport, const BG3MFXShadowTile &tile);
// Which face's triangle holds tile texel (x, y): the tile's diagonals divide
// it, as ClusteredLighting's face choice does for BG3's projections.
inline int BG3MFXShadowTileFace(float x, float y, float size) {
    if (y < x && y < size - x) return 2;
    if (y > x && y > size - x) return 0;
    if (x < y && x < size - y) return 3;
    return 1;
}

// The compositing copy of BG3's atlas LinearizeDepth: the same bindings and
// math (decoded from its AIR), reading each texel from its face's quarter.
inline const char *const BG3MFXPointLightShadowSource = R"METAL(
#include <metal_stdlib>
using namespace metal;
struct Lineralization { float2 constants; float2 viewportOffset; uint isOrtho; float pad; };
struct Tile { uint x, y, size, region; };
fragment float LinearizeDepthTetrahedron(float4 position [[position]],
                                         texture2d<float> sceneDepth [[texture(0)]],
                                         constant Lineralization &l [[buffer(0)]],
                                         constant Tile &tile [[buffer(30)]]) {
    uint2 texel = uint2(position.xy - l.viewportOffset);
    float2 p = float2(texel) - float2(tile.x, tile.y) + 0.5f;
    float size = float(tile.size);
    if (all(p >= 0.0f) && all(p < size)) {
        uint face = (p.y < p.x && p.y < size - p.x) ? 2u
                  : (p.y > p.x && p.y > size - p.x) ? 0u
                  : (p.x < p.y && p.x < size - p.y) ? 3u : 1u;
        float scale = float(tile.region) / size;
        texel = uint2(tile.x, tile.y) + uint2(p * scale) + uint2(face & 1u, face >> 1u) * tile.region;
    }
    float depth = sceneDepth.read(texel).x;
    if (depth == 0.0f) return 1.0f;
    return l.isOrtho != 0 ? (depth - l.constants.y) / l.constants.x : l.constants.y / (depth - l.constants.x);
}
)METAL";

// A depth-only pipeline into a Depth32Float target (BG3's shadow casters,
// with or without a fragment function).
bool BG3MFXShadowCasterPipeline(MTLRenderPipelineDescriptor *desc);
// BG3's atlas LinearizeDepth (its main-depth twin writes R32Float).
bool BG3MFXShadowAtlasPipeline(MTLRenderPipelineDescriptor *desc);
// The compositing clone of BG3's atlas LinearizeDepth pipeline, made with
// `create` (the original pipeline constructor, which returns +1). nil, with
// `error`, if the shader or pipeline cannot be built.
id<MTLRenderPipelineState> BG3MFXPointLightShadowPipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor *desc,
                                                          BG3MFXCreateRenderPipeline create, NSError **error);
// Takes metal-hooks' draw replacement and reads each encoder's source/lifetime.
BOOL BG3MFXInstallPointLightShadowFix(NSError **error);
