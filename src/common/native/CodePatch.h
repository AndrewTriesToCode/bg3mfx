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
// Encodes an ARM64 B from `from` to `to` (which must be in range).
uint32_t BG3MFXBranch(uintptr_t from, uintptr_t to);
