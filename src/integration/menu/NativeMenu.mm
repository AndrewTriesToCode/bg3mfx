#include "common/native/SupportedBuild.h"
#import "integration/menu/NativeMenu.h"
#import "features/metalfx-temporal-upscaling/TemporalJitter.h"
#import "features/shadows/ShadowDuplicateFix.h"
#import "features/lua-jump-fix/LuaJumpFix.h"
#ifndef BG3MFX_NO_TRACE
#import "integration/diagnostics/ServerPacingProbe.h"
#endif
#import "features/thread-idling/ThreadIdling.h"
#import "features/reduce-locking/UniformSlices.h"
#import <MetalFX/MetalFX.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <atomic>
#include <cstring>
#include <cstdlib>
#include <objc/runtime.h>

namespace Native = BG3MFXBuild::Menu;
namespace Layout = BG3MFXBuild::Menu::Layout;

namespace {
struct View { const char *data; uint32_t size; uint32_t padding; };
struct Handle { uint32_t id; uint16_t version; uint16_t padding; };
struct Text { Handle primary, arguments; };
static intptr_t slide;
static void (*reportEvent)(NSDictionary *);
static void (*originalInit)(void *);
static void (*originalApplyCombo)(void *, const void *);
static void (*originalUpscaleCall)(void *, const void *);
static void (*originalQualityCall)(void *, const void *);
static BOOL hudEnabled;
// Upscaling Type menu value: 0 Off, 1 FSR, 2 Spatial, 3 Temporal. Frame
// Generation is a separate checkbox that combines with any of them.
static std::atomic<int> selectedScalingMode{0};
static std::atomic<bool> frameGenerationChecked{false};
static bool metalFXValue(int value) { return value == 2 || value == 3; }
static bool temporalValue(int value) { return value == 3; }
static NSString *const frameGenerationPreference = @"BG3MFXFrameGenerationEnabled";
// The player's Anti-Aliasing choice while MetalFX holds it at TAA.
static NSString *const savedAntiAliasingPreference = @"BG3MFXSavedAntiAliasing";
// The open Video options manager, for the Frame Generation checkbox callback.
static void *optionsManager;
// Earlier builds stored Frame Generation as a Temporal-only checkbox under this
// key, then as Upscaling Type values 4 (Temporal + FG) and 5 (Spatial + FG).
static NSString *const legacyFrameGenerationPreference=@"BG3MFXFrameGeneration";
static NSString *const hudPreference = @"BG3MFXMetalHUD";
static NSString *const scalingPreference = @"BG3MFXUpscalingType";
static NSString *const qualityPreference = @"BG3MFXUpscalingQuality";
static const uint16_t hudID = 0x7f01;
static const uint16_t frameGenerationID = 0x7f02;
static IMP originalSetContentView;
static NSWindow *pendingFocusWindow;
static NSView *pendingFocusView;

static void event(NSDictionary *value);
template<class T> T at(uintptr_t address) { return reinterpret_cast<T>(address + slide); }
template<class T> T &field(void *object, size_t offset) { return *reinterpret_cast<T *>(static_cast<char *>(object) + offset); }
static void event(NSDictionary *value) { if (reportEvent) reportEvent(value); }
static bool isGameRenderView(NSView *view) {
    Class renderViewClass = NSClassFromString(@"LSMTLView");
    return view && renderViewClass && [view isKindOfClass:renderViewClass];
}
static void setContentViewWithFocusRepair(NSWindow *window, SEL selector, NSView *view) {
    using SetContentView = void (*)(id, SEL, NSView *);
    auto original = reinterpret_cast<SetContentView>(originalSetContentView);
    if (!original) return;

    if (NSThread.isMainThread && !view && window.contentView && isGameRenderView(window.contentView) &&
        window.firstResponder == window.contentView) {
        // BindSurface removes and reattaches the same render view synchronously.
        // Keep it alive across the pair, but only try to restore the focus it had.
        pendingFocusWindow = window;
        pendingFocusView = window.contentView;
    } else if (view && pendingFocusWindow != window) {
        pendingFocusWindow = nil;
        pendingFocusView = nil;
    }

    original(window, selector, view);

    if (!view || pendingFocusWindow != window) return;
    // Any view set in this window ends the pair; a different view must not
    // keep the old render view (and its layer) alive.
    NSView *restoreView = pendingFocusView;
    pendingFocusWindow = nil;
    pendingFocusView = nil;
    if (restoreView != view) return;

    NSWindow *modalWindow = NSApp.modalWindow;
    bool eligible = NSThread.isMainThread && NSApp.isActive && window.isKeyWindow &&
        !window.attachedSheet && !modalWindow &&
        (window.firstResponder == window || window.firstResponder == nil);
    bool restored = eligible && [window makeFirstResponder:restoreView];
#ifndef BG3MFX_NO_TRACE
    event(@{@"event":@"nativeMenuFocusRepair", @"attempted":@(eligible),
        @"restored":@(restored), @"keyWindow":@(window.isKeyWindow),
        @"active":@(NSApp.isActive)});
#else
    (void)restored;
#endif
}
static bool installRenderViewFocusRepair() {
    Class windowClass = NSClassFromString(@"LSWindow");
    SEL selector = @selector(setContentView:);
    Method method = windowClass ? class_getInstanceMethod(windowClass, selector) : nullptr;
    if (!method || method_getNumberOfArguments(method) != 3) return false;
    char *returnType = method_copyReturnType(method);
    char *viewType = method_copyArgumentType(method, 2);
    bool signatureOK = returnType && returnType[0] == 'v' && viewType && viewType[0] == '@';
    free(returnType);
    free(viewType);
    if (!signatureOK) return false;
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding) return false;
    IMP current = method_getImplementation(method);
    if (current == reinterpret_cast<IMP>(setContentViewWithFocusRepair)) return true;
    originalSetContentView = current;
    if (class_addMethod(windowClass, selector, reinterpret_cast<IMP>(setContentViewWithFocusRepair), encoding))
        return true; // The original implementation was inherited; the override is local to LSWindow.
    originalSetContentView = class_replaceMethod(windowClass, selector,
        reinterpret_cast<IMP>(setContentViewWithFocusRepair), encoding);
    return originalSetContentView != nullptr;
}
static void errorOut(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"BG3MFXNativeMenu" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static void applyLayer(CALayer *layer) {
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *metal = (CAMetalLayer *)layer;
        NSMutableDictionary *properties = [metal.developerHUDProperties mutableCopy] ?: [NSMutableDictionary dictionary];
        properties[@"mode"] = hudEnabled ? @"default" : @"disabled";
        metal.developerHUDProperties = properties;
    }
    for (CALayer *child in layer.sublayers) applyLayer(child);
}
static void applyView(NSView *view) {
    applyLayer(view.layer);
    for (NSView *child in view.subviews) applyView(child);
}
static void applyHUD() {
    for (NSWindow *window in NSApp.windows) applyView(window.contentView);
    event(@{@"event":@"metalHUDChanged",@"enabled":@(hudEnabled)});
}
static void hudChanged(void *, const void *item) {
    if (!item || field<uint16_t>(const_cast<void *>(item),Layout::ItemID) != hudID) return;
    hudEnabled = field<uint8_t>(const_cast<void *>(item),Layout::CheckboxValue) != 0;
    [NSUserDefaults.standardUserDefaults setBool:hudEnabled forKey:hudPreference];
    if (NSThread.isMainThread) applyHUD(); else dispatch_async(dispatch_get_main_queue(),^{ applyHUD(); });
}
static void updateDependentControls(void *manager, int mode);
static void frameGenerationChanged(void *, const void *item) {
    if (!item || field<uint16_t>(const_cast<void *>(item),Layout::ItemID) != frameGenerationID) return;
    bool enabled = field<uint8_t>(const_cast<void *>(item),Layout::CheckboxValue) != 0;
    frameGenerationChecked.store(enabled);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:frameGenerationPreference];
    // BG3 can quit right after a change; keep the next launch consistent.
    [NSUserDefaults.standardUserDefaults synchronize];
    event(@{@"event":@"frameGenerationChanged",@"enabled":@(enabled)});
    if (optionsManager) updateDependentControls(optionsManager,selectedScalingMode.load());
}
static void *findItem(void *manager, uint8_t type, uint16_t id) {
    void **items = field<void **>(manager,Layout::Items);
    uint32_t count = field<uint32_t>(manager,Layout::ItemCount);
    if (!items || count > 256) return nullptr;
    for (uint32_t i=0;i<count;++i)
        if (field<uint8_t>(items[i],Layout::ItemType) == type && field<uint16_t>(items[i],Layout::ItemID) == id) return items[i];
    return nullptr;
}
static void setItemEnabled(void *item, uint8_t enabled) {
    if (!item || field<uint8_t>(item,Layout::ItemEnabled) == enabled) return;
    field<uint8_t>(item,Layout::ItemEnabled) = enabled;
    // Match RefreshUIAntiAliasing's EnabledChanged notifications.
    void *observers = field<void *>(item,Layout::EnabledObservers);
    int32_t observersCount = field<int32_t>(item,Layout::EnabledObserverCount);
    if (!observers || observersCount < 0 || observersCount > 256) return;
    for (int32_t j=0;j<observersCount;++j) {
        char *entry = static_cast<char *>(observers) + j*Layout::ObserverStride;
        void **table = field<void **>(entry,Layout::VTable);
        if (table && table[0]) reinterpret_cast<void(*)(void *)>(table[0])(entry+Layout::ObserverContext);
    }
}
static NSArray *comboValues(void *combo, uint32_t count);
static bool frameGenerationSupported() {
    static bool supported = [MTLFXFrameInterpolatorDescriptor supportsDevice:MTLCreateSystemDefaultDevice()];
    return supported;
}
// The Anti-Aliasing combo value labelled "TAA", or -1. ComboItems are 0x24
// bytes: label Text at +0, description at +0x10, enum value at +0x20.
static int taaValue(void *aa) {
    uint32_t count = field<uint32_t>(aa,Layout::ComboCount);
    char *array = field<char *>(aa,Layout::ComboItems);
    if (!array || count > 16) return -1;
    for (uint32_t i=0;i<count;++i) {
        View label = at<View(*)(const void *,uint32_t,uint32_t)>(Native::ResolveText)(array+i*Layout::ComboItemStride,0,0);
        if (label.data && label.size >= 3 && label.size < 64 && memmem(label.data,label.size,"TAA",3))
            return (int)field<uint32_t>(array+i*Layout::ComboItemStride,Layout::ComboItemValue);
    }
    return -1;
}
// Select an Anti-Aliasing value through BG3's own callback, and show it.
static void selectAntiAliasing(void *aa, int value) {
    field<int32_t>(aa,Layout::ComboSelection) = value;
    if (auto call = field<void(*)(void *,const void *)>(aa,Layout::SelectionCallback)) call(static_cast<char *>(aa)+Layout::SelectionCallback,aa);
    void *observers = field<void *>(aa,Layout::SelectionObservers);
    int32_t observerCount = field<int32_t>(aa,Layout::SelectionObserverCount);
    if (observers && observerCount >= 0 && observerCount <= 256) for (int32_t j=0;j<observerCount;++j) {
        char *entry = static_cast<char *>(observers)+j*Layout::ObserverStride;
        void **table = field<void **>(entry,Layout::VTable);
        if (table && table[0]) reinterpret_cast<void(*)(void *,int)>(table[0])(entry+Layout::ObserverContext,value);
    }
}
static void *findItemByID(void *manager, uint16_t id) {
    void **items = field<void **>(manager,Layout::Items);
    uint32_t count = field<uint32_t>(manager,Layout::ItemCount);
    if (!items || count > 256) return nullptr;
    for (uint32_t i=0;i<count;++i) if (field<uint16_t>(items[i],Layout::ItemID) == id) return items[i];
    return nullptr;
}
static const uint16_t upscaleSharpnessID = 101;
// The player's sharpness is what the slider shows: moving it updates only the
// slider until Apply copies it to the manager (VideoOptionsManager::ApplySlider).
static float currentSharpness(void *manager) {
    void *slider = findItemByID(manager,upscaleSharpnessID);
    return slider ? field<float>(slider,Layout::SliderValue)/100 : field<float>(manager,Layout::UpscaleSharpness);
}
// BG3's FSR quality setter resets Upscaling Sharpness to 0.8 whenever the quality
// changes, which the MetalFX bridge does behind the player's back. Put back the
// player's value and show it, as the native Upscaling Type callback does.
static bool restoreSharpness(void *manager, float value) {
    bool changed = field<float>(manager,Layout::UpscaleSharpness) != value;
    field<float>(manager,Layout::UpscaleSharpness) = value;
    void *slider = findItemByID(manager,upscaleSharpnessID);
    if (!slider) return changed;
    if (field<float>(slider,Layout::SliderValue) == value*100) return changed;
    float shown = value*100;
    field<float>(slider,Layout::SliderValue) = shown;
    void *observers = field<void *>(slider,Layout::SliderObservers);
    int32_t observerCount = field<int32_t>(slider,Layout::SliderObserverCount);
    if (observers && observerCount >= 0 && observerCount <= 256) for (int32_t j=0;j<observerCount;++j) {
        char *entry = static_cast<char *>(observers)+j*Layout::ObserverStride;
        void **table = field<void **>(entry,Layout::VTable);
        if (table && table[0]) reinterpret_cast<void(*)(void *,float)>(table[0])(entry+Layout::ObserverContext,shown);
    }
    return changed;
}
static void updateDependentControls(void *manager, int mode) {
    // Upscaling Sharpness drives FSR's RCAS pass, which MetalFX replaces; dim it
    // there. BG3 enables it for its FSR type, which the MetalFX types run as.
    if (metalFXValue(mode)) setItemEnabled(findItemByID(manager,upscaleSharpnessID),0);
    // MetalFX Temporal and Frame Generation use the depth, motion and camera
    // data of BG3's TAA pass (Temporal then replaces its draw). While either is
    // on, select TAA and dim the control; afterwards restore the player's choice.
    void *aa = findItem(manager,3,98);
    if (!aa) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    bool requiresTAA = temporalValue(mode) || (frameGenerationChecked.load() && frameGenerationSupported());
    int current = field<int32_t>(aa,Layout::ComboSelection), taa = taaValue(aa);
    if (requiresTAA && taa >= 0 && current != taa) {
        if (![defaults objectForKey:savedAntiAliasingPreference]) [defaults setInteger:current forKey:savedAntiAliasingPreference];
        selectAntiAliasing(aa,taa);
        event(@{@"event":@"antiAliasingForced",@"previous":@(current),@"taa":@(taa)});
    } else if (!requiresTAA && [defaults objectForKey:savedAntiAliasingPreference]) {
        int saved = (int)[defaults integerForKey:savedAntiAliasingPreference];
        [defaults removeObjectForKey:savedAntiAliasingPreference];
        if (saved != current && [comboValues(aa,field<uint32_t>(aa,Layout::ComboCount)) containsObject:@(saved)]) {
            selectAntiAliasing(aa,saved);
            event(@{@"event":@"antiAliasingRestored",@"value":@(saved)});
        }
    }
    if (requiresTAA && taa < 0) event(@{@"event":@"nativeMenuError",@"error":@"No TAA Anti-Aliasing option found"});
    setItemEnabled(aa,!requiresTAA && field<uint32_t>(aa,Layout::ComboCount) > 1);
}
static int customQuality(void *manager) {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:qualityPreference];
    int value = saved ? [saved intValue] : (field<uint8_t>(manager,Layout::NativeUpscalingType) == 1 ? field<uint8_t>(manager,Layout::NativeQuality) : 2);
    return value >= 0 && value <= 3 ? value : 2;
}
static void restoreCustomQuality(void *manager, int value, BOOL refresh) {
    // Applying native type 1 always chooses Balanced. Reapply the requested
    // quality through BG3's setter, including the actual render-resolution state.
    at<void(*)(void *,int)>(Native::SetQuality)(static_cast<char *>(manager)+Layout::SettingsStorage,value);
    if (!refresh) return;
    // The native type callback already rebuilt the quality list. Rebuilding it
    // again while its UI change is being handled can leave the displayed value
    // blank. Update only the selection, using RefreshUIUpscaleMode's observed
    // SelectedChanged notification ABI.
    void **items = field<void **>(manager,Layout::Items);
    uint32_t count = field<uint32_t>(manager,Layout::ItemCount);
    if (items && count <= 256) for (uint32_t i=0;i<count;++i) {
        void *item = items[i];
        if (field<uint8_t>(item,Layout::ItemType) != 3 || field<uint16_t>(item,Layout::ItemID) != 100 || field<uint32_t>(item,Layout::ComboCount) != 4) continue;
        field<int32_t>(item,Layout::ComboSelection) = value;
        void *observers = field<void *>(item,Layout::SelectionObservers);
        int32_t observerCount = field<int32_t>(item,Layout::SelectionObserverCount);
        if (observers && observerCount >= 0 && observerCount <= 256) for (int32_t j=0;j<observerCount;++j) {
            char *entry = static_cast<char *>(observers)+j*Layout::ObserverStride;
            void **table = field<void **>(entry,Layout::VTable);
            if (table && table[0]) reinterpret_cast<void(*)(void *,int)>(table[0])(entry+Layout::ObserverContext,value);
        }
        event(@{@"event":@"nativeQualityRestored",@"value":@(value)});
        return;
    }
    at<void(*)(void *)>(Native::RefreshQuality)(manager);
}
static void qualityChanged(void *storage, const void *item) {
    int value = item ? field<int32_t>(const_cast<void *>(item),Layout::ComboSelection) : -1;
    int mode = selectedScalingMode.load();
    void *manager = storage ? field<void *>(storage,Layout::CallbackManager) : nullptr;
    float sharpness = manager ? currentSharpness(manager) : 0;
    if (originalQualityCall) originalQualityCall(storage,item);
    if (storage) {
        if (manager) {
            if (metalFXValue(mode) && restoreSharpness(manager,sharpness))
                at<void(*)(void *,bool)>(Native::PublishSettings)(manager,false);
            if (metalFXValue(mode) && value >= 0 && value <= 3) {
                [NSUserDefaults.standardUserDefaults setInteger:value forKey:qualityPreference];
                event(@{@"event":@"nativeQualityChanged",@"value":@(value),@"nativeQuality":@(field<uint8_t>(manager,Layout::NativeQuality)),
                    @"time":@(NSDate.timeIntervalSinceReferenceDate)});
            }
            updateDependentControls(manager,mode);
        }
    }
}
static void applyCombo(void *manager, const void *item) {
    // Apply() runs again when closing Options. Its virtual ComboItem apply
    // must use the same native resolution setup as the selection callback.
    void *mutableItem = const_cast<void *>(item);
    bool upscale = item && field<uint8_t>(mutableItem,Layout::ItemType) == 3 && field<uint16_t>(mutableItem,Layout::ItemID) == 99;
    int value = upscale ? field<int32_t>(mutableItem,Layout::ComboSelection) : -1;
    bool custom = metalFXValue(value);
    int quality = custom ? customQuality(manager) : -1;
    float sharpness = currentSharpness(manager);
    if (custom) field<int32_t>(mutableItem,Layout::ComboSelection) = 1;
    originalApplyCombo(manager,item);
    if (custom) {
        restoreCustomQuality(manager,quality,YES);
        restoreSharpness(manager,sharpness);
        field<int32_t>(mutableItem,Layout::ComboSelection) = value;
        updateDependentControls(manager,value);
        event(@{@"event":@"nativeUpscalingApplied",@"value":@(value),@"nativeType":@(field<uint8_t>(manager,Layout::NativeUpscalingType))});
    }
}
static void upscaleChanged(void *storage, const void *item) {
    if (!originalUpscaleCall || !storage || !item || field<uint16_t>(const_cast<void *>(item),Layout::ItemID) != 99) {
        if (originalUpscaleCall) originalUpscaleCall(storage,item);
        return;
    }
    void *manager = field<void *>(storage,Layout::CallbackManager);
    int value = field<int32_t>(const_cast<void *>(item),Layout::ComboSelection);
    if (!manager || value < 0 || value > 3) {
        originalUpscaleCall(storage,item);
        event(@{@"event":@"nativeUpscalingSelectionError",@"value":@(value)});
        return;
    }

    // BG3's settings system only understands Off (0) and FSR (1). For the
    // MetalFX choices, apply the game's normal FSR quality/resolution setup,
    // then restore the menu's custom value and track it independently. The
    // renderer hooks replace only FSR dispatches while one of these values is
    // selected, so the native Off and FSR paths remain unchanged.
    int appliedValue = metalFXValue(value) ? 1 : value;
    int quality = metalFXValue(value) ? customQuality(manager) : -1;
    float sharpness = currentSharpness(manager);
    field<int32_t>(const_cast<void *>(item),Layout::ComboSelection) = appliedValue;
    originalUpscaleCall(storage,item);
    if (quality >= 0) restoreCustomQuality(manager,quality,YES);
    // Changing the type is not a sharpness choice, even to or from FSR.
    bool sharpnessRestored = restoreSharpness(manager,sharpness);
    field<int32_t>(const_cast<void *>(item),Layout::ComboSelection) = value;
    // The selection callback already published Balanced before we restored
    // the manager's quality. Publish the restored settings to the renderer too.
    if (quality >= 0 || sharpnessRestored) at<void(*)(void *,bool)>(Native::PublishSettings)(manager,false);
    int previous = selectedScalingMode.exchange(value);
    updateDependentControls(manager,value);
    if (metalFXValue(value))
        [NSUserDefaults.standardUserDefaults setInteger:value forKey:scalingPreference];
    else
        [NSUserDefaults.standardUserDefaults removeObjectForKey:scalingPreference];
    // BG3 can quit immediately after a selection; flush the separate mode so
    // the next process cannot revive a previously saved MetalFX selection.
    [NSUserDefaults.standardUserDefaults synchronize];
    event(@{@"event":@"upscalingModeChanged",@"value":@(value),
            @"nativeType":@(field<uint8_t>(manager,Layout::NativeUpscalingType)),@"changed":@(previous != value)});
}
// These native types/functions use BG3's observed ARM64 ABI. In particular,
// AddTranslatedString returns its nontrivial Handle through explicit argument 0,
// consumes argument 2, and takes StringView in registers 3/4.
static BOOL makeText(Text &text, const char *identifier, const char *literal, bool &constructed) {
    void *repository = *at<void **>(Native::TranslationRepository);
    if (!repository) return NO;
    Handle input{}, output{};
    void *map = field<void *>(repository,Layout::TranslationMap);
    if (!map) return NO;
    View idView{identifier,static_cast<uint32_t>(strlen(identifier)),0};
    at<void(*)(Handle *,const View *,uint16_t)>(Native::MakeHandle)(&input,&idView,1);
    at<void(*)(Handle *,void *,Handle *,const char *,uint32_t,void *,uint32_t)>(Native::AddTranslatedString)
        (&output,repository,&input,literal,static_cast<uint32_t>(strlen(literal)),map,0);
    at<void(*)(Text *,const Handle *)>(Native::MakeText)(&text,&output);
    constructed = true;
    at<void(*)(Handle *)>(Native::DestroyHandle)(&output);
    View resolved = at<View(*)(const Text *,uint32_t,uint32_t)>(Native::ResolveText)(&text,0,0);
    BOOL matches = resolved.size == strlen(literal) && resolved.data && memcmp(resolved.data,literal,resolved.size) == 0;
    event(@{@"event":@"nativeMenuText",@"identifier":@(identifier),@"matches":@(matches)});
    return matches;
}
static void destroyText(Text &text) { at<void(*)(Text *)>(Native::DestroyText)(&text); }
static NSArray *comboValues(void *combo, uint32_t count) {
    if (!combo || count > 16) return @[];
    void *array = field<void *>(combo,Layout::ComboItems);
    if (count && !array) return @[];
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i=0;i<count;++i) {
        void *item = static_cast<char *>(array) + i * Layout::ComboItemStride;
        [values addObject:@(field<uint32_t>(item,Layout::ComboItemValue))];
    }
    return values;
}
static void menuInit(void *manager) {
    originalInit(manager);
    optionsManager = manager;
    void **items = field<void **>(manager,Layout::Items);
    uint32_t count = field<uint32_t>(manager,Layout::ItemCount);
    void *upscale = nullptr, *quality = nullptr;
    NSMutableArray *optionSnapshot = [NSMutableArray array];
    if (!items || count > 256) { event(@{@"event":@"nativeMenuError",@"error":@"Unexpected option list"}); return; }
    for (uint32_t i=0;i<count;++i) {
        uint8_t type = field<uint8_t>(items[i],Layout::ItemType);
        uint16_t id = field<uint16_t>(items[i],Layout::ItemID);
        if (i < 96) [optionSnapshot addObject:@{@"index":@(i),@"type":@(type),@"id":@(id)}];
        if (type == 3 && id == 99) upscale = items[i];
        if (type == 3 && id == 100) quality = items[i];
    }
    if (!upscale) {
        event(@{@"event":@"nativeMenuDeferred",@"reason":@"Upscaling Type control is not in this options pass",
                @"videoOptionCount":@(count),@"items":optionSnapshot});
        return;
    }
    uint32_t nativeCount = upscale ? field<uint32_t>(upscale,Layout::ComboCount) : 0;
    NSArray *nativeValues = comboValues(upscale,nativeCount);
    BOOL nativeOptions = nativeCount == 2 && [nativeValues isEqualToArray:@[@0,@1]];
    bool frameGeneration = frameGenerationSupported();
    NSArray *extendedValues = @[@0,@1,@2,@3];
    BOOL alreadyExtended = nativeCount == extendedValues.count && [nativeValues isEqualToArray:extendedValues];
    if (!nativeOptions && !alreadyExtended) {
        event(@{@"event":@"nativeMenuError",@"error":@"Unexpected Upscaling Type options",
                @"videoOptionCount":@(count),@"upscalingTypeFound":@(upscale != nullptr),@"items":optionSnapshot,
                @"upscalingComboCount":@(nativeCount),@"upscalingComboValues":nativeValues});
        return;
    }
    Text spatialName{}, spatialDescription{}, temporalName{}, temporalDescription{}, hudName{}, hudDescription{}, frameName{}, frameDescription{};
    // A Text that failed its check is still constructed; one never constructed
    // stays zero and must not be destroyed.
    Text *made[8];
    unsigned madeCount = 0;
    auto make = [&](Text &text, const char *identifier, const char *literal) {
        bool constructed = false;
        BOOL matches = makeText(text,identifier,literal,constructed);
        if (constructed) made[madeCount++] = &text;
        return matches;
    };
    auto destroyTexts = [&] { for (unsigned i=0;i<madeCount;++i) destroyText(*made[i]); };
    BOOL ok = make(spatialName,"h00000000g0000g0000g0000g00000000f001","MetalFX Spatial") &&
        make(spatialDescription,"h00000000g0000g0000g0000g00000000f002","Upscales each frame with MetalFX Spatial. Anti-aliasing remains a separate setting.") &&
        make(temporalName,"h00000000g0000g0000g0000g00000000f005","MetalFX Temporal") &&
        make(temporalDescription,"h00000000g0000g0000g0000g00000000f006","Uses MetalFX Temporal history to upscale each frame and replaces TAA.") &&
        make(hudName,"h00000000g0000g0000g0000g00000000f003","Show Metal HUD") &&
        make(hudDescription,"h00000000g0000g0000g0000g00000000f004","Shows Apple's Metal performance overlay. Changes take effect immediately.") &&
        make(frameName,"h00000000g0000g0000g0000g00000000f00b","MetalFX Frame Generation") &&
        make(frameDescription,"h00000000g0000g0000g0000g00000000f00c","Adds a MetalFX-generated frame between rendered frames, with any Upscaling Type. Uses the game's TAA depth and motion data. The FPS limiter controls rendered frames.");
    if (!ok) { destroyTexts(); event(@{@"event":@"nativeMenuError",@"error":@"Could not register menu text"}); return; }
    if (nativeOptions) {
        at<void(*)(void *,int,const Text *,const Text *)>(Native::AppendComboValue)(upscale,2,&spatialName,&spatialDescription);
        at<void(*)(void *,int,const Text *,const Text *)>(Native::AppendComboValue)(upscale,3,&temporalName,&temporalDescription);
    }
    if (field<uint32_t>(upscale,Layout::ComboCount) != extendedValues.count) {
        event(@{@"event":@"nativeMenuError",@"error":@"Could not append the MetalFX options"});
        destroyTexts();
        return;
    }
    void *selectionCall = field<void *>(upscale,Layout::SelectionCallback);
    if (selectionCall != reinterpret_cast<void *>(upscaleChanged))
        originalUpscaleCall = reinterpret_cast<void(*)(void *,const void *)>(selectionCall);
    if (!originalUpscaleCall) { event(@{@"event":@"nativeMenuError",@"error":@"Missing Upscaling Type selection callback"}); }
    else field<void *>(upscale,Layout::SelectionCallback) = reinterpret_cast<void *>(upscaleChanged);

    id savedScaling = [NSUserDefaults.standardUserDefaults objectForKey:scalingPreference];
    int storedMode = savedScaling ? (int)[savedScaling integerValue] : -1;
    int nativeMode = field<uint8_t>(manager,Layout::NativeUpscalingType) == 1 ? 1 : 0;
    int mode = metalFXValue(storedMode) ? storedMode : nativeMode;
    if (quality) {
        void *qualityCall = field<void *>(quality,Layout::SelectionCallback);
        if (qualityCall != reinterpret_cast<void *>(qualityChanged))
            originalQualityCall = reinterpret_cast<void(*)(void *,const void *)>(qualityCall);
        if (originalQualityCall) field<void *>(quality,Layout::SelectionCallback) = reinterpret_cast<void *>(qualityChanged);
    }
    // Restore through the same native callback as an interactive selection.
    // Merely changing +0xf7 left the quality ComboItems disabled and never
    // activated the render-resolution setting.
    if (metalFXValue(mode)) {
        if (field<void *>(upscale,Layout::CapturedManager) != manager || !originalUpscaleCall) {
            event(@{@"event":@"nativeMenuError",@"error":@"Unsupported native upscaling callback storage."});
            destroyTexts();
            return;
        }
        field<int32_t>(upscale,Layout::ComboSelection) = mode;
        upscaleChanged(static_cast<char *>(upscale)+Layout::SelectionCallback,upscale);
    } else {
        selectedScalingMode.store(mode);
        updateDependentControls(manager,mode);
    }
    void *hud = at<void *(*)(void *,uint16_t,const Text *,const Text *,bool)>(Native::AddTickBox)
        (manager,hudID,&hudName,&hudDescription,hudEnabled);
    // AddTickBoxOption installs an inline POD Function table at +0x38. Replace
    // only Call; preserve its native Copy/MoveDestroy and captured manager.
    field<void *>(hud,Layout::SelectionCallback) = reinterpret_cast<void *>(hudChanged);
    // Put HUD first under General, before the first native control (Display Mode).
    items = field<void **>(manager,Layout::Items); count = field<uint32_t>(manager,Layout::ItemCount);
    if (count && items[count-1] == hud) {
        for (uint32_t i=0;i+1<count;++i) if (field<uint8_t>(items[i],Layout::ItemType) == 3) {
            memmove(items+i+1,items+i,(count-i-1)*sizeof(void *)); items[i] = hud; break;
        }
    }
    if (frameGeneration) {
        void *frameItem = at<void *(*)(void *,uint16_t,const Text *,const Text *,bool)>(Native::AddTickBox)
            (manager,frameGenerationID,&frameName,&frameDescription,frameGenerationChecked.load());
        field<void *>(frameItem,Layout::SelectionCallback) = reinterpret_cast<void *>(frameGenerationChanged);
        // Put Frame Generation right below VSync (combo 82, EVSyncMode), which
        // also governs presentation; without it, after the upscaling controls
        // (Upscaling Type, then Upscaling Quality when BG3 lists it).
        items = field<void **>(manager,Layout::Items); count = field<uint32_t>(manager,Layout::ItemCount);
        if (count && items[count-1] == frameItem) {
            uint32_t anchor = count, vsync = count;
            for (uint32_t i=0;i+1<count;++i) {
                uint16_t id = field<uint8_t>(items[i],Layout::ItemType) == 3 ? field<uint16_t>(items[i],Layout::ItemID) : 0;
                if (id == 99 || id == 100) anchor = i;
                if (id == 82) vsync = i;
            }
            if (vsync < count) anchor = vsync;
            if (anchor+2 < count) {
                memmove(items+anchor+2,items+anchor+1,(count-anchor-2)*sizeof(void *)); items[anchor+1] = frameItem;
            }
        }
    }
    destroyTexts();
    if (NSThread.isMainThread) applyHUD(); else dispatch_async(dispatch_get_main_queue(),^{ applyHUD(); });
    event(@{@"event":@"nativeMenuReady",@"upscalingOptions":@[@"Off",@"AMD FSR 1.0",@"MetalFX Spatial",@"MetalFX Temporal"],
            @"frameGenerationOption":@(frameGeneration),@"frameGeneration":@(frameGenerationChecked.load()),
            @"selectedScalingMode":@(mode),@"hudEnabled":@(hudEnabled)});
}
}

BOOL BG3MFXInstallNativeMenu(void (*report)(NSDictionary *), NSError **error) {
    reportEvent = report;
    uint32_t imageIndex = 0;
    const mach_header_64 *header = nullptr;
    for (uint32_t i=0;i<_dyld_image_count();++i) {
        const mach_header *candidate = _dyld_get_image_header(i);
        if (candidate->filetype == MH_EXECUTE) { imageIndex=i; header=reinterpret_cast<const mach_header_64 *>(candidate); break; }
    }
    if (!header || header->cputype != CPU_TYPE_ARM64) { errorOut(error,@"Native menu requires the validated ARM64 game build."); return NO; }
    unsigned char expectedUUID[16];
    [[[NSUUID alloc] initWithUUIDString:@BG3MFX_SUPPORTED_ARM64_UUID] getUUIDBytes:expectedUUID];
    BOOL supported = NO;
    const load_command *command = reinterpret_cast<const load_command *>(header+1);
    for (uint32_t i=0;i<header->ncmds;++i) {
        if (command->cmd == LC_UUID) {
            const unsigned char *uuid = reinterpret_cast<const uuid_command *>(command)->uuid;
            supported = memcmp(uuid,expectedUUID,16) == 0;
            event(@{@"event":@"nativeMenuBuild",@"image":@(_dyld_get_image_name(imageIndex)),@"uuid":[[NSUUID alloc] initWithUUIDBytes:uuid].UUIDString});
        }
        command = reinterpret_cast<const load_command *>(reinterpret_cast<const char *>(command)+command->cmdsize);
    }
    if (!supported) { errorOut(error,@"Unsupported BG3 build for native menu integration."); return NO; }
    slide = _dyld_get_image_vmaddr_slide(imageIndex);
    bool focusRepairInstalled = installRenderViewFocusRepair();
    event(@{@"event":@"nativeMenuFocusRepairHook", @"installed":@(focusRepairInstalled)});
    if (!BG3MFXInstallTemporalJitter(slide,report,error)) return NO;
    // Remove BG3's duplicate cascaded-shadow stage (docs/dev/performance.md). A mismatch
    // leaves BG3 unchanged. BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0 keeps both stages for
    // comparison.
    const char *shadowOptimizationSetting = getenv("BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS");
    if (!(shadowOptimizationSetting && strcmp(shadowOptimizationSetting, "0") == 0)) {
        NSError *shadowError = nil;
        if (!BG3MFXInstallShadowDuplicateFix(slide,report,&shadowError))
            event(@{@"event":@"shadowDuplicateFixSkipped",@"reason":shadowError.localizedDescription ?: @""});
    }
    // Skip the signal-mask system calls in BG3's Lua error handling
    // (src/features/lua-jump-fix/LuaJumpFix.mm). A mismatch leaves BG3 unchanged. BG3MFX_LUA_SYSTEM_CALL_ELIMINATION=0
    // keeps setjmp/longjmp for comparison.
    if (!(getenv("BG3MFX_LUA_SYSTEM_CALL_ELIMINATION") && strcmp(getenv("BG3MFX_LUA_SYSTEM_CALL_ELIMINATION"),"0") == 0)) {
        NSError *luaError = nil;
        if (!BG3MFXInstallLuaJumpFix(slide,report,&luaError))
            event(@{@"event":@"luaJumpFixSkipped",@"reason":luaError.localizedDescription ?: @""});
    }
    // Optimized thread idling: BG3's job system and frame limiter sleep instead
    // of spinning (src/features/thread-idling/ThreadIdling.mm). A mismatch leaves BG3 unchanged.
    // BG3MFX_CPU_THREAD_IDLING=0 keeps BG3's spinning for comparison.
    if (!(getenv("BG3MFX_CPU_THREAD_IDLING") && strcmp(getenv("BG3MFX_CPU_THREAD_IDLING"),"0") == 0)) {
        NSError *idlingError = nil;
        if (!BG3MFXInstallThreadIdling(slide,report,&idlingError))
            event(@{@"event":@"threadIdlingSkipped",@"reason":idlingError.localizedDescription ?: @""});
    }
    // Reduced locking: the hottest uniform allocations take per-thread slices
    // instead of BG3's shared lock each time (src/features/reduce-locking/UniformSlices.mm).
    // A mismatch leaves BG3 unchanged. BG3MFX_REDUCE_LOCKING=0 keeps BG3's lock for comparison.
    if (!(getenv("BG3MFX_REDUCE_LOCKING") && strcmp(getenv("BG3MFX_REDUCE_LOCKING"),"0") == 0)) {
        NSError *slicesError = nil;
        if (!BG3MFXInstallUniformSlices(slide,report,&slicesError))
            event(@{@"event":@"uniformSlicesSkipped",@"reason":slicesError.localizedDescription ?: @""});
    }
    // Diagnostic opt-in: time BG3's server tick, its CPU time and its limiter
    // (src/integration/diagnostics/ServerPacingProbe.h).
#ifndef BG3MFX_NO_TRACE
    if (getenv("BG3MFX_TRACE_SERVER_PACING") && strcmp(getenv("BG3MFX_TRACE_SERVER_PACING"),"1") == 0) {
        NSError *pacingError = nil;
        if (!BG3MFXInstallServerPacingProbe(slide,&pacingError))
            event(@{@"event":@"serverPacingSkipped",@"reason":pacingError.localizedDescription ?: @""});
    }
#endif
    void **table = at<void **>(Native::Callbacks);
    if (table[Layout::InitSlot] != at<void *>(Native::Init) || table[Layout::ApplyComboSlot] != at<void *>(Native::ApplyCombo)) { errorOut(error,@"The Video menu callback was already modified."); return NO; }
    originalInit = reinterpret_cast<void(*)(void *)>(table[Layout::InitSlot]);
    originalApplyCombo = reinterpret_cast<void(*)(void *,const void *)>(table[Layout::ApplyComboSlot]);
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:hudPreference];
    hudEnabled = saved ? [saved boolValue] : (getenv("MTL_HUD_ENABLED") && strcmp(getenv("MTL_HUD_ENABLED"),"1") == 0 &&
        !(getenv("MTL_HUD_HIDDEN") && strcmp(getenv("MTL_HUD_HIDDEN"),"1") == 0));
    uintptr_t page = reinterpret_cast<uintptr_t>(table) & ~(static_cast<uintptr_t>(vm_page_size)-1);
    kern_return_t result = vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
    if (result != KERN_SUCCESS) { errorOut(error,@"Could not make the native menu callback writable."); return NO; }
    table[Layout::InitSlot] = reinterpret_cast<void *>(menuInit);
    table[Layout::ApplyComboSlot] = reinterpret_cast<void *>(applyCombo);
    vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ);
    // The native settings file persists the FSR resolution/quality setup used
    // by MetalFX. Restore our separate renderer selection before BG3 creates
    // its first command buffer, rather than waiting for Video Options to open.
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
    frameGenerationChecked.store([defaults boolForKey:frameGenerationPreference]);
    event(@{@"event":@"nativeMenuStartupMode",@"value":@(startupMode),@"frameGeneration":@(frameGenerationChecked.load())});
    event(@{@"event":@"nativeMenuInstalled"});
    return YES;
}

int BG3MFXSelectedScalingMode(void) { return selectedScalingMode.load(); }

// Standalone GPU regression harnesses have no BG3 settings manager. Never
// permit them to override a real game's menu selection.
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
extern "C" BOOL BG3MFXSetStandaloneScalingMode(int mode) {
    if (originalInit || [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"] || mode < 0 || mode > 3) return NO;
    selectedScalingMode.store(mode);
    return YES;
}
extern "C" BOOL BG3MFXSetStandaloneFrameGeneration(BOOL enabled) {
    if (originalInit || [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return NO;
    frameGenerationChecked.store(enabled);
    return YES;
}
#endif

BOOL BG3MFXFrameGenerationEnabled(void) { return frameGenerationChecked.load() && frameGenerationSupported(); }

// The MetalFX types run as BG3's FSR type, so the game's settings need no
// change: track FSR and drop the saved MetalFX type. Video options then open on
// AMD FSR 1.0 (BG3's own type), and the next launch starts with it.
BOOL BG3MFXFallBackToFSR(void) {
    if (!originalInit) return NO;
    selectedScalingMode.store(1);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:scalingPreference];
    [defaults synchronize];
    return YES;
}
