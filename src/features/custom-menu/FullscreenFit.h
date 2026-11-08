#pragma once

// Keeps BG3's Borderless (macOS full screen) window below the notch: at startup
// AppKit left it as tall as the whole screen with its top under the notch, so
// its bottom was off screen until a resolution change. Installed by
// custom-menu.
void BG3MFXInstallFullscreenFit();
