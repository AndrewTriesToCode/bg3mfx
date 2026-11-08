#include "common/native/SupportedBuild.h"
#import "features/custom-render-stages/CustomRenderStages.h"
#include "common/Feature.h"
#include "common/native/CodePatch.h"
#include <atomic>
#include <bitset>
#include <cstring>
#include <string>
#include <vector>

// How the shim works (the contract is in CustomRenderStages.h):
//
// BaseApp::InitFrameStages(view) doesn't add stages itself. It passes fixed
// packs of rf::AppStageType codes to the virtual
// BaseApp::InitFrameStages(view, Span), which builds one stage per code. The
// install below points that method's slot in App's vtable at addSpan, so every
// pack call comes through here. addSpan classifies the view, identifies the
// pack, and either forwards the call to BG3, adds a registered list in its
// place, or drops it.
//
// Lists are registered before the shim is installed (this feature's
// activation, after every feature's install) and never change afterwards, so
// the hot path takes no locks. The replacement Span points straight into lists[], which
// is safe only because of that.
namespace Native = BG3MFXBuild::CustomRenderStages;
namespace Layout = BG3MFXBuild::CustomRenderStages::Layout;

namespace {
// ls::Span<rf::AppStageType const>, passed by reference in x2.
struct Span { const uint8_t *begin, *end; };
using AddSpan = void (*)(void *app, void *view, const Span *span);

// BG3's seven packs. A span is one of them only if it starts at that pack's
// address in the running executable and has its length; see identify.
enum Pack : int { FullScreen, Shadow, First, EarlyVtResolve, Second, Third, Additional, PackCount, Unknown = -1 };
struct PackInfo { const char *name; uintptr_t address; const uint8_t *bytes; size_t count; };
const PackInfo packInfo[PackCount] = {
    {"FullScreen", Native::FullScreenPack, BG3MFXStagePack::FullScreen, sizeof BG3MFXStagePack::FullScreen},
    {"Shadow", Native::ShadowPack, BG3MFXStagePack::Shadow, sizeof BG3MFXStagePack::Shadow},
    {"First", Native::FirstPack, BG3MFXStagePack::First, sizeof BG3MFXStagePack::First},
    {"EarlyVtResolve", Native::EarlyVtResolvePack, BG3MFXStagePack::EarlyVtResolve, sizeof BG3MFXStagePack::EarlyVtResolve},
    {"Second", Native::SecondPack, BG3MFXStagePack::Second, sizeof BG3MFXStagePack::Second},
    {"Third", Native::ThirdPack, BG3MFXStagePack::Third, sizeof BG3MFXStagePack::Third},
    {"Additional", Native::AdditionalPack, BG3MFXStagePack::Additional, sizeof BG3MFXStagePack::Additional},
};
const char *const kindNames[BG3MFXViewKindCount] = {"game", "player", "fullscreen", "offscreen"};

// The types the Span overload's switch builds, with the types each one's
// construction looks up in the view (first match), from 0x105d1ab24-
// 0x105d1ae88 and the cases they reach. Any other code adds nothing. A stage
// whose lookup runs before the stage it needs exists finds nothing, so
// BG3MFXSetViewStages rejects that order. For example, Alpha (0x00) needs Cull,
// both shadow stages, Lighting, SSAO, ClusteredAssignment and LocalLightShadow.
struct Built { uint8_t type; uint8_t count; uint8_t needs[7]; };
const Built built[] = {
    {0x00, 7, {0x08, 0x02, 0x03, 0x1b, 0x37, 0x05, 0x1e}},  // Alpha
    {0x02, 1, {0x47}},                                      // CascadedShadowBuffer
    {0x03, 2, {0x08, 0x02}},                                // CascadedShadowMask
    {0x05, 1, {0x08}},                                      // ClusteredAssignment
    {0x07, 0, {}},                                          // CombineUI
    {0x08, 1, {0x47}},                                      // Cull
    {0x0b, 1, {0x08}},                                      // DeferredBuffer
    {0x17, 1, {0x08}},                                      // EmissiveGameDecal
    {0x18, 1, {0x08}},                                      // Emissive
    {0x19, 0, {}},                                          // GameUI
    {0x1a, 1, {0x08}},                                      // LightingCombine
    {0x1b, 7, {0x08, 0x02, 0x03, 0x37, 0x05, 0x1e, 0x38}},  // Lighting
    {0x1e, 3, {0x08, 0x35, 0x47}},                          // LocalLightShadow
    {0x21, 0, {}},                                          // PostProcess
    {0x35, 1, {0x08}},                                      // ShadowTileAssignment
    {0x36, 0, {}},                                          // Sky
    {0x37, 0, {}},                                          // SSAO
    {0x38, 2, {0x08, 0x05}},                                // SSR
    {0x3e, 0, {}},                                          // TextureCull
    {0x3f, 1, {0x08}},                                      // Unlit
    {0x40, 1, {0x08}},                                      // Velocity
    {0x41, 3, {0x08, 0x02, 0x1e}},                          // VertexProcessing (added before Cull)
    {0x44, 0, {}},                                          // VolumetricClouds
    {0x45, 0, {}},                                          // VtResolve
    {0x46, 1, {0x08}},                                      // Decal
    {0x47, 0, {}},                                          // FxRenderPrepare
    {0x48, 1, {0x47}},                                      // FxRenderUpdate
};
// App::InitFrameStages (the override in vtable slot 0x2c0) calls BaseApp's,
// then inserts the game's own stages around these. It returns without its game
// stages unless the view has ClusteredAssignment, Decal, EmissiveGameDecal,
// PostProcess and Cull. Only Game and Player views get game stages, so only
// their lists must contain these.
const uint8_t appAnchors[] = {0x05, 0x46, 0x17, 0x21, 0x08};
constexpr size_t MaxStages = 128;

const uint8_t *packs[PackCount];  // where the running build keeps each pack
AddSpan original;                 // BaseApp::InitFrameStages(view, Span)
bool installed;
struct List { std::string feature; std::vector<uint8_t> codes; };
List lists[BG3MFXViewKindCount];  // indexed by BG3MFXViewKind; empty codes means BG3's packs

// BaseApp::InitFrameStages makes all of one view's calls in a row, on one
// thread, so a thread-local record of the view being built is enough to tell
// which later packs belong to a replaced sequence.
struct Sequence { void *view = nullptr; bool replaced = false; };
thread_local Sequence current;

template<class T> T read(const void *p, size_t offset) {
    T value; memcpy(&value, static_cast<const char *>(p) + offset, sizeof value); return value;
}
const Built *find(uint8_t type) {
    for (const Built &b : built) if (b.type == type) return &b;
    return nullptr;
}
// Compares the address, not the bytes: a span that only copies a pack's codes
// is not that pack. If a future build passed copies, they'd be Unknown and
// forwarded, adding them on top of a replaced view's list, which is why
// dispatch reports the first unknown span.
int identify(const Span *span) {
    for (int i = 0; i < PackCount; ++i)
        if (span->begin == packs[i] && size_t(span->end - span->begin) == packInfo[i].count) return i;
    return Unknown;
}
// Fullscreen first, as BaseApp checks it; then the default view; then offscreen
// frames. Anything else is a window view from ls::PlayerManager::CreateRenderView
// (split screen), which hasn't been seen in a live trace yet.
BG3MFXViewKind classify(void *app, void *view) {
    if (view == read<void *>(app, Layout::AppFullscreenView)) return BG3MFXViewKind::Fullscreen;
    if (view == read<void *>(app, Layout::AppDefaultView)) return BG3MFXViewKind::Game;
    void *frame = read<void *>(view, Layout::ViewFrame);
    if (frame && read<uint32_t>(frame, Layout::FrameOffscreen)) return BG3MFXViewKind::Offscreen;
    return BG3MFXViewKind::Player;
}
// A registered list is added once, on the pack that opens the view's sequence,
// and the view's later known packs are dropped. So the result doesn't depend
// on how many packs BG3 passes after the opening or in what order; a patch
// that removed one of BG3's Shadow calls would change only which packs get
// dropped.
void dispatch(void *app, void *view, BG3MFXViewKind kind, const Span *span) {
    int pack = identify(span);
    Sequence &sequence = current;
    if (pack == First || pack == FullScreen) {
        // Every window and offscreen view opens with First, the Fullscreen
        // view with FullScreen.
        const List &list = lists[size_t(kind)];
        sequence = {view, !list.codes.empty()};
        if (sequence.replaced) {
            Span replacement{list.codes.data(), list.codes.data() + list.codes.size()};
            original(app, view, &replacement);
            return;
        }
    } else if (pack != Unknown && sequence.view == view && sequence.replaced) {
        // Already covered by the list added on the opening pack.
        return;
    }
    // A kind without a list, a known pack outside an opened sequence, or a
    // caller or pack this build's checks don't know: BG3's call, unchanged.
    original(app, view, span);
}
void addSpan(void *app, void *view, const Span *span) {
    dispatch(app, view, classify(app, view), span);
}
}

BOOL BG3MFXSetViewStages(BG3MFXViewKind kind, const char *feature, const uint8_t *codes, size_t count, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXCustomRenderStages" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    // A list the Span overload would build wrongly is rejected here, at
    // startup, rather than producing a view with missing or broken stages.
    size_t index = size_t(kind);
    if (installed) return fail(@"Stage lists must be set before the stage-list shim is installed.");
    if (index >= BG3MFXViewKindCount || !feature || !*feature) return fail(@"A stage list needs a view kind and a feature name.");
    if (!lists[index].feature.empty())
        return fail([NSString stringWithFormat:@"%s already sets the %s stage list.", lists[index].feature.c_str(), kindNames[index]]);
    if (!codes || !count || count > MaxStages)
        return fail([NSString stringWithFormat:@"A stage list has 1 to %zu stages.", MaxStages]);
    // Every code must be one the switch builds, and each stage's lookups must
    // find a stage added earlier in the list.
    std::bitset<256> present;
    for (size_t i = 0; i < count; ++i) {
        const Built *stage = find(codes[i]);
        if (!stage) return fail([NSString stringWithFormat:@"BG3 does not build stage type 0x%02x from a stage list.", codes[i]]);
        for (uint8_t j = 0; j < stage->count; ++j)
            if (!present[stage->needs[j]])
                return fail([NSString stringWithFormat:@"Stage type 0x%02x needs stage type 0x%02x before it.", codes[i], stage->needs[j]]);
        present.set(codes[i]);
    }
    if (kind == BG3MFXViewKind::Game || kind == BG3MFXViewKind::Player)
        for (uint8_t anchor : appAnchors)
            if (!present[anchor])
                return fail([NSString stringWithFormat:@"The %s stage list needs stage type 0x%02x for BG3's game stages.", kindNames[index], anchor]);
    lists[index] = {feature, std::vector<uint8_t>(codes, codes + count)};
    return YES;
}

BOOL BG3MFXStageListRequested(void) {
    for (const List &list : lists) if (!list.codes.empty()) return YES;
    return NO;
}

// Stage method overrides: each replaces one entry of a stage class's vtable,
// so every stage of that class, in every view, calls the replacement. Like
// the lists, they are registered before activation and never change after.
namespace {
struct Override {
    std::string feature;
    const Native::StageMethodSlot *slot;
    void *replacement;
    void **original;
};
std::vector<Override> overrides;
bool methodsPatched;

const Native::StageMethodSlot *findSlot(uint8_t type, uint8_t method) {
    for (const auto &slot : Native::StageMethods)
        if (slot.type == type && slot.slot == method) return &slot;
    return nullptr;
}
}

BOOL BG3MFXOverrideStageMethod(uint8_t type, BG3MFXStageMethod method, const char *feature,
    void *replacement, void **original, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXCustomRenderStages" code:2 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    if (methodsPatched) return fail(@"Stage methods must be overridden before custom-render-stages activates.");
    if (!feature || !*feature || !replacement || !original) return fail(@"A stage method override needs a feature, a replacement and a place for BG3's method.");
    const Native::StageMethodSlot *slot = findSlot(type, uint8_t(method));
    if (!slot) return fail([NSString stringWithFormat:@"Method %u of stage type 0x%02x can't be overridden on this build.", unsigned(method), type]);
    for (const Override &o : overrides)
        if (o.slot == slot)
            return fail([NSString stringWithFormat:@"%s already overrides method %u of stage type 0x%02x.", o.feature.c_str(), unsigned(method), type]);
    overrides.push_back({feature, slot, replacement, original});
    return YES;
}

namespace {
// Checks every overridden entry before changing any, then writes them; if a
// write fails, the ones already written are put back.
BOOL patchStageMethods(intptr_t slide, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXCustomRenderStages" code:2 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    if (methodsPatched) return YES;
    auto entry = [&](const Override &o) { return reinterpret_cast<void **>(o.slot->entry + slide); };
    for (const Override &o : overrides)
        if (*entry(o) != reinterpret_cast<void *>(o.slot->method + slide))
            return fail([NSString stringWithFormat:@"Unsupported native method %u of stage type 0x%02x.", o.slot->slot, o.slot->type]);
    for (size_t i = 0; i < overrides.size(); ++i) {
        const Override &o = overrides[i];
        *o.original = *entry(o);
        bool pageRestored = false;
        if (!BG3MFXPatchPointer(entry(o), o.replacement, &pageRestored)) {
            for (size_t j = 0; j < i; ++j) BG3MFXPatchPointer(entry(overrides[j]), *overrides[j].original, &pageRestored);
            return fail(@"Could not make a stage vtable writable.");
        }
    }
    methodsPatched = true;
    return YES;
}
}

namespace {
BOOL installShim(intptr_t slide, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXCustomRenderStages" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
        return NO;
    };
    if (installed) return YES;
    // The caller has checked the executable UUID; also check App's vtable
    // and every pack before changing anything.
    void **slot = reinterpret_cast<void **>(Native::AppAddSpanSlot + slide);
    if (*reinterpret_cast<uintptr_t *>(Native::AppInitSlot + slide) != uintptr_t(Native::AppInit + slide) ||
        reinterpret_cast<uintptr_t>(*slot) != uintptr_t(Native::AddSpan + slide))
        return fail(@"Unsupported native frame-stage setup.");
    for (int i = 0; i < PackCount; ++i) {
        packs[i] = reinterpret_cast<const uint8_t *>(packInfo[i].address + slide);
        if (memcmp(packs[i], packInfo[i].bytes, packInfo[i].count) != 0) return fail(@"Unsupported native frame-stage packs.");
    }
    // Only App's vtable is patched: App is the BaseApp subclass BG3 runs, and
    // the slot is App's own copy of the method, so BaseApp's vtable is left
    // alone. __DATA_CONST is read-only; BG3MFXPatchPointer opens the page,
    // stores the pointer atomically and makes it read-only again.
    original = reinterpret_cast<AddSpan>(*slot);
    bool restored = false;
    if (!BG3MFXPatchPointer(slot, reinterpret_cast<void *>(addSpan), &restored))
        return fail(@"Could not make App's vtable writable.");
    installed = true;
    return YES;
}

// Dependents register their lists from their own install.
BOOL installCustomRenderStages(const BG3MFXFeatureContext &, NSError **) { return YES; }
// Then the vtables are patched only for what was registered.
BOOL activateCustomRenderStages(const BG3MFXFeatureContext &context, NSError **error) {
    if (!overrides.empty() && !patchStageMethods(context.slide, error)) return NO;
    if (!BG3MFXStageListRequested()) return YES;
    return installShim(context.slide, error);
}
}
BG3MFX_FEATURE(customRenderStages, {"custom-render-stages", nullptr, true,
    installCustomRenderStages, activateCustomRenderStages});
