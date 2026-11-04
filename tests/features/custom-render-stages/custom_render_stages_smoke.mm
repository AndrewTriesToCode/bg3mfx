// Test-only fixtures for the per-view stage-list shim; no BG3 code or assets
// are linked. The packs, the Span overload and the views are stand-ins.
#import "features/custom-render-stages/CustomRenderStages.mm"
#import "common/native/CodePatch.mm"
#include <sys/mman.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {
// BG3's packs at stand-in addresses, as the shim finds them after install.
std::vector<uint8_t> storage[PackCount];
std::vector<std::vector<uint8_t>> received;
void record(void *, void *, const Span *span) { received.emplace_back(span->begin, span->end); }
}
namespace {
void check(bool ok, const char *what) {
    if (!ok) { fprintf(stderr, "custom-render-stages smoke failed: %s\n", what); exit(1); }
}
Span pack(int i) { return {packs[i], packs[i] + packInfo[i].count}; }
// Each sequence's calls to the Span overload, as BG3MFX would see them.
void run(BG3MFXViewKind kind, void *view, std::initializer_list<int> calls) {
    received.clear();
    for (int i : calls) { Span span = pack(i); dispatch(nullptr, view, kind, &span); }
}
std::vector<std::vector<uint8_t>> expected(std::initializer_list<int> calls) {
    std::vector<std::vector<uint8_t>> spans;
    for (int i : calls) spans.emplace_back(packInfo[i].bytes, packInfo[i].bytes + packInfo[i].count);
    return spans;
}
std::vector<uint8_t> join(std::initializer_list<int> calls) {
    std::vector<uint8_t> codes;
    for (int i : calls) codes.insert(codes.end(), packInfo[i].bytes, packInfo[i].bytes + packInfo[i].count);
    return codes;
}
BOOL set(BG3MFXViewKind kind, const char *feature, const std::vector<uint8_t> &codes) {
    return BG3MFXSetViewStages(kind, feature, codes.data(), codes.size(), nullptr);
}
}

int main() {
    @autoreleasepool {
        for (int i = 0; i < PackCount; ++i) {
            storage[i].assign(packInfo[i].bytes, packInfo[i].bytes + packInfo[i].count);
            packs[i] = storage[i].data();
        }
        original = record;
        int game, player, fullscreen, offscreen;
        const std::initializer_list<int> gameCalls = {First, Shadow, Second, Shadow, Third};
        const std::initializer_list<int> offscreenCalls = {First, EarlyVtResolve, Shadow, Second, Shadow, Third, Additional};

        // Without lists, every kind gets BG3's calls unchanged.
        run(BG3MFXViewKind::Game, &game, gameCalls); check(received == expected(gameCalls), "game passthrough");
        run(BG3MFXViewKind::Player, &player, gameCalls); check(received == expected(gameCalls), "player passthrough");
        run(BG3MFXViewKind::Offscreen, &offscreen, offscreenCalls); check(received == expected(offscreenCalls), "offscreen passthrough");
        run(BG3MFXViewKind::Fullscreen, &fullscreen, {FullScreen}); check(received == expected({FullScreen}), "fullscreen passthrough");
        check(!BG3MFXStageListRequested(), "no list requested");

        // Validation: unknown types, lookup order, App's anchors, owners.
        check(!set(BG3MFXViewKind::Game, "test", {0x0a}), "DebugWorld is not built from a list");
        check(!set(BG3MFXViewKind::Offscreen, "test", {0x47, 0x08, 0x00}), "Alpha before its lookups");
        check(!set(BG3MFXViewKind::Offscreen, "test", {0x08}), "Cull before FxRenderPrepare");
        check(!set(BG3MFXViewKind::Player, "test", join({First, Shadow, Third})), "player without App's anchors");
        check(!set(BG3MFXViewKind::Game, "test", {}), "empty list");
        check(!set(BG3MFXViewKind::Game, "", join(gameCalls)), "unnamed feature");
        const std::vector<uint8_t> single = join({First, Second, Shadow, Third});
        check(set(BG3MFXViewKind::Game, "test", single), "game list without the first shadow");
        check(!set(BG3MFXViewKind::Game, "other", join(gameCalls)), "second owner of a kind");
        const std::vector<uint8_t> minimal = {0x47, 0x08};
        check(set(BG3MFXViewKind::Offscreen, "test", minimal), "offscreen needs no anchors");
        check(BG3MFXStageListRequested(), "list requested");

        // A list is added once, on the opening pack, whatever BG3 passes after it.
        run(BG3MFXViewKind::Game, &game, gameCalls); check(received.size() == 1 && received[0] == single, "game list replaces packs");
        run(BG3MFXViewKind::Game, &game, {First, Second, Shadow, Third}); check(received.size() == 1 && received[0] == single, "patched sequence");
        run(BG3MFXViewKind::Game, &game, {First, Third, Shadow}); check(received.size() == 1 && received[0] == single, "reordered sequence");
        run(BG3MFXViewKind::Offscreen, &offscreen, offscreenCalls); check(received.size() == 1 && received[0] == minimal, "offscreen list");
        // Kinds without a list are unchanged, also right after a replaced view.
        run(BG3MFXViewKind::Player, &player, gameCalls); check(received == expected(gameCalls), "player still passthrough");
        run(BG3MFXViewKind::Fullscreen, &fullscreen, {FullScreen}); check(received == expected({FullScreen}), "fullscreen still passthrough");
        // A known pack outside an opened sequence is forwarded.
        received.clear(); { Span span = pack(Shadow); dispatch(nullptr, &player, BG3MFXViewKind::Game, &span); }
        check(received == expected({Shadow}), "pack without its view's opening");

        // A span that is not one of the packs is forwarded unchanged, once reported.
        const uint8_t other[] = {0x02};
        received.clear();
        { Span open = pack(First); dispatch(nullptr, &game, BG3MFXViewKind::Game, &open); }
        { Span span{other, other + 1}; dispatch(nullptr, &game, BG3MFXViewKind::Game, &span); }
        { Span span = pack(Third); dispatch(nullptr, &game, BG3MFXViewKind::Game, &span); }
        check(received.size() == 2 && received[0] == single && received[1] == std::vector<uint8_t>{0x02}, "unknown span forwarded");

        // Classification reads BaseApp's two views and the frame's offscreen flag.
        alignas(8) uint8_t app[0x98] = {}, view[0x10] = {}, frame[0x40] = {}, defaultView[0x10] = {}, fullView[0x10] = {};
        void *pointer = defaultView; memcpy(app + Layout::AppDefaultView, &pointer, 8);
        pointer = fullView; memcpy(app + Layout::AppFullscreenView, &pointer, 8);
        pointer = frame; memcpy(view + Layout::ViewFrame, &pointer, 8);
        check(classify(app, defaultView) == BG3MFXViewKind::Game, "default view");
        check(classify(app, fullView) == BG3MFXViewKind::Fullscreen, "fullscreen view");
        check(classify(app, view) == BG3MFXViewKind::Player, "window frame view");
        uint32_t offscreenFlag = 2; memcpy(frame + Layout::FrameOffscreen, &offscreenFlag, 4);
        check(classify(app, view) == BG3MFXViewKind::Offscreen, "offscreen frame view");

        // The vtable write: a read-only page is written and made read-only again.
        void **page = static_cast<void **>(mmap(nullptr, vm_page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0));
        check(page != MAP_FAILED, "page");
        page[3] = reinterpret_cast<void *>(record);
        check(mprotect(page, vm_page_size, PROT_READ) == 0, "read-only page");
        bool restored = false;
        check(BG3MFXPatchPointer(page + 3, reinterpret_cast<void *>(addSpan), &restored) && restored, "pointer patched");
        check(page[3] == reinterpret_cast<void *>(addSpan), "pointer value");
        vm_region_basic_info_data_64_t info; mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
        vm_address_t address = reinterpret_cast<vm_address_t>(page); vm_size_t size = 0; mach_port_t object;
        check(vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &infoCount, &object) == KERN_SUCCESS &&
            info.protection == VM_PROT_READ, "page read-only again");
        // Stage method overrides. Stand-in vtables: read-only pages with the
        // entries at the same offsets as the real ones from 0x10885c000, each
        // holding BG3's method at the same slide.
        const uintptr_t vtableBase = 0x10885c000;
        void **vtables = static_cast<void **>(mmap(nullptr, 2 * vm_page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0));
        check(vtables != MAP_FAILED, "vtable pages");
        const intptr_t slide = reinterpret_cast<intptr_t>(vtables) - intptr_t(vtableBase);
        auto entryOf = [&](const Native::StageMethodSlot &s) { return reinterpret_cast<void **>(s.entry + slide); };
        auto methodOf = [&](const Native::StageMethodSlot &s) { return reinterpret_cast<void *>(s.method + slide); };
        for (const auto &s : Native::StageMethods) {
            check(s.entry - vtableBase + 8 <= 2 * vm_page_size, "stand-in vtables cover every entry");
            *entryOf(s) = methodOf(s);
        }
        check(mprotect(vtables, 2 * vm_page_size, PROT_READ) == 0, "read-only vtables");

        static int deferredLoad, shadowUnload;
        void *deferredOriginal = nullptr, *shadowOriginal = nullptr, *unused = nullptr;
        auto override = [&](uint8_t type, BG3MFXStageMethod method, const char *feature, void *replacement, void **original) {
            return BG3MFXOverrideStageMethod(type, method, feature, replacement, original, nullptr);
        };
        check(!override(0x08, BG3MFXStageMethod::Load, "test", &deferredLoad, &unused), "type without methods");
        check(!override(0x03, BG3MFXStageMethod::Submit, "test", &deferredLoad, &unused), "method not listed for the type");
        check(!override(0x0b, BG3MFXStageMethod::Load, "", &deferredLoad, &unused), "unnamed feature");
        check(!override(0x0b, BG3MFXStageMethod::Load, "test", nullptr, &unused), "no replacement");
        check(!override(0x0b, BG3MFXStageMethod::Load, "test", &deferredLoad, nullptr), "nowhere for BG3's method");
        check(override(0x0b, BG3MFXStageMethod::Load, "test", &deferredLoad, &deferredOriginal), "DeferredBufferStage::Load");
        check(!override(0x0b, BG3MFXStageMethod::Load, "other", &shadowUnload, &unused), "second owner of a method");
        check(override(0x03, BG3MFXStageMethod::Unload, "test", &shadowUnload, &shadowOriginal), "CascadedShadowMaskStage::Unload");

        // An entry that isn't BG3's method stops every override.
        const Native::StageMethodSlot &deferredSlot = *findSlot(0x0b, 3), &shadowSlot = *findSlot(0x03, 4);
        bool restoredPage = false;
        check(BG3MFXPatchPointer(entryOf(shadowSlot), &unused, &restoredPage), "stand-in entry changed");
        check(!patchStageMethods(slide, nullptr), "unexpected entry rejected");
        check(*entryOf(deferredSlot) == methodOf(deferredSlot) && !deferredOriginal, "nothing patched after a rejected entry");
        check(BG3MFXPatchPointer(entryOf(shadowSlot), methodOf(shadowSlot), &restoredPage), "stand-in entry restored");

        check(patchStageMethods(slide, nullptr), "overrides patched");
        check(*entryOf(deferredSlot) == &deferredLoad && *entryOf(shadowSlot) == &shadowUnload, "entries replaced");
        check(deferredOriginal == methodOf(deferredSlot) && shadowOriginal == methodOf(shadowSlot), "BG3's methods handed back");
        const Native::StageMethodSlot &submitSlot = *findSlot(0x0b, 5);
        check(*entryOf(submitSlot) == methodOf(submitSlot), "other entries untouched");
        address = reinterpret_cast<vm_address_t>(vtables); size = 0; infoCount = VM_REGION_BASIC_INFO_COUNT_64;
        check(vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &infoCount, &object) == KERN_SUCCESS &&
            info.protection == VM_PROT_READ, "vtables read-only again");
        check(!override(0x0b, BG3MFXStageMethod::Submit, "test", &deferredLoad, &unused), "no overrides after activation");

        puts("Stage lists: passthrough for every kind, one list per opened view whatever packs follow, unknown spans forwarded, "
             "validation, view classification and the read-only pointer write passed. Stage method overrides: validation, "
             "one owner per method, the entry guard, the patch and BG3's methods handed back passed.");
    }
}
