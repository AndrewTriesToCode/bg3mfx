#import "common/gpu/GPUResources.h"
#import <objc/runtime.h>
#include <atomic>
#include <mutex>
#include <unordered_map>

#ifdef BG3MFX_STANDALONE_TEST_HOOKS
static std::atomic<NSUInteger> poolAllocations{0};
extern "C" NSUInteger BG3MFXTexturePoolAllocations(void) { return poolAllocations.load(); }
#endif
extern "C" void (*BG3MFXGPUWorkHook)(double, double) = nullptr;
extern "C" BOOL (*BG3MFXMetal4CommitHooked)(id<MTLCommandBuffer>) = nullptr;

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
#ifdef BG3MFX_STANDALONE_TEST_HOOKS
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
// Shared so the CPU can release the Metal 4 queue if BG3's buffer fails.
@property(nonatomic) id<MTLSharedEvent> event;
@property(nonatomic) uint64_t value;
@end
@implementation BG3MFXMetal4Slot
@end

// A recorded Metal 4 submission waiting for BG3 to commit its buffer: `submit`
// queues it behind BG3's signal; `orphan` runs it without that wait, for a
// buffer BG3 dropped uncommitted (see -resolveThrough:).
@interface BG3MFXMetal4Pending : NSObject
@property(nonatomic) BG3MFXMetal4Bridge *bridge;
@property(nonatomic, copy) void (^submit)(void);
@property(nonatomic, copy) void (^orphan)(void);
@end
@implementation BG3MFXMetal4Pending
@end
@interface BG3MFXMetal4Bridge ()
- (void)resolveThrough:(BG3MFXMetal4Pending *)pending;
@end
static char pendingSubmissionsKey;
extern "C" void BG3MFXMetal4BridgeCommitted(id<MTLCommandBuffer> buffer) {
    NSArray<BG3MFXMetal4Pending *> *pending=objc_getAssociatedObject(buffer,&pendingSubmissionsKey);
    if (!pending) return;
    objc_setAssociatedObject(buffer,&pendingSubmissionsKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (BG3MFXMetal4Pending *submission in pending) [submission.bridge resolveThrough:submission];
}

@implementation BG3MFXMetal4Bridge {
    id<MTLDevice> _device;
    id<MTL4CommandQueue> _queue;
    id<MTLResidencySet> _residency;
    NSString *_label;
    std::mutex _mutex;
    NSMutableArray<BG3MFXMetal4Slot *> *_free;
    // Recorded submissions not yet on the queue, in encode order.
    NSMutableArray<BG3MFXMetal4Pending *> *_unresolved;
    // Submission count, and the last submission that used each member of
    // _residency (keyed by identity; the set keeps every key alive).
    uint64_t _submissions;
    std::unordered_map<const void *, uint64_t> _lastUse;
}
// A member unused this many submissions is dropped when the set is rebuilt.
// Pools rotate their textures within a few submissions; a BG3 render target
// replaced at the same size (live: save loads, settings changes) never returns.
static constexpr uint64_t ResidencyIdleSubmissions = 16;
- (instancetype)initWithDevice:(id<MTLDevice>)device label:(NSString *)label error:(NSError **)error {
    if (!(self=[super init])) return nil;
    auto descriptor=[MTL4CommandQueueDescriptor new]; descriptor.label=label;
    _device=device; _label=[label copy]; _queue=[device newMTL4CommandQueueWithDescriptor:descriptor error:error];
    _free=[NSMutableArray array]; _unresolved=[NSMutableArray array];
    if (!_queue) { if (error && !*error) *error=resourceError(@"Could not create the Metal 4 queue."); return nil; }
    return self;
}
- (id<MTLResidencySet>)residencyFor:(NSArray<id<MTLAllocation>> *)allocations error:(NSError **)error {
    id<MTLResidencySet> residency;
    NSUInteger added=0; BOOL replaced=NO;
    { std::lock_guard<std::mutex> lock(_mutex);
      uint64_t now=++_submissions;
      // The set retains its members, so BG3 textures it no longer uses would
      // stay allocated. Look for idle members periodically; scanning at most 64
      // entries every few submissions costs nothing measurable.
      bool idle=false;
      if (_residency && now%ResidencyIdleSubmissions==0)
          for (auto &use:_lastUse) if (now-use.second>ResidencyIdleSubmissions) { idle=true; break; }
      NSUInteger missing=0;
      for (id<MTLAllocation> allocation in allocations)
          if (!_residency || ![_residency containsAllocation:allocation]) ++missing;
      // Rebuild rather than remove: in-flight submissions keep the previous set.
      if (!_residency || idle || _residency.allocationCount+missing>64) {
          auto descriptor=[MTLResidencySetDescriptor new]; descriptor.initialCapacity=16;
          id<MTLResidencySet> next=[_device newResidencySetWithDescriptor:descriptor error:error];
          if (!next) return nil;
          std::unordered_map<const void *, uint64_t> kept;
          if (_residency) {
              replaced=YES;
              for (id<MTLAllocation> allocation in _residency.allAllocations) {
                  auto use=_lastUse.find((__bridge const void *)allocation);
                  if (use==_lastUse.end() || now-use->second>ResidencyIdleSubmissions) continue;
                  [next addAllocation:allocation]; kept.insert(*use);
              }
          }
          _residency=next; _lastUse.swap(kept);
      }
      for (id<MTLAllocation> allocation in allocations) {
          if (![_residency containsAllocation:allocation]) { [_residency addAllocation:allocation]; ++added; }
          _lastUse[(__bridge const void *)allocation]=now;
      }
      if (added || replaced) [_residency commit];
      residency=_residency; }
    return residency;
}
- (void)releaseResidency {
    std::lock_guard<std::mutex> lock(_mutex);
    _residency = nil; _lastUse.clear();
}
// Queues `pending` and, first, every submission recorded before it that is
// still unresolved. BG3 commits buffers in order, so those buffers were dropped
// and will never signal; MetalFX still needs every command buffer it encoded
// to run, in order (skipping one stalls its next submission), so they run
// without the wait. Their frames are discarded anyway.
- (void)resolveThrough:(BG3MFXMetal4Pending *)pending {
    NSArray<BG3MFXMetal4Pending *> *dropped;
    { std::lock_guard<std::mutex> lock(_mutex);
      NSUInteger index=[_unresolved indexOfObjectIdenticalTo:pending];
      if (index==NSNotFound) return;
      dropped=[_unresolved subarrayWithRange:NSMakeRange(0,index)];
      [_unresolved removeObjectsInRange:NSMakeRange(0,index+1)]; }
    for (BG3MFXMetal4Pending *orphan in dropped) { orphan.orphan(); orphan.submit=nil; orphan.orphan=nil; }
    pending.submit(); pending.submit=nil; pending.orphan=nil;
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
        slot.allocator=[_device newCommandAllocator]; slot.commands=[_device newCommandBuffer]; slot.event=[_device newSharedEvent];
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
    auto options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        if (feedback.error && report) report(feedback.error);
        if (auto hook=BG3MFXGPUWorkHook) hook(feedback.GPUStartTime,feedback.GPUEndTime);
        [flight removeAllObjects];
        [slot.allocator reset];
        std::lock_guard<std::mutex> lock(bridge->_mutex); [bridge->_free addObject:slot];
    }];
    id<MTL4CommandBuffer> commands=slot.commands;
    // The Metal 4 queue waits for BG3's buffer to reach this point. If that
    // buffer fails first and never signals, the queue would wait forever and
    // every later submission behind it would stall; release it instead (its
    // results are discarded with the failed frame).
    id<MTLSharedEvent> event=slot.event;
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status==MTLCommandBufferStatusError && event.signaledValue<ready) event.signaledValue=ready;
    }];
    [buffer encodeSignalEvent:slot.event value:ready];
    [buffer encodeWaitForEvent:slot.event value:done];
    // Submit only once BG3 commits `buffer` (BG3MFXMetal4BridgeCommitted, from
    // the commit hook). Submitted earlier, the queue would wait on a signal
    // from a buffer BG3 might never commit and stall every later submission
    // for 4 s. Without the hook nothing would submit and `buffer` would wait
    // for `done` until the GPU times it out (a scheduled handler does not run
    // in time), so then submit at once.
    id<MTL4CommandQueue> queue=_queue;
    BG3MFXMetal4Pending *pending=[BG3MFXMetal4Pending new];
    pending.bridge=self;
    pending.submit=^{
        id<MTL4CommandBuffer> submitted=commands;
        [queue waitForEvent:event value:ready];
        [queue commit:&submitted count:1 options:options];
        [queue signalEvent:event value:done];
    };
    pending.orphan=^{
        id<MTL4CommandBuffer> submitted=commands;
        [queue commit:&submitted count:1 options:options];
        [queue signalEvent:event value:done];
    };
    { std::lock_guard<std::mutex> lock(_mutex); [_unresolved addObject:pending]; }
    if (!BG3MFXMetal4CommitHooked || !BG3MFXMetal4CommitHooked(buffer)) { [self resolveThrough:pending]; return YES; }
    NSMutableArray *submissions=objc_getAssociatedObject(buffer,&pendingSubmissionsKey);
    if (!submissions) {
        submissions=[NSMutableArray array];
        objc_setAssociatedObject(buffer,&pendingSubmissionsKey,submissions,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [submissions addObject:pending];
    return YES;
}
@end
