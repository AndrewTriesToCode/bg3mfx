#import "common/EventLog.h"
#import "features/custom-menu/RenderViewFocus.h"
#import <AppKit/AppKit.h>
#include <objc/runtime.h>
#include <cstdlib>

// BG3's BindSurface removes its render view (LSMTLView) from the window and
// sets it back, which leaves the window, not the view, as first responder.
// After a Video settings change in fullscreen, the next click then only gave
// the view focus back, so the controls needed a second click. LSWindow's
// setContentView: is wrapped to restore the view's focus when it had it.
// Part of custom-menu (the Video options menu fix).

namespace {
IMP originalSetContentView;
NSWindow *pendingFocusWindow;
NSView *pendingFocusView;

bool isGameRenderView(NSView *view) {
    Class renderViewClass = NSClassFromString(@"LSMTLView");
    return view && renderViewClass && [view isKindOfClass:renderViewClass];
}
void setContentViewWithFocusRepair(NSWindow *window, SEL selector, NSView *view) {
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
    BG3MFX_EVENT(@{@"event":@"renderViewFocusRepair", @"attempted":@(eligible),
        @"restored":@(restored), @"keyWindow":@(window.isKeyWindow),
        @"active":@(NSApp.isActive)});
}
bool installRepair() {
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
}

bool BG3MFXInstallRenderViewFocus() {
    return installRepair();
}
