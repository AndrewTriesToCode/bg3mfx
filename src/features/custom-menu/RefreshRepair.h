#pragma once
#include <cstdint>

// BG3 presents each frame no sooner than 1/(refresh rate + 1) after the last,
// with the refresh rate from its Video settings: the fullscreen mode's, kept
// in a borderless window too, where the screen runs at its own rate (60 chosen
// in fullscreen held a 120 Hz borderless window at 60). Through metal-hooks'
// present-duration filters, this uses the game window's screen rate instead.
// Installed by custom-menu; false when metal-hooks does not take the filter.
bool BG3MFXInstallRefreshRepair(intptr_t slide);
