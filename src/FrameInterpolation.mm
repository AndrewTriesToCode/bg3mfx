#import "FrameInterpolation.h"
#import "GPUResources.h"
#import "FrameLog.h"
#import <MetalFX/MetalFX.h>
#include <cmath>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <atomic>
#include <memory>
#include <mach/mach_time.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSError *fgError(NSString *reason) {
    return [NSError errorWithDomain:@"BG3MFXFrameGeneration" code:1 userInfo:@{NSLocalizedDescriptionKey:reason}];
}
static BG3MFXTexturePool *fgPool(id<MTLDevice> device, NSUInteger w, NSUInteger h, MTLPixelFormat format, MTLTextureUsage usage) {
    auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModePrivate; d.usage=usage;
    return [[BG3MFXTexturePool alloc] initWithDevice:device descriptor:d];
}
@implementation BG3MFXFrameInterpolation {
    id<MTLDevice> _device;
    id<MTLFXFrameInterpolatorBase> _effect;
    id<MTLFXFrameInterpolator> _effect3;
    id<MTL4FXFrameInterpolator> _effect4;
    BG3MFXMetal4Bridge *_bridge;
    BG3MFXTexturePool *_colors, *_depths, *_motions, *_outputs;
    id<MTLComputePipelineState> _copy, _copyDepth;
    id<MTLTexture> _previous;
    NSUInteger _w, _h, _outW, _outH;
    MTLPixelFormat _colorFormat, _depthFormat;
    BOOL _reset;
    NSLock *_lock;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device width:(NSUInteger)w height:(NSUInteger)h
                   outputWidth:(NSUInteger)ow outputHeight:(NSUInteger)oh error:(NSError **)error {
    return [self initWithDevice:device width:w height:h outputWidth:ow outputHeight:oh scene:nil depth:nil motion:nil error:error];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device scene:(id<MTLTexture>)scene depth:(id<MTLTexture>)depth
                        motion:(id<MTLTexture>)motion error:(NSError **)error {
    return [self initWithDevice:device width:depth.width height:depth.height outputWidth:scene.width outputHeight:scene.height
                          scene:scene depth:depth motion:motion error:error];
}
static BOOL fgUsable(id<MTLTexture> t, MTLTextureUsage required) { return t && (t.usage&required)==required; }
// Creates the effect for the given input formats. Without our own color copy
// there is no history texture to pass, so the interpolator must keep it itself.
- (BOOL)makeEffectColor:(MTLPixelFormat)color depth:(MTLPixelFormat)depth error:(NSError **)error {
    auto d=[MTLFXFrameInterpolatorDescriptor new]; d.inputWidth=_w; d.inputHeight=_h; d.outputWidth=_outW; d.outputHeight=_outH;
    d.colorTextureFormat=color; d.outputTextureFormat=MTLPixelFormatRGBA16Float;
    d.depthTextureFormat=depth; d.motionTextureFormat=MTLPixelFormatRG16Float;
    if (color!=MTLPixelFormatRGBA16Float) {
        if (@available(macOS 27.0, *)) d.requiresPrevColorTexture=NO; else return NO;
    }
    _effect=_effect3=nil; _effect4=nil;
    if ([MTLFXFrameInterpolatorDescriptor supportsMetal4FX:_device]) {
        auto compiler=[_device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:error];
        _effect4=compiler ? [d newFrameInterpolatorWithDevice:_device compiler:compiler] : nil; _effect=_effect4;
    } else { _effect3=[d newFrameInterpolatorWithDevice:_device]; _effect=_effect3; }
    _colorFormat=color; _depthFormat=depth;
    return _effect!=nil;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device width:(NSUInteger)w height:(NSUInteger)h
                   outputWidth:(NSUInteger)ow outputHeight:(NSUInteger)oh scene:(id<MTLTexture>)scene
                         depth:(id<MTLTexture>)depth motion:(id<MTLTexture>)motion error:(NSError **)error {
    if (!(self=[super init])) return nil;
    if (!w || !h || !ow || !oh || ![MTLFXFrameInterpolatorDescriptor supportsDevice:device]) {
        if (error) *error=fgError(@"MetalFX frame generation is not supported by this device or resolution."); return nil;
    }
    _device=device; _w=w; _h=h; _outW=ow; _outH=oh; _reset=YES; _lock=[NSLock new];
    // Prefer reading BG3's own textures. MetalFX accepts its scene and depth
    // formats; any input it cannot read as-is is converted into a pooled copy.
    BOOL sceneDirect=scene && !scene.framebufferOnly && scene.width==ow && scene.height==oh;
    if (@available(macOS 27.0, *)) {} else sceneDirect=NO;
    BOOL depthDirect=depth && depth.width==w && depth.height==h;
    if (sceneDirect || depthDirect) {
        NSError *ignored=nil;
        if ([self makeEffectColor:sceneDirect ? scene.pixelFormat : MTLPixelFormatRGBA16Float
                            depth:depthDirect ? depth.pixelFormat : MTLPixelFormatR32Float error:&ignored]) {
            _directColor=sceneDirect && fgUsable(scene,_effect.colorTextureUsage);
            _directDepth=depthDirect && fgUsable(depth,_effect.depthTextureUsage);
            if (_directColor!=sceneDirect || _directDepth!=depthDirect) _effect=_effect3=nil, _effect4=nil;
        }
    }
    if (!_effect) {
        _directColor=_directDepth=NO;
        [self makeEffectColor:MTLPixelFormatRGBA16Float depth:MTLPixelFormatR32Float error:error];
    }
    _directMotion=_effect && fgUsable(motion,_effect.motionTextureUsage) && motion.width==w && motion.height==h;
    if (_effect4) _bridge=[[BG3MFXMetal4Bridge alloc] initWithDevice:device label:@"BG3 Metal 4 Frame Generation" error:error];
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void Copy(texture2d<float,access::read> s [[texture(0)]],texture2d<float,access::write> d [[texture(1)]],uint2 p [[thread_position_in_grid]]){if(all(p<uint2(d.get_width(),d.get_height())))d.write(s.read(p),p);}\n"
        "kernel void Depth(depth2d<float> s [[texture(0)]],texture2d<float,access::write> d [[texture(1)]],uint2 p [[thread_position_in_grid]]){if(all(p<uint2(d.get_width(),d.get_height()))){constexpr sampler q(coord::pixel,filter::nearest);d.write(s.sample(q,float2(p)+.5),p);}}";
    auto library=[device newLibraryWithSource:source options:nil error:error];
    _copy=library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"Copy"] error:error] : nil;
    _copyDepth=library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"Depth"] error:error] : nil;
    if (!_effect || (_effect4 && !_bridge) || !_copy || !_copyDepth) {
        if (error && !*error) *error=fgError(@"Could not initialize MetalFX frame generation."); return nil;
    }
    _colors=fgPool(device,ow,oh,MTLPixelFormatRGBA16Float,_effect.colorTextureUsage|MTLTextureUsageShaderWrite);
    _depths=fgPool(device,w,h,MTLPixelFormatR32Float,_effect.depthTextureUsage|MTLTextureUsageShaderWrite);
    _motions=fgPool(device,w,h,MTLPixelFormatRG16Float,_effect.motionTextureUsage|MTLTextureUsageShaderWrite);
    _outputs=fgPool(device,ow,oh,MTLPixelFormatRGBA16Float,_effect.outputTextureUsage|MTLTextureUsageShaderRead);
    return self;
}
- (BOOL)usesMetal4 { return _effect4!=nil; }
- (void)resetHistory { [_lock lock]; _reset=YES; [_lock unlock]; }
- (id<MTLTexture>)encodeScene:(id<MTLTexture>)scene depth:(id<MTLTexture>)depth motion:(id<MTLTexture>)motion
                      camera:(NSData *)camera parameters:(BG3MFXFrameParameters)p deltaTime:(float)delta
               commandBuffer:(id<MTLCommandBuffer>)buffer error:(NSError **)error {
    if (scene.width!=_outW || scene.height!=_outH || depth.width!=_w || depth.height!=_h ||
        motion.width!=_w || motion.height!=_h || motion.pixelFormat!=MTLPixelFormatRG16Float ||
        scene.framebufferOnly || camera.length<224 || !std::isfinite(delta) || delta<=0 ||
        !(scene.usage&MTLTextureUsageShaderRead) || !(depth.usage&MTLTextureUsageShaderRead) ||
        depth.hazardTrackingMode==MTLHazardTrackingModeUntracked || motion.hazardTrackingMode==MTLHazardTrackingModeUntracked) {
        if (error) *error=fgError(@"Frame generation received unsupported scene, depth, motion, or camera inputs."); return nil;
    }
    const float *c=(const float *)camera.bytes;
    float fov=2*std::atan(1/c[21])*180/M_PI;
    if (!std::isfinite(fov) || fov<=0 || fov>=180 || c[48]<=0 || c[49]<=c[48]) {
        if (error) *error=fgError(@"Frame generation received an unsupported camera projection."); return nil;
    }
    if ((_directColor && scene.pixelFormat!=_colorFormat) || (_directDepth && depth.pixelFormat!=_depthFormat) ||
        (_directColor && !fgUsable(scene,_effect.colorTextureUsage)) || (_directDepth && !fgUsable(depth,_effect.depthTextureUsage)) ||
        (_directMotion && !fgUsable(motion,_effect.motionTextureUsage))) {
        if (error) *error=fgError(@"Frame generation inputs changed format or usage."); return nil;
    }
    [_lock lock];
    // Direct inputs are BG3's textures; the rest are pooled converted copies.
    // A copied color also serves as the next frame's previous color, so the
    // pool keeps it until the frame that reads it as history completes. The
    // output is valid until `buffer` completes.
    id<MTLTexture> color=_directColor ? scene : [_colors acquire], z=_directDepth ? depth : [_depths acquire],
        mv=_directMotion ? motion : [_motions acquire], out=[_outputs acquire];
    if (!_directColor && color) [_colors relinquish:color afterCommandBuffer:buffer];
    if (!_directDepth && z) [_depths relinquish:z afterCommandBuffer:buffer];
    if (!_directMotion && mv) [_motions relinquish:mv afterCommandBuffer:buffer];
    if (out) [_outputs relinquish:out afterCommandBuffer:buffer];
    if (!color || !z || !mv || !out) { [_lock unlock]; if(error)*error=fgError(@"Could not allocate frame generation textures."); return nil; }
    if (!_directColor || !_directDepth || !_directMotion) {
        auto encoder=[buffer computeCommandEncoder];
        NSArray *sources=@[scene,depth,motion], *targets=@[color,z,mv];
        for (NSUInteger i=0;i<3;++i) {
            id<MTLTexture> t=targets[i];
            if (t==sources[i]) continue;
            [encoder setComputePipelineState:i==1 ? _copyDepth : _copy];
            [encoder setTexture:sources[i] atIndex:0]; [encoder setTexture:t atIndex:1];
            [encoder dispatchThreads:MTLSizeMake(t.width,t.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
        }
        [encoder endEncoding];
    }
    id<MTLTexture> previous=_directColor ? nil : (_previous ?: color);
    _effect.colorTexture=color; _effect.prevColorTexture=previous; _effect.outputTexture=out;
    _effect.depthTexture=z; _effect.motionTexture=mv; _effect.depthReversed=p.depthReversed;
    _effect.motionVectorScaleX=p.motionScaleX; _effect.motionVectorScaleY=p.motionScaleY;
    _effect.jitterOffsetX=p.jitterX; _effect.jitterOffsetY=p.jitterY;
    _effect.nearPlane=c[48]; _effect.farPlane=c[49]; _effect.fieldOfView=fov;
    _effect.aspectRatio=(float)_outW/_outH; _effect.deltaTime=delta;
    _effect.shouldResetHistory=_reset || p.reset; _effect.uiTexture=nil;
    if (_effect4) {
        id<MTL4FXFrameInterpolator> effect=_effect4;
        if (![_bridge encodeIntoBuffer:buffer allocations:previous ? @[color,z,mv,out,previous] : @[color,z,mv,out] retained:@[effect]
                encode:^(id<MTL4CommandBuffer> commands) {
                    commands.label=@"BG3 MetalFX generated scene"; [effect encodeToCommandBuffer:commands];
                } failure:self.failureHandler error:error]) {
            [_lock unlock]; return nil;
        }
    } else { [_effect3 encodeToCommandBuffer:buffer]; }
    if (!_directColor) {
        if (_previous) [_colors relinquish:_previous afterCommandBuffer:buffer];
        [_colors retainTexture:color]; _previous=color;
    }
    _reset=NO; [_lock unlock]; return out;
}
@end

static thread_local bool presentationThread=false;

// Bounds stand-ins in flight. Unlike a semaphore its limit can change per
// request: BG3's double-buffered vsync allows two, otherwise three.
@interface BG3MFXSlotGate : NSObject
- (BOOL)acquireWithLimit:(NSUInteger)limit timeout:(double)seconds;
- (void)releaseSlot;
- (NSUInteger)inFlight;
@end
@implementation BG3MFXSlotGate { NSCondition *_condition; NSUInteger _inFlight; }
- (NSUInteger)inFlight { [_condition lock]; NSUInteger count=_inFlight; [_condition unlock]; return count; }
- (instancetype)init { if ((self=[super init])) _condition=[NSCondition new]; return self; }
- (BOOL)acquireWithLimit:(NSUInteger)limit timeout:(double)seconds {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    [_condition lock];
    while (_inFlight>=limit) if (![_condition waitUntilDate:deadline]) { [_condition unlock]; return NO; }
    ++_inFlight; [_condition unlock]; return YES;
}
- (void)releaseSlot { [_condition lock]; if (_inFlight) --_inFlight; [_condition broadcast]; [_condition unlock]; }
@end
static char standInTextureKey;

@interface BG3MFXStandInDrawable : NSObject <CAMetalDrawable>
@property(nonatomic, readonly) id<MTLTexture> texture;
@property(nonatomic, readonly) CAMetalLayer *layer;
@property(nonatomic, readonly) BG3MFXFramePresenter *presenter;
@property(nonatomic, readonly) NSUInteger drawableID;
@property(nonatomic) CFTimeInterval presentedTime;
- (instancetype)initWithTexture:(id<MTLTexture>)texture pool:(BG3MFXTexturePool *)pool slots:(BG3MFXSlotGate *)slots
                          layer:(CAMetalLayer *)layer presenter:(BG3MFXFramePresenter *)presenter drawableID:(NSUInteger)drawableID;
- (BG3MFXTexturePool *)pool;
- (NSArray *)takeSubmission;
@end

struct PresentTask {
    id<MTLTexture> real, generated;
    BG3MFXTexturePool *realPool, *generatedPool;
    CAMetalLayer *layer;
    uint64_t value;
    double interval;           // BG3's work time: its interval minus stand-in waits
    double cadence;            // BG3's actual interval between frames
    NSArray *handlers;
    __weak BG3MFXStandInDrawable *standIn;
    CFTimeInterval submitted;  // BG3's commit of this frame, for the frame log
    unsigned queued;           // stand-ins in flight plus frames waiting here
};

@implementation BG3MFXFramePresenter {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _copy;
    id<MTLSharedEvent> _event;
    std::atomic<uint64_t> _eventValue;
    BG3MFXSlotGate *_slots;
    std::atomic<NSUInteger> _drawableIDs;
    std::atomic<double> _standInWait;
    // Paced presentation (vsync on, or vsync off up to half the refresh rate):
    // the display paces the pairs, and every extra stand-in only queues another
    // frame, so BG3 gets one.
    std::atomic<bool> _singleStandIn;
    // Diagnostics, in seconds; reset by takeTimingSummary.
    std::atomic<double> _idleTime, _drawableTime, _standInTime;
    std::atomic<unsigned> _timedTasks, _immediateTasks;
    std::mutex _mutex;
    std::condition_variable _wake;
    std::deque<PresentTask> _tasks;
    std::thread _thread;
    bool _stop;
    BG3MFXTexturePool *_standIns, *_generated;
}
+ (BOOL)isPresentationThread { return presentationThread; }
+ (BG3MFXFramePresenter *)presenterForStandIn:(id)drawable {
    return [drawable isKindOfClass:BG3MFXStandInDrawable.class] ? ((BG3MFXStandInDrawable *)drawable).presenter : nil;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device format:(MTLPixelFormat)format error:(NSError **)error {
    if (!(self=[super init])) return nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V{float4 p [[position]];float2 uv;};vertex V Vertex(uint i [[vertex_id]]){float2 u=float2((i<<1)&2,i&2);return {float4(u*float2(2,-2)+float2(-1,1),0,1),u};}\n"
        "fragment float4 Fragment(V v [[stage_in]],texture2d<float> t [[texture(0)]]){constexpr sampler s(filter::nearest);return t.sample(s,v.uv);}";
    auto library=[device newLibraryWithSource:source options:nil error:error]; auto d=[MTLRenderPipelineDescriptor new];
    d.vertexFunction=[library newFunctionWithName:@"Vertex"]; d.fragmentFunction=[library newFunctionWithName:@"Fragment"];
    d.colorAttachments[0].pixelFormat=format;
    _copy=library ? [device newRenderPipelineStateWithDescriptor:d error:error] : nil; _queue=[device newCommandQueue];
    _queue.label=@"BG3 Frame Generation presentation"; _event=[device newSharedEvent];
    if (!_copy || !_queue || !_event) { if (error && !*error) *error=fgError(@"Could not initialize frame presentation."); return nil; }
    _device=device; _pixelFormat=format;
    // Stand-ins in flight bound how far BG3 can run ahead of what has actually
    // been shown: BG3's own buffering choice, two or three.
    _slots=[BG3MFXSlotGate new];
    // Worker access is bounded by dealloc's stop/join; do not form a self/thread cycle.
    __unsafe_unretained BG3MFXFramePresenter *owner=self;
    _thread=std::thread([owner]{ [owner run]; }); return self;
}
- (void)dealloc {
    { std::lock_guard<std::mutex> lock(_mutex); _stop=true; _wake.notify_all(); }
    if (_thread.joinable()) _thread.join();
}
- (BG3MFXTexturePool *)poolLike:(id<MTLTexture>)texture standIn:(BOOL)standIn
                          width:(NSUInteger)w height:(NSUInteger)h format:(MTLPixelFormat)format {
    std::lock_guard<std::mutex> lock(_mutex);
    BG3MFXTexturePool *__strong &pool=standIn ? _standIns : _generated;
    // A resize replaces the pool; textures still in flight keep the old one alive.
    if (!pool || ![pool matchesWidth:w height:h format:format]) {
        auto d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
        d.storageMode=MTLStorageModePrivate; d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        pool=[[BG3MFXTexturePool alloc] initWithDevice:_device descriptor:d];
    }
    (void)texture; return pool;
}
- (id<CAMetalDrawable>)nextStandInForLayer:(CAMetalLayer *)layer limit:(NSUInteger)limit {
    NSUInteger w=(NSUInteger)layer.drawableSize.width, h=(NSUInteger)layer.drawableSize.height;
    if (!w || !h || layer.pixelFormat!=_pixelFormat) return nil;
    CFTimeInterval start=CACurrentMediaTime();
    NSUInteger slots=_singleStandIn ? 1 : std::min<NSUInteger>(std::max<NSUInteger>(limit,2),3);
    BG3MFXFrameLogBuffering((unsigned)limit,(unsigned)slots);
    BOOL acquired=[_slots acquireWithLimit:slots timeout:1];
    double waited=CACurrentMediaTime()-start;
    _standInWait=_standInWait+waited; _standInTime=_standInTime+waited;
    if (!acquired) return nil;
    BG3MFXTexturePool *pool=[self poolLike:nil standIn:YES width:w height:h format:_pixelFormat];
    id<MTLTexture> texture=[pool acquire];
    if (!texture) { [_slots releaseSlot]; return nil; }
    objc_setAssociatedObject(texture,&standInTextureKey,self,OBJC_ASSOCIATION_ASSIGN);
    return [[BG3MFXStandInDrawable alloc] initWithTexture:texture pool:pool slots:_slots layer:layer
        presenter:self drawableID:++_drawableIDs];
}
- (BOOL)ownsTexture:(id<MTLTexture>)texture {
    return texture && objc_getAssociatedObject(texture,&standInTextureKey)==self;
}
- (id<MTLTexture>)generatedTargetLike:(id<MTLTexture>)texture {
    return [[self poolLike:texture standIn:NO width:texture.width height:texture.height format:texture.pixelFormat] acquire];
}
- (void)discardGeneratedTarget:(id<MTLTexture>)texture afterCommandBuffer:(id<MTLCommandBuffer>)buffer {
    BG3MFXTexturePool *pool;
    { std::lock_guard<std::mutex> lock(_mutex); pool=_generated; }
    [pool relinquish:texture afterCommandBuffer:buffer];
}
- (void)submitStandIn:(id<CAMetalDrawable>)drawable generated:(id<MTLTexture>)generated
          afterBuffer:(id<MTLCommandBuffer>)buffer interval:(double)interval {
    BG3MFXStandInDrawable *standIn=(BG3MFXStandInDrawable *)drawable;
    NSArray *handlers=[standIn takeSubmission];
    if (!handlers) return;
    // BG3's work time excludes time blocked on a stand-in we still held: it
    // shows whether BG3 could render faster than it does.
    double waited=_standInWait.exchange(0), cadence=interval;
    if (interval>0) interval=fmax(interval-waited,1.0/240);
    uint64_t value=0;
    if (buffer) { value=++_eventValue; [buffer encodeSignalEvent:_event value:value]; }
    BG3MFXTexturePool *generatedPool;
    { std::lock_guard<std::mutex> lock(_mutex); generatedPool=_generated; }
    PresentTask task{standIn.texture,generated,[standIn pool],generatedPool,standIn.layer,value,interval,cadence,handlers,standIn,
        CACurrentMediaTime(),(unsigned)[_slots inFlight]};
    std::lock_guard<std::mutex> lock(_mutex); task.queued+=(unsigned)_tasks.size();
    _tasks.push_back(std::move(task)); _wake.notify_all();
}
- (NSDictionary *)takeTimingSummary {
    unsigned tasks=_timedTasks.exchange(0);
    auto ms=[&](std::atomic<double> &total){ double value=total.exchange(0); return @(tasks ? value*1000/tasks : 0); };
    return @{@"tasks":@(tasks),@"vsyncOffTasks":@(_immediateTasks.exchange(0)),
        @"idleMs":ms(_idleTime),@"drawableWaitMs":ms(_drawableTime),@"bg3StandInWaitMs":ms(_standInTime)};
}
- (void)encodeCopy:(id<MTLTexture>)src to:(id<CAMetalDrawable>)drawable into:(id<MTLCommandBuffer>)cb {
    auto pass=[MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture=drawable.texture; pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    auto e=[cb renderCommandEncoderWithDescriptor:pass]; [e setRenderPipelineState:_copy]; [e setFragmentTexture:src atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
}
// Sleeps this thread until a CACurrentMediaTime value; both use the host clock.
static void waitUntilMediaTime(CFTimeInterval target) {
    static mach_timebase_info_data_t info; if (!info.denom) mach_timebase_info(&info);
    double delay=target-CACurrentMediaTime();
    if (delay>0) mach_wait_until(mach_absolute_time()+(uint64_t)(delay*1e9*info.denom/info.numer));
}
- (void)run {
    presentationThread=true;
    @autoreleasepool { NSThread.currentThread.name=@"BG3 Frame Generation Present"; }
    // Each rendered frame yields a generated and a real image that finish on the
    // GPU at about the same time. To look smooth they must reach the display
    // about half a frame interval apart, generated first.
    //
    // Vsync on, and vsync off while a frame spans at least two refreshes: each
    // image is presented with presentDrawable:afterMinimumDuration:, which
    // rounds up to whole refreshes. The frame's whole refreshes are split
    // between the generated image (the smaller half) and the real one, each
    // minimum set just under its refresh count. Using half the interval instead
    // rounded up past the frame time between about 30 and 60 fps: the presenter
    // fell behind, every buffer filled, and BG3 was dragged to about 31 fps with
    // about 110 ms from commit to display (live log and a standalone window
    // test at 120 Hz). Split by whole refreshes, the same test kept the frame
    // rate with 30-45 ms. Standalone at 120 Hz, two presents every 50 ms with
    // display sync off: 118 of 120 shown, every gap exactly 25 ms (plain
    // presents: 59 of 120 shown); live at about 20 rendered fps this was much
    // smoother than plain presents, which dropped 20-28% of generated images.
    //
    // Vsync off and faster: the minimum durations would cap the frame rate
    // (standalone at 125 pairs/s: exactly 120 images/s, falling behind), and
    // presenting both images at once shows the generated one for a sliver at
    // most (live: very jittery). This thread presents the generated image when
    // its copy is done, waits half an interval, then presents the real one,
    // tearing as vsync off does without Frame Generation. It skips the wait
    // when BG3's next frame is already queued so it never falls behind.
    //
    // On the paced paths the display limits the pairs, and extra stand-ins only
    // queue frames: BG3 gets one stand-in whatever its double/triple buffering.
    // Live at about 32 fps with BG3 triple-buffered: 47 ms from commit to
    // display with one stand-in, 107 ms with three, at the same frame rate
    // (without Frame Generation: 25 ms double, 50 ms triple). Standalone at
    // 90 fps, 120 Hz, vsync on: 65 ms -> 48 ms. Vsync off above half the
    // refresh rate keeps BG3's buffering: one stand-in cost frames there.
    //
    // Both copies are committed at once, and the stand-in is released when the
    // real copy completes, before any wait: BG3 never waits for this thread's
    // pacing. (Earlier designs that waited for display held stand-ins and slowed
    // BG3 to about 13 fps.)
    double smoothed=0, smoothedCadence=0; bool fast=false;
    // The display's refresh interval, read on the main thread from the layer's
    // window and refreshed periodically (the window can move between displays).
    auto refresh=std::make_shared<std::atomic<double>>(1.0/120);
    unsigned refreshCheck=0;
    for (;;) { @autoreleasepool {
        PresentTask task;
        CFTimeInterval idleStart=CACurrentMediaTime();
        { std::unique_lock<std::mutex> lock(_mutex); _wake.wait(lock,[&]{return _stop || !_tasks.empty();});
          if (_tasks.empty() && _stop) break; task=std::move(_tasks.front()); _tasks.pop_front(); }
        _idleTime=_idleTime+(CACurrentMediaTime()-idleStart); ++_timedTasks;
        // Times one blocking step into the given diagnostic total.
        auto timed=[](std::atomic<double> &total, auto &&step) {
            CFTimeInterval begin=CACurrentMediaTime(); auto result=step(); total=total+(CACurrentMediaTime()-begin); return result; };
        void (^failure)(NSError *)=self.failureHandler;
        void (^diagnostic)(BOOL,CFTimeInterval,CFTimeInterval,double)=self.presentedHandler;
        if (task.interval>0) {
            double sample=fmin(fmax(task.interval,1.0/240),0.1);
            smoothed=smoothed>0 ? smoothed*0.75+sample*0.25 : sample;
            sample=fmin(fmax(task.cadence,1.0/240),0.1);
            smoothedCadence=smoothedCadence>0 ? smoothedCadence*0.75+sample*0.25 : sample;
        }
        double work=smoothed>0 ? smoothed : 1.0/60;
        // Presentation follows BG3's actual frame interval.
        double interval=smoothedCadence>0 ? smoothedCadence : 1.0/60;
        if (refreshCheck++%120==0) {
            CAMetalLayer *layer=task.layer;
            dispatch_async(dispatch_get_main_queue(),^{
                id view=layer.delegate;
                NSInteger fps=[view isKindOfClass:NSView.class] ? ((NSView *)view).window.screen.maximumFramesPerSecond : 0;
                if (fps>0) refresh->store(1.0/fps);
            });
        }
        bool synced=task.layer.displaySyncEnabled;
        double frameRefresh=refresh->load();
        // Vsync off and BG3 able to exceed half the refresh rate: it is held at
        // about half the refresh rate while its work time is shorter. Work time
        // alone misleads with one stand-in: a GPU-bound BG3 at 32 fps spends
        // much of each frame waiting for it, so its work time looked fast and
        // the method and stand-in count flipped every few frames (live: 66 ms,
        // 2-11% of generated images dropped). Leave only once BG3 is clearly
        // slower than half the refresh rate.
        if (interval<2*frameRefresh*1.05 && work<2*frameRefresh*0.95) fast=true;
        else if (interval>2*frameRefresh*1.15) fast=false;
        BG3MFXPresentMethod method=synced ? BG3MFXPresentSynced : fast ? BG3MFXPresentSpaced : BG3MFXPresentMinimum;
        bool spaced=method==BG3MFXPresentSpaced;
        // Whole refreshes per frame (at least two), split between the generated
        // and the real image; each minimum just under its count of refreshes.
        // Rounded down with a margin, so a pair never takes a whole frame: BG3
        // can always speed up.
        int refreshes=std::max(2,(int)floor(interval/frameRefresh-0.05));
        double generatedMinimum=(refreshes/2)*frameRefresh-0.0005;
        double realMinimum=(refreshes-refreshes/2)*frameRefresh-0.0005;
        _singleStandIn=!spaced;
        BG3MFXFrameLogMethod(method);
        if (!synced) ++_immediateTasks;
        dispatch_semaphore_t generatedReady=spaced ? dispatch_semaphore_create(0) : nil;
        dispatch_semaphore_t realReady=spaced ? dispatch_semaphore_create(0) : nil;
        id<CAMetalDrawable> generatedDrawable=nil;
        if (task.generated) {
            generatedDrawable=timed(_drawableTime,[&]{ return [task.layer nextDrawable]; });
            if (generatedDrawable) {
                auto cb=[_queue commandBuffer];
                if (task.value) [cb encodeWaitForEvent:_event value:task.value];
                [self encodeCopy:task.generated to:generatedDrawable into:cb];
                [task.generatedPool relinquish:task.generated afterCommandBuffer:cb];
                [generatedDrawable addPresentedHandler:^(id<MTLDrawable> d){
                    BG3MFXFrameLogShown(YES,d.presentedTime); if (diagnostic) diagnostic(YES,d.presentedTime,0,interval); }];
                [cb addCompletedHandler:^(id<MTLCommandBuffer> b){
                    if (generatedReady) dispatch_semaphore_signal(generatedReady); if (b.error && failure) failure(b.error); }];
                if (!spaced) [cb presentDrawable:generatedDrawable afterMinimumDuration:generatedMinimum];
                [cb commit];
            } else {
                // BG3 may hold the remaining drawables briefly (for example while
                // leaving Frame Generation): skip the generated image, keep going.
                [task.generatedPool relinquish:task.generated];
                BG3MFXFrameLogShown(YES,-1); if (diagnostic) diagnostic(YES,-1,0,interval);
            }
        }
        dispatch_time_t limit=dispatch_time(DISPATCH_TIME_NOW,(int64_t)((interval+0.2)*NSEC_PER_SEC));
        id<CAMetalDrawable> drawable=timed(_drawableTime,[&]{ return [task.layer nextDrawable]; });
        if (!drawable) {
            // Dropping one frame is recoverable; never end the game for it.
            [task.realPool relinquish:task.real]; [_slots releaseSlot];
            BG3MFXFrameLogShown(NO,-1); if (diagnostic) diagnostic(NO,-1,0,interval);
            if (spaced && generatedDrawable && !dispatch_semaphore_wait(generatedReady,limit)) [generatedDrawable present];
            continue;
        }
        auto cb=[_queue commandBuffer];
        if (task.value) [cb encodeWaitForEvent:_event value:task.value];
        [self encodeCopy:task.real to:drawable into:cb];
        BG3MFXTexturePool *pool=task.realPool; id<MTLTexture> real=task.real; BG3MFXSlotGate *slots=_slots;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> b){
            [pool relinquish:real]; [slots releaseSlot]; if (realReady) dispatch_semaphore_signal(realReady);
            if (b.error && failure) failure(b.error); }];
        NSArray *handlers=task.handlers; __weak BG3MFXStandInDrawable *standIn=task.standIn;
        CFTimeInterval submitted=task.submitted; unsigned queued=task.queued;
        [drawable addPresentedHandler:^(id<MTLDrawable> d){
            BG3MFXFrameLogShown(NO,d.presentedTime);
            if (d.presentedTime>0) BG3MFXFrameLogLatency(d.presentedTime-submitted,queued); if (diagnostic) diagnostic(NO,d.presentedTime,0,interval);
            BG3MFXStandInDrawable *owner=standIn; owner.presentedTime=d.presentedTime;
            for (MTLDrawablePresentedHandler h in handlers) h(owner ?: d);
        }];
        if (!spaced) {
            // A frame without a generated image (menus, loading) shows at once.
            if (generatedDrawable) [cb presentDrawable:drawable afterMinimumDuration:realMinimum];
            else [cb presentDrawable:drawable];
            [cb commit];
        } else {
            [cb commit];
            auto backlog=[&]{ std::lock_guard<std::mutex> lock(_mutex); return !_tasks.empty(); };
            CFTimeInterval realAt=0;
            if (generatedDrawable && !dispatch_semaphore_wait(generatedReady,limit)) {
                [generatedDrawable present]; realAt=CACurrentMediaTime()+interval*0.5;
            }
            if (!dispatch_semaphore_wait(realReady,limit)) {
                if (realAt>0 && !backlog()) waitUntilMediaTime(realAt);
                [drawable present];
            }
        }
        if (generatedDrawable) _presentedPairs++;
    }}
}
@end

@implementation BG3MFXStandInDrawable {
    BG3MFXTexturePool *_pool;
    BG3MFXSlotGate *_slots;
    std::mutex _mutex;
    bool _submitted;
    NSMutableArray *_handlers;
}
- (instancetype)initWithTexture:(id<MTLTexture>)texture pool:(BG3MFXTexturePool *)pool slots:(BG3MFXSlotGate *)slots
                          layer:(CAMetalLayer *)layer presenter:(BG3MFXFramePresenter *)presenter drawableID:(NSUInteger)drawableID {
    if (!(self=[super init])) return nil;
    _texture=texture; _pool=pool; _slots=slots; _layer=layer; _presenter=presenter; _drawableID=drawableID;
    _handlers=[NSMutableArray array]; return self;
}
- (BG3MFXTexturePool *)pool { return _pool; }
// Hands the texture and its slot to the presenter exactly once.
- (NSArray *)takeSubmission {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_submitted) return nil;
    _submitted=true; return [_handlers copy];
}
- (void)dealloc {
    // BG3 dropped this stand-in without presenting it: recycle immediately.
    if (!_submitted) { [_pool relinquish:_texture]; [_slots releaseSlot]; }
}
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block {
    std::lock_guard<std::mutex> lock(_mutex); if (block) [_handlers addObject:[block copy]];
}
- (void)present { [_presenter submitStandIn:self generated:nil afterBuffer:nil interval:0]; }
- (void)presentAtTime:(CFTimeInterval)time { (void)time; [self present]; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)duration { (void)duration; [self present]; }
@end
