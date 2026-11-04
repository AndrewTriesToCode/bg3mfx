#include "common/Feature.h"
#import "common/EventLog.h"
#import "features/custom-menu/CustomMenu.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cstdlib>
#include <cstring>

// The metal-hud feature: a persistent Show Metal HUD checkbox at the top of
// General in Video options, which shows or hides Apple's Metal performance
// overlay on BG3's layers.

namespace {
constexpr uint16_t hudID = 0x7f01;
NSString *const hudPreference = @"BG3MFXMetalHUD";
BOOL hudEnabled;

void applyLayer(CALayer *layer) {
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *metal = (CAMetalLayer *)layer;
        NSMutableDictionary *properties = [metal.developerHUDProperties mutableCopy] ?: [NSMutableDictionary dictionary];
        properties[@"mode"] = hudEnabled ? @"default" : @"disabled";
        metal.developerHUDProperties = properties;
    }
    for (CALayer *child in layer.sublayers) applyLayer(child);
}
void applyView(NSView *view) {
    applyLayer(view.layer);
    for (NSView *child in view.subviews) applyView(child);
}
void applyHUD() {
    for (NSWindow *window in NSApp.windows) applyView(window.contentView);
    BG3MFX_EVENT(@{@"event":@"metalHUDChanged", @"enabled":@(hudEnabled)});
}
void applyHUDOnMain() {
    if (NSThread.isMainThread) applyHUD(); else dispatch_async(dispatch_get_main_queue(), ^{ applyHUD(); });
}
void hudChanged(void *, const void *item) {
    if (!item || BG3MFXMenuItemID(const_cast<void *>(item)) != hudID) return;
    hudEnabled = BG3MFXMenuTickBoxValue(item);
    [NSUserDefaults.standardUserDefaults setBool:hudEnabled forKey:hudPreference];
    applyHUDOnMain();
}
void menuBuilt(void *manager) {
    BG3MFXMenuText name, description;
    if (!BG3MFXMenuMakeText(name, "h00000000g0000g0000g0000g00000000f003", "Show Metal HUD") ||
        !BG3MFXMenuMakeText(description, "h00000000g0000g0000g0000g00000000f004",
                            "Shows Apple's Metal performance overlay. Changes take effect immediately.")) {
        BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
        BG3MFXMenuProblem(@"Could not register the Show Metal HUD text.");
        return;
    }
    void *hud = BG3MFXMenuAddTickBox(manager, hudID, name, description, hudEnabled, hudChanged);
    BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
    // First under General, before the first native control (Display Mode).
    size_t count = BG3MFXMenuItemCount(manager);
    if (hud && count && BG3MFXMenuItem(manager, count - 1) == hud)
        for (size_t i = 0; i + 1 < count; ++i)
            if (BG3MFXMenuItemType(BG3MFXMenuItem(manager, i)) == 3) { BG3MFXMenuMoveLast(manager, i); break; }
    applyHUDOnMain();
}
BOOL installMetalHUD(const BG3MFXFeatureContext &, NSError **) {
    // The launcher always loads the HUD so the checkbox can toggle it; until
    // the player chooses, it follows MTL_HUD_HIDDEN.
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:hudPreference];
    hudEnabled = saved ? [saved boolValue] : (getenv("MTL_HUD_ENABLED") && strcmp(getenv("MTL_HUD_ENABLED"), "1") == 0 &&
        !(getenv("MTL_HUD_HIDDEN") && strcmp(getenv("MTL_HUD_HIDDEN"), "1") == 0));
    BG3MFXMenuOnBuilt(menuBuilt);
    return YES;
}
const char *const metalHUDRequires[] = {"custom-menu", nullptr};
}
BG3MFX_FEATURE(metalHUD, {"metal-hud", metalHUDRequires, false, nullptr, installMetalHUD, nullptr});
