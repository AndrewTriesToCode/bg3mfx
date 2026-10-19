#include "common/native/CodePatch.h"
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <cstring>
#include <set>

// Mach-O load commands and declared sections own no bytes in this interval.
// The supported image has 49 KiB of zero header padding; use its second page
// rather than searching occupied address space for a new near allocation.
uintptr_t BG3MFXHeaderPadding(const mach_header_64 *header, intptr_t slide, size_t bytes) {
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

bool BG3MFXBranchReaches(uintptr_t from, uintptr_t to) {
    intptr_t delta=intptr_t(to)-intptr_t(from);
    return !(delta&3) && delta>=-0x08000000 && delta<0x08000000;
}

uint32_t BG3MFXBranch(uintptr_t from, uintptr_t to) {
    return 0x14000000|(uint32_t((intptr_t(to)-intptr_t(from))/4)&0x03ffffff);
}

BG3MFXCodePatchResult BG3MFXPatchCode(const std::vector<std::pair<uintptr_t, size_t>> &ranges,
    const std::function<void()> &write) {
    const uintptr_t mask=~(uintptr_t(vm_page_size)-1);
    std::set<uintptr_t> pages;
    for (auto &range:ranges)
        for (uintptr_t page=range.first&mask; page<range.first+range.second; page+=vm_page_size) pages.insert(page);
    // Prepare every page before changing any bytes; a failure rolls back.
    std::vector<uintptr_t> writable;
    for (uintptr_t page:pages) {
        if (vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS) {
            for (uintptr_t previous:writable)
                vm_protect(mach_task_self(),previous,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE);
            return BG3MFXCodePatchResult::NotWritable;
        }
        writable.push_back(page);
    }
    write();
    for (auto &range:ranges) sys_icache_invalidate(reinterpret_cast<void *>(range.first),range.second);
    // The bytes are already written and cannot be safely unwritten, and a page
    // left writable is not executable: retry before reporting failure.
    bool restored=true;
    for (uintptr_t page:pages) {
        bool pageRestored=false;
        for (int attempt=0; attempt<3 && !pageRestored; ++attempt)
            pageRestored=vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)==KERN_SUCCESS;
        restored&=pageRestored;
    }
    return restored ? BG3MFXCodePatchResult::Patched : BG3MFXCodePatchResult::NotRestored;
}
