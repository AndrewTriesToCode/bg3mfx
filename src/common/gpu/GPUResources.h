#pragma once
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Reuses same-descriptor private textures across frames instead of allocating
// per frame. Each texture carries a use count; it returns to the free list only
// when every holder has relinquished it, typically on command-buffer completion.
@interface BG3MFXTexturePool : NSObject
@property(nonatomic, readonly) MTLTextureDescriptor *descriptor;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLTextureDescriptor *)descriptor;
- (BOOL)matchesWidth:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format;
// Returns a texture with a use count of one, allocating only when none is free.
- (nullable id<MTLTexture>)acquire;
- (void)retainTexture:(id<MTLTexture>)texture;
- (void)relinquish:(id<MTLTexture>)texture;
- (void)relinquish:(id<MTLTexture>)texture afterCommandBuffer:(id<MTLCommandBuffer>)buffer;
@end

// Runs Metal 4 FX work between earlier and later commands of a Metal 3 command
// buffer, entirely on the GPU timeline. Allocators, command buffers, events and
// the residency set are reused once their previous submission completes.
@interface BG3MFXMetal4Bridge : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device label:(NSString *)label error:(NSError **)error;
// `allocations` are made resident for this submission. `retained` objects and
// the allocations stay alive until the GPU reports completion.
- (BOOL)encodeIntoBuffer:(id<MTLCommandBuffer>)buffer
             allocations:(NSArray<id<MTLAllocation>> *)allocations
                retained:(NSArray *)retained
                  encode:(void (^)(id<MTL4CommandBuffer> commands))encode
                 failure:(nullable void (^)(NSError *error))failure
                   error:(NSError **)error;
// The residency set retains its allocations. Drop it while idle; submissions
// in flight keep their own reference, and the next one starts a new set.
- (void)releaseResidency;
@end

// Diagnostics: when set, receives each Metal 4 bridge submission's GPU time.
#ifndef BG3MFX_NO_TRACE
extern "C" void (*_Nullable BG3MFXGPUTimingHook)(NSString *label, double gpuSeconds);
#endif

NS_ASSUME_NONNULL_END

// Total textures ever allocated by pools in this process (regression checks).
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
extern "C" NSUInteger BG3MFXTexturePoolAllocations(void);
#endif
