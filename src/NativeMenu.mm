#import "NativeMenu.h"
#import "NativeJitter.h"
#import <MetalFX/MetalFX.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <atomic>
#include <cstring>
#include <cstdlib>

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
// Upscaling Type menu value: 0 Off, 1 FSR, 2 Spatial, 3 Temporal,
// 4 Temporal + Frame Generation. The renderer sees 4 as Temporal plus a flag.
static std::atomic<int> selectedScalingMode{0};
static bool metalFXValue(int value) { return value >= 2 && value <= 4; }
static bool temporalValue(int value) { return value == 3 || value == 4; }
// Earlier builds stored Frame Generation as a separate checkbox.
static NSString *const legacyFrameGenerationPreference=@"BG3MFXFrameGeneration";
static NSString *const hudPreference = @"BG3MFXMetalHUD";
static NSString *const scalingPreference = @"BG3MFXUpscalingType";
static NSString *const qualityPreference = @"BG3MFXUpscalingQuality";
static const uint16_t hudID = 0x7f01;

static void event(NSDictionary *value);
template<class T> T at(uintptr_t address) { return reinterpret_cast<T>(address + slide); }
template<class T> T &field(void *object, size_t offset) { return *reinterpret_cast<T *>(static_cast<char *>(object) + offset); }
static void event(NSDictionary *value) { if (reportEvent) reportEvent(value); }
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
static void *findItem(void *manager, uint8_t type, uint16_t id) {
    void **items = field<void **>(manager,0x30);
    uint32_t count = field<uint32_t>(manager,0x3c);
    if (!items || count > 256) return nullptr;
    for (uint32_t i=0;i<count;++i)
        if (field<uint8_t>(items[i],8) == type && field<uint16_t>(items[i],0x88) == id) return items[i];
    return nullptr;
}
static void setItemEnabled(void *item, uint8_t enabled) {
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
static bool frameGenerationSupported() {
    static bool supported = [MTLFXFrameInterpolatorDescriptor supportsDevice:MTLCreateSystemDefaultDevice()];
    return supported;
}
static void updateDependentControls(void *manager, int mode) {
    // Keep the underlying TAA value: the renderer needs that pass's inputs even
    // when MetalFX Temporal replaces its draw.
    void *aa = findItem(manager,3,98);
    if (aa) setItemEnabled(aa,!temporalValue(mode) && field<uint32_t>(aa,0x9c) > 1);
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
    if (!originalUpscaleCall || !storage || !item || field<uint16_t>(const_cast<void *>(item),0x88) != 99) {
        if (originalUpscaleCall) originalUpscaleCall(storage,item);
        return;
    }
    void *manager = field<void *>(storage,0x18);
    int value = field<int32_t>(const_cast<void *>(item),0xd0);
    if (!manager || value < 0 || value > 4 || (value == 4 && !frameGenerationSupported())) {
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
    originalInit(manager);
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
    NSArray *extendedValues = frameGeneration ? @[@0,@1,@2,@3,@4] : @[@0,@1,@2,@3];
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
        makeText(frameName,"h00000000g0000g0000g0000g00000000f007","MetalFX Temporal + Frame Generation") &&
        makeText(frameDescription,"h00000000g0000g0000g0000g00000000f008","MetalFX Temporal upscaling, plus a MetalFX-generated frame between rendered frames. The FPS limiter controls rendered frames.");
    if (!ok) { event(@{@"event":@"nativeMenuError",@"error":@"Could not register menu text"}); return; }
    if (nativeOptions) {
        at<void(*)(void *,int,const Text *,const Text *)>(0x103294954)(upscale,2,&spatialName,&spatialDescription);
        at<void(*)(void *,int,const Text *,const Text *)>(0x103294954)(upscale,3,&temporalName,&temporalDescription);
        if (frameGeneration) at<void(*)(void *,int,const Text *,const Text *)>(0x103294954)(upscale,4,&frameName,&frameDescription);
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
    destroyText(frameName); destroyText(frameDescription);
    destroyText(spatialName); destroyText(spatialDescription);
    destroyText(temporalName); destroyText(temporalDescription);
    destroyText(hudName); destroyText(hudDescription);
    if (NSThread.isMainThread) applyHUD(); else dispatch_async(dispatch_get_main_queue(),^{ applyHUD(); });
    event(@{@"event":@"nativeMenuReady",@"upscalingOptions":frameGeneration ? @[@"Off",@"AMD FSR 1.0",@"MetalFX Spatial",@"MetalFX Temporal",@"MetalFX Temporal + Frame Generation"] :
                @[@"Off",@"AMD FSR 1.0",@"MetalFX Spatial",@"MetalFX Temporal"],
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
    if (!BG3MFXInstallNativeJitter(slide,report,error)) return NO;
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
    if ([defaults objectForKey:legacyFrameGenerationPreference]) {
        if (startupMode == 3 && [defaults boolForKey:legacyFrameGenerationPreference]) {
            startupMode = 4; [defaults setInteger:startupMode forKey:scalingPreference];
        }
        [defaults removeObjectForKey:legacyFrameGenerationPreference]; [defaults synchronize];
    }
    if (!metalFXValue(startupMode) || (startupMode == 4 && !frameGenerationSupported())) startupMode = 0;
    selectedScalingMode.store(startupMode);
    event(@{@"event":@"nativeMenuStartupMode",@"value":@(startupMode)});
    event(@{@"event":@"nativeMenuInstalled"});
    return YES;
}

int BG3MFXSelectedScalingMode(void) { int value = selectedScalingMode.load(); return value == 4 ? 3 : value; }

// Standalone GPU regression harnesses have no BG3 settings manager. Never
// permit them to override a real game's menu selection.
extern "C" BOOL BG3MFXSetStandaloneScalingMode(int mode) {
    if (originalInit || [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"] || mode < 0 || mode > 4) return NO;
    selectedScalingMode.store(mode);
    return YES;
}

BOOL BG3MFXFrameGenerationEnabled(void) { return selectedScalingMode.load() == 4 && frameGenerationSupported(); }
