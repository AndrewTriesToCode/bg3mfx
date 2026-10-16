#pragma once

#import <Metal/Metal.h>

// Per-encoder state for suppressing texture and pipeline binds that already
// match the encoder's current bindings. The texture references are unretained:
// the Metal encoder keeps resources alive while they are bound.
struct BG3MFXBindFilter {
    __unsafe_unretained id<MTLTexture> fragmentTexture[64] = {};

    static inline bool forwardPipeline(__unsafe_unretained id current,
                                       __unsafe_unretained id next) {
        // A nil pipeline must still reach Metal, including when unbinding.
        return !current || current != next;
    }

    inline bool forwardTexture(__unsafe_unretained id<MTLTexture> texture,
                               NSUInteger index) {
        if (index >= 64) return true;
        if (fragmentTexture[index] == texture) return false;
        fragmentTexture[index] = texture;
        return true;
    }

    template <typename Forward>
    inline void forwardTextures(id<MTLTexture> const *textures, NSRange range,
                                Forward forward) {
        // Subtraction keeps both the bounds check and subsequent index math
        // safe even for a malformed NSRange whose addition would overflow.
        if (range.location > 64 || range.length > 64 - range.location) {
            forward(textures, range);
            return;
        }

        NSUInteger i = 0;
        const NSUInteger n = range.length;
        const NSUInteger base = range.location;
        while (i < n) {
            while (i < n && fragmentTexture[base + i] == textures[i]) ++i;
            if (i == n) break;

            const NSUInteger start = i;
            NSUInteger end = i;
            while (i < n) {
                if (fragmentTexture[base + i] != textures[i]) {
                    end = i;
                    ++i;
                    continue;
                }

                NSUInteger gap = i;
                while (gap < n && gap - end <= 2 &&
                       fragmentTexture[base + gap] == textures[gap]) ++gap;
                if (gap < n && gap - end <= 3 &&
                    fragmentTexture[base + gap] != textures[gap]) {
                    i = gap;
                    continue;
                }
                break;
            }

            for (NSUInteger j = start; j <= end; ++j)
                fragmentTexture[base + j] = textures[j];
            forward(textures + start,
                    NSMakeRange(base + start, end - start + 1));
            i = end + 1;
        }
    }
};
