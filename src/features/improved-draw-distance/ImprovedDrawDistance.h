#pragma once
#include <cstdint>
#include <cstring>

// BG3's size cull drops an object of bounding radius r at distance d when
//   T * min(d / D, 1)^10 >= r / (d - r)
// (ls::sse::CullOnBoundSizeAndAABBs). Detail Distance picks T (0.016, 0.018 or
// 0.020) and D, which is 50 m for every value. Within D the tenth power
// collapses the threshold, so small objects vanish at about 40-48 m whatever
// the setting; improved-draw-distance raises D.
inline constexpr float BG3MFXImprovedDrawDistance = 100.0f;

// `mov w9, #imm` (MOVZ, shift 16) loading `distance`'s bits, or 0 when its low
// 16 bits are not zero and so cannot be loaded by one instruction.
inline uint32_t BG3MFXImprovedDrawDistanceMove(float distance) {
    uint32_t bits;
    memcpy(&bits, &distance, sizeof bits);
    if (bits & 0xffff) return 0;
    return 0x52a00000u | (bits >> 16) << 5 | 9u;
}
