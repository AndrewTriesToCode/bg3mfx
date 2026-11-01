#pragma once
#import <Foundation/Foundation.h>
#include <cstddef>
#include <cstdint>

// The custom-render-stages feature: per-view stage lists. A feature that
// requires it registers lists from its install; this feature patches BG3 at
// activation, only if one did. BaseApp::InitFrameStages(view) builds a view's stages
// by passing fixed packs of rf::AppStageType codes, one virtual call each, to
// BaseApp::InitFrameStages(view, Span), which adds one stage per code
// (docs/dev/baseline/README.md, "Views and their stage lists"). The shim
// replaces that call's slot in App's vtable.
//
// A view kind without a registered list gets BG3's calls unchanged. A
// registered list replaces the kind's packs: it is added on the call that
// opens a view's sequence (BG3's FIRST or FULL_SCREEN pack), and that view's
// later pack calls are skipped. The shim does not depend on how many packs BG3
// passes or in what order, so code patches inside InitFrameStages don't affect
// it, and a registered list overrides them for its kind (a list with two
// Shadow packs adds two shadow stages).

enum class BG3MFXViewKind : uint8_t {
    Game,        // BaseApp's "default" view
    Player,      // other window views (ls::PlayerManager::CreateRenderView)
    Fullscreen,  // BaseApp's "Fullscreen" view: UI and composition
    Offscreen,   // views of offscreen frames (BasicGameObjectRenderer)
};
inline constexpr size_t BG3MFXViewKindCount = 4;

// BG3's packs in the supported build, for building lists from them. Game and
// Player views get First, Shadow, Second, Shadow, Third; Offscreen views
// First, EarlyVtResolve, Shadow, Second, Shadow, Third, Additional; the
// Fullscreen view FullScreen.
namespace BG3MFXStagePack {
inline constexpr uint8_t FullScreen[] = {0x19, 0x45, 0x07};
inline constexpr uint8_t Shadow[] = {0x02};
inline constexpr uint8_t First[] = {0x47, 0x08, 0x48, 0x35, 0x1e, 0x05, 0x0b};
inline constexpr uint8_t EarlyVtResolve[] = {0x45};
inline constexpr uint8_t Second[] = {0x46, 0x36, 0x44, 0x18, 0x17, 0x40, 0x37, 0x38};
inline constexpr uint8_t Third[] = {0x41, 0x03, 0x1b, 0x1a, 0x00, 0x21, 0x3e, 0x3f};
inline constexpr uint8_t Additional[] = {0x07};
}

// Replaces `kind`'s stage list with `codes`, added in order. Call from a
// feature's install, before this feature activates; one feature per kind. Rejects a code the Span
// overload does not build, a stage before a stage it looks up, and, for Game
// and Player, a list without the stages App::InitFrameStages inserts around.
BOOL BG3MFXSetViewStages(BG3MFXViewKind kind, const char *feature, const uint8_t *codes, size_t count, NSError **error);
// Whether any kind has a registered list.
BOOL BG3MFXStageListRequested(void);

// Stage methods a feature can override, by vtable slot (counted from the
// address point of ls::RenderStage's primary vtable). Load is
// `bool (*)(void *stage)`: it sets the stage's enabled byte, and
// StageGroup::AddAppStage checks the result. The others are
// `void (*)(void *stage)`.
enum class BG3MFXStageMethod : uint8_t { Load = 3, Unload = 4, Submit = 5, StartRecording = 7 };
// Replaces `method` of stage type `type` (an rf::AppStageType code) with
// `replacement`, for every stage of that class, from this feature's activation
// on. `*original` is set to BG3's method at activation, before the replacement
// can be called; the replacement calls it. Call from a feature's install; one
// feature per method. Rejects a type and method SupportedBuild.h doesn't list
// (CustomRenderStages::StageMethods).
BOOL BG3MFXOverrideStageMethod(uint8_t type, BG3MFXStageMethod method, const char *feature,
    void *replacement, void **original, NSError **error);
