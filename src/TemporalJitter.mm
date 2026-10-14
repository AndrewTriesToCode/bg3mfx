#import "TemporalJitter.h"
#include "CodePatch.h"
#import "NativeMenu.h"
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <libkern/OSCacheControl.h>
#include <array>
#include <cstring>
#include <mutex>
#include <cmath>
#include <map>

namespace {
intptr_t gameSlide;
void (*reportEvent)(NSDictionary *);
#ifdef BG3MFX_JITTER_TEST
void *testSettings;
#endif
template<class T> T read(const void *p, size_t offset) {
    T value; memcpy(&value, static_cast<const char *>(p)+offset, sizeof value); return value;
}
float halton(unsigned index, unsigned base) {
    float value=0, weight=1;
    while (index) { weight/=base; value+=weight*(index%base); index/=base; }
    return value;
}
// Inspect the native view's actual enabled FSR step, not a size heuristic.
bool upscaledView(void *view) {
    void **stages=read<void **>(view,0x20);
    unsigned count=read<unsigned>(view,0x2c);
    if (!stages || count>256) return false;
    for (unsigned i=0;i<count;++i) {
        void *stage=stages[i];
        if (!stage || read<uintptr_t>(stage,0)!=uintptr_t(0x10886b5a0+gameSlide) || !read<uint8_t>(stage,0x18)) continue;
        void **steps=read<void **>(stage,0x2150);
        unsigned n=read<unsigned>(stage,0x215c);
        if (!steps || n>256) return false;
        for (unsigned j=0;j<n;++j)
            if (steps[j] && read<uintptr_t>(steps[j],0)==uintptr_t(0x10886c380+gameSlide))
                return read<uint8_t>(steps[j],0x18)!=0;
    }
    return false;
}
struct Choice { void *frame=nullptr; void *camera=nullptr; uint64_t size=0; uint32_t index=0; unsigned phases=8; bool valid=false; };
// A view may ask for its projection several times in one frame. Freeze the
// choice for that native frame, including a menu switch during CPU recording.
std::mutex &lock() { static auto *m=new std::mutex; return *m; }
std::map<void *,Choice> &choices() { static auto *m=new std::map<void *,Choice>; return *m; }
}
extern "C" uint64_t BG3MFXTemporalJitterSample(void *view, uint64_t original) {
    if (!view) return original;
    void *frame=read<void *>(view,0x2050), *camera=read<void *>(view,0x21d8);
    if (!frame || !camera) return original;
    uint32_t index=read<uint32_t>(frame,8)+read<uint32_t>(frame,12);
    uint64_t size=read<uint64_t>(view,0x2180);
    std::lock_guard<std::mutex> hold(lock());
    Choice &c=choices()[view];
    if (!c.valid || c.frame!=frame || c.camera!=camera || c.index!=index || c.size!=size) {
        c={frame,camera,size,index,8,true};
        if (BG3MFXSelectedScalingMode()==3 && !read<uint8_t>(camera,0xa) && upscaledView(view)) {
            #ifdef BG3MFX_JITTER_TEST
            void *settings=testSettings;
#else
            void *settings=*reinterpret_cast<void **>(0x108af4118+gameSlide);
#endif
            unsigned quality=settings ? read<uint8_t>(settings,0x98) : 2;
            static const unsigned phases[]={14,18,24,32};
            if (quality<4) c.phases=phases[quality];
        }
#ifndef BG3MFX_NO_TRACE
        if (reportEvent) reportEvent(@{@"event":@"nativeTemporalJitter",@"view":@((uintptr_t)view),
            @"frame":@(index),@"phases":@(c.phases),@"sample":@[@(halton(index%c.phases+1,2)-0.5f),@(halton(index%c.phases+1,3)-0.5f)]});
#endif
        // Native views are recreated on transitions; bound CPU bookkeeping.
        if (choices().size()>64) { Choice saved=c; choices().clear(); choices()[view]=saved; }
    }
    unsigned phases=choices()[view].phases;
    if (phases==8) return original;
    float sample[2]={halton(index%phases+1,2),halton(index%phases+1,3)};
    uint64_t bits; memcpy(&bits,sample,8); return bits;
}

static void writeIsland(uintptr_t stub, uintptr_t wrapper, uintptr_t resume) {
    uint32_t code[]={0xa9bf47f0,0x100000d1,0x58000070,0xd61f0200,0xd503201f,0,0,
        0xa8c147f0,0x14000000};
    memcpy(code+5,&wrapper,8);
    code[8]|=uint32_t((intptr_t(resume)-intptr_t(stub+32))/4)&0x03ffffff;
    memcpy(reinterpret_cast<void *>(stub),code,sizeof code);
}

extern "C" void BG3MFXJitterProjection(), BG3MFXJitterCamera(), BG3MFXJitterVelocity();
BOOL BG3MFXInstallTemporalJitter(intptr_t slide, void (*report)(NSDictionary *), NSError **error) {
    gameSlide=slide; reportEvent=report;
    auto fail=[&](NSString *message) { if(error) *error=[NSError errorWithDomain:@"BG3MFXTemporalJitter" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; return NO; };
    struct Site { uintptr_t address; uint32_t load; void (*wrapper)(); };
    const Site sites[]={{0x105f8bdc8,0xfc685923,BG3MFXJitterProjection},
        {0x105f8af84,0xfc685921,BG3MFXJitterCamera},{0x106253924,0xfc685920,BG3MFXJitterVelocity}};
    // NativeMenu has already checked the executable UUID. Validate all new
    // sampling sites and the classifier's vtable methods before any mutation.
    for (auto s:sites) if (*reinterpret_cast<uint32_t *>(s.address+slide)!=s.load)
        return fail(@"Unsupported native jitter sampling instructions.");
    if (*reinterpret_cast<uintptr_t *>(0x10886b5a0+slide+0x10)!=uintptr_t(0x10608f590+slide))
        return fail(@"Unsupported native post-processing view layout.");
    auto *header=reinterpret_cast<const mach_header_64 *>(0x100000000+slide);
    uintptr_t island=BG3MFXHeaderPadding(header,slide,3*64);
    if (!island || header->sizeofcmds!=0x1b28 || island!=uintptr_t(0x100004000+slide))
        return fail(@"Unsupported native jitter header padding.");
    std::vector<std::pair<uintptr_t,size_t>> ranges={{island,vm_page_size}};
    for (unsigned i=0;i<3;++i) {
        uintptr_t site=sites[i].address+slide, stub=island+i*64;
        if (!BG3MFXBranchReaches(site,stub) || !BG3MFXBranchReaches(stub+32,site+4))
            return fail(@"Native jitter branch islands are out of range.");
        ranges.push_back({site,4});
    }
    auto result=BG3MFXPatchCode(ranges,[&] {
        for (unsigned i=0;i<3;++i) {
            uintptr_t stub=island+i*64, site=sites[i].address+slide;
            // Preserve IP registers before entering the assembly wrapper. Its
            // return restores them and branches to the instruction after the load.
            writeIsland(stub,reinterpret_cast<uintptr_t>(sites[i].wrapper),site+4);
        }
        // Islands are complete before any site branches to them.
        sys_icache_invalidate(reinterpret_cast<void *>(island),vm_page_size);
        for (unsigned i=0;i<3;++i) {
            uintptr_t site=sites[i].address+slide;
            uint32_t branch=BG3MFXBranch(site,island+i*64);
            memcpy(reinterpret_cast<void *>(site),&branch,4);
        }
    });
    if (result==BG3MFXCodePatchResult::NotWritable) return fail(@"Could not install native jitter sampling hooks.");
    if (result==BG3MFXCodePatchResult::NotRestored) return fail(@"Could not restore native jitter code protection.");
    if(report) report(@{@"event":@"temporalJitterInstalled",@"phases":@[@14,@18,@24,@32]});
    return YES;
}
