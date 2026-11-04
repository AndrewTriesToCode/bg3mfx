// Test-only fixtures; no BG3 code or assets are linked. The packs and the
// Span overload are stand-ins (see tests/features/custom-render-stages/custom_render_stages_smoke.mm).
#import "features/custom-render-stages/CustomRenderStages.mm"
#import "common/native/CodePatch.mm"
#import "features/duplicate-shadow-fix/DuplicateShadowFix.mm"
#include <algorithm>
#include <cstdio>
#include <cstdlib>

namespace {
std::vector<uint8_t> storage[PackCount];
std::vector<std::vector<uint8_t>> received;
void record(void *, void *, const Span *span) { received.emplace_back(span->begin, span->end); }
void check(bool ok, const char *what) {
    if (!ok) { fprintf(stderr, "duplicate-shadow-fix smoke failed: %s\n", what); exit(1); }
}
// The stages a view gets from BG3's calls, one list per call.
std::vector<uint8_t> stages(BG3MFXViewKind kind, std::initializer_list<int> calls) {
    static int view;
    received.clear();
    for (int i : calls) { Span span{packs[i], packs[i] + packInfo[i].count}; dispatch(nullptr, &view, kind, &span); }
    std::vector<uint8_t> all;
    for (auto &codes : received) all.insert(all.end(), codes.begin(), codes.end());
    return all;
}
size_t shadows(const std::vector<uint8_t> &codes) { return std::count(codes.begin(), codes.end(), uint8_t(0x02)); }
}

int main() {
    @autoreleasepool {
        for (int i = 0; i < PackCount; ++i) {
            storage[i].assign(packInfo[i].bytes, packInfo[i].bytes + packInfo[i].count);
            packs[i] = storage[i].data();
        }
        original = record;
        const std::initializer_list<int> window = {First, Shadow, Second, Shadow, Third};
        const std::initializer_list<int> offscreen = {First, EarlyVtResolve, Shadow, Second, Shadow, Third, Additional};
        const std::vector<uint8_t> nativeWindow = stages(BG3MFXViewKind::Game, window);
        const std::vector<uint8_t> nativeOffscreen = stages(BG3MFXViewKind::Offscreen, offscreen);
        check(shadows(nativeWindow) == 2 && shadows(nativeOffscreen) == 2, "BG3 adds two shadow stages");

        NSError *error = nil;
        check(BG3MFXInstallDuplicateShadowFix(&error), "registration");
        for (BG3MFXViewKind kind : {BG3MFXViewKind::Game, BG3MFXViewKind::Player}) {
            std::vector<uint8_t> codes = stages(kind, window);
            check(received.size() == 1 && shadows(codes) == 1, "one shadow stage in window views");
            // The rest of BG3's list, in order, with the first shadow stage kept.
            std::vector<uint8_t> expected = nativeWindow;
            expected.erase(std::find(expected.begin() + 8, expected.end(), uint8_t(0x02)));
            check(codes == expected, "BG3's window list without the second shadow stage");
            // The same list when BG3's first Shadow call is missing.
            check(stages(kind, {First, Second, Shadow, Third}) == expected, "without BG3's first Shadow call");
        }
        std::vector<uint8_t> codes = stages(BG3MFXViewKind::Offscreen, offscreen);
        std::vector<uint8_t> expected = nativeOffscreen;
        expected.erase(std::find(expected.begin() + 9, expected.end(), uint8_t(0x02)));
        check(shadows(codes) == 1 && codes == expected, "BG3's offscreen list without the second shadow stage");
        check(stages(BG3MFXViewKind::Fullscreen, {FullScreen}) == std::vector<uint8_t>(std::begin(BG3MFXStagePack::FullScreen),
            std::end(BG3MFXStagePack::FullScreen)), "fullscreen unchanged");
        puts("Duplicate shadow fix: game, player and offscreen views get one shadow stage, BG3's order otherwise; fullscreen unchanged.");
    }
}
