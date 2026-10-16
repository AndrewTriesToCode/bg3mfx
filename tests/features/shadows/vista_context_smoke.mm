// Synthetic ARM64 call-site fixture: no BG3 code or assets are executed.
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <dlfcn.h>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <initializer_list>

using Submit=uintptr_t(*)(void *,uintptr_t,void *);
using Replay=uintptr_t(*)(void *,uintptr_t,void *,Submit);
static bool (*active)();
static Replay replay;
static bool argumentsOK;
static uintptr_t nested(void *commands,uintptr_t flags,void *fence) {
    argumentsOK &= active() && commands==reinterpret_cast<void *>(0x12345000) &&
        flags==0xabcde123 && fence==reinterpret_cast<void *>(0x98765000);
    return uintptr_t(commands)^flags^uintptr_t(fence);
}
static uintptr_t target(void *commands,uintptr_t flags,void *fence) {
    argumentsOK=active();
    uintptr_t result=replay(commands,flags,fence,nested);
    argumentsOK &= active(); // Nested replay must restore the outer scope.
    return result;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if (argc!=2) return 2;
        void *runtime=dlopen(argv[1],RTLD_NOW);
        if (!runtime) { fprintf(stderr,"%s\n",dlerror()); return 3; }
        auto install=reinterpret_cast<BOOL(*)(intptr_t,NSError **)>(dlsym(runtime,
            "_Z25BG3MFXInstallVistaContextlPU15__autoreleasingP7NSError"));
        active=reinterpret_cast<bool(*)()>(dlsym(runtime,"_Z23BG3MFXVistaReplayActivev"));
        replay=reinterpret_cast<Replay>(dlsym(runtime,"BG3MFXReplayVista"));
        if (!install || !active || !replay || active()) return 4;
        // Reserve a sparse region matching relative native addresses, with only
        // the fixture pages populated. The installer applies real code protections.
        vm_address_t base=0; constexpr size_t size=0x6430000;
        if (vm_allocate(mach_task_self(),&base,size,VM_FLAGS_ANYWHERE)!=KERN_SUCCESS) return 5;
        intptr_t slide=base-0x100000000ULL;
        uintptr_t site=base+0x5d41154, native=base+0x6429f40, island=base+0x4b00;
        uint32_t context[]={0xf9400668,0xf9400508,0xb9403908,0x35000088,0xf950d268,0x9100c100,0x941ba37b};
        memcpy(reinterpret_cast<void *>(site-24),context,sizeof context);
        auto put=[](uintptr_t address,uint32_t instruction) { memcpy(reinterpret_cast<void *>(address),&instruction,4); };
        put(native,0xd106c3ff);
        NSError *error=nil;
        // Both instruction guards and occupied-island rejection must leave the BL intact.
        for (uintptr_t address : {site-24,site-20,site-16,site-12,site-8,site-4,site,native,island}) {
            uint32_t old=*reinterpret_cast<uint32_t *>(address); put(address,old^1);
            if (install(slide,&error) || !error || *reinterpret_cast<uint32_t *>(site)!=(address==site ? (context[6]^1) : context[6])) return 6;
            put(address,old); error=nil;
        }
        // Restore the synthetic stack allocation before tail-calling our C++ target.
        put(native+4,0x9106c3ff); put(native+8,0x58000050); put(native+12,0xd61f0200);
        uintptr_t callback=reinterpret_cast<uintptr_t>(target);
        memcpy(reinterpret_cast<void *>(native+16),&callback,8);
        // A caller saves LR, branches to the guarded BL, then restores LR after it.
        uintptr_t caller=base+0x5d41000;
        put(caller,0xa9bf7bfd);
        put(caller+4,0x14000000|(uint32_t((site-(caller+4))/4)&0x03ffffff));
        put(site+4,0xa8c17bfd); put(site+8,0xd65f03c0);
        sys_icache_invalidate(reinterpret_cast<void *>(native),24);
        uintptr_t page=native&~(uintptr_t(vm_page_size)-1);
        if (vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)!=KERN_SUCCESS) return 7;
        if (!install(slide,&error)) { fprintf(stderr,"%s\n",error.description.UTF8String); return 8; }
        uint32_t expected=0x94000000|(uint32_t((intptr_t(island)-intptr_t(site))/4)&0x03ffffff);
        if (*reinterpret_cast<uint32_t *>(site)!=expected) return 9;
        auto call=reinterpret_cast<Submit>(caller);
        uintptr_t result=call(reinterpret_cast<void *>(0x12345000),0xabcde123,reinterpret_cast<void *>(0x98765000));
        if (!argumentsOK || active() || result!=(0x12345000ULL^0xabcde123ULL^0x98765000ULL)) return 10;
        vm_deallocate(mach_task_self(),base,size);
        puts("Vista context: guarded ARM64 branch, arguments/result, nested scope restoration passed");
    }
}
