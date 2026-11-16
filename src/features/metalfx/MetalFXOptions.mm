#include "common/native/SupportedBuild.h"
#import "common/Notice.h"
#import "features/metalfx/MetalFX.h"
#import "features/custom-menu/CustomMenu.h"
#import "features/metalfx/ultra-performance/UltraPerformance.h"
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <atomic>
#include <cmath>

// MetalFX's Video options: the MetalFX Spatial and Temporal Upscaling Types,
// the Frame Generation checkbox, Temporal's Ultra Performance quality and the
// MetalFX AA Anti-Aliasing entry. BG3's settings code accepts
// only Off and FSR as upscaling types, so a MetalFX type runs BG3's FSR setup
// for its quality and render resolution and is tracked separately here.
// Frame Generation requires BG3's VSync (Double or Triple Buffering): the
// checkbox is dimmed while VSync is Off, and while it is ticked choosing VSync Off
// snaps back to the previous Double or Triple.
// MetalFX AA is MetalFX Temporal at 1x scale: with the Upscaling Type Off it runs
// that FSR setup at the hidden full-size quality, and while a Temporal upscaler
// is selected the Anti-Aliasing combo shows it, dimmed. BG3's own Anti-Aliasing
// setting stays TAA underneath, whose inputs MetalFX uses.

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
// The Upscaling Type BG3's native type callback is applying, or -1. That
// callback rebuilds the Anti-Aliasing combo before selectedScalingMode changes,
// and runs MetalFX Spatial and Temporal as its FSR type.
int nativeTypeTarget = -1;
// MetalFX AA is offered with the Upscaling Type Off or MetalFX Temporal.
bool aaOffered(int mode) { return mode == 0 || mode == 3; }
NSString *const frameGenerationPreference = @"BG3MFXFrameGenerationEnabled";
// The player's Anti-Aliasing choice while MetalFX holds it at TAA.
NSString *const savedAntiAliasingPreference = @"BG3MFXSavedAntiAliasing";
std::atomic<int> startupQuality{0};
// MetalFX AA chosen with the Upscaling Type Off: Temporal at 1x on BG3's FSR
// setup (the runtime mode is 3, the menu's type stays Off).
std::atomic<bool> aaOnlyActive{false};
NSString *const metalFXAAPreference = @"BG3MFXMetalFXAA";
// The Anti-Aliasing combo's MetalFX AA value (-1 until added), the player's last
// other choice, BG3's callback for it, and a guard for the menu's own changes.
int aaMetalFXValue = -1, lastAAChoice = -1;
BG3MFXMenuCallback originalAACall;
bool syncingAA;
// Earlier builds stored Frame Generation as a Temporal-only checkbox under this
// key, then as Upscaling Type values 4 (Temporal + FG) and 5 (Spatial + FG).
NSString *const legacyFrameGenerationPreference = @"BG3MFXFrameGeneration";
NSString *const scalingPreference = @"BG3MFXUpscalingType";
NSString *const qualityPreference = @"BG3MFXUpscalingQuality";
constexpr uint16_t upscaleTypeID = 99, upscaleQualityID = 100, upscaleSharpnessID = 101, antiAliasingID = 98, vsyncID = 82;
constexpr uint16_t frameGenerationID = 0x7f02;
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
void addMetalFXAA(void *manager);
void enterAAOnly(void *manager);
void leaveAAOnly(void *manager, int mode, BG3MFXMenuApply apply = nullptr);
// Shows `value` in the Anti-Aliasing combo. MetalFX AA is not a BG3 value: BG3's
// setting is set to TAA through its own callback and the entry is only shown.
void setAA(void *aa, int value, int taa) {
    syncingAA = true;
    if (value == aaMetalFXValue) {
        if (taa >= 0 && BG3MFXMenuComboSelection(aa) != taa) BG3MFXMenuSelectCombo(aa, taa);
        BG3MFXMenuShowComboSelection(aa, value);
    } else BG3MFXMenuSelectCombo(aa, value);
    syncingAA = false;
}
// MetalFX AA keeps BG3's type at FSR (quality 5) while the menu shows Off. Show
// the Upscaling Quality as RefreshUIUpscaleMode does for Off: its one Off entry,
// dimmed (so Apply skips it). Only the list changes, not the settings.
void showQualityOff(void *manager) {
    void *quality = BG3MFXMenuFind(manager, 3, upscaleQualityID);
    if (!quality || ([BG3MFXMenuComboValues(quality) isEqualToArray:@[@0]] && BG3MFXMenuComboSelection(quality) == 0)) {
        BG3MFXMenuSetEnabled(quality, false);
        return;
    }
    uint8_t &type = field<uint8_t>(manager, Layout::NativeUpscalingType);
    uint8_t native = type;
    type = 0;
    at<void (*)(void *)>(Native::RefreshQuality)(manager);
    type = native;
}
void updateDependentControls(void *manager, int mode) {
    // Upscaling Sharpness drives FSR's RCAS pass, which MetalFX replaces; dim it
    // there. BG3 enables it for its FSR type, which the MetalFX types run as.
    if (metalFXValue(mode) || aaOnlyActive.load()) BG3MFXMenuSetEnabled(BG3MFXMenuFind(manager, -1, upscaleSharpnessID), false);
    // MetalFX Temporal and Frame Generation use the depth, motion and camera
    // data of BG3's TAA pass (Temporal then replaces its draw). With Temporal the
    // combo shows MetalFX AA and is dimmed; with Frame Generation alone it shows
    // TAA and is dimmed; afterwards the player's choice is restored.
    void *aa = BG3MFXMenuFind(manager, 3, antiAliasingID);
    if (!aa) return;
    // Any Upscaling Type but Off ends MetalFX AA. Temporal keeps showing it and
    // returns to it when left for Off; FSR and Spatial do not offer it and go
    // back to the player's earlier choice. (The type's native callback already
    // showed BG3's TAA.)
    bool endedAAOnly = aaOnlyActive.load() && mode != 0;
    if (endedAAOnly) leaveAAOnly(manager, mode);
    if (aaOffered(mode)) addMetalFXAA(manager);
    else if (aaMetalFXValue >= 0 && BG3MFXMenuRemoveComboValue(aa, aaMetalFXValue)) BG3MFXMenuComboItemsChanged(aa);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray<NSNumber *> *values = BG3MFXMenuComboValues(aa);
    int current = BG3MFXMenuComboSelection(aa), taa = taaValue(aa);
    int metal = aaMetalFXValue >= 0 && [values containsObject:@(aaMetalFXValue)] ? aaMetalFXValue : -1;
    auto isMetal = [](int value) { return aaMetalFXValue >= 0 && value == aaMetalFXValue; };
    bool temporal = temporalValue(mode);
    bool frameGeneration = frameGenerationChecked.load() && frameGenerationSupported();
    id saved = [defaults objectForKey:savedAntiAliasingPreference];
    int fallback = lastAAChoice >= 0 && !isMetal(lastAAChoice) ? lastAAChoice : taa;
    int desired = current;
    if (temporal) {
        desired = metal >= 0 ? metal : taa;
        if (!saved && (endedAAOnly || !isMetal(current))) [defaults setInteger:endedAAOnly ? aaMetalFXValue : current forKey:savedAntiAliasingPreference];
    } else if (aaOnlyActive.load()) {
        desired = metal;
    } else if (saved && (!frameGeneration || isMetal([saved intValue]))) {
        desired = [saved intValue];
        [defaults removeObjectForKey:savedAntiAliasingPreference];
    } else if (frameGeneration && current != taa) {
        desired = taa;
        if (!saved) [defaults setInteger:current forKey:savedAntiAliasingPreference];
    }
    if (endedAAOnly && !temporal) desired = fallback;
    // MetalFX AA needs the Upscaling Type Off (or Temporal).
    if (isMetal(desired) && (mode != 0 || metal < 0) && !temporal) desired = fallback;
    if (metal >= 0 && desired == metal && mode == 0 && !aaOnlyActive.load()) {
        // A restored choice of MetalFX AA. BG3's type callback rebuilds the list.
        enterAAOnly(manager);
        if (!aaOnlyActive.load()) desired = fallback;
        values = BG3MFXMenuComboValues(aa);
        current = BG3MFXMenuComboSelection(aa);
    }
    if (desired != current && [values containsObject:@(desired)]) setAA(aa, desired, taa);
    if (taa < 0 && (temporal || frameGeneration)) BG3MFXMenuProblem(@"No TAA Anti-Aliasing option found");
    int shown = BG3MFXMenuComboSelection(aa);
    bool enabled = !(temporal || (frameGeneration && shown != metal)) && values.count > 1;
    BG3MFXMenuSetEnabled(aa, enabled);
    if (enabled && shown != metal) lastAAChoice = shown;
    if (aaOnlyActive.load()) {
        showQualityOff(manager);
        BG3MFXMenuSetEnabled(BG3MFXMenuFind(manager, -1, upscaleSharpnessID), false);
    }
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
// Ultra Performance is an Upscaling Quality of MetalFX Temporal only. BG3 renders any quality above Ultra Quality at full size; the
// reduced-resolution hook then renders a fixed smaller region
// (src/features/metalfx/ultra-performance/).
// Only where MetalFX Temporal can render a smaller region than the targets:
// with a device maximum no larger than the minimum scale the area would stay 1.
bool reductionSupported() {
    static bool supported = [] {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device && [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device] >
            std::max(1.0f, [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device]);
    }();
    return supported;
}
bool reducedOffered(int mode) { return temporalValue(mode) && BG3MFXUltraPerformanceInstalled() && reductionSupported(); }
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
// BG3's native Upscaling Type callback, applying the menu's type `target`.
void callNativeType(void *storage, const void *item, int target) {
    int previous = nativeTypeTarget;
    nativeTypeTarget = target;
    originalUpscaleCall(storage, item);
    nativeTypeTarget = previous;
}
// MetalFX AA with the Upscaling Type Off: BG3's FSR setup at the hidden
// full-size quality, which MetalFX Temporal replaces; the type combo keeps
// showing Off.
void enterAAOnly(void *manager) {
    void *upscale = BG3MFXMenuFind(manager, 3, upscaleTypeID);
    if (!upscale || !originalUpscaleCall || BG3MFXMenuItemManager(upscale) != manager) {
        BG3MFXMenuProblem(@"Cannot start MetalFX AA: unsupported native upscaling callback.");
        return;
    }
    float sharpness = currentSharpness(manager);
    BG3MFXMenuSetComboSelection(upscale, 1);
    callNativeType(BG3MFXMenuCallbackStorage(upscale), upscale, 0);
    restoreCustomQuality(manager, 0, BG3MFXMetalFXAAQuality, false);
    restoreSharpness(manager, sharpness);
    BG3MFXMenuSetComboSelection(upscale, 0);
    publishSettings(manager);
    aaOnlyActive.store(true);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:metalFXAAPreference];
    [defaults synchronize];
    BG3MFXMetalFXSelectionChanged(true);
}
// `mode` is the Upscaling Type now: 0 means BG3's FSR setup must be turned off
// again, through the type's native callback or, during Apply, through `apply`;
// otherwise the type that replaced Off has already set BG3's.
void leaveAAOnly(void *manager, int mode, BG3MFXMenuApply apply) {
    aaOnlyActive.store(false);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:metalFXAAPreference];
    [defaults synchronize];
    void *upscale = BG3MFXMenuFind(manager, 3, upscaleTypeID);
    if (mode == 0) {
        float sharpness = currentSharpness(manager);
        if (upscale) BG3MFXMenuSetComboSelection(upscale, 0);
        if (upscale && apply) apply(manager, upscale);
        else if (upscale && originalUpscaleCall && BG3MFXMenuItemManager(upscale) == manager)
            callNativeType(BG3MFXMenuCallbackStorage(upscale), upscale, 0);
        else BG3MFXMenuProblem(@"Cannot end MetalFX AA: unsupported native upscaling callback.");
        restoreSharpness(manager, sharpness);
        publishSettings(manager);
    }
    BG3MFXMetalFXSelectionChanged(true);
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
    bool aa = item && BG3MFXMenuItemType(mutableItem) == 3 && BG3MFXMenuItemID(mutableItem) == antiAliasingID;
    if (item && BG3MFXMenuItemType(mutableItem) == 3 && BG3MFXMenuItemID(mutableItem) == vsyncID) {
        next(manager, item);
        syncFrameGenerationVSync(manager);
        return;
    }
    if (aa) {
        int aaValue = BG3MFXMenuComboSelection(item), taa = taaValue(mutableItem);
        bool metal = aaMetalFXValue >= 0 && aaValue == aaMetalFXValue;
        // BG3 only knows TAA; MetalFX AA is shown over it.
        if (metal && taa >= 0) BG3MFXMenuSetComboSelection(mutableItem, taa);
        if (!metal || taa >= 0) next(manager, item);
        if (metal) {
            BG3MFXMenuShowComboSelection(mutableItem, aaValue);
            return;
        }
        // Another option ends MetalFX AA, as its selection callback does.
        if (aaOnlyActive.load()) leaveAAOnly(manager, selectedScalingMode.load(), next);
        updateDependentControls(manager, selectedScalingMode.load());
        return;
    }
    int value = upscale ? BG3MFXMenuComboSelection(item) : -1;
    if (upscale && value == 0 && aaOnlyActive.load()) {
        // MetalFX AA keeps BG3's FSR setup while the type shows Off.
        float keep = currentSharpness(manager);
        BG3MFXMenuSetComboSelection(mutableItem, 1);
        next(manager, item);
        restoreCustomQuality(manager, 0, BG3MFXMetalFXAAQuality, false);
        restoreSharpness(manager, keep);
        BG3MFXMenuSetComboSelection(mutableItem, 0);
        updateDependentControls(manager, 0);
        return;
    }
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
    if (value == 0 && aaOnlyActive.load()) {
        // MetalFX AA runs on BG3's FSR setup with the type showing Off.
        BG3MFXMenuSetComboSelection(mutableItem, 0);
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
    callNativeType(storage, item, value);
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

// The Anti-Aliasing combo's selection callback: MetalFX AA is shown over BG3's TAA.
void aaChanged(void *storage, const void *item) {
    if (!originalAACall || !storage || !item) { if (originalAACall) originalAACall(storage, item); return; }
    void *mutableItem = const_cast<void *>(item);
    int value = BG3MFXMenuComboSelection(item);
    void *manager = BG3MFXMenuStorageManager(storage);
    if (syncingAA || aaMetalFXValue < 0 || value != aaMetalFXValue) {
        originalAACall(storage, item);
        if (!syncingAA && manager) {
            // The player chose a real option: forget the saved one and end
            // MetalFX AA (BG3 has just stored the choice, which the type's
            // callback then shows).
            [NSUserDefaults.standardUserDefaults removeObjectForKey:savedAntiAliasingPreference];
            if (aaOnlyActive.load()) leaveAAOnly(manager, selectedScalingMode.load());
            updateDependentControls(manager, selectedScalingMode.load());
        }
        return;
    }
    // MetalFX AA chosen (offered with the type Off, or dimmed with Temporal).
    // BG3's own setting becomes TAA; the entry stays shown.
    int taa = taaValue(mutableItem);
    if (taa < 0) { BG3MFXMenuProblem(@"No TAA Anti-Aliasing option found"); return; }
    syncingAA = true;
    BG3MFXMenuSetComboSelection(mutableItem, taa);
    originalAACall(storage, item);
    BG3MFXMenuShowComboSelection(mutableItem, value);
    syncingAA = false;
    if (!manager) return;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:savedAntiAliasingPreference];
    if (selectedScalingMode.load() == 0 && !aaOnlyActive.load()) enterAAOnly(manager);
    // The type callback showed BG3's TAA; this shows MetalFX AA again.
    updateDependentControls(manager, selectedScalingMode.load());
}
// Adds the MetalFX AA entry to the Anti-Aliasing combo when `offer` (telling
// the menu when `notify`) and takes the combo's callback.
void completeAA(void *aa, bool notify, bool offer) {
    NSArray<NSNumber *> *values = BG3MFXMenuComboValues(aa);
    if (taaValue(aa) < 0) return;
    if (offer && (aaMetalFXValue < 0 || ![values containsObject:@(aaMetalFXValue)])) {
        int highest = 0;
        for (NSNumber *v in values) highest = std::max(highest, v.intValue);
        BG3MFXMenuText name, description;
        if (BG3MFXMenuMakeText(name, "h00000000g0000g0000g0000g00000000f017", "MetalFX AA") &&
            BG3MFXMenuMakeText(description, "h00000000g0000g0000g0000g00000000f018",
                "Anti-aliasing with MetalFX Temporal at native resolution, with no upscaling. Selected automatically, and dimmed, while an upscaler that uses MetalFX Temporal is on.")) {
            BG3MFXMenuAppendComboValue(aa, highest + 1, name, description);
            aaMetalFXValue = highest + 1;
        } else BG3MFXMenuProblem(@"Could not register the MetalFX AA text.");
        BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
        if (notify) BG3MFXMenuComboItemsChanged(aa);
    }
    BG3MFXMenuCallback call = BG3MFXMenuSelectionCallback(aa);
    if (call != aaChanged) originalAACall = call;
    if (originalAACall) BG3MFXMenuSetSelectionCallback(aa, aaChanged);
}
void addMetalFXAA(void *manager) {
    if (void *aa = BG3MFXMenuFind(manager, 3, antiAliasingID)) completeAA(aa, true, true);
}
// BG3's RefreshUIAntiAliasing (menu build, Reset, every Upscaling Type change)
// rebuilds BG3's list, installs BG3's own callback again and shows BG3's
// setting; custom-menu runs this before the menu hears of it. The entry is left
// out while the type being applied is FSR or Spatial.
void antiAliasingRefreshed(void *manager, void *aa) {
    int mode = nativeTypeTarget;
    if (mode < 0) {
        // Outside a type change (menu build, Reset): BG3's own FSR type is not
        // tracked by selectedScalingMode until the menu is built. MetalFX AA
        // also runs as BG3's FSR, with the menu at Off.
        mode = selectedScalingMode.load();
        if (mode == 0 && !aaOnlyActive.load() && field<uint8_t>(manager, Layout::NativeUpscalingType) == 1) mode = 1;
    }
    completeAA(aa, false, aaOffered(mode));
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
    // MetalFX AA runs on BG3's FSR setup while the type shows Off.
    if (aaOnlyActive.load() && !metalFXValue(storedMode)) {
        mode = 0;
        BG3MFXMenuSetComboSelection(upscale, 0);
    } else if (aaOnlyActive.load()) {
        // A MetalFX type was saved: MetalFX AA is not restored with it.
        aaOnlyActive.store(false);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:metalFXAAPreference];
    }
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
    addMetalFXAA(manager);
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
    BG3MFXMenuOnAntiAliasingRefreshed(antiAliasingRefreshed);
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
    // MetalFX AA with the type Off: BG3's FSR setup at the hidden quality 5.
    if (startupMode == 0 && [defaults boolForKey:metalFXAAPreference]) {
        aaOnlyActive.store(true);
        startupQuality.store(BG3MFXMetalFXAAQuality);
    } else [defaults removeObjectForKey:metalFXAAPreference];
    // Dynamic's minimum frame rate and thermal guard no longer exist.
    [defaults removeObjectForKey:@"BG3MFXDynamicMinimumFrameRate"];
    [defaults removeObjectForKey:@"BG3MFXDynamicThermalGuard"];
    id savedQuality = [defaults objectForKey:qualityPreference];
    // The unreleased Max Performance quality 5 is now Ultra Performance.
    if (savedQuality && [savedQuality intValue] == 5) {
        [defaults setInteger:BG3MFXUltraPerformanceQuality forKey:qualityPreference];
        savedQuality = @(BG3MFXUltraPerformanceQuality);
    }
    if (savedQuality && [savedQuality intValue] == BG3MFXUltraPerformanceQuality && !aaOnlyActive.load()) startupQuality.store([savedQuality intValue]);
    frameGenerationChecked.store([defaults boolForKey:frameGenerationPreference]);
}

// MetalFX AA with the type Off runs MetalFX Temporal (3).
int BG3MFXSelectedScalingMode(void) { return aaOnlyActive.load() ? 3 : selectedScalingMode.load(); }
// Frame Generation needs BG3's VSync, checked live: a saved tick with VSync Off
// stays inactive until Options is opened, and a VSync change that bypasses the
// menu (a reverted display setting) ends it at once.
BOOL BG3MFXFrameGenerationEnabled(void) { return frameGenerationChecked.load() && frameGenerationSupported() && bg3VSyncOn(); }

void BG3MFXPublishStartupReducedQuality(void) {
    int quality = startupQuality.load();
    if (!quality || BG3MFXMenuOptionsBuilt() || !(reducedOffered(selectedScalingMode.load()) || aaOnlyActive.load())) return;
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
    aaOnlyActive.store(false);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:scalingPreference];
    [defaults removeObjectForKey:metalFXAAPreference];
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
