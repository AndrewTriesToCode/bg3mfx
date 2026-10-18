#import "NativeMenu.h"
#import "TemporalJitter.h"
#import "ShadowDuplicateFix.h"
#import "LuaJumpFix.h"
#import "ServerPacingProbe.h"
#import "ThreadIdling.h"
#import <MetalFX/MetalFX.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <atomic>
#include <cstring>
#include <cstdlib>
#include <time.h>

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

    if (!view || pendingFocusWindow != window || pendingFocusView != view) return;
    NSView *restoreView = pendingFocusView;
    pendingFocusWindow = nil;
    pendingFocusView = nil;

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
// This probe observes the native lifecycle without changing callbacks or input.
// Compile it out of the player runtime, including the NSEvent monitor.
#ifndef BG3MFX_NO_TRACE
static bool menuProbeEnabled() {
    const char *value = getenv("BG3MFX_MENU_PROBE");
    return value && strcmp(value,"1") == 0;
}
static std::atomic<uint64_t> menuProbeSequence{0};
static thread_local const char *menuProbeContext = "none";
static NSString *probePointer(const void *pointer) { return [NSString stringWithFormat:@"%p",pointer]; }
static NSDictionary *probeControl(void *item) {
    uint8_t type = field<uint8_t>(item,8);
    NSMutableDictionary *state = [@{@"pointer":probePointer(item),@"type":@(type),
        @"id":@(field<uint16_t>(item,0x88)),@"enabled":@(field<uint8_t>(item,0x2c)),
        @"enabledObservers":@(field<int32_t>(item,0x84))} mutableCopy];
    if (type == 3) {
        state[@"value"] = @(field<int32_t>(item,0xd0));
        state[@"choices"] = @(field<uint32_t>(item,0x9c));
        state[@"selectedObservers"] = @(field<int32_t>(item,0xcc));
    } else if (field<uint16_t>(item,0x88) == hudID || field<uint16_t>(item,0x88) == frameGenerationID)
        state[@"checked"] = @(field<uint8_t>(item,0xa8));
    return state;
}
static NSArray *probeControls(void *manager) {
    if (!manager) return @[];
    void **items = field<void **>(manager,0x30);
    uint32_t count = field<uint32_t>(manager,0x3c);
    if (!items || count > 256) return @[];
    NSMutableArray *controls = [NSMutableArray array];
    bool firstCombo = true;
    for (uint32_t i=0;i<count;++i) {
        if (!items[i]) continue;
        uint8_t type = field<uint8_t>(items[i],8);
        uint16_t id = field<uint16_t>(items[i],0x88);
        bool displayCandidate = type == 3 && firstCombo;
        if (type == 3) firstCombo = false;
        if (displayCandidate || id == 98 || id == 99 || id == 100 || id == hudID || id == frameGenerationID) {
            NSMutableDictionary *state = [probeControl(items[i]) mutableCopy];
            state[@"index"] = @(i);
            // BG3's first native combo is Display Mode; no unverified ID needed.
            if (displayCandidate) state[@"role"] = @"firstNativeCombo";
            [controls addObject:state];
        }
    }
    return controls;
}
static void menuProbe(const char *phase, void *manager, const void *item, bool snapshot) {
    if (!menuProbeEnabled()) return;
    struct timespec now{};
    clock_gettime(CLOCK_MONOTONIC,&now);
    NSMutableDictionary *state = [@{@"event":@"nativeMenuProbeCallback",@"phase":@(phase),
        @"sequence":@(menuProbeSequence.fetch_add(1)+1),
        @"monotonicSeconds":@(double(now.tv_sec)+double(now.tv_nsec)/1e9),
        @"mainThread":@(NSThread.isMainThread),@"context":@(menuProbeContext),
        @"manager":probePointer(manager),@"item":probePointer(item)} mutableCopy];
    if (item) state[@"control"] = probeControl(const_cast<void *>(item));
    if (snapshot) state[@"controls"] = probeControls(manager);
    event(state);
}
struct MenuProbeScope {
    const char *name, *previous;
    void *manager;
    const void *item;
    bool snapshot;
    MenuProbeScope(const char *name, void *manager, const void *item=nullptr, bool snapshot=true)
        : name(name), previous(menuProbeContext), manager(manager), item(item), snapshot(snapshot) {
        if (menuProbeEnabled()) {
            menuProbe(name,manager,item,snapshot);
            menuProbeContext = name;
        }
    }
    ~MenuProbeScope() {
        if (menuProbeEnabled()) {
            menuProbe("exit",manager,item,snapshot);
            menuProbeContext = previous;
        }
    }
};
static NSEvent *probeInput(NSEvent *input) {
    if (!menuProbeEnabled()) return input;
    struct timespec now{};
    clock_gettime(CLOCK_MONOTONIC,&now);
    NSWindow *window = input.window;
    event(@{@"event":@"nativeMenuProbeInput",@"sequence":@(menuProbeSequence.fetch_add(1)+1),
        @"monotonicSeconds":@(double(now.tv_sec)+double(now.tv_nsec)/1e9),
        @"eventType":@(input.type),@"active":@(NSApp.active),
        @"window":probePointer((__bridge void *)window),
        @"keyWindow":@(window.isKeyWindow),@"mainWindow":@(window.isMainWindow),
        @"firstResponderClass":window.firstResponder ? NSStringFromClass(window.firstResponder.class) : @"none"});
    // No characters, key codes, coordinates, or event replacement.
    return input;
}
static void installMenuProbeMonitor() {
    if (!menuProbeEnabled()) return;
    // The constructor can precede NSApplication creation. Install when its main
    // run loop starts; never initialize AppKit or inspect windows off-thread.
    dispatch_async(dispatch_get_main_queue(),^{
        static id monitor;
        if (monitor) return;
        NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
            NSEventMaskRightMouseDown | NSEventMaskRightMouseUp |
            NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp |
            NSEventMaskKeyDown | NSEventMaskKeyUp;
        monitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *input) {
            return probeInput(input);
        }];
        menuProbe(monitor ? "monitorInstalled" : "monitorUnavailable",nullptr,nullptr,false);
    });
}
#define MENU_PROBE_SCOPE(name, manager, item, snapshot) MenuProbeScope probeScope(name,manager,item,snapshot)
#define MENU_PROBE(phase, manager, item, snapshot) menuProbe(phase,manager,item,snapshot)
#define MENU_PROBE_INITIALIZED() probeScope.snapshot = true
#else
#define MENU_PROBE_SCOPE(name, manager, item, snapshot)
#define MENU_PROBE(phase, manager, item, snapshot)
#define MENU_PROBE_INITIALIZED()
#endif
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
    if (!item || field<uint16_t>(const_cast<void *>(item),0x88) != hudID) return;
    hudEnabled = field<uint8_t>(const_cast<void *>(item),0xa8) != 0;
    [NSUserDefaults.standardUserDefaults setBool:hudEnabled forKey:hudPreference];
    if (NSThread.isMainThread) applyHUD(); else dispatch_async(dispatch_get_main_queue(),^{ applyHUD(); });
}
static void updateDependentControls(void *manager, int mode);
static void frameGenerationChanged(void *, const void *item) {
    if (!item || field<uint16_t>(const_cast<void *>(item),0x88) != frameGenerationID) return;
    bool enabled = field<uint8_t>(const_cast<void *>(item),0xa8) != 0;
    frameGenerationChecked.store(enabled);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:frameGenerationPreference];
    // BG3 can quit right after a change; keep the next launch consistent.
    [NSUserDefaults.standardUserDefaults synchronize];
    event(@{@"event":@"frameGenerationChanged",@"enabled":@(enabled)});
    if (optionsManager) updateDependentControls(optionsManager,selectedScalingMode.load());
}
static void *findItem(void *manager, uint8_t type, uint16_t id) {
    void **items = field<void **>(manager,0x30);
    uint32_t count = field<uint32_t>(manager,0x3c);
    if (!items || count > 256) return nullptr;
    for (uint32_t i=0;i<count;++i)
        if (field<uint8_t>(items[i],8) == type && field<uint16_t>(items[i],0x88) == id) return items[i];
    return nullptr;
}
static void setItemEnabled(void *item, uint8_t enabled) {
    MENU_PROBE_SCOPE("setItemEnabled",nullptr,item,false);
    if (!item || field<uint8_t>(item,0x2c) == enabled) return;
    field<uint8_t>(item,0x2c) = enabled;
    // Match RefreshUIAntiAliasing's EnabledChanged notifications.
    void *observers = field<void *>(item,0x78);
    int32_t observersCount = field<int32_t>(item,0x84);
    if (!observers || observersCount < 0 || observersCount > 256) return;
    for (int32_t j=0;j<observersCount;++j) {
        char *entry = static_cast<char *>(observers) + j*0x48;
        void **table = field<void **>(entry,0);
        if (table && table[0]) reinterpret_cast<void(*)(void *)>(table[0])(entry+8);
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
    uint32_t count = field<uint32_t>(aa,0x9c);
    char *array = field<char *>(aa,0x90);
    if (!array || count > 16) return -1;
    for (uint32_t i=0;i<count;++i) {
        View label = at<View(*)(const void *,uint32_t,uint32_t)>(0x1065465e4)(array+i*0x24,0,0);
        if (label.data && label.size >= 3 && label.size < 64 && memmem(label.data,label.size,"TAA",3))
            return (int)field<uint32_t>(array+i*0x24,0x20);
    }
    return -1;
}
// Select an Anti-Aliasing value through BG3's own callback, and show it.
static void selectAntiAliasing(void *aa, int value) {
    MENU_PROBE_SCOPE("selectAntiAliasing",nullptr,aa,false);
    field<int32_t>(aa,0xd0) = value;
    if (auto call = field<void(*)(void *,const void *)>(aa,0x38)) call(static_cast<char *>(aa)+0x38,aa);
    void *observers = field<void *>(aa,0xc0);
    int32_t observerCount = field<int32_t>(aa,0xcc);
    if (observers && observerCount >= 0 && observerCount <= 256) for (int32_t j=0;j<observerCount;++j) {
        char *entry = static_cast<char *>(observers)+j*0x48;
        void **table = field<void **>(entry,0);
        if (table && table[0]) reinterpret_cast<void(*)(void *,int)>(table[0])(entry+8,value);
    }
}
static void updateDependentControls(void *manager, int mode) {
    // MetalFX Temporal and Frame Generation use the depth, motion and camera
    // data of BG3's TAA pass (Temporal then replaces its draw). While either is
    // on, select TAA and dim the control; afterwards restore the player's choice.
    void *aa = findItem(manager,3,98);
    if (!aa) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    bool requiresTAA = temporalValue(mode) || (frameGenerationChecked.load() && frameGenerationSupported());
    int current = field<int32_t>(aa,0xd0), taa = taaValue(aa);
    if (requiresTAA && taa >= 0 && current != taa) {
        if (![defaults objectForKey:savedAntiAliasingPreference]) [defaults setInteger:current forKey:savedAntiAliasingPreference];
        selectAntiAliasing(aa,taa);
        event(@{@"event":@"antiAliasingForced",@"previous":@(current),@"taa":@(taa)});
    } else if (!requiresTAA && [defaults objectForKey:savedAntiAliasingPreference]) {
        int saved = (int)[defaults integerForKey:savedAntiAliasingPreference];
        [defaults removeObjectForKey:savedAntiAliasingPreference];
        if (saved != current && [comboValues(aa,field<uint32_t>(aa,0x9c)) containsObject:@(saved)]) {
            selectAntiAliasing(aa,saved);
            event(@{@"event":@"antiAliasingRestored",@"value":@(saved)});
        }
    }
    if (requiresTAA && taa < 0) event(@{@"event":@"nativeMenuError",@"error":@"No TAA Anti-Aliasing option found"});
    setItemEnabled(aa,!requiresTAA && field<uint32_t>(aa,0x9c) > 1);
}
static int customQuality(void *manager) {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:qualityPreference];
    int value = saved ? [saved intValue] : (field<uint8_t>(manager,0xf7) == 1 ? field<uint8_t>(manager,0xf8) : 2);
    return value >= 0 && value <= 3 ? value : 2;
}
static void restoreCustomQuality(void *manager, int value, BOOL refresh) {
    // Applying native type 1 always chooses Balanced. Reapply the requested
    // quality through BG3's setter, including the actual render-resolution state.
    at<void(*)(void *,int)>(0x10640df94)(static_cast<char *>(manager)+0x60,value);
    if (!refresh) return;
    // The native type callback already rebuilt the quality list. Rebuilding it
    // again while its UI change is being handled can leave the displayed value
    // blank. Update only the selection, using RefreshUIUpscaleMode's observed
    // SelectedChanged notification ABI.
    void **items = field<void **>(manager,0x30);
    uint32_t count = field<uint32_t>(manager,0x3c);
    if (items && count <= 256) for (uint32_t i=0;i<count;++i) {
        void *item = items[i];
        if (field<uint8_t>(item,8) != 3 || field<uint16_t>(item,0x88) != 100 || field<uint32_t>(item,0x9c) != 4) continue;
        field<int32_t>(item,0xd0) = value;
        void *observers = field<void *>(item,0xc0);
        int32_t observerCount = field<int32_t>(item,0xcc);
        if (observers && observerCount >= 0 && observerCount <= 256) for (int32_t j=0;j<observerCount;++j) {
            char *entry = static_cast<char *>(observers)+j*0x48;
            void **table = field<void **>(entry,0);
            if (table && table[0]) reinterpret_cast<void(*)(void *,int)>(table[0])(entry+8,value);
        }
        event(@{@"event":@"nativeQualityRestored",@"value":@(value)});
        return;
    }
    at<void(*)(void *)>(0x103291ef8)(manager);
}
static void qualityChanged(void *storage, const void *item) {
    MENU_PROBE_SCOPE("qualityChanged",storage ? field<void *>(storage,0x18) : nullptr,item,true);
    int value = item ? field<int32_t>(const_cast<void *>(item),0xd0) : -1;
    int mode = selectedScalingMode.load();
    if (originalQualityCall) originalQualityCall(storage,item);
    if (storage) {
        void *manager = field<void *>(storage,0x18);
        if (manager) {
            if (metalFXValue(mode) && value >= 0 && value <= 3) {
                [NSUserDefaults.standardUserDefaults setInteger:value forKey:qualityPreference];
                event(@{@"event":@"nativeQualityChanged",@"value":@(value),@"nativeQuality":@(field<uint8_t>(manager,0xf8)),
                    @"time":@(NSDate.timeIntervalSinceReferenceDate)});
            }
            updateDependentControls(manager,mode);
        }
    }
}
static void applyCombo(void *manager, const void *item) {
    MENU_PROBE_SCOPE("applyCombo",manager,item,true);
    // Apply() runs again when closing Options. Its virtual ComboItem apply
    // must use the same native resolution setup as the selection callback.
    void *mutableItem = const_cast<void *>(item);
    bool upscale = item && field<uint8_t>(mutableItem,8) == 3 && field<uint16_t>(mutableItem,0x88) == 99;
    int value = upscale ? field<int32_t>(mutableItem,0xd0) : -1;
    bool custom = metalFXValue(value);
    int quality = custom ? customQuality(manager) : -1;
    if (custom) field<int32_t>(mutableItem,0xd0) = 1;
    originalApplyCombo(manager,item);
    if (custom) {
        restoreCustomQuality(manager,quality,YES);
        field<int32_t>(mutableItem,0xd0) = value;
        updateDependentControls(manager,value);
        event(@{@"event":@"nativeUpscalingApplied",@"value":@(value),@"nativeType":@(field<uint8_t>(manager,0xf7))});
    }
}
static void upscaleChanged(void *storage, const void *item) {
    MENU_PROBE_SCOPE("upscaleChanged",storage ? field<void *>(storage,0x18) : nullptr,item,true);
    if (!originalUpscaleCall || !storage || !item || field<uint16_t>(const_cast<void *>(item),0x88) != 99) {
        if (originalUpscaleCall) originalUpscaleCall(storage,item);
        return;
    }
    void *manager = field<void *>(storage,0x18);
    int value = field<int32_t>(const_cast<void *>(item),0xd0);
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
    field<int32_t>(const_cast<void *>(item),0xd0) = appliedValue;
    originalUpscaleCall(storage,item);
    if (quality >= 0) restoreCustomQuality(manager,quality,YES);
    field<int32_t>(const_cast<void *>(item),0xd0) = value;
    // The selection callback already published Balanced before we restored
    // the manager's quality. Publish the restored settings to the renderer too.
    if (quality >= 0) at<void(*)(void *,bool)>(0x1032906c4)(manager,false);
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
            @"nativeType":@(field<uint8_t>(manager,0xf7)),@"changed":@(previous != value)});
}
// These native types/functions use BG3's observed ARM64 ABI. In particular,
// AddTranslatedString returns its nontrivial Handle through explicit argument 0,
// consumes argument 2, and takes StringView in registers 3/4.
static BOOL makeText(Text &text, const char *identifier, const char *literal) {
    void *repository = *at<void **>(0x108b26098);
    if (!repository) return NO;
    Handle input{}, output{};
    void *map = field<void *>(repository,8);
    if (!map) return NO;
    View idView{identifier,static_cast<uint32_t>(strlen(identifier)),0};
    at<void(*)(Handle *,const View *,uint16_t)>(0x106535df4)(&input,&idView,1);
    at<void(*)(Handle *,void *,Handle *,const char *,uint32_t,void *,uint32_t)>(0x106549388)
        (&output,repository,&input,literal,static_cast<uint32_t>(strlen(literal)),map,0);
    at<void(*)(Text *,const Handle *)>(0x106545cc4)(&text,&output);
    at<void(*)(Handle *)>(0x1064d0c60)(&output);
    View resolved = at<View(*)(const Text *,uint32_t,uint32_t)>(0x1065465e4)(&text,0,0);
    BOOL matches = resolved.size == strlen(literal) && resolved.data && memcmp(resolved.data,literal,resolved.size) == 0;
    event(@{@"event":@"nativeMenuText",@"identifier":@(identifier),@"matches":@(matches)});
    return matches;
}
static void destroyText(Text &text) { at<void(*)(Text *)>(0x106545e94)(&text); }
static NSArray *comboValues(void *combo, uint32_t count) {
    if (!combo || count > 16) return @[];
    void *array = field<void *>(combo,0x90);
    if (count && !array) return @[];
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i=0;i<count;++i) {
        void *item = static_cast<char *>(array) + i * 0x24;
        [values addObject:@(field<uint32_t>(item,0x20))];
    }
    return values;
}
static void menuInit(void *manager) {
    // Do not inspect the list until BG3 has initialized the manager.
    MENU_PROBE_SCOPE("menuInit",manager,nullptr,false);
    originalInit(manager);
    MENU_PROBE_INITIALIZED();
    MENU_PROBE("originalInitReturned",manager,nullptr,true);
    optionsManager = manager;
    void **items = field<void **>(manager,0x30);
    uint32_t count = field<uint32_t>(manager,0x3c);
    void *upscale = nullptr, *quality = nullptr;
    NSMutableArray *optionSnapshot = [NSMutableArray array];
    if (!items || count > 256) { event(@{@"event":@"nativeMenuError",@"error":@"Unexpected option list"}); return; }
    for (uint32_t i=0;i<count;++i) {
        uint8_t type = field<uint8_t>(items[i],8);
        uint16_t id = field<uint16_t>(items[i],0x88);
        if (i < 96) [optionSnapshot addObject:@{@"index":@(i),@"type":@(type),@"id":@(id)}];
        if (type == 3 && id == 99) upscale = items[i];
        if (type == 3 && id == 100) quality = items[i];
    }
    if (!upscale) {
        event(@{@"event":@"nativeMenuDeferred",@"reason":@"Upscaling Type control is not in this options pass",
                @"videoOptionCount":@(count),@"items":optionSnapshot});
        return;
    }
    uint32_t nativeCount = upscale ? field<uint32_t>(upscale,0x9c) : 0;
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
    BOOL ok = makeText(spatialName,"h00000000g0000g0000g0000g00000000f001","MetalFX Spatial") &&
        makeText(spatialDescription,"h00000000g0000g0000g0000g00000000f002","Upscales each frame with MetalFX Spatial. Anti-aliasing remains a separate setting.") &&
        makeText(temporalName,"h00000000g0000g0000g0000g00000000f005","MetalFX Temporal") &&
        makeText(temporalDescription,"h00000000g0000g0000g0000g00000000f006","Uses MetalFX Temporal history to upscale each frame and replaces TAA.") &&
        makeText(hudName,"h00000000g0000g0000g0000g00000000f003","Show Metal HUD") &&
        makeText(hudDescription,"h00000000g0000g0000g0000g00000000f004","Shows Apple's Metal performance overlay. Changes take effect immediately.") &&
        makeText(frameName,"h00000000g0000g0000g0000g00000000f00b","MetalFX Frame Generation") &&
        makeText(frameDescription,"h00000000g0000g0000g0000g00000000f00c","Adds a MetalFX-generated frame between rendered frames, with any Upscaling Type. Uses the game's TAA depth and motion data. The FPS limiter controls rendered frames.");
    if (!ok) { event(@{@"event":@"nativeMenuError",@"error":@"Could not register menu text"}); return; }
    if (nativeOptions) {
        at<void(*)(void *,int,const Text *,const Text *)>(0x103294954)(upscale,2,&spatialName,&spatialDescription);
        at<void(*)(void *,int,const Text *,const Text *)>(0x103294954)(upscale,3,&temporalName,&temporalDescription);
    }
    if (field<uint32_t>(upscale,0x9c) != extendedValues.count) {
        event(@{@"event":@"nativeMenuError",@"error":@"Could not append the MetalFX options"});
        return;
    }
    void *selectionCall = field<void *>(upscale,0x38);
    if (selectionCall != reinterpret_cast<void *>(upscaleChanged))
        originalUpscaleCall = reinterpret_cast<void(*)(void *,const void *)>(selectionCall);
    if (!originalUpscaleCall) { event(@{@"event":@"nativeMenuError",@"error":@"Missing Upscaling Type selection callback"}); }
    else field<void *>(upscale,0x38) = reinterpret_cast<void *>(upscaleChanged);

    id savedScaling = [NSUserDefaults.standardUserDefaults objectForKey:scalingPreference];
    int storedMode = savedScaling ? (int)[savedScaling integerValue] : -1;
    int nativeMode = field<uint8_t>(manager,0xf7) == 1 ? 1 : 0;
    int mode = metalFXValue(storedMode) ? storedMode : nativeMode;
    if (quality) {
        void *qualityCall = field<void *>(quality,0x38);
        if (qualityCall != reinterpret_cast<void *>(qualityChanged))
            originalQualityCall = reinterpret_cast<void(*)(void *,const void *)>(qualityCall);
        if (originalQualityCall) field<void *>(quality,0x38) = reinterpret_cast<void *>(qualityChanged);
    }
    // Restore through the same native callback as an interactive selection.
    // Merely changing +0xf7 left the quality ComboItems disabled and never
    // activated the render-resolution setting.
    if (metalFXValue(mode)) {
        if (field<void *>(upscale,0x50) != manager || !originalUpscaleCall) {
            event(@{@"event":@"nativeMenuError",@"error":@"Unsupported native upscaling callback storage."});
            return;
        }
        field<int32_t>(upscale,0xd0) = mode;
        upscaleChanged(static_cast<char *>(upscale)+0x38,upscale);
    } else {
        selectedScalingMode.store(mode);
        updateDependentControls(manager,mode);
    }
    void *hud = at<void *(*)(void *,uint16_t,const Text *,const Text *,bool)>(0x1030a39bc)
        (manager,hudID,&hudName,&hudDescription,hudEnabled);
    // AddTickBoxOption installs an inline POD Function table at +0x38. Replace
    // only Call; preserve its native Copy/MoveDestroy and captured manager.
    field<void *>(hud,0x38) = reinterpret_cast<void *>(hudChanged);
    // Put HUD first under General, before the first native control (Display Mode).
    items = field<void **>(manager,0x30); count = field<uint32_t>(manager,0x3c);
    if (count && items[count-1] == hud) {
        for (uint32_t i=0;i+1<count;++i) if (field<uint8_t>(items[i],8) == 3) {
            memmove(items+i+1,items+i,(count-i-1)*sizeof(void *)); items[i] = hud; break;
        }
    }
    if (frameGeneration) {
        void *frameItem = at<void *(*)(void *,uint16_t,const Text *,const Text *,bool)>(0x1030a39bc)
            (manager,frameGenerationID,&frameName,&frameDescription,frameGenerationChecked.load());
        field<void *>(frameItem,0x38) = reinterpret_cast<void *>(frameGenerationChanged);
        // Put Frame Generation right after the upscaling controls (Upscaling
        // Type, then Upscaling Quality when BG3 lists it).
        items = field<void **>(manager,0x30); count = field<uint32_t>(manager,0x3c);
        if (count && items[count-1] == frameItem) {
            uint32_t anchor = count;
            for (uint32_t i=0;i+1<count;++i) {
                uint16_t id = field<uint8_t>(items[i],8) == 3 ? field<uint16_t>(items[i],0x88) : 0;
                if (id == 99 || id == 100) anchor = i;
            }
            if (anchor+2 < count) {
                memmove(items+anchor+2,items+anchor+1,(count-anchor-2)*sizeof(void *)); items[anchor+1] = frameItem;
            }
        }
    }
    destroyText(frameName); destroyText(frameDescription);
    destroyText(spatialName); destroyText(spatialDescription);
    destroyText(temporalName); destroyText(temporalDescription);
    destroyText(hudName); destroyText(hudDescription);
    if (NSThread.isMainThread) applyHUD(); else dispatch_async(dispatch_get_main_queue(),^{ applyHUD(); });
    MENU_PROBE("initializationComplete",manager,nullptr,true);
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
    const unsigned char expectedUUID[16] = {0x3b,0x6f,0x64,0x92,0x11,0x4e,0x3e,0xa2,0xbc,0x64,0xdf,0xdd,0xbd,0x36,0x14,0x34};
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
    // Remove BG3's duplicate cascaded-shadow stage. A mismatch leaves BG3
    // unchanged; the environment switch allows comparison runs.
    if (!(getenv("BG3MFX_SINGLE_SHADOW_STAGE") && strcmp(getenv("BG3MFX_SINGLE_SHADOW_STAGE"),"0") == 0)) {
        NSError *shadowError = nil;
        if (!BG3MFXInstallShadowDuplicateFix(slide,report,&shadowError))
            event(@{@"event":@"shadowDuplicateFixSkipped",@"reason":shadowError.localizedDescription ?: @""});
    }
    // Skip the signal-mask system calls in BG3's Lua error handling
    // (src/LuaJumpFix.mm). A mismatch leaves BG3 unchanged. BG3MFX_LUA_JUMP_FIX=0
    // keeps setjmp/longjmp for comparison.
    if (!(getenv("BG3MFX_LUA_JUMP_FIX") && strcmp(getenv("BG3MFX_LUA_JUMP_FIX"),"0") == 0)) {
        NSError *luaError = nil;
        if (!BG3MFXInstallLuaJumpFix(slide,report,&luaError))
            event(@{@"event":@"luaJumpFixSkipped",@"reason":luaError.localizedDescription ?: @""});
    }
    // Optimized thread idling: BG3's job system and frame limiter sleep instead
    // of spinning (src/ThreadIdling.mm). A mismatch leaves BG3 unchanged.
    // BG3MFX_OPTIMIZED_IDLING=0 keeps BG3's spinning for comparison.
    if (!(getenv("BG3MFX_OPTIMIZED_IDLING") && strcmp(getenv("BG3MFX_OPTIMIZED_IDLING"),"0") == 0)) {
        NSError *idlingError = nil;
        if (!BG3MFXInstallThreadIdling(slide,report,&idlingError))
            event(@{@"event":@"threadIdlingSkipped",@"reason":idlingError.localizedDescription ?: @""});
    }
    // Opt-in: time BG3's server tick, its CPU time and its limiter
    // (src/ServerPacingProbe.h).
    if (getenv("BG3MFX_TRACE_SERVER_PACING") && strcmp(getenv("BG3MFX_TRACE_SERVER_PACING"),"1") == 0) {
        NSError *pacingError = nil;
        if (!BG3MFXInstallServerPacingProbe(slide,&pacingError))
            event(@{@"event":@"serverPacingSkipped",@"reason":pacingError.localizedDescription ?: @""});
    }
    void **table = at<void **>(0x1087ac1a0);
    if (table[4] != at<void *>(0x103288fb8) || table[7] != at<void *>(0x103290180)) { errorOut(error,@"The Video menu callback was already modified."); return NO; }
    originalInit = reinterpret_cast<void(*)(void *)>(table[4]);
    originalApplyCombo = reinterpret_cast<void(*)(void *,const void *)>(table[7]);
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:hudPreference];
    hudEnabled = saved ? [saved boolValue] : (getenv("MTL_HUD_ENABLED") && strcmp(getenv("MTL_HUD_ENABLED"),"1") == 0 &&
        !(getenv("MTL_HUD_HIDDEN") && strcmp(getenv("MTL_HUD_HIDDEN"),"1") == 0));
    uintptr_t page = reinterpret_cast<uintptr_t>(table) & ~(static_cast<uintptr_t>(vm_page_size)-1);
    kern_return_t result = vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
    if (result != KERN_SUCCESS) { errorOut(error,@"Could not make the native menu callback writable."); return NO; }
    table[4] = reinterpret_cast<void *>(menuInit);
    table[7] = reinterpret_cast<void *>(applyCombo);
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
#ifndef BG3MFX_NO_TRACE
    installMenuProbeMonitor();
#endif
    return YES;
}

int BG3MFXSelectedScalingMode(void) { return selectedScalingMode.load(); }

// Standalone GPU regression harnesses have no BG3 settings manager. Never
// permit them to override a real game's menu selection.
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

BOOL BG3MFXFrameGenerationEnabled(void) { return frameGenerationChecked.load() && frameGenerationSupported(); }
