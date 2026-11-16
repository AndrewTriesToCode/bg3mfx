#import "features/metalfx/cas-sharpening/CASSharpening.h"
// BG3 runs CAS only with Upscaling Type Off; MetalFX Spatial and Temporal (on
// BG3's FSR type underneath) also run it. Off and FSR stay as BG3 decides.
int main() {
    struct Case { bool enabled; int type, mode; bool expected; };
    const Case cases[] = {
        {true, 0, 0, true},   {false, 0, 0, false},                // Off
        {true, 1, 1, false},  {false, 1, 1, false},                // FSR: BG3's own rule
        {true, 1, 2, true},   {true, 1, 3, true},                  // MetalFX Spatial, Temporal
        {false, 1, 2, false}, {false, 1, 3, false},                // the player's choice still decides
        {true, 1, 0, false},                                       // MetalFX fell back to FSR
    };
    for (const Case &c : cases)
        if (BG3MFXCASRenders(c.enabled, c.type, c.mode) != c.expected) return 1;
    puts("CAS rule: runs with Off, Spatial and Temporal when enabled; FSR keeps BG3's rule.");
    return 0;
}
