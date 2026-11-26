#include "common/Feature.h"
#include "common/Notice.h"
#include "common/native/CodePatch.h"
#include "common/native/SupportedBuild.h"
#import "features/custom-menu/CustomMenu.h"
#import <AppKit/AppKit.h>
#include <objc/runtime.h>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>

// The notch-area feature: BG3's Borderless window drawn beside the camera
// notch, with a persistent Use Notch Area tick box after Display Mode.
//
// BG3 creates its Borderless (and Fullscreen) window as a borderless LSWindow,
// and CocoaWindow::Show calls toggleFullScreen: while its style mask is 0.
// macOS keeps a native full-screen window below the notch and paints the strip
// beside it black. On a screen with a notch, that call instead gives the window
// the screen's whole frame and hides the menu bar and Dock, as full screen
// does; BG3 already raises the window above the menu bar (level 25) while it is
// key. BG3 never toggles back: a Display Mode change closes the window and
// creates a new one, which restores the presentation options here. The tick
// box moves the current window between the two at once.
//
// While the window is beside the notch, the combat turn order (the
// CombatantsOverlay widget, anchored at the top center) is moved below it:
// its full-screen CombatState border gets the notch's share of the UI's height
// as extra top margin. Noesis hit-tests in its own layout, so clicks follow.

namespace {
namespace Native = BG3MFXBuild::NotchArea;
namespace Layout = BG3MFXBuild::NotchArea::Layout;
constexpr uint16_t notchAreaID = 0x7f03;
NSString *const notchAreaPreference = @"BG3MFXNotchArea";
std::atomic<bool> notchAreaEnabled{true};
std::atomic<bool> notchedScreenPresent{false};
IMP originalToggleFullScreen;
__weak NSWindow *notchWindow;
NSApplicationPresentationOptions optionsBeforeNotchWindow;

// Noesis::Thickness.
struct Thickness { float left, top, right, bottom; };
// The notch's share of the screen's height while the window is beside it, else 0.
std::atomic<float> turnOrderInset{0};
// The Noesis::View BG3's UI manager last rendered.
std::atomic<uintptr_t> mainView{0};
void (*managerRender)(void *manager);
void (*viewUpdate)(void *view, double time);
const char *(*getName)(const void *element);
float (*getActualHeight)(const void *element);
const Thickness &(*getMargin)(const void *element);
void (*setMargin)(void *element, const Thickness &margin);
unsigned (*getChildrenCount)(const void *visual);
void *(*getChild)(const void *visual, unsigned index);
// Touched only on the thread that updates the main view.
void *insetElement;
float elementTop, insetTop;

bool named(const void *element, const char *name) {
    const char *actual = element ? getName(element) : nullptr;
    return actual && strcmp(actual, name) == 0;
}
// The first child, if it has the name.
void *namedChild(const void *element, const char *name) {
    void *child = element && getChildrenCount(element) ? getChild(element, 0) : nullptr;
    return named(child, name) ? child : nullptr;
}
// BG3's view: CanvasRoot > ViewboxRoot > Decorator > ContentRoot, a grid of
// widgets; CombatantsOverlay > HudRoot > HudRootPresenter > CombatState, a
// full-screen border around the top-anchored turn order.
void *combatState(void *view) {
    void *root = *reinterpret_cast<void **>(static_cast<char *>(view) + Layout::ViewContent);
    if (!named(root, "CanvasRoot")) return nullptr;
    void *viewbox = namedChild(root, "ViewboxRoot");
    void *decorator = viewbox && getChildrenCount(viewbox) ? getChild(viewbox, 0) : nullptr;
    void *content = namedChild(decorator, "ContentRoot");
    if (!content) return nullptr;
    const unsigned widgets = getChildrenCount(content);
    for (unsigned i = 0; i < widgets; ++i) {
        void *widget = getChild(content, i);
        if (named(widget, "CombatantsOverlay"))
            return namedChild(namedChild(namedChild(widget, "HudRoot"), "HudRootPresenter"), "CombatState");
    }
    return nullptr;
}
// Gives the turn order the inset as extra top margin, over the margin BG3
// gave it.
void insetTurnOrder(void *view) {
    void *element = combatState(view);
    if (!element) return;
    Thickness margin = getMargin(element);
    if (element != insetElement || margin.top != insetTop) {
        insetElement = element;
        elementTop = insetTop = margin.top;
    }
    const float height = getActualHeight(element) + margin.top + margin.bottom;
    if (!(height > 0)) return;
    const float top = elementTop + std::round(turnOrderInset.load(std::memory_order_relaxed) * height);
    if (top == margin.top) return;
    margin.top = insetTop = top;
    setMargin(element, margin);
}
void managerRenderHook(void *manager) {
    const uintptr_t view = *reinterpret_cast<uintptr_t *>(static_cast<char *>(manager) + Layout::ManagerView);
    mainView.store(view ? view - Layout::ViewInterface : 0, std::memory_order_relaxed);
    managerRender(manager);
}
void viewUpdateHook(void *view, double time) {
    if (reinterpret_cast<uintptr_t>(view) == mainView.load(std::memory_order_relaxed)) insetTurnOrder(view);
    viewUpdate(view, time);
}
// The turn order needs the supported build's Noesis; without it the window is
// still drawn beside the notch.
const char *hookTurnOrder(intptr_t slide) {
    if (!slide) return "this BG3 build is not supported";
    getName = reinterpret_cast<decltype(getName)>(Native::GetName + slide);
    getActualHeight = reinterpret_cast<decltype(getActualHeight)>(Native::GetActualHeight + slide);
    getMargin = reinterpret_cast<decltype(getMargin)>(Native::GetMargin + slide);
    setMargin = reinterpret_cast<decltype(setMargin)>(Native::SetMargin + slide);
    getChildrenCount = reinterpret_cast<decltype(getChildrenCount)>(Native::GetChildrenCount + slide);
    getChild = reinterpret_cast<decltype(getChild)>(Native::GetChild + slide);
    const uintptr_t islands = BG3MFXBuild::HeaderPadding + slide + BG3MFXBuild::Islands::NotchArea.offset;
    const uintptr_t renderIsland = islands, updateIsland = islands + BG3MFXEntryIslandBytes;
    managerRender = reinterpret_cast<decltype(managerRender)>(renderIsland + BG3MFXEntryOriginalOffset);
    viewUpdate = reinterpret_cast<decltype(viewUpdate)>(updateIsland + BG3MFXEntryOriginalOffset);
    if (const char *failure = BG3MFXHookEntry(Native::ManagerRender + slide, Native::ManagerRenderFirst, renderIsland,
                                              reinterpret_cast<void *>(managerRenderHook)))
        return failure;
    return BG3MFXHookEntry(Native::ViewUpdate + slide, Native::ViewUpdateFirst, updateIsland,
                           reinterpret_cast<void *>(viewUpdateHook));
}

bool hasNotch(NSScreen *screen) {
    return screen && screen.safeAreaInsets.top > 0;
}
// The window's screen; before it is first ordered in, the screen under its frame.
NSScreen *screenOf(NSWindow *window) {
    if (NSScreen *screen = window.screen) return screen;
    NSPoint center = NSMakePoint(NSMidX(window.frame), NSMidY(window.frame));
    for (NSScreen *screen in NSScreen.screens)
        if (NSPointInRect(center, screen.frame)) return screen;
    return nil;
}
void updateNotchedScreenPresent() {
    bool notched = false;
    for (NSScreen *screen in NSScreen.screens) notched = notched || hasNotch(screen);
    notchedScreenPresent.store(notched, std::memory_order_relaxed);
}
void coverScreen(NSWindow *window) {
    NSScreen *screen = screenOf(window);
    if (!screen) return;
    if (window != notchWindow) {
        // BG3's delegate records the cursor capture, display and display rect
        // that native full screen would; its options are replaced below.
        id<NSWindowDelegate> delegate = window.delegate;
        if ([delegate respondsToSelector:@selector(window:willUseFullScreenPresentationOptions:)])
            [delegate window:window willUseFullScreenPresentationOptions:NSApp.presentationOptions];
        if (!notchWindow) optionsBeforeNotchWindow = NSApp.presentationOptions;
        notchWindow = window;
    }
    NSApp.presentationOptions = NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
    [window setFrame:screen.frame display:YES];
    turnOrderInset.store(screen.frame.size.height > 0 ? screen.safeAreaInsets.top / screen.frame.size.height : 0,
                         std::memory_order_relaxed);
}
void leaveScreen(NSWindow *window) {
    if (!window || window != notchWindow) return;
    notchWindow = nil;
    NSApp.presentationOptions = optionsBeforeNotchWindow;
    turnOrderInset.store(0, std::memory_order_relaxed);
}
void toggleFullScreenBesideNotch(NSWindow *window, SEL selector, id sender) {
    auto original = reinterpret_cast<void (*)(id, SEL, id)>(originalToggleFullScreen);
    bool besideNotch = NSThread.isMainThread && (window == notchWindow ||
        (notchAreaEnabled.load(std::memory_order_relaxed) && window.styleMask == NSWindowStyleMaskBorderless &&
         hasNotch(screenOf(window))));
    if (besideNotch) coverScreen(window);
    else if (original) original(window, selector, sender);
}
bool wrapToggleFullScreen() {
    Class windowClass = NSClassFromString(@"LSWindow");
    SEL selector = @selector(toggleFullScreen:);
    Method method = windowClass ? class_getInstanceMethod(windowClass, selector) : nullptr;
    if (!method || method_getNumberOfArguments(method) != 3) return false;
    char *returnType = method_copyReturnType(method);
    char *senderType = method_copyArgumentType(method, 2);
    bool signatureOK = returnType && returnType[0] == 'v' && senderType && senderType[0] == '@';
    free(returnType);
    free(senderType);
    const char *encoding = method_getTypeEncoding(method);
    if (!signatureOK || !encoding) return false;
    IMP current = method_getImplementation(method);
    if (current == reinterpret_cast<IMP>(toggleFullScreenBesideNotch)) return true;
    originalToggleFullScreen = current;
    if (class_addMethod(windowClass, selector, reinterpret_cast<IMP>(toggleFullScreenBesideNotch), encoding))
        return true;
    originalToggleFullScreen = class_replaceMethod(windowClass, selector,
        reinterpret_cast<IMP>(toggleFullScreenBesideNotch), encoding);
    return originalToggleFullScreen != nullptr;
}
bool isGameWindow(NSWindow *window) {
    Class gameWindowClass = NSClassFromString(@"LSWindow");
    return gameWindowClass && [window isKindOfClass:gameWindowClass];
}
// Moves BG3's current Borderless or Fullscreen window between the notch area
// and macOS full screen when the tick box changes.
void switchGameWindow(bool besideNotch) {
    auto original = reinterpret_cast<void (*)(id, SEL, id)>(originalToggleFullScreen);
    if (!original) return;
    if (!besideNotch) {
        NSWindow *window = notchWindow;
        if (!window) return;
        leaveScreen(window);
        original(window, @selector(toggleFullScreen:), nil);
        return;
    }
    for (NSWindow *window in NSApp.windows) {
        if (!isGameWindow(window) || !(window.styleMask & NSWindowStyleMaskFullScreen) || !hasNotch(window.screen)) continue;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        __block id observer = [center addObserverForName:NSWindowDidExitFullScreenNotification object:window
                                                   queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            observer = nil;
            // After BG3's own windowDidExitFullScreen:, which clears the presentation options.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (notchAreaEnabled.load(std::memory_order_relaxed) && !(window.styleMask & NSWindowStyleMaskFullScreen))
                    coverScreen(window);
            });
        }];
        original(window, @selector(toggleFullScreen:), nil);
        return;
    }
}
void observeWindows() {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    // BG3 may close its window off the main thread.
    [center addObserverForName:NSWindowWillCloseNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSWindow *closing = note.object;
        dispatch_async(dispatch_get_main_queue(), ^{ leaveScreen(closing); });
    }];
    [center addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
        updateNotchedScreenPresent();
        if (NSWindow *window = notchWindow) coverScreen(window);
    }];
}

void notchAreaChanged(void *, const void *item) {
    if (!item || BG3MFXMenuItemID(const_cast<void *>(item)) != notchAreaID) return;
    bool enabled = BG3MFXMenuTickBoxValue(item);
    notchAreaEnabled.store(enabled, std::memory_order_relaxed);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:notchAreaPreference];
    dispatch_async(dispatch_get_main_queue(), ^{ switchGameWindow(enabled); });
}
void menuBuilt(void *manager) {
    if (!notchedScreenPresent.load(std::memory_order_relaxed)) return;
    BG3MFXMenuText name, description;
    if (!BG3MFXMenuMakeText(name, "h00000000g0000g0000g0000g00000000f028", "Use Notch Area") ||
        !BG3MFXMenuMakeText(description, "h00000000g0000g0000g0000g00000000f029",
                            "Fills the area beside the camera notch in Borderless and moves the combat turn order "
                            "below it. Changes take effect immediately.")) {
        BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
        BG3MFXMenuProblem(@"Could not register the Use Notch Area text.");
        return;
    }
    void *tickBox = BG3MFXMenuAddTickBox(manager, notchAreaID, name, description,
                                         notchAreaEnabled.load(std::memory_order_relaxed), notchAreaChanged);
    BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
    // Right after the first native combo (Display Mode).
    size_t count = BG3MFXMenuItemCount(manager);
    if (tickBox && count && BG3MFXMenuItem(manager, count - 1) == tickBox)
        for (size_t i = 0; i + 2 < count; ++i)
            if (BG3MFXMenuItemType(BG3MFXMenuItem(manager, i)) == 3) { BG3MFXMenuMoveLast(manager, i + 1); break; }
}

BOOL installNotchArea(const BG3MFXFeatureContext &context, NSError **error) {
    if (!wrapToggleFullScreen()) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXNotchArea" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"LSWindow's toggleFullScreen: is not the expected method."}];
        return NO;
    }
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:notchAreaPreference];
    notchAreaEnabled.store(saved ? [saved boolValue] : true, std::memory_order_relaxed);
    dispatch_async(dispatch_get_main_queue(), ^{ updateNotchedScreenPresent(); });
    observeWindows();
    if (const char *failure = hookTurnOrder(context.slide))
        BG3MFXFail([NSString stringWithFormat:@"The combat turn order stays under the notch: %s.", failure], nil, nil);
    BG3MFXMenuOnBuilt(menuBuilt);
    return YES;
}
const char *const notchAreaRequires[] = {"custom-menu", nullptr};
}
BG3MFX_FEATURE(notchArea, {"notch-area", notchAreaRequires, false, installNotchArea, nullptr});
