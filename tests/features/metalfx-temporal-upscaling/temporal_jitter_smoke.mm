// Test-only native-layout fixtures; no BG3 code or assets are linked.
#define BG3MFX_JITTER_TEST 1
#import "features/metalfx-temporal-upscaling/TemporalJitter.mm"
#import "common/native/CodePatch.mm"
#include <cstdio>
#include <vector>
static int mode=3;
int BG3MFXSelectedScalingMode(void) { return mode; }
extern "C" void BG3MFXTestJitterProjection(void *,void *,void *,void *);
extern "C" void BG3MFXTestJitterCamera(void *,void *,void *,void *);
extern "C" void BG3MFXTestJitterVelocity(void *,void *,void *,void *);
extern "C" void BG3MFXTestJitterProjectionResume(), BG3MFXTestJitterCameraResume(), BG3MFXTestJitterVelocityResume();
template<class T> void put(std::vector<uint8_t> &v,size_t offset,T x) { memcpy(v.data()+offset,&x,sizeof x); }
int main() {
    std::vector<uint8_t> view(0x3000), frame(32), camera(0x200), stage(0x2200), step(0x100), settings(0x100), velocity(32);
    void *stages[]={stage.data()}, *steps[]={step.data()};
    put(view,0x20,stages); put(view,0x2c,uint32_t(1));
    put(view,0x2050,frame.data()); put(view,0x21d8,camera.data()); put(view,0x2180,uint64_t(256)|uint64_t(144)<<32);
    put(stage,0,uintptr_t(0x10886b5a0)); put(stage,0x18,uint8_t(1));
    put(stage,0x2150,steps); put(stage,0x215c,uint32_t(1));
    put(step,0,uintptr_t(0x10886c380)); put(step,0x18,uint8_t(1));
    put(velocity,8,view.data()); testSettings=settings.data();
    auto bits=[](float x,float y) { float f[]={x,y}; uint64_t v;memcpy(&v,f,8);return v; };
    auto check=[&](unsigned phases,bool changed) {
        choices().clear();
        for (unsigned i=0;i<phases*3;++i) {
            put(frame,8,uint32_t(i));
            uint64_t native=bits(halton(i%8+1,2),halton(i%8+1,3));
            uint64_t expected=changed ? bits(halton(i%phases+1,2),halton(i%phases+1,3)) : native;
            if(BG3MFXTemporalJitterSample(view.data(),native)!=expected) return false;
            // A same-frame menu/quality change cannot split projection and motion.
            int saved=mode;mode=0;
            if(BG3MFXTemporalJitterSample(view.data(),native)!=expected) return false;
            mode=saved;
        }
        return true;
    };
    unsigned counts[]={14,18,24,32};
    for(unsigned q=0;q<4;++q) { put(settings,0x98,uint8_t(q)); if(!check(counts[q],true)) return 1; }
    for(mode=0;mode<3;++mode) if(!check(8,false)) return 2;
    mode=3;put(step,0x18,uint8_t(0)); if(!check(8,false)) return 3;
    put(step,0x18,uint8_t(1));put(stage,0x18,uint8_t(0)); if(!check(8,false)) return 4;
    put(stage,0x18,uint8_t(1));put(camera,0xa,uint8_t(1)); if(!check(8,false)) return 5;
    put(camera,0xa,uint8_t(0));
    put(settings,0x98,uint8_t(3));put(frame,8,uint32_t(17));choices().clear();
    uint64_t native=bits(halton(2,2),halton(2,3));
    // Use only zero bytes between complete Mach-O commands and the first
    // declared section. Reject occupied padding, insufficient space and malformed commands.
    vm_address_t fixture=0;
    if(vm_allocate(mach_task_self(),&fixture,vm_page_size*3,VM_FLAGS_ANYWHERE)!=KERN_SUCCESS) return 9;
    auto *header=reinterpret_cast<mach_header_64 *>(fixture);
    header->magic=MH_MAGIC_64; header->ncmds=1;
    header->sizeofcmds=sizeof(segment_command_64)+sizeof(section_64);
    auto *segment=reinterpret_cast<segment_command_64 *>(header+1);
    segment->cmd=LC_SEGMENT_64;segment->cmdsize=header->sizeofcmds;
    strcpy(segment->segname,"__TEXT");segment->vmaddr=fixture;segment->nsects=1;
    auto *section=reinterpret_cast<section_64 *>(segment+1);
    section->addr=fixture+vm_page_size*2;section->size=16;
    uintptr_t padding=fixture+vm_page_size;
    if(BG3MFXHeaderPadding(header,0,192)!=padding) return 10;
    *reinterpret_cast<uint8_t *>(padding)=1;
    if(BG3MFXHeaderPadding(header,0,192)) return 11;
    *reinterpret_cast<uint8_t *>(padding)=0;
    section->addr=padding+128;
    if(BG3MFXHeaderPadding(header,0,192)) return 12;
    section->addr=fixture+vm_page_size*2;segment->cmdsize=8;
    if(BG3MFXHeaderPadding(header,0,192)) return 13;
    vm_deallocate(mach_task_self(),fixture,vm_page_size*3);
    if(!BG3MFXBranchReaches(0x20000000,0x18000000) || BG3MFXBranchReaches(0x20000000,0x28000000) ||
       BG3MFXBranchReaches(0x20000000,0x20000001)) return 14;
    // Independent executable test islands have no dependency on BG3 mappings.
    auto allocateTestIsland=[](uintptr_t near) {
        near &= ~(uintptr_t(vm_page_size)-1);
        for (uintptr_t delta=vm_page_size;delta<0x07000000;delta+=vm_page_size)
            for (uintptr_t candidate : {near-delta,near+delta}) {
                vm_address_t address=candidate;
                if(vm_allocate(mach_task_self(),&address,vm_page_size,VM_FLAGS_FIXED)==KERN_SUCCESS) return address;
            }
        return vm_address_t(0);
    };
    auto run=[&](void(*test)(void *,void *,void *,void *),void (*resume)(),void (*wrapper)(),void *context,unsigned destination) {
        uintptr_t returnAddress=reinterpret_cast<uintptr_t>(resume);
        vm_address_t island=allocateTestIsland(returnAddress);
        if(!island) return false;
        writeIsland(island,reinterpret_cast<uintptr_t>(wrapper),returnAddress);
        sys_icache_invalidate(reinterpret_cast<void *>(island),vm_page_size);
        if(vm_protect(mach_task_self(),island,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)!=KERN_SUCCESS) return false;
        alignas(16) std::array<uint8_t,1600> snapshot{};
        test(snapshot.data(),context,&native,reinterpret_cast<void *>(island));
        vm_deallocate(mach_task_self(),island,vm_page_size);
        // Both snapshots use 256 bytes for GPRs/flags then 512 for full SIMD.
        for(unsigned i=0;i<31;++i) if(memcmp(snapshot.data()+i*8,snapshot.data()+800+i*8,8)) return false;
        if(memcmp(snapshot.data()+248,snapshot.data()+800+248,8)) return false;
        for(unsigned i=0;i<32;++i) {
            uint8_t *before=snapshot.data()+256+i*16, *after=snapshot.data()+800+256+i*16;
            if(i!=destination) { if(memcmp(before,after,16)) return false; }
            else {
                uint64_t expected=bits(halton(18,2),halton(18,3));
                uint64_t zero=0;
                if(memcmp(after,&expected,8)||memcmp(after+8,&zero,8)) return false;
            }
        }
        return true;
    };
    if(!run(BG3MFXTestJitterProjection,BG3MFXTestJitterProjectionResume,BG3MFXJitterProjection,view.data(),3)) return 6;
    if(!run(BG3MFXTestJitterCamera,BG3MFXTestJitterCameraResume,BG3MFXJitterCamera,view.data(),1)) return 7;
    if(!run(BG3MFXTestJitterVelocity,BG3MFXTestJitterVelocityResume,BG3MFXJitterVelocity,velocity.data(),0)) return 8;
    printf("Native jitter: 14/18/24/32-phase wrap, same-frame consistency, native/auxiliary isolation, and all three ARM64 register-preserving wrappers passed.\n");
}
