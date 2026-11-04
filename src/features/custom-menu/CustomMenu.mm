#include "common/native/SupportedBuild.h"
#import "features/custom-menu/CustomMenu.h"
#import "features/custom-menu/RenderViewFocus.h"
#include "common/Feature.h"
#import "common/Notice.h"
#include <mach/mach.h>
#include <atomic>
#include <cstring>

namespace Native = BG3MFXBuild::Menu;
namespace Layout = BG3MFXBuild::Menu::Layout;

namespace {
struct View { const char *data; uint32_t size; uint32_t padding; };
struct TextHandle { uint32_t id; uint16_t version; uint16_t padding; };
struct Text { TextHandle primary, arguments; };
static_assert(sizeof(Text) == sizeof(BG3MFXMenuText::storage), "BG3MFXMenuText holds an ls::TranslatedString");

intptr_t slide;
void (*originalInit)(void *);
BG3MFXMenuApply originalApplyCombo;
void *optionsManager;
std::atomic<bool> optionsBuilt{false};
bool active;
// Registered from the features' install, before activation; read only after.
constexpr size_t MaxBuilt = 8, MaxWrappers = 4;
void (*built[MaxBuilt])(void *);
size_t builtCount;
void (*wrappers[MaxWrappers])(void *, const void *, BG3MFXMenuApply);
size_t wrapperCount;

template<class T> T at(uintptr_t address) { return reinterpret_cast<T>(address + slide); }
template<class T> T &field(const void *object, size_t offset) {
    return *reinterpret_cast<T *>(static_cast<char *>(const_cast<void *>(object)) + offset);
}
Text &text(BG3MFXMenuText &t) { return *reinterpret_cast<Text *>(t.storage); }
const Text &text(const BG3MFXMenuText &t) { return *reinterpret_cast<const Text *>(t.storage); }
// Observer lists: BG3 calls each entry's first virtual with its context.
template<class... A> void notify(const void *object, size_t list, size_t count, A... arguments) {
    void *observers = field<void *>(object, list);
    int32_t observerCount = field<int32_t>(object, count);
    if (!observers || observerCount < 0 || observerCount > 256) return;
    for (int32_t j = 0; j < observerCount; ++j) {
        char *entry = static_cast<char *>(observers) + j * Layout::ObserverStride;
        void **table = field<void **>(entry, Layout::VTable);
        if (table && table[0]) reinterpret_cast<void (*)(void *, A...)>(table[0])(entry + Layout::ObserverContext, arguments...);
    }
}

// ApplyCombo's chain: wrapper I's `next` is wrapper I+1, the last one's BG3's.
template<size_t I> void applyLevel(void *manager, const void *item) {
    if constexpr (I < MaxWrappers) {
        if (I < wrapperCount) { wrappers[I](manager, item, applyLevel<I + 1>); return; }
    }
    originalApplyCombo(manager, item);
}
void menuInit(void *manager) {
    originalInit(manager);
    optionsBuilt = true;
    if (!field<void **>(manager, Layout::Items) || field<uint32_t>(manager, Layout::ItemCount) > 256) {
        BG3MFXMenuProblem(@"Unexpected option list");
        return;
    }
    // BG3 also builds options without the Video controls; wait for those.
    if (!BG3MFXMenuFind(manager, 3, 99)) return;
    optionsManager = manager;
    for (size_t i = 0; i < builtCount; ++i) built[i](manager);
}

void errorOut(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"BG3MFXCustomMenu" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
// The focus fix, then the features register their options.
BOOL installCustomMenu(const BG3MFXFeatureContext &context, NSError **) {
    slide = context.slide;
    BG3MFXInstallRenderViewFocus();
    return YES;
}
// After every feature's install: patch the Video options manager's callbacks.
BOOL activateCustomMenu(const BG3MFXFeatureContext &, NSError **error) {
    void **table = at<void **>(Native::Callbacks);
    if (table[Layout::InitSlot] != at<void *>(Native::Init) || table[Layout::ApplyComboSlot] != at<void *>(Native::ApplyCombo)) {
        errorOut(error, @"The Video menu callback was already modified.");
        return NO;
    }
    originalInit = reinterpret_cast<void (*)(void *)>(table[Layout::InitSlot]);
    originalApplyCombo = reinterpret_cast<BG3MFXMenuApply>(table[Layout::ApplyComboSlot]);
    uintptr_t page = reinterpret_cast<uintptr_t>(table) & ~(static_cast<uintptr_t>(vm_page_size) - 1);
    if (vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        errorOut(error, @"Could not make the native menu callback writable.");
        return NO;
    }
    table[Layout::InitSlot] = reinterpret_cast<void *>(menuInit);
    table[Layout::ApplyComboSlot] = reinterpret_cast<void *>(applyLevel<0>);
    vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ);
    active = true;
    return YES;
}
}
BG3MFX_FEATURE(customMenu, {"custom-menu", nullptr, true, nullptr, installCustomMenu, activateCustomMenu});

// AddTranslatedString returns its nontrivial TextHandle through explicit argument 0,
// consumes argument 2, and takes StringView in registers 3/4.
BOOL BG3MFXMenuMakeText(BG3MFXMenuText &result, const char *identifier, const char *literal) {
    void *repository = *at<void **>(Native::TranslationRepository);
    if (!repository) return NO;
    void *map = field<void *>(repository, Layout::TranslationMap);
    if (!map) return NO;
    TextHandle input{}, output{};
    View idView{identifier, static_cast<uint32_t>(strlen(identifier)), 0};
    at<void (*)(TextHandle *, const View *, uint16_t)>(Native::MakeHandle)(&input, &idView, 1);
    at<void (*)(TextHandle *, void *, TextHandle *, const char *, uint32_t, void *, uint32_t)>(Native::AddTranslatedString)
        (&output, repository, &input, literal, static_cast<uint32_t>(strlen(literal)), map, 0);
    at<void (*)(Text *, const TextHandle *)>(Native::MakeText)(&text(result), &output);
    // A text that fails its check is still constructed and must be destroyed.
    result.constructed = true;
    at<void (*)(TextHandle *)>(Native::DestroyHandle)(&output);
    View resolved = at<View (*)(const Text *, uint32_t, uint32_t)>(Native::ResolveText)(&text(result), 0, 0);
    return resolved.size == strlen(literal) && resolved.data && memcmp(resolved.data, literal, resolved.size) == 0;
}
void BG3MFXMenuDestroyText(BG3MFXMenuText &t) {
    if (!t.constructed) return;
    at<void (*)(Text *)>(Native::DestroyText)(&text(t));
    t = BG3MFXMenuText{};
}

void BG3MFXMenuOnBuilt(void (*callback)(void *)) {
    if (!active && builtCount < MaxBuilt) built[builtCount++] = callback;
}
void BG3MFXMenuWrapApplyCombo(void (*wrapper)(void *, const void *, BG3MFXMenuApply)) {
    if (!active && wrapperCount < MaxWrappers) wrappers[wrapperCount++] = wrapper;
}
void *BG3MFXMenuManager(void) { return optionsManager; }
bool BG3MFXMenuOptionsBuilt(void) { return optionsBuilt.load(); }
bool BG3MFXMenuActive(void) { return active; }
void BG3MFXMenuProblem(NSString *reason) {
    static std::atomic<bool> shown{false};
    if (![reason isKindOfClass:NSString.class] || reason.length == 0) reason = @"The Video options could not be extended.";
    BG3MFXFail([@"bg3mfx menu integration: " stringByAppendingString:reason],
        shown.exchange(true) ? nil : @"bg3mfx options may be unavailable",
        [reason stringByAppendingString:@"\n\nThe game continues with its own video options."]);
}

size_t BG3MFXMenuItemCount(void *manager) {
    if (!field<void **>(manager, Layout::Items)) return 0;
    uint32_t count = field<uint32_t>(manager, Layout::ItemCount);
    return count > 256 ? 0 : count;
}
void *BG3MFXMenuItem(void *manager, size_t index) { return field<void **>(manager, Layout::Items)[index]; }
uint8_t BG3MFXMenuItemType(void *item) { return field<uint8_t>(item, Layout::ItemType); }
uint16_t BG3MFXMenuItemID(void *item) { return field<uint16_t>(item, Layout::ItemID); }
void *BG3MFXMenuFind(void *manager, int type, uint16_t id) {
    for (size_t i = 0, count = BG3MFXMenuItemCount(manager); i < count; ++i) {
        void *item = BG3MFXMenuItem(manager, i);
        if (BG3MFXMenuItemID(item) == id && (type < 0 || BG3MFXMenuItemType(item) == type)) return item;
    }
    return nullptr;
}
void BG3MFXMenuMoveLast(void *manager, size_t index) {
    size_t count = BG3MFXMenuItemCount(manager);
    if (!count || index + 1 >= count) return;
    void **items = field<void **>(manager, Layout::Items);
    void *last = items[count - 1];
    memmove(items + index + 1, items + index, (count - index - 1) * sizeof(void *));
    items[index] = last;
}
void BG3MFXMenuSetEnabled(void *item, bool enabled) {
    if (!item || field<uint8_t>(item, Layout::ItemEnabled) == enabled) return;
    field<uint8_t>(item, Layout::ItemEnabled) = enabled;
    notify(item, Layout::EnabledObservers, Layout::EnabledObserverCount);
}

BG3MFXMenuCallback BG3MFXMenuSelectionCallback(void *item) { return field<BG3MFXMenuCallback>(item, Layout::SelectionCallback); }
void BG3MFXMenuSetSelectionCallback(void *item, BG3MFXMenuCallback callback) { field<BG3MFXMenuCallback>(item, Layout::SelectionCallback) = callback; }
void *BG3MFXMenuCallbackStorage(void *item) { return static_cast<char *>(item) + Layout::SelectionCallback; }
void *BG3MFXMenuStorageManager(void *storage) { return storage ? field<void *>(storage, Layout::CallbackManager) : nullptr; }
void *BG3MFXMenuItemManager(void *item) { return field<void *>(item, Layout::CapturedManager); }

// AddTickBoxOption and AddSliderOption install an inline POD Function table
// at +0x38; only its Call is replaced.
void *BG3MFXMenuAddTickBox(void *manager, uint16_t id, const BG3MFXMenuText &name, const BG3MFXMenuText &description,
                           bool value, BG3MFXMenuCallback changed) {
    void *item = at<void *(*)(void *, uint16_t, const Text *, const Text *, bool)>(Native::AddTickBox)
        (manager, id, &text(name), &text(description), value);
    if (item) BG3MFXMenuSetSelectionCallback(item, changed);
    return item;
}
bool BG3MFXMenuTickBoxValue(const void *item) { return field<uint8_t>(item, Layout::CheckboxValue) != 0; }
void *BG3MFXMenuAddSlider(void *manager, uint16_t id, const BG3MFXMenuText &name, const BG3MFXMenuText &description,
                          float value, float lowest, float highest, BG3MFXMenuCallback changed) {
    void *item = at<void *(*)(void *, uint16_t, const Text *, const Text *, float, float, float, bool)>(Native::AddSlider)
        (manager, id, &text(name), &text(description), value, lowest, highest, true);
    if (item) BG3MFXMenuSetSelectionCallback(item, changed);
    return item;
}
float BG3MFXMenuSliderValue(const void *item) { return field<float>(item, Layout::SliderValue); }
void BG3MFXMenuShowSliderValue(void *item, float value) {
    if (field<float>(item, Layout::SliderValue) == value) return;
    field<float>(item, Layout::SliderValue) = value;
    notify(item, Layout::SliderObservers, Layout::SliderObserverCount, value);
}

NSArray<NSNumber *> *BG3MFXMenuComboValues(void *combo) {
    uint32_t count = combo ? field<uint32_t>(combo, Layout::ComboCount) : 0;
    char *array = combo ? field<char *>(combo, Layout::ComboItems) : nullptr;
    if (count > 16 || (count && !array)) return @[];
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; ++i) [values addObject:@(field<uint32_t>(array + i * Layout::ComboItemStride, Layout::ComboItemValue))];
    return values;
}
// ComboItems are 0x24 bytes: label Text at +0, description at +0x10, value at +0x20.
NSString *BG3MFXMenuComboLabel(void *combo, size_t index) {
    char *array = field<char *>(combo, Layout::ComboItems);
    if (!array || index >= field<uint32_t>(combo, Layout::ComboCount)) return nil;
    View label = at<View (*)(const void *, uint32_t, uint32_t)>(Native::ResolveText)(array + index * Layout::ComboItemStride, 0, 0);
    if (!label.data || label.size >= 256) return nil;
    return [[NSString alloc] initWithBytes:label.data length:label.size encoding:NSUTF8StringEncoding];
}
void BG3MFXMenuAppendComboValue(void *combo, int value, const BG3MFXMenuText &name, const BG3MFXMenuText &description) {
    at<void (*)(void *, int, const Text *, const Text *)>(Native::AppendComboValue)(combo, value, &text(name), &text(description));
}
void BG3MFXMenuComboItemsChanged(void *combo) { notify(combo, Layout::ComboItemsObservers, Layout::ComboItemsObserverCount); }
int BG3MFXMenuComboSelection(const void *combo) { return field<int32_t>(combo, Layout::ComboSelection); }
void BG3MFXMenuSetComboSelection(void *combo, int value) { field<int32_t>(combo, Layout::ComboSelection) = value; }
void BG3MFXMenuShowComboSelection(void *combo, int value) {
    BG3MFXMenuSetComboSelection(combo, value);
    notify(combo, Layout::SelectionObservers, Layout::SelectionObserverCount, value);
}
void BG3MFXMenuSelectCombo(void *combo, int value) {
    BG3MFXMenuSetComboSelection(combo, value);
    if (BG3MFXMenuCallback call = BG3MFXMenuSelectionCallback(combo)) call(BG3MFXMenuCallbackStorage(combo), combo);
    notify(combo, Layout::SelectionObservers, Layout::SelectionObserverCount, value);
}
