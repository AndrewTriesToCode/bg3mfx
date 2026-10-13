# BG3 MetalFX

Better image quality and up to 2x the frame rate for **Baldur's Gate 3 on Mac**,
using Apple MetalFX upscaling and frame generation.

It adds three new choices to the game's own **Upscaling Type** setting:

| Option | What it does |
| --- | --- |
| **MetalFX Spatial** | Sharp upscaling from a lower render resolution. Keeps the game's anti-aliasing setting. |
| **MetalFX Temporal** | Higher-quality upscaling that uses previous frames. Replaces the game's anti-aliasing. |
| **MetalFX Temporal + Frame Generation** | Temporal upscaling, plus an extra generated frame between each pair of rendered frames for smoother motion. |

It also adds a **Show Metal HUD** checkbox, Apple's on-screen performance overlay.

The game's original **Off** and **AMD FSR 1.0** options still work as before.
Nothing in your game folder is changed: BG3 MetalFX loads alongside the game
when you start it with BG3 MetalFX, and the game is untouched when you start it
from Steam as usual.

> **Unofficial and experimental.** BG3 MetalFX is a fan project, not affiliated
> with or endorsed by Larian Studios or Apple. Use it at your own risk. Your
> saves are not touched, but please keep backups as you would with any mod.

> **Built with AI assistance.** Much of BG3 MetalFX's code and documentation was
> written with an AI coding assistant (Claude by Anthropic), directed, reviewed
> and tested in the game by the author. It may still contain mistakes; please
> report anything that looks wrong.

## How it works

The `bg3mfx` launcher finds your Steam copy of the game, checks its version, and
starts it with the BG3 MetalFX library loaded. The library adds the menu
options and swaps the game's FSR upscaling step for Apple's MetalFX, using the
game's own depth, motion and camera data. For Frame Generation it generates an
in-between frame with MetalFX frame interpolation and paces it between the real
frames. Details are in the [developer documentation](docs/dev/development.md).

## Performance

16-inch MacBook Pro, M5 Pro (18-core CPU, 20-core GPU)  
ProMotion Retina Display  
macOS 27.0, Metal 4 MetalFX  
Ultra Preset, VSync off, Balanced Upscaling Quality  
Act 3, Lower City  

**Native Resolution, 3456x2160**

| Upscaling | FPS |
| --- | --- |
| Off | ~30 |
| AMD FSR 1.0 | ~51 |
| MetalFX Spatial | ~50 |
| MetalFX Temporal | ~45 |
| MetalFX Temporal + Frame Generation | ~70 |

**2x Scaled Resolution, 1728x1080**

| Upscaling | FPS |
| --- | --- |
| Off | ~58 |
| AMD FSR 1.0 | ~74 |
| MetalFX Spatial | ~76 |
| MetalFX Temporal | ~71 |
| MetalFX Temporal + Frame Generation | ~124 |

## Requirements

- A Mac with **Apple Silicon**. Frame Generation appears only on Macs that
  support MetalFX frame interpolation. So far BG3 MetalFX has been tested on an
  M5 Pro.
- **macOS 26 Tahoe** or later
- **Baldur's Gate 3 from Steam**, version **4.1.1.7631656**. Other versions have not been tested.
- [Homebrew](https://brew.sh)

## Install

```sh
brew update
brew trust --formula andrewtriestocode/brews/bg3mfx
brew install andrewtriestocode/brews/bg3mfx
```

Homebrew asks you to trust formulae from outside its official taps before it
will install them; the second command trusts only BG3 MetalFX. Homebrew then
builds BG3 MetalFX on your Mac, which takes a few seconds.

Want an app you can open from Launchpad, Spotlight or the Dock? Run this once:

```sh
bg3mfx install-app
```

This adds **BG3 MetalFX** to the Applications folder in your home folder.

## Play

Make sure Steam is running (BG3 MetalFX starts it if it isn't), then either:

- open **BG3 MetalFX** from your Applications folder, or
- run `bg3mfx` in Terminal.

Baldur's Gate 3 starts with MetalFX available. In the game, go to
**Options → Video → Upscaling Type** and pick a MetalFX option, then choose a
quality (Ultra Quality, Quality, Balanced or Performance). Your choice is
remembered.

**Play from your Steam library:** in Steam, choose
**Games → Add a Non-Steam Game to My Library…**, select **BG3 MetalFX**, and
optionally rename it to something like *Baldur's Gate 3 (MetalFX)*. The normal
Baldur's Gate 3 entry still starts the game without MetalFX.

## Tips

- **Frame Generation** works best on a high refresh rate display, such as a
  MacBook Pro's 120 Hz ProMotion screen, with **VSync on**. Set the game's
  FPS limiter to half the frame rate you want to see (for example, 60 on a
  120 Hz display).
- **MetalFX Temporal** turns off the game's own anti-aliasing option, because it
  does the anti-aliasing itself.
- Turn on **Show Metal HUD** (Options → Video → General) to see your frame rate.

## Troubleshooting

**"This version of Baldur's Gate 3 isn't supported yet."** The game was
updated. Run `brew upgrade` to get the latest BG3 MetalFX. If there isn't a
release for the new game version yet, play from Steam as usual in the meantime.

**"Baldur's Gate 3 wasn't found."** BG3 MetalFX looks in your Steam libraries.
If you opened the app, it lets you choose the game's location. In Terminal, use
`bg3mfx --game "/path/to/Baldur's Gate 3.app"`.

**The game shows a "MetalFX … could not continue" message and closes.** Please
[open an issue](https://github.com/AndrewTriesToCode/bg3mfx/issues) with the
message text, your Mac model, and what you were doing. In the meantime, choose
Off or AMD FSR 1.0 in Upscaling Type, or play from Steam as usual.

**Check your setup without starting the game:** `bg3mfx --dry-run`.

## Uninstall

```sh
brew uninstall bg3mfx
brew untap andrewtriestocode/brews
brew untrust --formula andrewtriestocode/brews/bg3mfx
rm -rf ~/Applications/"BG3 MetalFX.app"   # if you ran install-app
```

Baldur's Gate 3 itself was never modified. MetalFX modes use the game's FSR
resolution settings, so when you start the game from Steam it shows
**AMD FSR 1.0** with the same quality instead. BG3 MetalFX also keeps a few
settings in the game's preferences; to remove them:

```sh
defaults read com.larian.bg3 | grep BG3MFX    # list them
defaults delete com.larian.bg3 BG3MFXUpscalingType BG3MFXUpscalingQuality BG3MFXMetalHUD
```

## Building from source and contributing

See [docs/dev/development.md](docs/dev/development.md) for building, testing,
and releasing. Bug reports and pull requests are welcome.

## License and credits

BG3 MetalFX is released under the [MIT License](LICENSE). It contains no game
files or assets, and downloading it doesn't give you the game: you need your own
copy of Baldur's Gate 3 from Steam.

Baldur's Gate 3 is a trademark of Larian Studios. Apple, Mac, Metal, MetalFX and
ProMotion are trademarks of Apple Inc.
