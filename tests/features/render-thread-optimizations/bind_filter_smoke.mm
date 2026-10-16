#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>

#include "features/render-thread-optimizations/BindFilter.h"

static void check(bool condition, const char *message) {
    if (!condition) {
        std::fprintf(stderr, "bind-filter-smoke: %s\n", message);
        std::exit(1);
    }
}

static id<MTLTexture> fakeTexture(NSObject *object) {
    return (id<MTLTexture>)(id)object;
}

struct EmittedRun {
    NSRange range;
    std::vector<const void *> textures;
};

static void testPipelineAndSingleBinds() {
    NSObject *a = [NSObject new];
    NSObject *b = [NSObject new];
    id current = a;
    check(BG3MFXBindFilter::forwardPipeline(nil, nil), "nil pipeline must forward");
    check(BG3MFXBindFilter::forwardPipeline(current, nil), "pipeline unbind must forward");
    check(BG3MFXBindFilter::forwardPipeline(nil, current), "pipeline bind must forward");
    check(!BG3MFXBindFilter::forwardPipeline(current, current), "same pipeline should be filtered");
    check(BG3MFXBindFilter::forwardPipeline(current, b), "changed pipeline should forward");

    BG3MFXBindFilter filter;
    id<MTLTexture> ta = fakeTexture(a);
    id<MTLTexture> tb = fakeTexture(b);
    check(!filter.forwardTexture(nil, 0), "initial nil texture should be filtered");
    check(filter.forwardTexture(ta, 0), "first texture bind should forward");
    check(!filter.forwardTexture(ta, 0), "repeated texture bind should be filtered");
    check(filter.forwardTexture(nil, 0), "texture unbind should forward");
    check(!filter.forwardTexture(nil, 0), "repeated texture unbind should be filtered");
    check(filter.forwardTexture(tb, 64), "out-of-range single bind must forward");
}

static std::vector<EmittedRun> capture(BG3MFXBindFilter &filter,
                                      id<MTLTexture> const *textures,
                                      NSRange range) {
    std::vector<EmittedRun> runs;
    filter.forwardTextures(textures, range,
        [&](id<MTLTexture> const *pointer, NSRange emittedRange) {
            EmittedRun run{emittedRange, {}};
            for (NSUInteger i = 0; i < emittedRange.length; ++i)
                run.textures.push_back((__bridge const void *)pointer[i]);
            runs.push_back(std::move(run));
        });
    return runs;
}

static void checkRun(const EmittedRun &run, NSUInteger location,
                     NSUInteger length, const char *message) {
    check(run.range.location == location && run.range.length == length, message);
}

static void testBulkRunsAndMixedBinds() {
    NSObject *objects[3] = {[NSObject new], [NSObject new], [NSObject new]};
    id<MTLTexture> a = fakeTexture(objects[0]);
    id<MTLTexture> b = fakeTexture(objects[1]);
    id<MTLTexture> c = fakeTexture(objects[2]);
    BG3MFXBindFilter filter;

    id<MTLTexture> initial[8] = {a, a, a, a, a, a, a, a};
    auto runs = capture(filter, initial, NSMakeRange(0, 8));
    check(runs.size() == 1, "initial bind should emit one bulk run");
    checkRun(runs[0], 0, 8, "initial run should preserve the requested range");
    check(capture(filter, initial, NSMakeRange(0, 8)).empty(),
          "repeated bulk bind should emit nothing");

    check(filter.forwardTexture(b, 2), "single bind should update bulk cache");
    id<MTLTexture> mixed[4] = {a, a, b, a};
    check(capture(filter, mixed, NSMakeRange(0, 4)).empty(),
          "bulk bind should observe a preceding single-slot bind");

    id<MTLTexture> closeChanges[8] = {b, a, a, c, a, a, a, a};
    runs = capture(filter, closeChanges, NSMakeRange(0, 8));
    check(runs.size() == 1, "changes separated by two unchanged slots should coalesce");
    checkRun(runs[0], 0, 4, "coalesced run should include the two-slot gap");
    check(runs[0].textures.size() == 4 && runs[0].textures[0] == (__bridge const void *)b &&
          runs[0].textures[3] == (__bridge const void *)c,
          "coalesced run should pass the matching texture slice");

    id<MTLTexture> farChanges[8] = {a, a, a, a, b, a, a, a};
    // Reset slots zero and four to texture a before changing both positions.
    id<MTLTexture> reset[8] = {a, a, a, a, a, a, a, a};
    capture(filter, reset, NSMakeRange(0, 8));
    runs = capture(filter, farChanges, NSMakeRange(0, 8));
    check(runs.size() == 1, "one changed slot should emit one run");
    checkRun(runs[0], 4, 1, "changed slot should emit its narrow run");

    // Two changes with three unchanged slots between them must split.
    capture(filter, reset, NSMakeRange(0, 8));
    id<MTLTexture> split[8] = {b, a, a, a, a, c, a, a};
    runs = capture(filter, split, NSMakeRange(0, 8));
    check(runs.size() == 2, "changes separated by three unchanged slots should split");
    checkRun(runs[0], 0, 1, "first split run should cover the first change");
    checkRun(runs[1], 5, 1, "second split run should cover the second change");

    id<MTLTexture> unbind[1] = {nil};
    check(filter.forwardTexture(a, 63), "seed final slot before edge check");
    runs = capture(filter, unbind, NSMakeRange(63, 1));
    check(runs.size() == 1, "last valid slot should be filtered and updated");
    checkRun(runs[0], 63, 1, "last valid slot should use a one-slot run");
    check(capture(filter, unbind, NSMakeRange(64, 0)).empty(),
          "empty range at cache boundary should be accepted");
}

static void testOutOfBoundsFallback() {
    NSObject *aObject = [NSObject new];
    id<MTLTexture> a = fakeTexture(aObject);
    BG3MFXBindFilter filter;
    id<MTLTexture> textures[2] = {a, nil};
    auto runs = capture(filter, textures, NSMakeRange(63, 2));
    check(runs.size() == 1, "range crossing cache boundary should forward once");
    checkRun(runs[0], 63, 2, "boundary fallback should preserve the full range");
    check(filter.fragmentTexture[63] == nil,
          "out-of-bounds fallback must not partially update the cache");

    runs = capture(filter, textures, NSMakeRange(NSUIntegerMax, 2));
    check(runs.size() == 1, "overflowing range should forward once");
    check(runs[0].range.location == NSUIntegerMax && runs[0].range.length == 2,
          "overflow fallback should preserve the original range");
}

int main() {
    @autoreleasepool {
        testPipelineAndSingleBinds();
        testBulkRunsAndMixedBinds();
        testOutOfBoundsFallback();
        std::puts("bind-filter-smoke: ok");
    }
    return 0;
}
