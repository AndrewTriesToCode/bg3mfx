#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "common/gpu/MetalFXPipeline.h"

// Owns interpolation and dual presentation; does not discover BG3 resources.
@interface BG3MFXFrameInterpolation : NSObject
@property(nonatomic, readonly) BOOL usesMetal4;
// Inputs read in place rather than converted into pooled copies.
@property(nonatomic, readonly) BOOL directColor, directDepth, directMotion;
@property(nonatomic, copy) void (^failureHandler)(NSError *);
- (instancetype)initWithDevice:(id<MTLDevice>)device width:(NSUInteger)width height:(NSUInteger)height
                   outputWidth:(NSUInteger)outWidth outputHeight:(NSUInteger)outHeight error:(NSError **)error;
// Configured for these textures' sizes, formats and usages: each is read in
// place when MetalFX accepts it, otherwise converted per frame.
- (instancetype)initWithDevice:(id<MTLDevice>)device scene:(id<MTLTexture>)scene depth:(id<MTLTexture>)depth
                        motion:(id<MTLTexture>)motion error:(NSError **)error;
- (id<MTLTexture>)encodeScene:(id<MTLTexture>)scene depth:(id<MTLTexture>)depth motion:(id<MTLTexture>)motion
                      camera:(NSData *)camera parameters:(BG3MFXFrameParameters)p deltaTime:(float)delta
               commandBuffer:(id<MTLCommandBuffer>)buffer error:(NSError **)error;
- (void)resetHistory;
@end

// Frame Generation presentation, modelled on Apple's present thread. While it is
// active BG3 receives stand-in drawables backed by pooled textures; BG3 renders
// and "presents" into them as usual. A worker thread then acquires real
// drawables itself and shows the generated image, then the real image half a
// frame interval after the generated one was actually displayed. GPU ordering
// uses a shared event signalled at the end of BG3's presenting command buffer.
@interface BG3MFXFramePresenter : NSObject
// Pairs whose generated and real images were both submitted for presentation.
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
@property(atomic, readonly) NSUInteger presentedPairs;
#endif
@property(nonatomic, readonly) MTLPixelFormat pixelFormat;
// Diagnostics: called when each worker drawable is shown (presentedTime > 0),
// dropped (0), or skipped because no drawable was available (-1). `target` is
// the requested display time (0 for as soon as possible).
#ifndef BG3MFX_NO_TRACE
@property(atomic, copy) void (^presentedHandler)(BOOL generated, CFTimeInterval presentedTime,
                                                  CFTimeInterval target, double interval);
#endif
@property(atomic, copy) void (^failureHandler)(NSError *);
- (instancetype)initWithDevice:(id<MTLDevice>)device format:(MTLPixelFormat)format error:(NSError **)error;
// Diagnostics: average milliseconds per frame the worker spent idle, waiting
// for drawables, waiting for GPU copies, and sleeping for pacing, and how long
// BG3 waited for a free stand-in, since the previous call.
#ifndef BG3MFX_NO_TRACE
- (NSDictionary *)takeTimingSummary;
#endif
// True on the presenter's own thread, whose drawable requests must stay real.
+ (BOOL)isPresentationThread;
// The presenter that owns `drawable` if it is a stand-in, otherwise nil.
+ (BG3MFXFramePresenter *)presenterForStandIn:(id)drawable;
// Like -[CAMetalLayer nextDrawable]: blocks (up to one second) while `limit`
// stand-ins (BG3's buffering, clamped to 2...3) are still waiting to be shown,
// then returns nil.
- (id<CAMetalDrawable>)nextStandInForLayer:(CAMetalLayer *)layer limit:(NSUInteger)limit;
- (BOOL)ownsTexture:(id<MTLTexture>)texture;
// A pooled target matching `texture` for composing the generated image. It is
// recycled after presentation, or by -discardGeneratedTarget:afterCommandBuffer:.
- (id<MTLTexture>)generatedTargetLike:(id<MTLTexture>)texture;
- (void)discardGeneratedTarget:(id<MTLTexture>)texture afterCommandBuffer:(id<MTLCommandBuffer>)buffer;
// Call before BG3 commits the buffer that presents `standIn`. `generated` is
// shown first when present. A nil buffer presents without GPU ordering.
- (void)submitStandIn:(id<CAMetalDrawable>)standIn generated:(id<MTLTexture>)generated
          afterBuffer:(id<MTLCommandBuffer>)buffer interval:(double)interval;
@end
