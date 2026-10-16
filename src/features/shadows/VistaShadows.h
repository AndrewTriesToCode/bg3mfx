#pragma once
#import <Metal/Metal.h>
#include <cstdint>

// Called only after NativeMenu has checked the supported executable UUID.
BOOL BG3MFXInstallVistaContext(intptr_t slide, NSError **error);
bool BG3MFXVistaReplayActive();
// Internal merge encoders must remain visible in the vista-only diagnostic.
bool BG3MFXVistaInternalEncoding();
// Preserves the submission's arguments/result and restores nested context.
using BG3MFXNativeSubmit = uintptr_t (*)(void *, uintptr_t, void *);
extern "C" uintptr_t BG3MFXReplayVista(void *commands, uintptr_t flags, void *fence, BG3MFXNativeSubmit submit);

// One explicitly identified native vista pass; nil preparation leaves it native.
@interface BG3MFXVistaPass : NSObject
@property(nonatomic, readonly) MTLRenderPassDescriptor *descriptor;
+ (BOOL)supportsDescriptor:(MTLRenderPassDescriptor *)native device:(id<MTLDevice>)device;
+ (instancetype)prepare:(MTLRenderPassDescriptor *)native buffer:(id<MTLCommandBuffer>)buffer;
- (void)setNativeViewports:(const MTLViewport *)values count:(NSUInteger)count;
- (void)setNativeScissors:(const MTLScissorRect *)values count:(NSUInteger)count;
- (void)noteDraw;
- (MTLViewport)scaleViewport:(MTLViewport)viewport;
- (MTLScissorRect)scaleScissor:(MTLScissorRect)scissor;
// Called after ending BG3's redirected encoder, before any following BG3 work.
- (BOOL)finishInBuffer:(id<MTLCommandBuffer>)buffer;
@end
