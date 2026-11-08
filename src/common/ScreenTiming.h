#pragma once

// The game window's screen timing, from NSScreen: the shortest and longest
// frame intervals it shows (seconds) and the step between them (zero when it
// does not vary in steps). All zero until first read.
struct BG3MFXScreenTiming {
    double minimumInterval, maximumInterval, granularity;
};

// Starts tracking: reads the screen on the main thread now and whenever screens
// or the game window's screen change. Idempotent.
void BG3MFXScreenTimingStart(void);
// The latest copy. Any thread.
BG3MFXScreenTiming BG3MFXScreenTimingCurrent(void);
