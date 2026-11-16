#include "common/native/SupportedBuild.h"
#import "common/Notice.h"
#import "features/metalfx/MetalFX.h"
#import "features/custom-menu/CustomMenu.h"
#import "features/metalfx/ultra-performance/UltraPerformance.h"
#import "features/metalfx/cas-sharpening/CASSharpening.h"
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <atomic>
#include <cmath>

// MetalFX's Video options: the MetalFX Spatial and Temporal Upscaling Types,
// the Frame Generation checkbox and Temporal's Ultra Performance quality. BG3's settings code accepts
// only Off and FSR as upscaling types, so a MetalFX type runs BG3's FSR setup
// for its quality and render resolution and is tracked separately here.
// Frame Generation requires BG3's VSync (Double or Triple Buffering): the
// checkbox is dimmed while VSync is Off, and while it is ticked choosing VSync Off
// snaps back to the previous Double or Triple.

namespace Native = BG3MFXBuild::Menu;
namespace Layout = BG3MFXBuild::Menu::Layout;

namespace {
intptr_t slide;
BG3MFXMenuCallback originalUpscaleCall, originalQualityCall, originalVSyncCall;
// The last VSync combo value that was on (1 Double, 2 Triple).
int lastVSyncOn = 1;
// -1: BG3's own setting; 0 or 1: a standalone test harness's VSync.
std::atomic<int> standaloneVSync{-1};
// Upscaling Type menu value: 0 Off, 1 FSR, 2 Spatial, 3 Temporal. Frame
// Generation is a separate checkbox that combines with any of them.
std::atomic<int> selectedScalingMode{0};
std::atomic<bool> frameGenerationChecked{false};
bool metalFXValue(int value) { return value == 2 || value == 3; }
bool temporalValue(int value) { return value == 3; }
NSString *const frameGenerationPreference = @"BG3MFXFrameGenerationEnabled";
// The player's Anti-Aliasing choice while MetalFX holds it at TAA.
NSString *const savedAntiAliasingPreference = @"BG3MFXSavedAntiAliasing";
std::atomic<int> startupQuality{0};
// Earlier builds stored Frame Generation as a Temporal-only checkbox under this
// key, then as Upscaling Type values 4 (Temporal + FG) and 5 (Spatial + FG).
NSString *const legacyFrameGenerationPreference = @"BG3MFXFrameGeneration";
NSString *const scalingPreference = @"BG3MFXUpscalingType";
NSString *const qualityPreference = @"BG3MFXUpscalingQuality";
constexpr uint16_t upscaleTypeID = 99, upscaleQualityID = 100, upscaleSharpnessID = 101, antiAliasingID = 98, vsyncID = 82;
constexpr uint16_t frameGenerationID = 0x7f02;
constexpr uint16_t casTickBoxID = BG3MFXBuild::CASRendering::TickBoxID, casSliderID = BG3MFXBuild::CASRendering::SliderID;
template<class T> T at(uintptr_t address) { return reinterpret_cast<T>(address + slide); }
template<class T> T &field(const void *object, size_t offset) {
    return *reinterpret_cast<T *>(static_cast<char *>(const_cast<void *>(object)) + offset);
}
bool menuVSyncOn(void *manager) { return field<uint8_t>(manager, Layout::VSync) != 0; }
// BG3's live VSync, for the renderer. Outside BG3 (no slide) it is a harness's.
bool bg3VSyncOn() {
    int standalone = standaloneVSync.load();
    if (standalone >= 0) return standalone != 0;
    if (!slide) return true;
    void *settings = *at<void **>(BG3MFXBuild::Temporal::Settings);
    return !settings || field<uint8_t>(settings, BG3MFXBuild::Temporal::Layout::SettingsVSync) != 0;
}
void publishSettings(void *manager) { at<void (*)(void *, bool)>(Native::PublishSettings)(manager, false); }
bool frameGenerationSupported() {
    static bool supported = [MTLFXFrameInterpolatorDescriptor supportsMetal4FX:MTLCreateSystemDefaultDevice()];
    return supported;
}
// The Anti-Aliasing combo value labelled "TAA", or -1.
int taaValue(void *aa) {
    NSArray<NSNumber *> *values = BG3MFXMenuComboValues(aa);
    for (NSUInteger i = 0; i < values.count; ++i) {
        NSString *label = BG3MFXMenuComboLabel(aa, i);
        if (label.length < 64 && [label containsString:@"TAA"]) return values[i].intValue;
    }
    return -1;
}
// The player's sharpness is what the slider shows: moving it updates only the
// slider until Apply copies it to the manager (VideoOptionsManager::ApplySlider).
float currentSharpness(void *manager) {
    void *slider = BG3MFXMenuFind(manager, -1, upscaleSharpnessID);
    return slider ? BG3MFXMenuSliderValue(slider) / 100 : field<float>(manager, Layout::UpscaleSharpness);
}
// BG3's FSR quality setter resets Upscaling Sharpness to 0.8 whenever the quality
// changes, which the MetalFX bridge does behind the player's back. Put back the
// player's value and show it, as the native Upscaling Type callback does.
bool restoreSharpness(void *manager, float value) {
    bool changed = field<float>(manager, Layout::UpscaleSharpness) != value;
    field<float>(manager, Layout::UpscaleSharpness) = value;
    if (void *slider = BG3MFXMenuFind(manager, -1, upscaleSharpnessID)) BG3MFXMenuShowSliderValue(slider, value * 100);
    return changed;
}
void updateDependentControls(void *manager, int mode) {
    // Upscaling Sharpness drives FSR's RCAS pass, which MetalFX replaces; dim it
    // there. BG3 enables it for its FSR type, which the MetalFX types run as.
    if (metalFXValue(mode)) BG3MFXMenuSetEnabled(BG3MFXMenuFind(manager, -1, upscaleSharpnessID), false);
    // BG3 dims its CAS options for every type but Off; CAS runs with MetalFX
    // (src/features/metalfx/cas-sharpening/), so they stay available.
    if (BG3MFXCASSharpeningInstalled() && (mode == 2 || mode == 3)) {
        void *tick = BG3MFXMenuFind(manager, -1, casTickBoxID);
        BG3MFXMenuSetEnabled(tick, true);
        BG3MFXMenuSetEnabled(BG3MFXMenuFind(manager, -1, casSliderID), tick && BG3MFXMenuTickBoxValue(tick));
    }
    // MetalFX Temporal and Frame Generation use the depth, motion and camera
    // data of BG3's TAA pass (Temporal then replaces its draw). While either is
    // on, select TAA and dim the control; afterwards restore the player's choice.
    void *aa = BG3MFXMenuFind(manager, 3, antiAliasingID);
    if (!aa) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    bool requiresTAA = temporalValue(mode) || (frameGenerationChecked.load() && frameGenerationSupported());
    int current = BG3MFXMenuComboSelection(aa), taa = taaValue(aa);
    NSArray<NSNumber *> *values = BG3MFXMenuComboValues(aa);
    if (requiresTAA && taa >= 0 && current != taa) {
        if (![defaults objectForKey:savedAntiAliasingPreference]) [defaults setInteger:current forKey:savedAntiAliasingPreference];
        BG3MFXMenuSelectCombo(aa, taa);
    } else if (!requiresTAA && [defaults objectForKey:savedAntiAliasingPreference]) {
        int saved = (int)[defaults integerForKey:savedAntiAliasingPreference];
        [defaults removeObjectForKey:savedAntiAliasingPreference];
        if (saved != current && [values containsObject:@(saved)]) {
            BG3MFXMenuSelectCombo(aa, saved);
        }
    }
    if (requiresTAA && taa < 0) BG3MFXMenuProblem(@"No TAA Anti-Aliasing option found");
    BG3MFXMenuSetEnabled(aa, !requiresTAA && values.count > 1);
}
// Frame Generation needs VSync: dim its checkbox while VSync is Off. While it is
// ticked, VSync Off is refused (removing the entry blanks BG3's dropdown).
void syncFrameGenerationVSync(void *manager) {
    if (!frameGenerationSupported()) return;
    BG3MFXMenuSetEnabled(BG3MFXMenuFind(manager, -1, frameGenerationID), menuVSyncOn(manager));
}
void vsyncChanged(void *storage, const void *item) {
    void *manager = BG3MFXMenuStorageManager(storage);
    void *combo = const_cast<void *>(item);
    int value = item ? BG3MFXMenuComboSelection(item) : -1;
    if (value == 0 && frameGenerationChecked.load() && frameGenerationSupported() && combo) {
        BG3MFXMenuSetComboSelection(combo, lastVSyncOn);
        if (originalVSyncCall) originalVSyncCall(storage, item);
        BG3MFXMenuShowComboSelection(combo, lastVSyncOn);
        return;
    }
    if (value == 1 || value == 2) lastVSyncOn = value;
    if (originalVSyncCall) originalVSyncCall(storage, item);
    if (manager) syncFrameGenerationVSync(manager);
}
void frameGenerationChanged(void *, const void *item) {
    if (!item || BG3MFXMenuItemID(const_cast<void *>(item)) != frameGenerationID) return;
    bool enabled = BG3MFXMenuTickBoxValue(item);
    frameGenerationChecked.store(enabled);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:frameGenerationPreference];
    // BG3 can quit right after a change; keep the next launch consistent.
    [NSUserDefaults.standardUserDefaults synchronize];
    BG3MFXMetalFXSelectionChanged(false);
    if (void *manager = BG3MFXMenuManager()) {
        syncFrameGenerationVSync(manager);
        updateDependentControls(manager, selectedScalingMode.load());
    }
}
// Ultra Performance is an Upscaling Quality of MetalFX Temporal only. BG3 renders
// any quality above Ultra Quality at full size; the patch in
// src/features/metalfx/ultra-performance/ gives quality 4 its own render scale.
// Only where MetalFX Temporal can scale input down at all (installed checks the
// device's maximum scale).
bool reducedOffered(int mode) { return temporalValue(mode) && BG3MFXUltraPerformanceInstalled(); }
int customQuality(void *manager, int mode) {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:qualityPreference];
    int value = saved ? [saved intValue] : (field<uint8_t>(manager, Layout::NativeUpscalingType) == 1 ? field<uint8_t>(manager, Layout::NativeQuality) : 2);
    // Other types keep the saved choice for Temporal but use Balanced.
    if (value == BG3MFXUltraPerformanceQuality) return reducedOffered(mode) ? value : 2;
    return value >= 0 && value <= 3 ? value : 2;
}
// The native type callback rebuilds the quality list with BG3's four
// qualities; add Ultra Performance after them while MetalFX Temporal is selected.
constexpr uint32_t offeredQualityCount = 5;
void offerReducedQualities(void *manager, int mode) {
    if (!reducedOffered(mode)) return;
    void *quality = BG3MFXMenuFind(manager, 3, upscaleQualityID);
    if (!quality || ![BG3MFXMenuComboValues(quality) isEqualToArray:@[@0, @1, @2, @3]]) return;
    BG3MFXMenuText name, description;
    if (BG3MFXMenuMakeText(name, "h00000000g0000g0000g0000g00000000f00d", "Ultra Performance") &&
        BG3MFXMenuMakeText(description, "h00000000g0000g0000g0000g00000000f00e",
            "Renders at the lowest resolution MetalFX Temporal supports on this Mac (3x less per axis, 1/9 of the pixels) and upscales it. The most frame rate, at the lowest image quality."))
        BG3MFXMenuAppendComboValue(quality, BG3MFXUltraPerformanceQuality, name, description);
    else BG3MFXMenuProblem(@"Could not register the Ultra Performance text.");
    BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
    // An open menu shows the list it was given: send the items-changed
    // notification RefreshUIUpscaleMode sends after rebuilding it.
    BG3MFXMenuComboItemsChanged(quality);
}
void restoreCustomQuality(void *manager, int mode, int value, bool refresh) {
    // Applying native type 1 always chooses Balanced. Reapply the requested
    // quality through BG3's setter, including the actual render-resolution state.
    at<void (*)(void *, int)>(Native::SetQuality)(static_cast<char *>(manager) + Layout::SettingsStorage, value);
    if (!refresh) return;
    offerReducedQualities(manager, mode);
    // The native type callback already rebuilt the quality list. Rebuilding it
    // again while its UI change is being handled can leave the displayed value
    // blank. Update only the selection, using RefreshUIUpscaleMode's observed
    // SelectedChanged notification ABI.
    void *quality = BG3MFXMenuFind(manager, 3, upscaleQualityID);
    if (quality && BG3MFXMenuComboValues(quality).count == (reducedOffered(mode) ? offeredQualityCount : 4u)) {
        BG3MFXMenuShowComboSelection(quality, value);
        return;
    }
    at<void (*)(void *)>(Native::RefreshQuality)(manager);
}
void qualityChanged(void *storage, const void *item) {
    int value = item ? BG3MFXMenuComboSelection(item) : -1;
    int mode = selectedScalingMode.load();
    void *manager = BG3MFXMenuStorageManager(storage);
    float sharpness = manager ? currentSharpness(manager) : 0;
    if (originalQualityCall) originalQualityCall(storage, item);
    if (!manager) return;
    if (metalFXValue(mode) && restoreSharpness(manager, sharpness)) publishSettings(manager);
    if (metalFXValue(mode) && ((value >= 0 && value <= 3) || (value == BG3MFXUltraPerformanceQuality && reducedOffered(mode)))) {
        [NSUserDefaults.standardUserDefaults setInteger:value forKey:qualityPreference];
    }
    updateDependentControls(manager, mode);
}
// Apply() runs again when closing Options. Its virtual ComboItem apply must use
// the same native resolution setup as the selection callback.
void applyCombo(void *manager, const void *item, BG3MFXMenuApply next) {
    void *mutableItem = const_cast<void *>(item);
    bool upscale = item && BG3MFXMenuItemType(mutableItem) == 3 && BG3MFXMenuItemID(mutableItem) == upscaleTypeID;
    if (item && BG3MFXMenuItemType(mutableItem) == 3 && BG3MFXMenuItemID(mutableItem) == vsyncID) {
        next(manager, item);
        syncFrameGenerationVSync(manager);
        return;
    }
    int value = upscale ? BG3MFXMenuComboSelection(item) : -1;
    bool custom = metalFXValue(value);
    int quality = custom ? customQuality(manager, value) : -1;
    float sharpness = currentSharpness(manager);
    if (custom) BG3MFXMenuSetComboSelection(mutableItem, 1);
    next(manager, item);
    if (!custom) return;
    restoreCustomQuality(manager, value, quality, true);
    restoreSharpness(manager, sharpness);
    BG3MFXMenuSetComboSelection(mutableItem, value);
    updateDependentControls(manager, value);
}
void upscaleChanged(void *storage, const void *item) {
    void *mutableItem = const_cast<void *>(item);
    if (!originalUpscaleCall || !storage || !item || BG3MFXMenuItemID(mutableItem) != upscaleTypeID) {
        if (originalUpscaleCall) originalUpscaleCall(storage, item);
        return;
    }
    void *manager = BG3MFXMenuStorageManager(storage);
    int value = BG3MFXMenuComboSelection(item);
    if (!manager || value < 0 || value > 3) {
        originalUpscaleCall(storage, item);
        BG3MFXFail([NSString stringWithFormat:@"The Upscaling Type menu reported an unknown value (%d).", value], nil, nil);
        return;
    }
    // BG3's settings system only understands Off (0) and FSR (1). For the
    // MetalFX choices, apply the game's normal FSR quality/resolution setup,
    // then restore the menu's custom value and track it independently. The
    // renderer hooks replace only FSR dispatches while one of these values is
    // selected, so the native Off and FSR paths remain unchanged.
    int quality = metalFXValue(value) ? customQuality(manager, value) : -1;
    float sharpness = currentSharpness(manager);
    BG3MFXMenuSetComboSelection(mutableItem, metalFXValue(value) ? 1 : value);
    originalUpscaleCall(storage, item);
    if (quality >= 0) restoreCustomQuality(manager, value, quality, true);
    // Changing the type is not a sharpness choice, even to or from FSR.
    bool sharpnessRestored = restoreSharpness(manager, sharpness);
    BG3MFXMenuSetComboSelection(mutableItem, value);
    // The selection callback already published Balanced before we restored
    // the manager's quality. Publish the restored settings to the renderer too.
    if (quality >= 0 || sharpnessRestored) publishSettings(manager);
    int previous = selectedScalingMode.exchange(value);
    updateDependentControls(manager, value);
    if (metalFXValue(value)) [NSUserDefaults.standardUserDefaults setInteger:value forKey:scalingPreference];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:scalingPreference];
    // BG3 can quit immediately after a selection; flush the separate mode so
    // the next process cannot revive a previously saved MetalFX selection.
    [NSUserDefaults.standardUserDefaults synchronize];
    BG3MFXMetalFXSelectionChanged(previous != value);
}

void addFrameGeneration(void *manager) {
    BG3MFXMenuText name, description;
    if (BG3MFXMenuMakeText(name, "h00000000g0000g0000g0000g00000000f00b", "MetalFX Frame Generation") &&
        BG3MFXMenuMakeText(description, "h00000000g0000g0000g0000g00000000f00c",
            "Adds a MetalFX-generated frame between rendered frames, with any Upscaling Type. Uses the game's TAA depth and motion data. The FPS limiter controls rendered frames. Requires VSync (Double or Triple Buffering): unavailable while VSync is Off, and VSync cannot be set to Off while it is on.")) {
        void *item = BG3MFXMenuAddTickBox(manager, frameGenerationID, name, description, frameGenerationChecked.load(), frameGenerationChanged);
        // Right below VSync (combo 82, EVSyncMode), which also governs
        // presentation; without it, after the upscaling controls (Upscaling
        // Type, then Upscaling Quality when BG3 lists it).
        size_t count = BG3MFXMenuItemCount(manager);
        if (item && count && BG3MFXMenuItem(manager, count - 1) == item) {
            size_t anchor = count, vsync = count;
            for (size_t i = 0; i + 1 < count; ++i) {
                void *candidate = BG3MFXMenuItem(manager, i);
                uint16_t id = BG3MFXMenuItemType(candidate) == 3 ? BG3MFXMenuItemID(candidate) : 0;
                if (id == upscaleTypeID || id == upscaleQualityID) anchor = i;
                if (id == vsyncID) vsync = i;
            }
            if (vsync < count) anchor = vsync;
            if (anchor + 2 < count) BG3MFXMenuMoveLast(manager, anchor + 1);
        }
    } else BG3MFXMenuProblem(@"Could not register the Frame Generation text.");
    BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
}
void menuBuilt(void *manager) {
    void *upscale = BG3MFXMenuFind(manager, 3, upscaleTypeID), *quality = BG3MFXMenuFind(manager, 3, upscaleQualityID);
    NSArray<NSNumber *> *nativeValues = BG3MFXMenuComboValues(upscale);
    BOOL nativeOptions = [nativeValues isEqualToArray:@[@0, @1]];
    NSArray *extendedValues = @[@0, @1, @2, @3];
    if (!nativeOptions && ![nativeValues isEqualToArray:extendedValues]) {
        BG3MFXMenuProblem([NSString stringWithFormat:@"Unexpected Upscaling Type options (%@).", [nativeValues componentsJoinedByString:@", "]]);
        return;
    }
    if (nativeOptions) {
        BG3MFXMenuText spatialName, spatialDescription, temporalName, temporalDescription;
        if (BG3MFXMenuMakeText(spatialName, "h00000000g0000g0000g0000g00000000f001", "MetalFX Spatial") &&
            BG3MFXMenuMakeText(spatialDescription, "h00000000g0000g0000g0000g00000000f002",
                "Upscales each frame with MetalFX Spatial. Anti-aliasing remains a separate setting.") &&
            BG3MFXMenuMakeText(temporalName, "h00000000g0000g0000g0000g00000000f005", "MetalFX Temporal") &&
            BG3MFXMenuMakeText(temporalDescription, "h00000000g0000g0000g0000g00000000f006",
                "Uses MetalFX Temporal history to upscale each frame and replaces TAA.")) {
            BG3MFXMenuAppendComboValue(upscale, 2, spatialName, spatialDescription);
            BG3MFXMenuAppendComboValue(upscale, 3, temporalName, temporalDescription);
        }
        for (BG3MFXMenuText *t : {&spatialName, &spatialDescription, &temporalName, &temporalDescription}) BG3MFXMenuDestroyText(*t);
    }
    if (![BG3MFXMenuComboValues(upscale) isEqualToArray:extendedValues]) {
        BG3MFXMenuProblem(@"Could not append the MetalFX options");
        return;
    }
    BG3MFXMenuCallback selectionCall = BG3MFXMenuSelectionCallback(upscale);
    if (selectionCall != upscaleChanged) originalUpscaleCall = selectionCall;
    if (!originalUpscaleCall) BG3MFXMenuProblem(@"Missing Upscaling Type selection callback");
    else BG3MFXMenuSetSelectionCallback(upscale, upscaleChanged);
    id savedScaling = [NSUserDefaults.standardUserDefaults objectForKey:scalingPreference];
    int storedMode = savedScaling ? (int)[savedScaling integerValue] : -1;
    int nativeMode = field<uint8_t>(manager, Layout::NativeUpscalingType) == 1 ? 1 : 0;
    int mode = metalFXValue(storedMode) ? storedMode : nativeMode;
    if (quality) {
        BG3MFXMenuCallback qualityCall = BG3MFXMenuSelectionCallback(quality);
        if (qualityCall != qualityChanged) originalQualityCall = qualityCall;
        if (originalQualityCall) BG3MFXMenuSetSelectionCallback(quality, qualityChanged);
    }
    // Frame Generation needs VSync: a tick saved with VSync Off (an earlier
    // version allowed it) is cleared.
    if (frameGenerationChecked.load() && frameGenerationSupported() && !menuVSyncOn(manager)) {
        frameGenerationChecked.store(false);
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:frameGenerationPreference];
        [NSUserDefaults.standardUserDefaults synchronize];
        BG3MFXMetalFXSelectionChanged(false);
    }
    if (void *vsync = BG3MFXMenuFind(manager, 3, vsyncID)) {
        BG3MFXMenuCallback call = BG3MFXMenuSelectionCallback(vsync);
        if (call != vsyncChanged) originalVSyncCall = call;
        int shown = BG3MFXMenuComboSelection(vsync);
        if (shown == 1 || shown == 2) lastVSyncOn = shown;
        if (originalVSyncCall) BG3MFXMenuSetSelectionCallback(vsync, vsyncChanged);
        else BG3MFXMenuProblem(@"Missing VSync selection callback");
    }
    // Restore through the same native callback as an interactive selection.
    // Merely changing +0xf7 left the quality ComboItems disabled and never
    // activated the render-resolution setting.
    if (metalFXValue(mode)) {
        if (BG3MFXMenuItemManager(upscale) != manager || !originalUpscaleCall) {
            BG3MFXMenuProblem(@"Unsupported native upscaling callback storage.");
            return;
        }
        BG3MFXMenuSetComboSelection(upscale, mode);
        upscaleChanged(BG3MFXMenuCallbackStorage(upscale), upscale);
    } else {
        selectedScalingMode.store(mode);
        updateDependentControls(manager, mode);
    }
    bool frameGeneration = frameGenerationSupported();
    if (frameGeneration) {
        addFrameGeneration(manager);
        syncFrameGenerationVSync(manager);
    }
}
}

void BG3MFXInstallMetalFXOptions(intptr_t gameSlide) {
    slide = gameSlide;
    BG3MFXMenuOnBuilt(menuBuilt);
    BG3MFXMenuWrapApplyCombo(applyCombo);
}

// The native settings file persists the FSR resolution/quality setup used by
// MetalFX. Restore the separate selection before BG3 creates its first command
// buffer, rather than waiting for Video Options to open.
void BG3MFXRestoreMetalFXChoices(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id savedScaling = [defaults objectForKey:scalingPreference];
    int startupMode = savedScaling ? [savedScaling intValue] : 0;
    // Migrate earlier Frame Generation settings to the checkbox.
    if ([defaults objectForKey:legacyFrameGenerationPreference]) {
        if (startupMode == 3 && [defaults boolForKey:legacyFrameGenerationPreference])
            [defaults setBool:YES forKey:frameGenerationPreference];
        [defaults removeObjectForKey:legacyFrameGenerationPreference];
    }
    if (startupMode == 4 || startupMode == 5) {
        [defaults setBool:YES forKey:frameGenerationPreference];
        startupMode = startupMode == 4 ? 3 : 2;
        [defaults setInteger:startupMode forKey:scalingPreference];
    }
    [defaults synchronize];
    if (!metalFXValue(startupMode)) startupMode = 0;
    selectedScalingMode.store(startupMode);
    // MetalFX AA, removed, stored its choice under this key.
    [defaults removeObjectForKey:@"BG3MFXMetalFXAA"];
    // Dynamic's minimum frame rate and thermal guard no longer exist.
    [defaults removeObjectForKey:@"BG3MFXDynamicMinimumFrameRate"];
    [defaults removeObjectForKey:@"BG3MFXDynamicThermalGuard"];
    id savedQuality = [defaults objectForKey:qualityPreference];
    // The unreleased Max Performance quality 5 is now Ultra Performance.
    if (savedQuality && [savedQuality intValue] == 5) {
        [defaults setInteger:BG3MFXUltraPerformanceQuality forKey:qualityPreference];
        savedQuality = @(BG3MFXUltraPerformanceQuality);
    }
    if (savedQuality && [savedQuality intValue] == BG3MFXUltraPerformanceQuality) startupQuality.store([savedQuality intValue]);
    frameGenerationChecked.store([defaults boolForKey:frameGenerationPreference]);
}

int BG3MFXSelectedScalingMode(void) { return selectedScalingMode.load(); }
// Frame Generation needs BG3's VSync, checked live: a saved tick with VSync Off
// stays inactive until Options is opened, and a VSync change that bypasses the
// menu (a reverted display setting) ends it at once.
BOOL BG3MFXFrameGenerationEnabled(void) { return frameGenerationChecked.load() && frameGenerationSupported() && bg3VSyncOn(); }

void BG3MFXPublishStartupReducedQuality(void) {
    int quality = startupQuality.load();
    if (!quality || BG3MFXMenuOptionsBuilt() || !reducedOffered(selectedScalingMode.load())) return;
    void *settings = *at<void **>(BG3MFXBuild::Temporal::Settings);
    if (!settings || field<uint8_t>(settings, BG3MFXBuild::Temporal::Layout::SettingsQuality) == quality) return;
    // Once a second at most, in case BG3 loads its quality again later.
    static std::atomic<double> published{0};
    double now = CACurrentMediaTime(), last = published.load();
    if (now - last < 1 || !published.compare_exchange_strong(last, now)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        void *current = *at<void **>(BG3MFXBuild::Temporal::Settings);
        if (BG3MFXMenuOptionsBuilt() || !current) return;
        // PublishSettings reads only the manager's settings storage (its two
        // strings by copy) and +0x131, so a zeroed manager holding a copy of
        // the renderer's settings stands in for the Video options manager.
        alignas(16) char manager[Layout::PublishedManagerBytes] = {};
        char *storage = manager + Layout::SettingsStorage;
        memcpy(storage, current, Layout::PublishedSettingsBytes);
        float sharpness = field<float>(storage, BG3MFXBuild::Temporal::Layout::SettingsSharpness);
        at<void (*)(void *, int)>(Native::SetQuality)(storage, quality);
        field<float>(storage, BG3MFXBuild::Temporal::Layout::SettingsSharpness) = sharpness;
        publishSettings(manager);
    });
}

// The MetalFX types run as BG3's FSR type, so the game's settings need no
// change: track FSR and drop the saved MetalFX type. Video options then open on
// AMD FSR 1.0 (BG3's own type), and the next launch starts with it.
BOOL BG3MFXFallBackToFSR(void) {
    if (!BG3MFXMenuActive()) return NO;
    selectedScalingMode.store(1);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:scalingPreference];
    [defaults synchronize];
    return YES;
}

// Standalone GPU regression harnesses have no BG3 settings manager. Never
// permit them to override a real game's menu selection.
#ifdef BG3MFX_STANDALONE_TEST_HOOKS
extern "C" BOOL BG3MFXSetStandaloneScalingMode(int mode) {
    if (BG3MFXMenuActive() || [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"] || mode < 0 || mode > 3) return NO;
    selectedScalingMode.store(mode);
    return YES;
}
extern "C" BOOL BG3MFXSetStandaloneFrameGeneration(BOOL enabled) {
    if (BG3MFXMenuActive() || [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return NO;
    frameGenerationChecked.store(enabled);
    return YES;
}
extern "C" BOOL BG3MFXSetStandaloneVSync(BOOL on) {
    if (BG3MFXMenuActive() || [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return NO;
    standaloneVSync.store(on ? 1 : 0);
    return YES;
}
#endif
