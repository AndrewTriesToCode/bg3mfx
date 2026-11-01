#pragma once
#import <Foundation/Foundation.h>

// Keeps BG3's render view first responder across BindSurface, so the Video
// options respond to the first click after a fullscreen settings change.
// Installed by custom-menu; false when LSWindow's setContentView: is missing or
// has another signature.
bool BG3MFXInstallRenderViewFocus(void (*report)(NSDictionary *));
