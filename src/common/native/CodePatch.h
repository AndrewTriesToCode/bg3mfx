#pragma once
// In-memory patching of BG3's executable code. The installed app on disk is
// never modified; callers validate the executable UUID and the exact
// instructions they replace before patching.
#include <cstddef>
#include <cstdint>
#include <functional>
#include <utility>
#include <vector>
#include <mach-o/loader.h>

// Zero bytes between the end of the load commands and the image's first
// __TEXT section, page-aligned, if at least `bytes` are available. Used for
// branch islands without searching address space for a near allocation.
uintptr_t BG3MFXHeaderPadding(const mach_header_64 *header, intptr_t slide, size_t bytes);
// Whether an ARM64 B/BL at `from` can reach `to`.
bool BG3MFXBranchReaches(uintptr_t from, uintptr_t to);

enum class BG3MFXCodePatchResult { Patched, NotWritable, NotRestored };
// Makes every page of `ranges` (address, length) writable before any write,
// runs `write`, flushes the instruction cache for each range, and restores
// read+execute. If a page cannot be made writable, nothing is written.
// NotRestored means the code was written but a page is still not executable.
BG3MFXCodePatchResult BG3MFXPatchCode(const std::vector<std::pair<uintptr_t, size_t>> &ranges,
    const std::function<void()> &write);
// Replaces one pointer in read-only data, such as a vtable entry in
// __DATA_CONST: makes its page writable (copy-on-write), writes, and makes it
// read-only again. false if the page could not be made writable (nothing was
// written); *restored says whether the page is read-only again.
bool BG3MFXPatchPointer(void **slot, void *value, bool *restored);
// Encodes an ARM64 B from `from` to `to` (which must be in range).
uint32_t BG3MFXBranch(uintptr_t from, uintptr_t to);
// Whether an ARM64 instruction runs the same at another address: not
// PC-relative (B, BL, B.cond, CBZ/CBNZ, TBZ/TBNZ, ADR/ADRP, literal loads).
bool BG3MFXRelocatable(uint32_t word);
// An entry hook replaces a function's first instruction with `b island`. The
// island, 8-byte aligned, jumps to `hook` through x16 (LR still the caller's);
// at BG3MFXEntryOriginalOffset it runs the moved instruction and branches to
// the function's second, so island + BG3MFXEntryOriginalOffset is the original
// function. `first` must be relocatable, and both branches in range.
inline constexpr size_t BG3MFXEntryIslandBytes = 24, BG3MFXEntryOriginalOffset = 16;
void BG3MFXEncodeEntryIsland(uint32_t words[BG3MFXEntryIslandBytes / 4], uintptr_t island, uintptr_t function,
    uint32_t first, uintptr_t hook);
