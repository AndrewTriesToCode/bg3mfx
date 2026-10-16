# BG3MFX

BGMMFX mods Baldur's Gate 3 on Mac to improve performance and reduce power usage. It does not alter any actual game files on disk.

- Framerate improvements anywhere from **50% to 100%** at no visual loss.

- CPU consumption up t0 **~75% lower**, meaning less heat and fan noise.

## Table of Contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Play](#play)
- [Tips](#tips)
- [Troubleshooting](#troubleshooting)
- [Disabling features](#disabling-features)
- [Uninstall](#uninstall)
- [Building from source and contributing](#building-from-source-and-contributing)
- [License and credits](#license-and-credits)

> **Unofficial and experimental.** BG3MFX is a fan project, not affiliated
> with or endorsed by Larian Studios or Apple. Use it at your own risk. Your
> saves are not touched, but please keep backups as you would with any mod.

> **Built with AI assistance.** Much of BG3MFX's code and documentation was
> written with an AI coding assistant (Claude by Anthropic), directed, reviewed
> and tested in the game by the author. It may still contain mistakes; please
> report anything that looks wrong.

## Features

### GPU features

| Feature | Description | Result |
| --- | --- | --- |
| **Metal Performance Overlay** | Shows Apple's performance overlay with FPS and GPU activity. | |
| **MetalFX Frame Generation** | Creates extra in-between frames for smoother motion. | **~100% more FPS** |
| **MetalFX Spatial Upscaling** | Upscales a smaller rendered image to the final game resolution. | **~30% more FPS** |
| **MetalFX Temporal Upscaling** | Builds an upscaled image from current and earlier frames; better result than spatial. | **~20% more FPS** |
| **Shadow Rendering Optimizations** | Fixes shadow rendering bugs and adds other optimizations. | **~15% more FPS** |
| **Depth Prepass Optimization** | Skips some repeated work when drawing scene depth. | **~2% more FPS** |

### CPU features

| Feature | Description | Result |
| --- | --- | --- |
| **CPU Thread Idling** | Lets idle game workers sleep instead of repeatedly checking for work. | **~50% less thread CPU usage** |
| **Dynamic Worker Prioritization** | Moves background-capable workers to lower-power cores when frame rate allows. | **~33% less thread CPU usage** |
| **Render Thread Optimizations** | Skips repeated texture and pipeline commands to reduce graphics-driver work. | **~1% more FPS**; **~25% less thread CPU usage** |
| **Lua System Call Elimination** | Removes signal-mask and alternate-stack system calls from protected Lua calls. | **~14% less thread CPU usage** in affected calls |

### Other

| Feature | Description |
| --- | --- |
| **Metal HUD** | Shows Apple's on-screen performance overlay. |
| **Video Options Menu Fix** | Fixes a base game bug that can make the video menu unresponsive in fullscreen. |

## How it works

The `bg3mfx` launcher verifies your Steam build and loads BG3MFX's runtime into
the game when it starts, without changing the game files on disk. The runtime
uses hooks—small interceptors that let BG3MFX inspect or adjust selected game
operations as they run—to add MetalFX upscaling and frame generation, reduce
repeated graphics work, and apply CPU and power-use optimizations. See the
[developer documentation](docs/dev/development.md) for implementation details.

## Requirements

- M1 or newer with macOS Tahoe or newer.
- Baldur's Gate 3 for Mac, most-up-to-date version (only the Steam version has been tested; GOG may work).
- [Homebrew](https://brew.sh/) for installation.

## Install

```sh
brew update
brew trust --formula andrewtriestocode/brews/bg3mfx
brew install andrewtriestocode/brews/bg3mfx
```

Homebrew asks you to trust formulae from outside its official taps before it
will install them; the second command trusts only BG3MFX. Homebrew then
builds BG3MFX on your Mac, which takes a few seconds.

Want an app you can open from Launchpad, Spotlight or the Dock? Run this once:

```sh
bg3mfx install-app
```

This adds **BG3MFX** to the Applications folder in your home folder.

## Play

- open **BG3MFX** from your Applications folder, or
- run `bg3mfx` in Terminal.

Baldur's Gate 3 starts with features available. In the game, go to
**Options → Video screen to configure applicable features.

## Tips

- Turn on **Show Metal HUD** (Options → Video → General) to see your frame rate.
- Temporal Upscaling is more resource intensive than spatial but produces much better image quality.
- At lower game resolution higher quality upscaling is needed to get a good result. At higher resolutions even the performance quality option can produce good results.
- **Frame Generation** works best on a high refresh rate display, such as a
  MacBook Pro's 120 Hz ProMotion screen, with **VSync on**. Set the game's
  FPS limiter to half the frame rate you want to see (for example, 60 on a
  120 Hz display).
- The frame limiter will significantly reduce cpu and gpu usage.

## Troubleshooting

**"This version of Baldur's Gate 3 isn't supported yet."** The game was
updated. Run `brew upgrade` to get the latest BG3MFX. If there isn't a
release for the new game version yet, play from Steam as usual in the meantime.

**"Baldur's Gate 3 wasn't found."** BG3MFX looks in your Steam libraries.
If you opened the app, it lets you choose the game's location. In Terminal, use
`bg3mfx --game "/path/to/Baldur's Gate 3.app"`.

**The game shows a "MetalFX … could not continue" message and closes.** Please
[open an issue](https://github.com/AndrewTriesToCode/bg3mfx/issues) with the
message text, your Mac model, and what you were doing. In the meantime, choose
Off or AMD FSR 1.0 in Upscaling Type, or play from Steam as usual.

**"MetalFX Frame Generation is off."** Frame Generation couldn't handle the
game's frames, so it turned itself off. The game keeps running with your
Upscaling Type. Untick and tick MetalFX Frame Generation to try again. If it
keeps happening, please
[open an issue](https://github.com/AndrewTriesToCode/bg3mfx/issues) with the
message text.

**Check your setup without starting the game:** `bg3mfx --dry-run`.

## Disabling features

To turn off an upscaler, set **Upscaling Type** to **Off** in Options → Video.
Untick **MetalFX Frame Generation** or **Show Metal HUD** to turn off those
options.

The other features can be disabled with these environment variables. Set the
variable in the environment used to launch `bg3mfx`:

| Feature | Environment variable |
| --- | --- |
| **Shadow Rendering Optimizations** | `BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0` disables the feature. The vista experiment is off by default; enable it with `BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA=1`. |
| **Depth Prepass Optimization** | `BG3MFX_DEPTH_PREPASS_OPTIMIZATION=0` |
| **Render Thread Optimizations** | `BG3MFX_RENDER_THREAD_OPTIMIZATIONS=0` |
| **CPU Thread Idling** | `BG3MFX_CPU_THREAD_IDLING=0` |
| **Dynamic Worker Prioritization** | `BG3MFX_DYNAMIC_WORKER_PRIORITIZATION=0` |
| **Lua System Call Elimination** | `BG3MFX_LUA_SYSTEM_CALL_ELIMINATION=0` |

## Uninstall

```sh
brew uninstall bg3mfx
brew untap andrewtriestocode/brews
brew untrust --formula andrewtriestocode/brews/bg3mfx
rm -rf ~/Applications/"BG3MFX.app"   # if you ran install-app
```

## Building from source and contributing

See [docs/dev/development.md](docs/dev/development.md) for building, testing,
and releasing. Bug reports and pull requests are welcome.

## License and credits

BG3MFX is released under the [MIT License](LICENSE). It contains no game
files or assets, and downloading it doesn't give you the game: you need your own
copy of Baldur's Gate 3 from Steam.

Baldur's Gate 3 is a trademark of Larian Studios. Apple, Mac, Metal, MetalFX and
ProMotion are trademarks of Apple Inc.
