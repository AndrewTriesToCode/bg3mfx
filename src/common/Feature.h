#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>

// Every part of bg3mfx is a feature. Each registers itself with
// BG3MFX_FEATURE in its own source file, and the root feature
// (src/features/root/) installs the enabled ones when the runtime loads. A
// feature knows only the features it names in `requires`, through their
// headers; root knows none of them by name.
//
// A feature is enabled only when requested: by BG3MFX_FEATURE_<NAME>=1 (its
// name in upper case, with '-' as '_') while BG3MFX_ENABLE=1, or by an enabled
// feature that requires it. BG3MFX_FEATURE_<NAME>=0 keeps it off even
// then, and skips the features that require it. The player launcher (src/launcher/main.m)
// sets every player-facing feature; development launches opt in one at a time.

struct BG3MFXFeatureContext {
    intptr_t slide;              // the game executable's slide; 0 outside BG3 or on another build
    bool runtimeEnabled;         // BG3MFX_ENABLE=1
};

struct BG3MFXFeature {
    const char *name;            // the folder name under src/features/
    const char *const *requires; // nullptr-terminated feature names, or nullptr
    // Patches the game executable, so needs the supported build (root checks
    // its UUID once; each feature still checks the code it patches).
    bool native;
    // Called in dependency order, after every feature this one requires has
    // installed. A provider gets ready to take registrations here; its
    // dependents register with it from their own install.
    BOOL (*install)(const BG3MFXFeatureContext &context, NSError **error);
    // Optional: called in the same order once every feature has installed, so
    // a provider can patch BG3 knowing everything registered with it.
    BOOL (*activate)(const BG3MFXFeatureContext &context, NSError **error);
};

// Root reads the registrations from this section of the runtime image.
#define BG3MFX_FEATURE_SECTION "bg3mfx_features"
#define BG3MFX_FEATURE(identifier, ...) \
    static const BG3MFXFeature identifier = __VA_ARGS__; \
    __attribute__((used, section("__DATA," BG3MFX_FEATURE_SECTION))) \
    static const BG3MFXFeature *const identifier##Registration = &identifier

inline bool BG3MFXFeatureEnabled(const char *variable) {
    const char *value = getenv(variable);
    return value && strcmp(value, "1") == 0;
}
