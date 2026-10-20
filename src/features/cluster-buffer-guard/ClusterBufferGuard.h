#pragma once
#import <Metal/Metal.h>

// BG3's clustered lighting reads ClusterInfoBuffer at compute and fragment
// buffer index 1, and ClusterAssignment writes it at compute index 6. At some
// render sizes (live: 1796×1123 entering character creation) BG3 dispatches
// these passes with the buffer unbound, and the GPU fault wedges the driver.
// Binding a zero-filled stand-in at each new encoder turns that into frames lit
// without local lights; BG3's own bind replaces it whenever it makes one.
inline constexpr NSUInteger BG3MFXClusterInfoIndex = 1, BG3MFXClusterInfoWriteIndex = 6;

// Binds the stand-in on an encoder BG3 just created.
void BG3MFXBindClusterStandIns(id encoder, BOOL compute);
// Whether `buffer` is the stand-in (diagnostics: BG3 left the slot unbound).
BOOL BG3MFXIsClusterStandIn(id<MTLBuffer> buffer);
