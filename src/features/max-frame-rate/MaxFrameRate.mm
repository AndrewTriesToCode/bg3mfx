#include "common/Feature.h"
#import "features/custom-menu/CustomMenu.h"
#import "features/metal-hooks/MetalHooks.h"
#import "common/native/SupportedBuild.h"
#import "common/ScreenTiming.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <string>

// The max-frame-rate feature: two checkboxes under the Max Frame Rate tick box
// and above its slider, available while the cap is on. Snap to Native FPS
// does two things:
// - keeps the slider on rates the screen paces evenly, to the nearest (the
//   arrows step to the next): the divisors of its native refresh rates, down
//   to 30 (120, 80, 60, 48, 40, 30 on ProMotion; 60, 30 on a fixed 60 Hz
//   screen);
// - paces presents to the cap: BG3 presents each frame no sooner than
//   1/(refresh rate + 1) after the last; that minimum becomes 1/rate - 0.25 ms,
//   with the rate the lowest the screen can show that is at least the cap (the
//   cap itself once snapped).
// FPS Thermal Guard, independent of Snap and of the upscaler's Thermal Guard, lowers the frame rate while macOS reports a
// thermal state above nominal, without changing the saved cap.

namespace {
// BG3's cap: a tick box (0x53) for on/off and a slider (0x54) for the rate.
constexpr uint16_t snapID = 0x7f07, thermalGuardID = 0x7f08, frameCapToggleID = 0x53, frameCapID = 0x54;
NSString *const snapPreference = @"BG3MFXSnapNativeFPS", *const thermalGuardPreference = @"BG3MFXFPSThermalGuard";
std::atomic<bool> snapChecked{false}, thermalGuardChecked{false};
BG3MFXMenuCallback capToggleChanged, capChanged;  // BG3's own
uintptr_t settingsGlobal;

template<class T> T read(const void *p, size_t offset) {
    T value; memcpy(&value, static_cast<const char *>(p) + offset, sizeof value); return value;
}
// BG3's live Video settings: the frame cap's toggle and frames per second.
// Zero when the cap is off.
uint16_t activeFrameCap() {
    namespace Temporal = BG3MFXBuild::Temporal::Layout;
    const void *settings = *reinterpret_cast<void *const *>(settingsGlobal);
    if (!settings || !read<uint8_t>(settings, Temporal::SettingsFrameCapEnabled)) return 0;
    return read<uint16_t>(settings, Temporal::SettingsFrameCap);
}
// The lowest rate the screen shows that is at least `cap`: its longest
// interval no longer than 1/cap. `cap` itself when the screen is unknown.
double displayRate(uint16_t cap) {
    BG3MFXScreenTiming screen = BG3MFXScreenTimingCurrent();
    double minimum = screen.minimumInterval, maximum = screen.maximumInterval, step = screen.granularity;
    if (minimum <= 0 || step <= 0) return cap;
    double interval = 1.0 / cap;
    if (interval <= minimum) return 1.0 / minimum;
    double steps = std::floor((interval - minimum) / step + 1e-6);
    interval = std::min(minimum + steps * step, std::max(maximum, minimum));
    return 1.0 / interval;
}
// Item ids are unique only per type: the cap's items are not combos.
void *findCapItem(void *manager, uint16_t id) {
    for (size_t i = 0, count = BG3MFXMenuItemCount(manager); i < count; ++i) {
        void *item = BG3MFXMenuItem(manager, i);
        if (BG3MFXMenuItemID(item) == id && BG3MFXMenuItemType(item) != 3) return item;
    }
    return nullptr;
}
size_t indexOf(void *manager, void *item) {
    for (size_t i = 0, count = BG3MFXMenuItemCount(manager); i < count; ++i)
        if (BG3MFXMenuItem(manager, i) == item) return i;
    return SIZE_MAX;
}
// The slider's range (AddSliderOption's 10 and 240).
constexpr int lowestCap = 10, highestCap = 240;
// The lowest rate Snap and FPS Thermal Guard use (the screen's refresh rate,
// if lower).
constexpr int lowestNative = 30;
// Whether the screen shows `rate` natively: no faster than the screen, its
// interval a whole number of the screen's update steps (the refresh interval
// on a fixed-rate screen, and on a variable one without steps), so the rates
// that divide the native refresh rates, down to lowestNative. Every rate from
// lowestNative when the screen is unknown.
bool nativeRate(int rate) {
    BG3MFXScreenTiming screen = BG3MFXScreenTimingCurrent();
    double minimum = screen.minimumInterval, step = screen.granularity;
    double interval = 1.0 / rate;
    if (rate < lowestNative && !(minimum > 0 && std::fabs(interval - minimum) < 1e-6)) return false;
    if (step <= 0) step = minimum;
    if (step <= 0) return true;
    double steps = interval / step;
    return interval >= minimum - 1e-6 && std::fabs(steps - std::round(steps)) < 1e-3;
}
// The native rate closest to `value` (the lower on a tie).
float nearestRate(float value) {
    int best = 0;
    for (int rate = lowestCap; rate <= highestCap; ++rate)
        if (nativeRate(rate) && (!best || std::fabs(rate - value) < std::fabs(best - value))) best = rate;
    return best ? best : value;
}
// The next native rate above (`direction` 1) or below (-1) `value`, or
// `value` at the end of the range.
float nextRate(float value, int direction) {
    for (int rate = int(std::lround(value)) + direction; rate >= lowestCap && rate <= highestCap; rate += direction)
        if (nativeRate(rate)) return rate;
    return value;
}
// FPS Thermal Guard: a lower frame rate while macOS reports a thermal state
// above nominal (NSProcessInfo thermalState: fair, serious or critical). After
// GuardDropSeconds above nominal it steps down one native rate, and again every
// GuardDropSeconds, to the lowest native rate; after
// GuardRiseSeconds at nominal it steps back up one rate at a time until it no
// longer limits. The upscaler's Thermal Guard cuts at once and every 5 s and
// recovers every 15 s, so it reacts first and this one recovers first.
constexpr double GuardDropSeconds = 10, GuardRiseSeconds = 10;
// Render thread only.
int guardRate;  // 0 while not limiting
bool guardHot;
double guardSteppedAt;
int thermalGuardRate(uint16_t cap) {
    if (!thermalGuardChecked.load(std::memory_order_relaxed) || !cap) { guardRate = 0; guardHot = false; return 0; }
    double now = CACurrentMediaTime();
    bool hot = NSProcessInfo.processInfo.thermalState > NSProcessInfoThermalStateNominal;
    if (hot != guardHot) { guardHot = hot; guardSteppedAt = now; }
    // Unlimited, start from the highest native rate at or under the cap: an
    // unsnapped cap (65) already runs at the one below it (60).
    int current = guardRate;
    if (!current) for (current = cap; current > lowestCap && !nativeRate(current); --current) {}
    if (hot && now - guardSteppedAt >= GuardDropSeconds) {
        guardSteppedAt = now;
        for (int rate = current - 1; rate >= lowestCap; --rate)
            if (nativeRate(rate)) { guardRate = rate; break; }
    } else if (!hot && guardRate && now - guardSteppedAt >= GuardRiseSeconds) {
        guardSteppedAt = now;
        int rate = guardRate + 1;
        while (rate < cap && !nativeRate(rate)) ++rate;
        guardRate = rate >= cap ? 0 : rate;
    }
    return guardRate;
}
// Snap paces presents to the cap; the guard's rate, when lower, lengthens the
// minimum further. BG3's saved cap is unchanged.
double presentDuration(double duration) {
    uint16_t cap = activeFrameCap();
    if (cap && snapChecked.load(std::memory_order_relaxed)) duration = 1.0 / displayRate(cap) - 0.00025;
    if (int rate = thermalGuardRate(cap)) duration = std::max(duration, 1.0 / rate - 0.00025);
    return duration;
}
// The rate Snap last showed on the slider, NAN before it showed one.
float shownRate = NAN;
// Shows the snapped rate on the slider before BG3 reads it: BG3 applies the
// slider's value (item +0xb8) after its callback, every UI frame of a drag.
// A change of exactly one from the rate shown, as the slider's arrows (and
// keys) make, moves to the next native rate that way; anything else (a drag)
// snaps to the nearest.
void snapCap(void *slider) {
    if (!snapChecked || !slider) return;
    float value = BG3MFXMenuSliderValue(slider), snapped;
    float change = std::isnan(shownRate) ? 0 : value - shownRate;
    if (std::fabs(std::fabs(change) - 1) < 1e-4) snapped = nextRate(shownRate, change > 0 ? 1 : -1);
    else snapped = nearestRate(value);
    shownRate = snapped;
    if (snapped != value) BG3MFXMenuShowSliderValue(slider, snapped);
}
void sliderChanged(void *storage, const void *item) {
    snapCap(const_cast<void *>(item));
    if (capChanged) capChanged(storage, item);
}
bool capOn(void *manager) {
    void *toggle = findCapItem(manager, frameCapToggleID);
    return toggle ? BG3MFXMenuTickBoxValue(toggle) : activeFrameCap() != 0;
}
void refreshEnabled(void *manager) {
    bool on = capOn(manager);
    BG3MFXMenuSetEnabled(BG3MFXMenuFind(manager, -1, snapID), on);
    BG3MFXMenuSetEnabled(BG3MFXMenuFind(manager, -1, thermalGuardID), on);
}
void capToggled(void *storage, const void *item) {
    if (capToggleChanged) capToggleChanged(storage, item);
    if (void *manager = BG3MFXMenuManager()) refreshEnabled(manager);
}
void snapChanged(void *, const void *item) {
    if (!item || BG3MFXMenuItemID(const_cast<void *>(item)) != snapID) return;
    snapChecked.store(BG3MFXMenuTickBoxValue(item));
    [NSUserDefaults.standardUserDefaults setBool:snapChecked.load() forKey:snapPreference];
    // Snap the current cap through BG3's callback, as a drag would.
    void *manager = BG3MFXMenuManager();
    void *slider = manager ? findCapItem(manager, frameCapID) : nullptr;
    if (!slider) return;
    float before = BG3MFXMenuSliderValue(slider);
    shownRate = NAN;
    snapCap(slider);
    if (BG3MFXMenuSliderValue(slider) != before && capChanged) capChanged(BG3MFXMenuCallbackStorage(slider), slider);
}
void thermalGuardChanged(void *, const void *item) {
    if (!item || BG3MFXMenuItemID(const_cast<void *>(item)) != thermalGuardID) return;
    thermalGuardChecked.store(BG3MFXMenuTickBoxValue(item));
    [NSUserDefaults.standardUserDefaults setBool:thermalGuardChecked.load() forKey:thermalGuardPreference];
}
// Settings reset or restored by Apply.
void applyCombo(void *manager, const void *item, BG3MFXMenuApply next) {
    next(manager, item);
    refreshEnabled(manager);
}
// BG3 indents the cap's slider in its own menu layout, which options cannot
// set; leading em spaces line the new labels up with it.
constexpr const char *labelIndent = "\u2003\u2003";
// Adds a tick box `offset` places under the cap's tick box (or that far above
// the slider without it), its label indented; null after reporting why.
void *addUnderCapToggle(void *manager, size_t offset, uint16_t id, const char *nameHandle, const char *nameText,
                        const char *descriptionHandle, const char *descriptionText, bool value, BG3MFXMenuCallback changed) {
    BG3MFXMenuText name, description;
    std::string label = std::string(labelIndent) + nameText;
    if (!BG3MFXMenuMakeText(name, nameHandle, label.c_str()) || !BG3MFXMenuMakeText(description, descriptionHandle, descriptionText)) {
        BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
        BG3MFXMenuProblem([NSString stringWithFormat:@"Could not register the %s text.", nameText]);
        return nullptr;
    }
    void *box = BG3MFXMenuAddTickBox(manager, id, name, description, value, changed);
    BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
    if (!box) { BG3MFXMenuProblem([NSString stringWithFormat:@"Could not add the %s option.", nameText]); return nullptr; }
    size_t count = BG3MFXMenuItemCount(manager), toggle = indexOf(manager, findCapItem(manager, frameCapToggleID));
    size_t slider = indexOf(manager, findCapItem(manager, frameCapID));
    size_t index = toggle != SIZE_MAX ? toggle + 1 + offset : slider != SIZE_MAX ? slider + offset : SIZE_MAX;
    if (index == SIZE_MAX || !count || BG3MFXMenuItem(manager, count - 1) != box)
        BG3MFXMenuProblem([NSString stringWithFormat:@"Could not find Max Frame Rate; %s is at the end of Video options.", nameText]);
    else BG3MFXMenuMoveLast(manager, index);
    return box;
}
void menuBuilt(void *manager) {
    // Under the cap's tick box, above its slider: Snap, then FPS Thermal Guard.
    addUnderCapToggle(manager, 0, snapID, "h00000000g0000g0000g0000g00000000f019", "Snap to Native FPS",
                "h00000000g0000g0000g0000g00000000f01a",
                "Keeps Max Frame Rate on rates the display shows evenly and paces frames to it. Available while Max Frame Rate is on.",
                snapChecked.load(), snapChanged);
    addUnderCapToggle(manager, 1, thermalGuardID, "h00000000g0000g0000g0000g00000000f01b", "FPS Thermal Guard",
                "h00000000g0000g0000g0000g00000000f01c",
                "Lowers the frame rate while the Mac is warmer than normal, and restores it as it cools. Available while Max Frame Rate is on.",
                thermalGuardChecked.load(), thermalGuardChanged);
    // BG3's cap items are rebuilt with the menu: wrap their callbacks again.
    shownRate = NAN;
    if (void *slider = findCapItem(manager, frameCapID)) {
        if (snapChecked) shownRate = nearestRate(BG3MFXMenuSliderValue(slider));
        if (BG3MFXMenuSelectionCallback(slider) != sliderChanged) capChanged = BG3MFXMenuSelectionCallback(slider);
        BG3MFXMenuSetSelectionCallback(slider, sliderChanged);
    }
    if (void *toggle = findCapItem(manager, frameCapToggleID)) {
        if (BG3MFXMenuSelectionCallback(toggle) != capToggled) capToggleChanged = BG3MFXMenuSelectionCallback(toggle);
        BG3MFXMenuSetSelectionCallback(toggle, capToggled);
    }
    refreshEnabled(manager);
}
BOOL installMaxFrameRate(const BG3MFXFeatureContext &context, NSError **) {
    snapChecked.store([NSUserDefaults.standardUserDefaults boolForKey:snapPreference]);
    thermalGuardChecked.store([NSUserDefaults.standardUserDefaults boolForKey:thermalGuardPreference]);
    settingsGlobal = BG3MFXBuild::Temporal::Settings + context.slide;
    if (!BG3MFXMetalHooksFilterPresentDuration(presentDuration)) return NO;
    BG3MFXMenuOnBuilt(menuBuilt);
    BG3MFXMenuWrapApplyCombo(applyCombo);
    BG3MFXScreenTimingStart();
    return YES;
}
const char *const maxFrameRateRequires[] = {"custom-menu", "metal-hooks", nullptr};
}
BG3MFX_FEATURE(maxFrameRate, {"max-frame-rate", maxFrameRateRequires, true, installMaxFrameRate, nullptr});
