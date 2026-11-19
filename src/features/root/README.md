# Root

Technical name: `root`.

Installs every other feature when the runtime loads. It has no flag and knows
no feature by name; every feature, including the infrastructure the others
build on, registers itself with `BG3MFX_FEATURE` (`src/common/Feature.h`).

## Behavior

Before BG3's `main`, root:

1. checks once that the process is BG3's supported ARM64 executable (its
   Mach-O UUID in `SupportedBuild.h`) and finds its slide;
2. reads the registrations from the runtime image's `__DATA,bg3mfx_features`
   section;
3. enables a feature when `BG3MFX_FEATURE_<NAME>=1` is set while
   `BG3MFX_ENABLE=1` (the name in upper case, `-` as `_`), or when an enabled
   feature requires it; nothing is enabled unless requested. An
   explicit `BG3MFX_FEATURE_<NAME>=0` keeps a feature off even then, and the
   features that require it are skipped: the player launcher sets every flag
   to 1, so a player's 0 must win;
4. installs the enabled features, each after everything it requires, ties
   in name order;
5. activates them in the same order, once every feature has installed.

A feature that patches the executable (`native`) installs only on the
supported build. A feature whose requirement did not install or activate is
skipped, as are features with an unknown requirement or in a requirement
cycle. Each skip is reported through `BG3MFXFail`. On an unsupported BG3 build with a native
feature enabled, root shows one notice; the game continues without bg3mfx's
features.

The constructor must run after every other file's static initializers, so
the Makefile links `Root.mm` last (dyld runs initializers in link order).

## Improvement

None by itself: it only orders the installs.

## Tests

`tests/features/root/root_smoke.mm` runs root's resolution on stand-in
features: flags and the runtime switch, requirements enabled and
installed first, installs before activations, and native, install,
activation, cycle and unknown-requirement skips.
