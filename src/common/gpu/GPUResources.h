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
// the residency set are reused once their previous submission completes. The
// Metal 4 work is recorded at once; when BG3MFXMetal4CommitHooked reports that
// committing the Metal 3 buffer reaches the runtime's hook, it is submitted
// from there (BG3MFXMetal4BridgeCommitted), otherwise at once.
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

// Set by the runtime: whether committing `buffer` reaches its commit hook,
// which then calls BG3MFXMetal4BridgeCommitted. Unset or NO: submit at once.
extern "C" BOOL (*_Nullable BG3MFXMetal4CommitHooked)(id<MTLCommandBuffer> buffer);
// Call right after committing a Metal 3 command buffer: submits the Metal 4
// work bridges recorded into it. A no-op for buffers without any.
extern "C" void BG3MFXMetal4BridgeCommitted(id<MTLCommandBuffer> buffer);

// Every build: GPU start and end of each Metal 4 bridge submission (MetalFX
// work on its own queue), for dynamic resolution's GPU-busy measurement.
extern "C" void (*_Nullable BG3MFXGPUWorkHook)(double start, double end);
// Diagnostics: when set, receives each Metal 4 bridge submission's GPU time.
#ifndef BG3MFX_NO_TRACE
extern "C" void (*_Nullable BG3MFXGPUTimingHook)(NSString *label, double gpuSeconds);
// Diagnostics: when set, receives each change to a bridge's residency set: its
// allocation count and bytes after the change, how many allocations were added,
// and whether the set was rebuilt (dropping members idle for 16 submissions,
// or on reaching its 64-allocation bound).
extern "C" void (*_Nullable BG3MFXResidencyHook)(NSString *label, NSUInteger allocations, uint64_t bytes,
    NSUInteger added, BOOL replaced);
// Diagnostics: when set, receives the allocations a residency change added
// (with their index in the submission's allocation list) and dropped.
extern "C" void (*_Nullable BG3MFXResidencyDetailHook)(NSString *label, NSArray<NSDictionary *> *added,
    NSArray<id<MTLAllocation>> *dropped);
// Diagnostics: when set, receives the bridge's recent submission timelines
// (encode, BG3 buffer scheduled/completed, Metal 4 feedback; media-time
// seconds) whenever a submission takes over half a second or fails.
extern "C" void (*_Nullable BG3MFXBridgeStallHook)(NSString *label, NSDictionary *stalled, NSArray<NSDictionary *> *recent);
#endif

NS_ASSUME_NONNULL_END

// Total textures ever allocated by pools in this process (regression checks).
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
extern "C" NSUInteger BG3MFXTexturePoolAllocations(void);
#endif
