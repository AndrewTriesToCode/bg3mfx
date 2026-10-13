#import "NativeJitter.h"
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
extern "C" uint64_t BG3MFXNativeJitterSample(void *view, uint64_t original) {
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

// Mach-O load commands and declared sections own no bytes in this interval.
// The supported image has 49 KiB of zero header padding; use its second page
// rather than searching occupied address space for a new near allocation.
static uintptr_t headerPadding(const mach_header_64 *header, intptr_t slide, size_t bytes) {
    if (header->magic!=MH_MAGIC_64 || header->sizeofcmds>0x10000 || header->ncmds>256) return 0;
    uintptr_t base=reinterpret_cast<uintptr_t>(header);
    uintptr_t cursor=base+sizeof(*header), end=cursor+header->sizeofcmds, first=0;
    for (unsigned i=0;i<header->ncmds;++i) {
        if (cursor+sizeof(load_command)>end) return 0;
        auto *command=reinterpret_cast<const load_command *>(cursor);
        if (command->cmdsize<sizeof(load_command) || command->cmdsize>end-cursor) return 0;
        if (command->cmd==LC_SEGMENT_64) {
            if (command->cmdsize<sizeof(segment_command_64)) return 0;
            auto *segment=reinterpret_cast<const segment_command_64 *>(cursor);
            if (!strncmp(segment->segname,"__TEXT",16)) {
                if (segment->vmaddr+slide!=base || segment->fileoff ||
                    segment->nsects>(command->cmdsize-sizeof(*segment))/sizeof(section_64)) return 0;
                auto *sections=reinterpret_cast<const section_64 *>(segment+1);
                for (unsigned j=0;j<segment->nsects;++j) {
                    uintptr_t address=sections[j].addr+slide;
                    if (sections[j].size && (!first || address<first)) first=address;
                }
            }
        }
        cursor+=command->cmdsize;
    }
    if (cursor!=end) return 0;
    uintptr_t start=(end+vm_page_size-1)&~(uintptr_t(vm_page_size)-1);
    if (!first || start>=first || bytes>first-start) return 0;
    for (size_t i=0;i<bytes;++i) if (*reinterpret_cast<const uint8_t *>(start+i)) return 0;
    return start;
}
static bool branchReaches(uintptr_t from, uintptr_t to) {
    intptr_t delta=intptr_t(to)-intptr_t(from);
    return !(delta&3) && delta>=-0x08000000 && delta<0x08000000;
}
static void writeIsland(uintptr_t stub, uintptr_t wrapper, uintptr_t resume) {
    uint32_t code[]={0xa9bf47f0,0x100000d1,0x58000070,0xd61f0200,0xd503201f,0,0,
        0xa8c147f0,0x14000000};
    memcpy(code+5,&wrapper,8);
    code[8]|=uint32_t((intptr_t(resume)-intptr_t(stub+32))/4)&0x03ffffff;
    memcpy(reinterpret_cast<void *>(stub),code,sizeof code);
}

extern "C" void BG3MFXJitterProjection(), BG3MFXJitterCamera(), BG3MFXJitterVelocity();
BOOL BG3MFXInstallNativeJitter(intptr_t slide, void (*report)(NSDictionary *), NSError **error) {
    gameSlide=slide; reportEvent=report;
    auto fail=[&](NSString *message) { if(error) *error=[NSError errorWithDomain:@"BG3MFXNativeJitter" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; return NO; };
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
    uintptr_t island=headerPadding(header,slide,3*64);
    if (!island || header->sizeofcmds!=0x1b28 || island!=uintptr_t(0x100004000+slide))
        return fail(@"Unsupported native jitter header padding.");
    for (unsigned i=0;i<3;++i) {
        uintptr_t site=sites[i].address+slide, stub=island+i*64;
        if (!branchReaches(site,stub) || !branchReaches(stub+32,site+4))
            return fail(@"Native jitter branch islands are out of range.");
    }
    // Prepare every page before changing any bytes. A protection failure rolls
    // earlier pages back; the installed app on disk is never touched.
    std::map<uintptr_t,bool> pages;
    pages[island]=false;
    for (auto s:sites) pages[(s.address+slide)&~(uintptr_t(vm_page_size)-1)]=false;
    for (auto &page:pages) {
        if(vm_protect(mach_task_self(),page.first,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS) {
            for (auto previous:pages) if(previous.second)
                vm_protect(mach_task_self(),previous.first,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE);
            return fail(@"Could not install native jitter sampling hooks.");
        }
        page.second=true;
    }
    for (unsigned i=0;i<3;++i) {
        uintptr_t stub=island+i*64, site=sites[i].address+slide;
        // Preserve IP registers before entering the assembly wrapper. Its
        // return restores them and branches to the instruction after the load.
        writeIsland(stub,reinterpret_cast<uintptr_t>(sites[i].wrapper),site+4);
    }
    sys_icache_invalidate(reinterpret_cast<void *>(island),vm_page_size);
    for (unsigned i=0;i<3;++i) {
        uintptr_t site=sites[i].address+slide;
        intptr_t delta=intptr_t(island+i*64)-intptr_t(site);
        uint32_t branch=0x14000000|(uint32_t(delta/4)&0x03ffffff);
        memcpy(reinterpret_cast<void *>(site),&branch,4);
        sys_icache_invalidate(reinterpret_cast<void *>(site),4);
    }
    for (auto page:pages) if(vm_protect(mach_task_self(),page.first,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)!=KERN_SUCCESS)
        return fail(@"Could not restore native jitter code protection.");
    if(report) report(@{@"event":@"nativeJitterInstalled",@"phases":@[@14,@18,@24,@32]});
    return YES;
}
