#import "common/gpu/GPUResources.h"
#include <atomic>
#include <mutex>
#include <unordered_map>

#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
static std::atomic<NSUInteger> poolAllocations{0};
extern "C" NSUInteger BG3MFXTexturePoolAllocations(void) { return poolAllocations.load(); }
#endif
#ifndef BG3MFX_NO_TRACE
extern "C" void (*BG3MFXGPUTimingHook)(NSString *, double) = nullptr;
extern "C" void (*BG3MFXResidencyHook)(NSString *, NSUInteger, uint64_t, NSUInteger, BOOL) = nullptr;
#endif

static NSError *resourceError(NSString *reason) {
    return [NSError errorWithDomain:@"BG3MFXGPUResources" code:1 userInfo:@{NSLocalizedDescriptionKey:reason}];
}

@implementation BG3MFXTexturePool {
    id<MTLDevice> _device;
    std::mutex _mutex;
    NSMutableArray<id<MTLTexture>> *_free;
    // Keyed by object identity; the value array keeps each pooled texture alive.
    std::unordered_map<const void *, int> _uses;
    NSMutableArray<id<MTLTexture>> *_all;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLTextureDescriptor *)descriptor {
    if (!(self=[super init])) return nil;
    _device=device; _descriptor=[descriptor copy]; _free=[NSMutableArray array]; _all=[NSMutableArray array];
    return self;
}
- (BOOL)matchesWidth:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format {
    return _descriptor.width==width && _descriptor.height==height && _descriptor.pixelFormat==format;
}
- (id<MTLTexture>)acquire {
    std::lock_guard<std::mutex> lock(_mutex);
    id<MTLTexture> texture=_free.lastObject;
    if (texture) [_free removeLastObject];
    else {
        texture=[_device newTextureWithDescriptor:_descriptor];
        if (!texture) return nil;
        [_all addObject:texture];
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
        ++poolAllocations;
#endif
    }
    _uses[(__bridge const void *)texture]=1;
    return texture;
}
- (void)retainTexture:(id<MTLTexture>)texture {
    std::lock_guard<std::mutex> lock(_mutex);
    auto found=_uses.find((__bridge const void *)texture);
    if (found!=_uses.end()) ++found->second;
}
- (void)relinquish:(id<MTLTexture>)texture {
    std::lock_guard<std::mutex> lock(_mutex);
    auto found=_uses.find((__bridge const void *)texture);
    if (found==_uses.end() || --found->second>0) return;
    _uses.erase(found); [_free addObject:texture];
}
- (void)relinquish:(id<MTLTexture>)texture afterCommandBuffer:(id<MTLCommandBuffer>)buffer {
    // The handler keeps the pool alive until the GPU no longer needs the texture.
    BG3MFXTexturePool *pool=self;
    [buffer addCompletedHandler:^(id<MTLCommandBuffer>) { [pool relinquish:texture]; }];
}
@end

// One reusable Metal 4 submission. Its event values increase per reuse, so a
// slot's signal never moves backwards even if BG3 commits buffers out of order.
@interface BG3MFXMetal4Slot : NSObject
@property(nonatomic) id<MTL4CommandAllocator> allocator;
@property(nonatomic) id<MTL4CommandBuffer> commands;
@property(nonatomic) id<MTLEvent> event;
@property(nonatomic) uint64_t value;
@end
@implementation BG3MFXMetal4Slot
@end

@implementation BG3MFXMetal4Bridge {
    id<MTLDevice> _device;
    id<MTL4CommandQueue> _queue;
    id<MTLResidencySet> _residency;
    NSString *_label;
    std::mutex _mutex;
    NSMutableArray<BG3MFXMetal4Slot *> *_free;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device label:(NSString *)label error:(NSError **)error {
    if (!(self=[super init])) return nil;
    auto descriptor=[MTL4CommandQueueDescriptor new]; descriptor.label=label;
    _device=device; _label=[label copy]; _queue=[device newMTL4CommandQueueWithDescriptor:descriptor error:error];
    _free=[NSMutableArray array];
    if (!_queue) { if (error && !*error) *error=resourceError(@"Could not create the Metal 4 queue."); return nil; }
    return self;
}
- (id<MTLResidencySet>)residencyFor:(NSArray<id<MTLAllocation>> *)allocations error:(NSError **)error {
    id<MTLResidencySet> residency;
    NSUInteger added=0; BOOL replaced=NO;
    { std::lock_guard<std::mutex> lock(_mutex);
      // A full set is replaced rather than cleared: in-flight submissions keep
      // using the previous one. Replacement bounds growth from resized inputs.
      if (!_residency || _residency.allocationCount+allocations.count>64) {
          replaced=_residency!=nil;
          auto descriptor=[MTLResidencySetDescriptor new]; descriptor.initialCapacity=16;
          _residency=[_device newResidencySetWithDescriptor:descriptor error:error];
          if (!_residency) return nil;
      }
      for (id<MTLAllocation> allocation in allocations)
          if (![_residency containsAllocation:allocation]) { [_residency addAllocation:allocation]; ++added; }
      if (added) [_residency commit];
      residency=_residency; }
#ifndef BG3MFX_NO_TRACE
    // Outside the bridge lock: the hook records through the tracer's guard.
    if (added) if (auto hook=BG3MFXResidencyHook)
        hook(_label,residency.allocationCount,residency.allocatedSize,added,replaced);
#else
    (void)replaced;
#endif
    return residency;
}
- (void)releaseResidency {
    std::lock_guard<std::mutex> lock(_mutex);
    _residency = nil;
}
- (BOOL)encodeIntoBuffer:(id<MTLCommandBuffer>)buffer allocations:(NSArray<id<MTLAllocation>> *)allocations
                retained:(NSArray *)retained encode:(void (^)(id<MTL4CommandBuffer>))encode
                 failure:(void (^)(NSError *))failure error:(NSError **)error {
    id<MTLResidencySet> residency=[self residencyFor:allocations error:error];
    if (!residency) { if (error && !*error) *error=resourceError(@"Could not create a residency set."); return NO; }
    BG3MFXMetal4Slot *slot;
    { std::lock_guard<std::mutex> lock(_mutex); slot=_free.lastObject; if (slot) [_free removeLastObject]; }
    if (!slot) {
        slot=[BG3MFXMetal4Slot new];
        slot.allocator=[_device newCommandAllocator]; slot.commands=[_device newCommandBuffer]; slot.event=[_device newEvent];
        if (!slot.allocator || !slot.commands || !slot.event) {
            if (error) *error=resourceError(@"Could not allocate a Metal 4 submission."); return NO;
        }
    }
    [slot.commands beginCommandBufferWithAllocator:slot.allocator];
    [slot.commands useResidencySet:residency];
    encode(slot.commands);
    [slot.commands endCommandBuffer];
    uint64_t ready=++slot.value, done=++slot.value;
    // Metal 4 command buffers do not retain allocations; keep everything the
    // submission touches alive until GPU feedback, then recycle the slot.
    NSMutableArray *flight=[NSMutableArray arrayWithArray:retained];
    [flight addObjectsFromArray:allocations]; [flight addObject:residency];
    BG3MFXMetal4Bridge *bridge=self; void (^report)(NSError *)=[failure copy];
#ifndef BG3MFX_NO_TRACE
    NSString *label=_label;
#endif
    auto options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        if (feedback.error && report) report(feedback.error);
#ifndef BG3MFX_NO_TRACE
        if (auto hook=BG3MFXGPUTimingHook) hook(label,feedback.GPUEndTime-feedback.GPUStartTime);
#endif
        [flight removeAllObjects];
        [slot.allocator reset];
        std::lock_guard<std::mutex> lock(bridge->_mutex); [bridge->_free addObject:slot];
    }];
    id<MTL4CommandBuffer> commands=slot.commands;
    [buffer encodeSignalEvent:slot.event value:ready];
    [_queue waitForEvent:slot.event value:ready];
    [_queue commit:&commands count:1 options:options];
    [_queue signalEvent:slot.event value:done];
    [buffer encodeWaitForEvent:slot.event value:done];
    return YES;
}
@end
